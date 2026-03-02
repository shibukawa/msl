import Foundation
#if canImport(Virtualization)
import Virtualization
#endif

public struct MemoryBalloonRuntimeStats {
    public var allocatedBytes: UInt64
    public var maxBytes: UInt64
    public var returnedTotalBytes: UInt64

    public init(allocatedBytes: UInt64, maxBytes: UInt64, returnedTotalBytes: UInt64) {
        self.allocatedBytes = allocatedBytes
        self.maxBytes = maxBytes
        self.returnedTotalBytes = returnedTotalBytes
    }
}

public final class VirtualMachineRunner {
    private let paths: MSLPaths
    private let metadataURL: URL
    private let bootProfile: RuntimeBootProfile?
    private let logger: MSLLogger?
    private let initProbeHandler: ((InitChannelProbeResult) -> Void)?
    private var terminalBridge: TerminalBridge?
    private var diagnosticCollector: GuestDiagnosticLogCollector?
    private var acceptedVsockConnection: AnyObject?  // retain VZVirtioSocketConnection
    private var dnsTunnelListener: AnyObject?
    private var dnsTunnelListenerDelegate: AnyObject?
    private var memoryPlan: RuntimeMemoryPlan?

    #if canImport(Virtualization)
    private var runningVM: VZVirtualMachine?
    private var runningVMQueue: DispatchQueue?
    private var runningDelegate: VMDelegate?
    private var balloonDevice: VZVirtioTraditionalMemoryBalloonDevice?
    private var balloonCurrentTargetBytes: UInt64?
    private var balloonReturnedTotalBytes: UInt64 = 0
    private var balloonControllerTimer: DispatchSourceTimer?
    private let balloonControllerQueue = DispatchQueue(label: "msl.vm.balloon")
    #endif

    public init(
        paths: MSLPaths,
        metadataURL: URL,
        bootProfile: RuntimeBootProfile? = nil,
        logger: MSLLogger? = nil,
        initProbeHandler: ((InitChannelProbeResult) -> Void)? = nil
    ) {
        self.paths = paths
        self.metadataURL = metadataURL
        self.bootProfile = bootProfile
        self.logger = logger
        self.initProbeHandler = initProbeHandler
    }

    public func runAttachedConsole() throws -> Int32 {
        #if canImport(Virtualization)
        defer {
            diagnosticCollector?.stop()
            diagnosticCollector = nil
        }
        let runnerStartMs = monotonicMs()
        if !VZVirtualMachine.isSupported {
            throw MSLRuntimeError("virtualization is not supported on this host")
        }

        let metadataStartMs = monotonicMs()
        let metadata = try loadMetadata()
        logger?.log("vm_runner_metadata_loaded", fields: [
            "elapsed_ms": String(monotonicMs() - metadataStartMs)
        ])
        logStartupPhase(
            phase: "runtime_metadata_resolve",
            elapsedMs: monotonicMs() - metadataStartMs,
            instanceName: metadata.instanceName
        )
        let diskURL = metadata.diskURL
        if !FileManager.default.fileExists(atPath: diskURL.path) {
            throw MSLRuntimeError("vm disk not found at \(diskURL.path)")
        }

        let useSerialAttach = ProcessInfo.processInfo.environment["MSL_ATTACH_SERIAL"] == "1"
        var serialAttachment: (FileHandle, FileHandle)?
        if useSerialAttach {
            let bridge = TerminalBridge()
            self.terminalBridge = bridge
            serialAttachment = try bridge.makeSerialAttachment()
        } else {
            self.terminalBridge = nil
            // Always attach a serial port and capture output to a log file
            // so kernel boot, cloud-init, and msl-init logs are available.
            serialAttachment = try makeSerialLogAttachment()
        }
        let diagnosticAttachment = makeDiagnosticAttachment(instanceName: metadata.instanceName)
        let configStartMs = monotonicMs()
        let configuration = try buildConfiguration(
            diskURL: diskURL,
            machineIdentifierURL: metadata.machineIdentifierURL,
            efiVariableStoreURL: metadata.efiVariableStoreURL,
            serialAttachment: serialAttachment,
            diagnosticAttachment: diagnosticAttachment
        )
        logger?.log("vm_runner_configuration_built", fields: [
            "elapsed_ms": String(monotonicMs() - configStartMs)
        ])
        logStartupPhase(
            phase: "vm_configuration_build",
            elapsedMs: monotonicMs() - configStartMs,
            instanceName: metadata.instanceName
        )

        let vmQueue = DispatchQueue(label: "msl.vm.queue")
        let virtualMachine = VZVirtualMachine(configuration: configuration, queue: vmQueue)
        let delegate = VMDelegate()
        virtualMachine.delegate = delegate

        let startSemaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        let vmStartRequestMs = monotonicMs()
        vmQueue.async {
            virtualMachine.start { result in
                switch result {
                case .success:
                    startError = nil
                case .failure(let error):
                    startError = error
                }
                startSemaphore.signal()
            }
        }

        _ = startSemaphore.wait(timeout: .now() + .seconds(30))
        if let error = startError {
            throw MSLRuntimeError("failed to start VM: \(error.localizedDescription)")
        }
        let vmStartElapsedMs = monotonicMs() - vmStartRequestMs
        logger?.log("vm_runner_started", fields: [
            "elapsed_ms": String(vmStartElapsedMs)
        ])
        logStartupPhase(
            phase: "vm_start",
            elapsedMs: vmStartElapsedMs,
            instanceName: metadata.instanceName
        )
        applyInitialBalloonTarget(virtualMachine: virtualMachine, vmQueue: vmQueue)
        probeInitChannelShadowMode()

        if !useSerialAttach {
            return try runInitChannelAttach(
                virtualMachine: virtualMachine,
                vmQueue: vmQueue,
                delegate: delegate,
                runnerStartMs: runnerStartMs,
                instanceName: metadata.instanceName
            )
        }

        fputs("msl: VM started, attached to serial console (PTY)\n", stderr)
        guard let bridge = terminalBridge else {
            throw MSLRuntimeError("serial attach requested but terminal bridge is unavailable")
        }
        let sigwinchSource = DispatchSource.makeSignalSource(signal: SIGWINCH)
        signal(SIGWINCH, SIG_IGN)
        sigwinchSource.setEventHandler { [weak bridge] in
            _ = bridge?.syncWindowSize()
        }
        sigwinchSource.resume()

        let ioPumpStartMs = monotonicMs()
        let pumpResult = bridge.runIOPump(
            shouldContinue: { !delegate.didStop },
            onFirstOutput: { [weak self] in
                guard let self else { return }
                self.logger?.log("vm_runner_first_output", fields: [
                    "elapsed_ms": String(monotonicMs() - ioPumpStartMs)
                ])
            }
        )

        if pumpResult == .sessionEnded {
            vmQueue.async {
                if virtualMachine.canRequestStop {
                    do {
                        try virtualMachine.requestStop()
                    } catch {
                        fputs("msl: failed to request stop after session end: \(error.localizedDescription)\n", stderr)
                    }
                } else if virtualMachine.canStop {
                    virtualMachine.stop { _ in }
                }
            }
            fputs("msl: session ended; returning without waiting for full VM shutdown\n", stderr)
            logger?.log("vm_runner_attach_finished", fields: [
                "result": "session_ended",
                "elapsed_ms": String(monotonicMs() - runnerStartMs)
            ])
            return 0
        }

        if let stopError = delegate.stopError {
            fputs("msl: VM stopped with error: \(stopError.localizedDescription)\n", stderr)
            logger?.log("vm_runner_attach_finished", fields: [
                "result": "vm_error",
                "elapsed_ms": String(monotonicMs() - runnerStartMs)
            ])
            return 1
        }
        fputs("msl: VM stopped\n", stderr)
        logger?.log("vm_runner_attach_finished", fields: [
            "result": "vm_stopped",
            "elapsed_ms": String(monotonicMs() - runnerStartMs)
        ])
        return 0
        #else
        throw MSLRuntimeError("Virtualization.framework is unavailable in this build")
        #endif
    }

    #if canImport(Virtualization)
    private func loadMetadata() throws -> RuntimeInstanceMetadata {
        let data = try Data(contentsOf: metadataURL)
        let distribution = try JSONDecoder().decode(DistributionInstanceMetadata.self, from: data)
        let instanceDir = metadataURL.deletingLastPathComponent()
        return RuntimeInstanceMetadata(
            instanceName: distribution.name,
            diskURL: URL(fileURLWithPath: distribution.diskPath),
            machineIdentifierURL: instanceDir.appendingPathComponent("machine-identifier.bin", isDirectory: false),
            efiVariableStoreURL: instanceDir.appendingPathComponent("efi-variable-store", isDirectory: false)
        )
    }

    private func buildConfiguration(
        diskURL: URL,
        machineIdentifierURL: URL,
        efiVariableStoreURL: URL,
        serialAttachment: (FileHandle, FileHandle)?,
        diagnosticAttachment: (FileHandle, FileHandle)?
    ) throws -> VZVirtualMachineConfiguration {
        let vm = VZVirtualMachineConfiguration()

        if let bootProfile {
            vm.bootLoader = try buildLinuxBootLoader(profile: bootProfile)
        } else if let linuxBootLoader = try resolveLinuxBootLoaderIfRequested() {
            vm.bootLoader = linuxBootLoader
        } else {
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = try loadOrCreateVariableStore(efiVariableStoreURL: efiVariableStoreURL)
            vm.bootLoader = bootLoader
        }

        vm.platform = try buildPlatform(machineIdentifierURL: machineIdentifierURL)
        vm.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(4, VZVirtualMachineConfiguration.maximumAllowedCPUCount))

        let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxMem = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        let plan = RuntimeMemoryPlan.resolve(
            physicalMemoryBytes: UInt64(ProcessInfo.processInfo.physicalMemory),
            environment: ProcessInfo.processInfo.environment,
            minimumAllowedBytes: minMem,
            maximumAllowedBytes: maxMem
        )
        self.memoryPlan = plan
        vm.memorySize = plan.maxBytes
        logger?.log("memory_plan_resolved", fields: [
            "max_bytes": String(plan.maxBytes),
            "startup_bytes": String(plan.startupBytes),
            "headroom_bytes": String(plan.headroomBytes),
            "min_delta_bytes": String(plan.minDeltaBytes),
            "poll_sec": String(plan.pollIntervalSec)
        ])

        var serialPorts: [VZSerialPortConfiguration] = []
        if let serialAttachment {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: serialAttachment.0,
                fileHandleForWriting: serialAttachment.1
            )
            serialPorts.append(serial)
        }
        if let diagnosticAttachment {
            let diagnostic = VZVirtioConsoleDeviceSerialPortConfiguration()
            diagnostic.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: diagnosticAttachment.0,
                fileHandleForWriting: diagnosticAttachment.1
            )
            serialPorts.append(diagnostic)
        }
        vm.serialPorts = serialPorts

        let nat = VZNATNetworkDeviceAttachment()
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = nat
        vm.networkDevices = [network]

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        vm.storageDevices = [blockDevice]

        if #available(macOS 12.0, *) {
            let hostShareRoot = ProcessInfo.processInfo.environment["MSL_HOST_SHARE_ROOT"].flatMap { $0.isEmpty ? nil : $0 } ?? "/"
            let hostShare = VZSharedDirectory(url: URL(fileURLWithPath: hostShareRoot), readOnly: false)
            let hostDevice = VZVirtioFileSystemDeviceConfiguration(tag: "macos")
            hostDevice.share = VZSingleDirectoryShare(directory: hostShare)
            vm.directorySharingDevices = [hostDevice]
        } else {
            throw MSLRuntimeError("shared directory requires macOS 12 or later")
        }

        vm.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vm.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        vm.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        try vm.validate()
        return vm
    }

    private func resolveLinuxBootLoaderIfRequested() throws -> VZLinuxBootLoader? {
        let env = ProcessInfo.processInfo.environment
        let envKernelRaw = env["MSL_KERNEL_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kernelIDRaw = (envKernelRaw?.isEmpty == false ? envKernelRaw : nil) ?? "slim"

        let kernelDir = paths.kernelsDir.appendingPathComponent(kernelIDRaw, isDirectory: true)
        let kernelURL = kernelDir.appendingPathComponent("vmlinuz", isDirectory: false)
        guard FileManager.default.fileExists(atPath: kernelURL.path) else {
            throw MSLRuntimeError("Step6 kernel not found at \(kernelURL.path) (MSL_KERNEL_PROFILE=\(kernelIDRaw))")
        }
        if isGzipKernelImage(kernelURL) {
            throw MSLRuntimeError(
                "kernel image is gzip-compressed and cannot be used for direct boot: \(kernelURL.path). " +
                "stage an uncompressed kernel image (arm64: arch/arm64/boot/Image) as vmlinuz."
            )
        }

        let loader = VZLinuxBootLoader(kernelURL: kernelURL)
        let defaultRoot = env["MSL_KERNEL_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/dev/vda"
        let cmdline = env["MSL_KERNEL_CMDLINE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cmdline, !cmdline.isEmpty {
            loader.commandLine = cmdline
        } else {
            loader.commandLine = "root=\(defaultRoot) rw console=hvc0"
        }

        logger?.log("kernel_profile_selected", fields: [
            "kernel_id": kernelIDRaw,
            "kernel_path": kernelURL.path
        ])
        return loader
    }

    private func buildLinuxBootLoader(profile: RuntimeBootProfile) throws -> VZLinuxBootLoader {
        guard FileManager.default.fileExists(atPath: profile.kernelURL.path) else {
            throw MSLRuntimeError("Step6 kernel not found: \(profile.kernelURL.path)")
        }
        if isGzipKernelImage(profile.kernelURL) {
            throw MSLRuntimeError(
                "kernel image is gzip-compressed and cannot be used for direct boot: \(profile.kernelURL.path). " +
                "stage an uncompressed kernel image (arm64: arch/arm64/boot/Image) as vmlinuz."
            )
        }
        let loader = VZLinuxBootLoader(kernelURL: profile.kernelURL)
        loader.commandLine = profile.commandLine
        logger?.log("linux_bootloader_selected", fields: [
            "instance": profile.instanceName,
            "kernel_id": profile.kernelID,
            "kernel_path": profile.kernelURL.path
        ])
        return loader
    }

    private func isGzipKernelImage(_ kernelURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: kernelURL) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 2), header.count == 2 else {
            return false
        }
        return header[0] == 0x1f && header[1] == 0x8b
    }

    private func buildPlatform(machineIdentifierURL: URL) throws -> VZGenericPlatformConfiguration {
        let platform = VZGenericPlatformConfiguration()

        if let data = try? Data(contentsOf: machineIdentifierURL),
           let machineID = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = machineID
            return platform
        }

        let newID = VZGenericMachineIdentifier()
        try newID.dataRepresentation.write(to: machineIdentifierURL, options: .atomic)
        platform.machineIdentifier = newID
        return platform
    }

    private func loadOrCreateVariableStore(efiVariableStoreURL: URL) throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: efiVariableStoreURL.path) {
            return VZEFIVariableStore(url: efiVariableStoreURL)
        }

        return try VZEFIVariableStore(
            creatingVariableStoreAt: efiVariableStoreURL,
            options: []
        )
    }
    #endif

    /// Start the VM for daemon mode: boot, wait for vsock, return InitChannelClient.
    /// The VM and vsock connection are retained on the instance.
    /// Call `stopRunningVM()` to clean up.
    public func startVMForDaemon() throws -> InitChannelClient {
        #if canImport(Virtualization)
        if !VZVirtualMachine.isSupported {
            throw MSLRuntimeError("virtualization is not supported on this host")
        }

        let daemonStartMs = monotonicMs()
        let metadataStartMs = monotonicMs()
        let metadata = try loadMetadata()
        logStartupPhase(
            phase: "runtime_metadata_resolve",
            elapsedMs: monotonicMs() - metadataStartMs,
            instanceName: metadata.instanceName
        )
        let diskURL = metadata.diskURL
        if !FileManager.default.fileExists(atPath: diskURL.path) {
            throw MSLRuntimeError("vm disk not found at \(diskURL.path)")
        }

        // Always log serial output in daemon mode
        let serialAttachment = try makeSerialLogAttachment()
        let diagnosticAttachment = makeDiagnosticAttachment(instanceName: metadata.instanceName)
        let configStartMs = monotonicMs()
        let configuration = try buildConfiguration(
            diskURL: diskURL,
            machineIdentifierURL: metadata.machineIdentifierURL,
            efiVariableStoreURL: metadata.efiVariableStoreURL,
            serialAttachment: serialAttachment,
            diagnosticAttachment: diagnosticAttachment
        )
        logStartupPhase(
            phase: "vm_configuration_build",
            elapsedMs: monotonicMs() - configStartMs,
            instanceName: metadata.instanceName
        )

        let vmQueue = DispatchQueue(label: "msl.vm.queue")
        let virtualMachine = VZVirtualMachine(configuration: configuration, queue: vmQueue)
        let delegate = VMDelegate()
        virtualMachine.delegate = delegate

        let startSemaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        let vmStartRequestMs = monotonicMs()
        vmQueue.async {
            virtualMachine.start { result in
                switch result {
                case .success: startError = nil
                case .failure(let error): startError = error
                }
                startSemaphore.signal()
            }
        }

        _ = startSemaphore.wait(timeout: .now() + .seconds(30))
        if let error = startError {
            throw MSLRuntimeError("failed to start VM: \(error.localizedDescription)")
        }
        logStartupPhase(
            phase: "vm_start",
            elapsedMs: monotonicMs() - vmStartRequestMs,
            instanceName: metadata.instanceName
        )
        logger?.log("vm_daemon_started")
        applyInitialBalloonTarget(virtualMachine: virtualMachine, vmQueue: vmQueue)

        // Wait for vsock connection from msl-init
        guard let vsockDevice = virtualMachine.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
            throw MSLRuntimeError("no VZVirtioSocketDevice found on VM")
        }
        let listener = VZVirtioSocketListener()
        let listenerDelegate = VsockListenerDelegate()
        listener.delegate = listenerDelegate
        let dnsTunnelListener = VZVirtioSocketListener()
        let dnsTunnelDelegate = DNSTunnelListenerDelegate { [weak self] fd in
            self?.handleDNSTunnelRequest(fd: fd)
        }
        dnsTunnelListener.delegate = dnsTunnelDelegate
        vmQueue.async {
            vsockDevice.setSocketListener(listener, forPort: 1024)
            vsockDevice.setSocketListener(dnsTunnelListener, forPort: 1053)
        }

        let timeoutSec = resolveInitAttachTimeoutSec()
        let handshakeStartMs = monotonicMs()
        let vsockFD = try waitForInitChannel(
            listenerDelegate: listenerDelegate,
            timeoutSec: timeoutSec
        )
        logStartupPhase(
            phase: "init_handshake_wait",
            elapsedMs: monotonicMs() - handshakeStartMs,
            instanceName: metadata.instanceName
        )

        let client = InitChannelClient(
            socketPath: paths.initChannelSocketFile.path,
            handoffPath: paths.initChannelHandoffFile.path,
            ackPath: paths.initChannelAckFile.path,
            retryCount: 2,
            retryDelayMs: 50,
            timeoutMs: 400,
            vsockFD: vsockFD
        )

        let ping = try client.ping()
        if !ping.ok {
            throw MSLRuntimeError("init channel ping failed after vsock accept")
        }
        logger?.log("vm_daemon_init_ready", fields: [
            "requestId": ping.requestId
        ])
        logStartupPhase(
            phase: "first_shell_attach_ready",
            elapsedMs: monotonicMs() - daemonStartMs,
            instanceName: metadata.instanceName
        )
        logStartupTotal(elapsedMs: monotonicMs() - daemonStartMs, instanceName: metadata.instanceName)

        // Store references to keep VM alive
        self.runningVM = virtualMachine
        self.runningVMQueue = vmQueue
        self.runningDelegate = delegate
        self.dnsTunnelListener = dnsTunnelListener
        self.dnsTunnelListenerDelegate = dnsTunnelDelegate
        startBalloonController(client: client)

        return client
        #else
        throw MSLRuntimeError("Virtualization.framework is unavailable in this build")
        #endif
    }

    /// Stop a VM previously started via `startVMForDaemon()`.
    public func stopRunningVM() {
        #if canImport(Virtualization)
        stopBalloonController()
        guard let vm = runningVM, let queue = runningVMQueue else { return }
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            if vm.canRequestStop {
                do {
                    try vm.requestStop()
                } catch {
                    fputs("msl: daemon requestStop failed: \(error.localizedDescription)\n", stderr)
                    if vm.canStop {
                        vm.stop { _ in }
                    }
                }
            } else if vm.canStop {
                vm.stop { _ in }
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + .seconds(5))
        self.runningVM = nil
        self.runningVMQueue = nil
        self.runningDelegate = nil
        self.acceptedVsockConnection = nil
        self.dnsTunnelListener = nil
        self.dnsTunnelListenerDelegate = nil
        self.balloonDevice = nil
        self.balloonCurrentTargetBytes = nil
        self.balloonReturnedTotalBytes = 0
        self.diagnosticCollector?.stop()
        self.diagnosticCollector = nil
        logger?.log("vm_daemon_stopped")
        #endif
    }

    /// Check if the VM (started via daemon mode) has stopped unexpectedly.
    public var isDaemonVMStopped: Bool {
        #if canImport(Virtualization)
        return runningDelegate?.didStop ?? true
        #else
        return true
        #endif
    }

    public func memoryBalloonRuntimeStats() -> MemoryBalloonRuntimeStats? {
        #if canImport(Virtualization)
        guard let plan = memoryPlan else {
            return nil
        }
        return balloonControllerQueue.sync {
            let allocated = balloonCurrentTargetBytes ?? plan.maxBytes
            return MemoryBalloonRuntimeStats(
                allocatedBytes: allocated,
                maxBytes: plan.maxBytes,
                returnedTotalBytes: balloonReturnedTotalBytes
            )
        }
        #else
        return nil
        #endif
    }

    private func applyInitialBalloonTarget(
        virtualMachine: VZVirtualMachine,
        vmQueue: DispatchQueue
    ) {
        guard let plan = memoryPlan else {
            return
        }
        guard let device = virtualMachine.memoryBalloonDevices.compactMap({ $0 as? VZVirtioTraditionalMemoryBalloonDevice }).first else {
            logger?.log("memory_balloon_initial_target_requested", fields: [
                "result": "skipped_no_balloon_device"
            ])
            return
        }

        let target = plan.startupBytes
        let sem = DispatchSemaphore(value: 0)
        vmQueue.async {
            device.targetVirtualMachineMemorySize = target
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + .seconds(2))

        if plan.maxBytes > target {
            recordReturnedBytes(plan.maxBytes - target)
        }
        balloonDevice = device
        balloonCurrentTargetBytes = target
        logger?.log("memory_balloon_initial_target_requested", fields: [
            "target_bytes": String(target),
            "max_bytes": String(plan.maxBytes)
        ])
    }

    private func startBalloonController(client: InitChannelClient) {
        stopBalloonController()
        guard let plan = memoryPlan else {
            return
        }
        guard balloonDevice != nil else {
            logger?.log("memory_balloon_controller_started", fields: [
                "result": "skipped_no_balloon_device"
            ])
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: balloonControllerQueue)
        timer.schedule(deadline: .now() + .seconds(plan.pollIntervalSec), repeating: .seconds(plan.pollIntervalSec))
        timer.setEventHandler { [weak self] in
            self?.sampleAndAdjustBalloonTarget(client: client, plan: plan)
        }
        timer.resume()
        balloonControllerTimer = timer

        logger?.log("memory_balloon_controller_started", fields: [
            "poll_sec": String(plan.pollIntervalSec),
            "headroom_bytes": String(plan.headroomBytes),
            "min_delta_bytes": String(plan.minDeltaBytes)
        ])
    }

    private func stopBalloonController() {
        balloonControllerTimer?.cancel()
        balloonControllerTimer = nil
        logger?.log("memory_balloon_controller_stopped")
    }

    private func sampleAndAdjustBalloonTarget(
        client: InitChannelClient,
        plan: RuntimeMemoryPlan
    ) {
        guard runningVM != nil, let vmQueue = runningVMQueue, let device = balloonDevice else {
            return
        }

        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/proc/meminfo"],
                timeoutMs: 1_500
            ))
            guard response.ok else {
                logger?.log("memory_balloon_sample_failed", fields: [
                    "reason": response.error?.message ?? "exec_failed"
                ])
                return
            }
            guard let stdout = response.stdout, let snapshot = LinuxMemInfoSnapshot.parse(stdout) else {
                logger?.log("memory_balloon_sample_failed", fields: [
                    "reason": "invalid_meminfo"
                ])
                return
            }

            let currentTarget = balloonCurrentTargetBytes ?? device.targetVirtualMachineMemorySize
            let desired = plan.desiredTargetBytes(snapshot: snapshot, currentTargetBytes: currentTarget)
            guard desired != currentTarget else {
                return
            }

            vmQueue.async {
                device.targetVirtualMachineMemorySize = desired
            }
            if currentTarget > desired {
                recordReturnedBytes(currentTarget - desired)
            }
            balloonCurrentTargetBytes = desired

            logger?.log("memory_balloon_target_updated", fields: [
                "from_bytes": String(currentTarget),
                "to_bytes": String(desired),
                "mem_total_bytes": String(snapshot.memTotalBytes),
                "mem_available_bytes": String(snapshot.memAvailableBytes)
            ])
        } catch {
            logger?.log("memory_balloon_sample_failed", fields: [
                "reason": String(describing: error)
            ])
        }
    }

    private func recordReturnedBytes(_ delta: UInt64) {
        let added = balloonReturnedTotalBytes.addingReportingOverflow(delta)
        balloonReturnedTotalBytes = added.overflow ? UInt64.max : added.partialValue
    }

    private func handleDNSTunnelRequest(fd: Int32) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
        }
        guard let header = readExact(handle: handle, count: 4), header.count == 4 else {
            return
        }
        let length = Int(header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard length > 0, length <= 64 * 1024,
              let body = readExact(handle: handle, count: length),
              let request = try? JSONDecoder().decode(DNSTunnelRequest.self, from: body) else {
            return
        }

        let answers = resolveHostAddresses(name: request.qname, qtype: request.qtype)
        let response = DNSTunnelResponse(ok: true, answers: answers, error: nil)
        guard let encoded = try? JSONEncoder().encode(response) else {
            return
        }
        var len = UInt32(encoded.count).bigEndian
        let lenData = Data(bytes: &len, count: 4)
        do {
            try handle.write(contentsOf: lenData)
            try handle.write(contentsOf: encoded)
        } catch {
            logger?.log("dns_tunnel_write_failed", fields: ["error": String(describing: error)])
        }
    }

    private func readExact(handle: FileHandle, count: Int) -> Data? {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            guard let chunk = try? handle.read(upToCount: count - out.count),
                  !chunk.isEmpty else {
                return nil
            }
            out.append(chunk)
        }
        return out
    }

    private func resolveHostAddresses(name: String, qtype: Int) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(name, nil, &hints, &result)
        guard code == 0, let head = result else {
            logger?.log("dns_tunnel_resolve_failed", fields: [
                "qname": name,
                "qtype": String(qtype),
                "error": String(cString: gai_strerror(code))
            ])
            return []
        }
        defer { freeaddrinfo(head) }

        var seen = Set<String>()
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let entry = cursor?.pointee {
            if qtype == 1, entry.ai_family == AF_INET {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.ai_addr, entry.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if seen.insert(value).inserted {
                        out.append(value)
                    }
                }
            } else if qtype == 28, entry.ai_family == AF_INET6 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.ai_addr, entry.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if seen.insert(value).inserted {
                        out.append(value)
                    }
                }
            }
            cursor = entry.ai_next
        }
        return out
    }

    private func runInitChannelAttach(
        virtualMachine: VZVirtualMachine,
        vmQueue: DispatchQueue,
        delegate: VMDelegate,
        runnerStartMs: Int64,
        instanceName: String
    ) throws -> Int32 {
        fputs("msl: VM started, attaching via msl-init control channel (vsock)\n", stderr)

        // Set up vsock listener — guest msl-init will connect to us
        guard let vsockDevice = virtualMachine.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
            throw MSLRuntimeError("no VZVirtioSocketDevice found on VM")
        }
        let listener = VZVirtioSocketListener()
        let listenerDelegate = VsockListenerDelegate()
        listener.delegate = listenerDelegate
        vmQueue.async {
            vsockDevice.setSocketListener(listener, forPort: 1024)
        }

        let timeoutSec = resolveInitAttachTimeoutSec()
        let handshakeStartMs = monotonicMs()
        let vsockFD = try waitForInitChannel(
            listenerDelegate: listenerDelegate,
            timeoutSec: timeoutSec
        )
        logStartupPhase(
            phase: "init_handshake_wait",
            elapsedMs: monotonicMs() - handshakeStartMs,
            instanceName: instanceName
        )

        let client = InitChannelClient(
            socketPath: paths.initChannelSocketFile.path,
            handoffPath: paths.initChannelHandoffFile.path,
            ackPath: paths.initChannelAckFile.path,
            retryCount: 2,
            retryDelayMs: 50,
            timeoutMs: 400,
            vsockFD: vsockFD
        )

        // Verify the connection with a ping
        let ping = try client.ping()
        if !ping.ok {
            throw MSLRuntimeError("init channel ping failed after vsock accept")
        }
        logger?.log("init_heartbeat_ok", fields: [
            "requestId": ping.requestId,
            "op": ping.op,
            "mode": "attach_ready"
        ])
        logStartupPhase(
            phase: "first_shell_attach_ready",
            elapsedMs: monotonicMs() - runnerStartMs,
            instanceName: instanceName
        )
        logStartupTotal(elapsedMs: monotonicMs() - runnerStartMs, instanceName: instanceName)

        let bridge = InitAttachBridge()
        let ioPumpStartMs = monotonicMs()
        let exitCode = try bridge.run(
            client: client,
            logger: logger,
            shouldContinue: { !delegate.didStop },
            onFirstOutput: { [weak self] in
                guard let self else { return }
                self.logger?.log("vm_runner_first_output", fields: [
                    "elapsed_ms": String(monotonicMs() - ioPumpStartMs)
                ])
            }
        )

        vmQueue.async {
            if virtualMachine.canRequestStop {
                do {
                    try virtualMachine.requestStop()
                } catch {
                    fputs("msl: failed to request stop after init attach exit: \(error.localizedDescription)\n", stderr)
                }
            } else if virtualMachine.canStop {
                virtualMachine.stop { _ in }
            }
        }

        logger?.log("vm_runner_attach_finished", fields: [
            "result": "init_channel_exit",
            "elapsed_ms": String(monotonicMs() - runnerStartMs)
        ])
        return exitCode
    }

    private func waitForInitChannel(
        listenerDelegate: VsockListenerDelegate,
        timeoutSec: Int
    ) throws -> Int32 {
        fputs("msl: waiting for msl-init vsock connection (timeout \(timeoutSec)s)\n", stderr)
        logger?.log("init_handshake_wait_started", fields: [
            "transport": "vsock_listener",
            "timeout_sec": String(timeoutSec)
        ])

        let waitResult = listenerDelegate.semaphore.wait(timeout: .now() + .seconds(timeoutSec))
        if waitResult == .timedOut {
            logger?.log("init_handshake_timeout", fields: [
                "timeout_sec": String(timeoutSec),
                "serial_log": paths.serialConsoleLogFile.path
            ])
            throw MSLRuntimeError(
                "init channel did not connect within \(timeoutSec)s; " +
                "verify direct-init path (e.g. `init=/sbin/msl-init`) and inspect serial log at \(paths.serialConsoleLogFile.path)"
            )
        }

        guard let connection = listenerDelegate.acceptedConnection else {
            throw MSLRuntimeError("init channel accept signaled but no connection available")
        }

        let fd = connection.fileDescriptor
        // Retain the connection object so the fd stays valid
        self.acceptedVsockConnection = connection
        fputs("msl: msl-init connected via vsock (fd=\(fd))\n", stderr)
        logger?.log("init_vsock_accepted", fields: [
            "fd": String(fd)
        ])
        logger?.log("init_handshake_ready", fields: ["fd": String(fd)])
        return fd
    }

    private func resolveInitAttachTimeoutSec() -> Int {
        if let raw = ProcessInfo.processInfo.environment["MSL_INIT_ATTACH_TIMEOUT_SEC"],
           let value = Int(raw), value > 0 {
            return max(10, min(value, 600))
        }
        return 30
    }

    private func logStartupPhase(phase: String, elapsedMs: Int64, instanceName: String) {
        logger?.log("startup_phase_duration_ms", fields: [
            "phase": phase,
            "elapsed_ms": String(max(0, elapsedMs)),
            "instance": instanceName
        ])
    }

    private func logStartupTotal(elapsedMs: Int64, instanceName: String) {
        logger?.log("startup_total_duration_ms", fields: [
            "elapsed_ms": String(max(0, elapsedMs)),
            "instance": instanceName
        ])
    }

    private var serialLogThread: Thread?
    private var serialLogReadFD: Int32 = -1

    private func makeDiagnosticAttachment(instanceName: String) -> (FileHandle, FileHandle)? {
        do {
            let collector = GuestDiagnosticLogCollector(paths: paths, instanceName: instanceName, logger: logger)
            let attachment = try collector.makeSerialAttachment()
            self.diagnosticCollector = collector
            return attachment
        } catch {
            logger?.log("guest_log_forwarder_error", fields: ["error": String(describing: error)])
            return nil
        }
    }

    private func makeSerialLogAttachment() throws -> (FileHandle, FileHandle) {
        var outMaster: Int32 = -1
        var outSlave: Int32 = -1
        if openpty(&outMaster, &outSlave, nil, nil, nil) != 0 {
            throw MSLRuntimeError("failed to allocate serial log PTY: \(String(cString: strerror(errno)))")
        }
        serialLogReadFD = outMaster

        let logURL = paths.serialConsoleLogFile
        // Truncate/create the log file for this boot.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logger?.log("serial_console_log_started", fields: ["path": logURL.path])

        let masterFD = outMaster
        let thread = Thread {
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }

            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(masterFD, &buffer, buffer.count)
                if n <= 0 { break }
                let data = Data(buffer[..<n])
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    break
                }
            }
        }
        thread.name = "msl.serial.log"
        thread.start()
        serialLogThread = thread

        let readHandle = FileHandle(fileDescriptor: outSlave, closeOnDealloc: false)
        let writeHandle = FileHandle(fileDescriptor: outSlave, closeOnDealloc: false)
        return (readHandle, writeHandle)
    }

    private func probeInitChannelShadowMode() {
        // In serial-attach mode, try a quick ping to check if msl-init is already running.
        // This is best-effort and expected to fail on first boot.
        if ProcessInfo.processInfo.environment["MSL_INIT_CHANNEL_ENABLE"] == "0" {
            return
        }
        logger?.log("init_started")
        let client = InitChannelClient(
            socketPath: paths.initChannelSocketFile.path,
            retryCount: 1,
            retryDelayMs: 50,
            timeoutMs: 500
        )
        do {
            let ping = try client.ping()
            logger?.log("init_heartbeat_ok", fields: [
                "requestId": ping.requestId,
                "op": ping.op
            ])

            let converge = try client.convergeStatus()
            logger?.log("init_convergence_status", fields: [
                "requestId": converge.requestId,
                "status": converge.status
            ])
            initProbeHandler?(InitChannelProbeResult(
                version: ping.version,
                status: .ok,
                errorCode: nil,
                errorMessage: nil
            ))
        } catch {
            logger?.log("init_heartbeat_failed", fields: ["error": String(describing: error)])
            logger?.log("init_channel_unavailable", fields: ["error": String(describing: error)])
            initProbeHandler?(InitChannelProbeResult(
                version: nil,
                status: .failed,
                errorCode: InitChannelErrorCode.unavailable.rawValue,
                errorMessage: String(describing: error)
            ))
        }
    }
}

private func monotonicMs() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}

private struct RuntimeInstanceMetadata {
    var instanceName: String
    var diskURL: URL
    var machineIdentifierURL: URL
    var efiVariableStoreURL: URL
}

#if canImport(Virtualization)
private final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    var didStop = false
    var stopError: Error?

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        didStop = true
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        stopError = error
        didStop = true
    }
}

/// Accepts the first inbound vsock connection from the guest (msl-init).
/// The accepted connection signals that msl-init is ready.
private final class VsockListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    var acceptedConnection: VZVirtioSocketConnection?
    let semaphore = DispatchSemaphore(value: 0)

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if acceptedConnection == nil {
            acceptedConnection = connection
            semaphore.signal()
        }
        return true
    }
}

private struct DNSTunnelRequest: Codable {
    var qname: String
    var qtype: Int
}

private struct DNSTunnelResponse: Codable {
    var ok: Bool
    var answers: [String]
    var error: String?
}

private final class DNSTunnelListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    private let onAccept: (Int32) -> Void

    init(onAccept: @escaping (Int32) -> Void) {
        self.onAccept = onAccept
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let retained: AnyObject = connection
        DispatchQueue.global(qos: .userInitiated).async {
            self.onAccept(connection.fileDescriptor)
            _ = retained
        }
        return true
    }
}
#endif

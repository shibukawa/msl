import Foundation
#if canImport(Virtualization)
import Virtualization
#endif
#if canImport(vmnet)
import vmnet
#endif
import Darwin

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
    private let codeOpenRequestHandler: ((String) -> Void)?
    private let backgroundMemoryMaintenanceAllowed: (() -> Bool)?
    private let startupPhaseObserver: ((String) -> Void)?
    private let networkMode: EffectiveNetworkMode
    private let networkTopologyOverride: VMNetNetworkTopology?
    private var terminalBridge: TerminalBridge?
    private var diagnosticCollector: GuestDiagnosticLogCollector?
    private var acceptedVsockConnection: AnyObject?  // retain VZVirtioSocketConnection
    private var initVsockListener: AnyObject?
    private var initVsockListenerDelegate: AnyObject?
    private var dnsTunnelListener: AnyObject?
    private var dnsTunnelListenerDelegate: AnyObject?
    private var timeTunnelListener: AnyObject?
    private var timeTunnelListenerDelegate: AnyObject?
    private var codeOpenListener: AnyObject?
    private var codeOpenListenerDelegate: AnyObject?
    private var memoryPlan: RuntimeMemoryPlan?
    public private(set) var activeNetworkTopology: VMNetNetworkTopology?

    #if canImport(Virtualization)
    private var runningVM: VZVirtualMachine?
    private var runningVMQueue: DispatchQueue?
    private var runningDelegate: VMDelegate?
    private var balloonDevice: VZVirtioTraditionalMemoryBalloonDevice?
    private var balloonCurrentTargetBytes: UInt64?
    private var balloonReturnedTotalBytes: UInt64 = 0
    private var balloonControllerTimer: DispatchSourceTimer?
    private let balloonControllerQueue = DispatchQueue(label: "msl.vm.balloon")
    #if canImport(vmnet)
    private var retainedVMNetNetwork: vmnet_network_ref?
    #endif
    #endif

    public init(
        paths: MSLPaths,
        metadataURL: URL,
        bootProfile: RuntimeBootProfile? = nil,
        logger: MSLLogger? = nil,
        initProbeHandler: ((InitChannelProbeResult) -> Void)? = nil,
        codeOpenRequestHandler: ((String) -> Void)? = nil,
        backgroundMemoryMaintenanceAllowed: (() -> Bool)? = nil,
        startupPhaseObserver: ((String) -> Void)? = nil,
        networkMode: EffectiveNetworkMode = .vmnetShared,
        networkTopologyOverride: VMNetNetworkTopology? = nil
    ) {
        self.paths = paths
        self.metadataURL = metadataURL
        self.bootProfile = bootProfile
        self.logger = logger
        self.initProbeHandler = initProbeHandler
        self.codeOpenRequestHandler = codeOpenRequestHandler
        self.backgroundMemoryMaintenanceAllowed = backgroundMemoryMaintenanceAllowed
        self.startupPhaseObserver = startupPhaseObserver
        self.networkMode = networkMode
        self.networkTopologyOverride = networkTopologyOverride
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
        if let stateDiskURL = metadata.stateDiskURL,
           !FileManager.default.fileExists(atPath: stateDiskURL.path) {
            throw MSLRuntimeError("vm state disk not found at \(stateDiskURL.path); reinstall or rebuild the instance writable state image")
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
            // so kernel boot and msl-init logs are available.
            serialAttachment = try makeSerialLogAttachment()
        }
        let diagnosticAttachment = makeDiagnosticAttachment(instanceName: metadata.instanceName)
        let configStartMs = monotonicMs()
        let configuration = try buildConfiguration(
            instanceName: metadata.instanceName,
            diskURL: diskURL,
            diskReadOnly: metadata.rootMode == .readonlyBaseCowState,
            stateDiskURL: metadata.stateDiskURL,
            machineIdentifierURL: metadata.machineIdentifierURL,
            efiVariableStoreURL: metadata.efiVariableStoreURL,
            serialAttachment: serialAttachment,
            diagnosticAttachment: diagnosticAttachment,
            extraWritableDisks: metadata.extraWritableDiskURLs()
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
                instanceName: metadata.instanceName,
                metadata: metadata
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
        let tmpStorage = try distribution.resolveValidatedTmpStoragePolicy()
        let rootMode = distribution.resolvedRootMode()
        let stateDiskURL: URL?
        if rootMode == .readonlyBaseCowState {
            guard let stateDiskPath = distribution.stateDiskPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !stateDiskPath.isEmpty else {
                throw MSLRuntimeError("instance '\(distribution.name)' rootMode=readonly-base-cow-state is missing stateDiskPath")
            }
            stateDiskURL = URL(fileURLWithPath: stateDiskPath)
        } else {
            stateDiskURL = nil
        }
        let ephemeralTmpDiskURL: URL?
        let ephemeralTmpDevicePath: String?
        let ephemeralTmpLabel: String?
        if tmpStorage.mode == "ephemeral" {
            let tmpLabel = sanitizeTmpStorageLabel(instanceName: distribution.name)
            ephemeralTmpDiskURL = try prepareEphemeralTmpDisk(
                instanceName: distribution.name,
                sizeMiB: tmpStorage.sizeMiB,
                label: tmpLabel
            )
            ephemeralTmpDevicePath = rootMode == .readonlyBaseCowState ? "/dev/vdc" : "/dev/vdb"
            ephemeralTmpLabel = tmpLabel
        } else {
            ephemeralTmpDiskURL = nil
            ephemeralTmpDevicePath = nil
            ephemeralTmpLabel = nil
        }
        logger?.log("tmp_storage_mode_resolved", fields: [
            "instance": distribution.name,
            "mode": tmpStorage.mode,
            "size_mib": String(tmpStorage.sizeMiB),
            "reset_on_stop": tmpStorage.resetOnStop ? "true" : "false"
        ])
        return RuntimeInstanceMetadata(
            instanceName: distribution.name,
            diskURL: URL(fileURLWithPath: distribution.baseDiskPath ?? distribution.diskPath),
            rootMode: rootMode,
            stateDiskURL: stateDiskURL,
            machineIdentifierURL: instanceDir.appendingPathComponent("machine-identifier.bin", isDirectory: false),
            efiVariableStoreURL: instanceDir.appendingPathComponent("efi-variable-store", isDirectory: false),
            tmpStorage: tmpStorage,
            ephemeralTmpDiskURL: ephemeralTmpDiskURL,
            ephemeralTmpDevicePath: ephemeralTmpDevicePath,
            ephemeralTmpLabel: ephemeralTmpLabel
        )
    }

    private func prepareEphemeralTmpDisk(instanceName: String, sizeMiB: Int, label: String) throws -> URL {
        let fileManager = FileManager.default
        let tmpDir = paths.distroTmpDirectory(named: instanceName)
        try fileManager.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let diskURL = paths.distroEphemeralTmpDiskFile(named: instanceName)
        if fileManager.fileExists(atPath: diskURL.path) {
            try fileManager.removeItem(at: diskURL)
        }

        guard let mkfsHelper = resolveExt4MkfsHelperExecutable() else {
            throw MSLRuntimeError(
                "tmp ext4 mkfs helper not found; expected staged helper at \(paths.mslHostExt4MkfsHelperBinaryFile.path)"
            )
        }
        let result = try runHostProcess(mkfsHelper, [
            "--output", diskURL.path,
            "--size-mb", String(sizeMiB),
            "--label", label
        ], captureOutput: true)
        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw MSLRuntimeError("tmp ext4 mkfs helper failed (\(result.exitCode)): \(detail)")
        }
        logger?.log("tmp_image_created", fields: [
            "instance": instanceName,
            "path": diskURL.path,
            "size_mib": String(sizeMiB)
        ])
        return diskURL
    }

    private func sanitizeTmpStorageLabel(instanceName: String) -> String {
        let mapped = instanceName.lowercased().map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                return ch
            }
            return "-"
        }
        return "msl-\(String(mapped))-tmp"
    }

    private func resolveExt4MkfsHelperExecutable() -> String? {
        let fileManager = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment["MSL_EXT4_MKFS_HELPER_PATH"],
           !explicit.isEmpty,
           fileManager.isExecutableFile(atPath: explicit) {
            return explicit
        }
        let staged = paths.mslHostExt4MkfsHelperBinaryFile.path
        if fileManager.isExecutableFile(atPath: staged) {
            return staged
        }
        return findExecutable(["msl-ext4-mkfs"])
    }

    private func runHostProcess(
        _ executable: String,
        _ arguments: [String],
        captureOutput: Bool = false
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var outPipe: Pipe?
        var errPipe: Pipe?
        if captureOutput {
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            outPipe = stdoutPipe
            errPipe = stderrPipe
        }

        var stdoutData = Data()
        var stderrData = Data()
        let readGroup = DispatchGroup()
        if let outPipe, let errPipe {
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
        }

        do {
            try process.run()
        } catch {
            if captureOutput {
                outPipe?.fileHandleForWriting.closeFile()
                errPipe?.fileHandleForWriting.closeFile()
                readGroup.wait()
            }
            throw MSLRuntimeError("failed to execute \(executable): \(error)")
        }

        if captureOutput {
            outPipe?.fileHandleForWriting.closeFile()
            errPipe?.fileHandleForWriting.closeFile()
        }
        process.waitUntilExit()
        if captureOutput {
            readGroup.wait()
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func findExecutable(_ names: [String]) -> String? {
        for name in names {
            if name.contains("/") {
                if FileManager.default.isExecutableFile(atPath: name) {
                    return name
                }
                continue
            }
            let result = try? runHostProcess("/usr/bin/env", ["which", name], captureOutput: true)
            if let result, result.exitCode == 0 {
                let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return nil
    }

    private func buildConfiguration(
        instanceName: String,
        diskURL: URL,
        diskReadOnly: Bool,
        stateDiskURL: URL?,
        machineIdentifierURL: URL,
        efiVariableStoreURL: URL,
        serialAttachment: (FileHandle, FileHandle)?,
        diagnosticAttachment: (FileHandle, FileHandle)?,
        extraWritableDisks: [URL]
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

        let network = VZVirtioNetworkDeviceConfiguration()
        switch networkMode {
        case .nat:
            network.attachment = VZNATNetworkDeviceAttachment()
            activeNetworkTopology = nil
        case .vmnetShared:
            if #available(macOS 26.0, *) {
                let vmnetAttachment = try buildVMNetAttachment(instanceName: instanceName)
                network.attachment = vmnetAttachment.attachment
                network.macAddress = vmnetAttachment.macAddress
                activeNetworkTopology = vmnetAttachment.topology
                #if canImport(vmnet)
                retainedVMNetNetwork = vmnetAttachment.retainedNetwork
                #endif
            } else {
                throw MSLRuntimeError("vmnet networking requires macOS 26 or later")
            }
        }
        vm.networkDevices = [network]

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: diskReadOnly)
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        var storageDevices: [VZStorageDeviceConfiguration] = [blockDevice]
        if let stateDiskURL {
            let stateAttachment = try VZDiskImageStorageDeviceAttachment(url: stateDiskURL, readOnly: false)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: stateAttachment))
        }
        for extraDiskURL in extraWritableDisks {
            let extraAttachment = try VZDiskImageStorageDeviceAttachment(url: extraDiskURL, readOnly: false)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: extraAttachment))
        }
        vm.storageDevices = storageDevices

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

    #if canImport(vmnet)
    @available(macOS 26.0, *)
    private func buildVMNetAttachment(instanceName: String) throws -> (
        attachment: VZVmnetNetworkDeviceAttachment,
        macAddress: VZMACAddress,
        topology: VMNetNetworkTopology,
        retainedNetwork: vmnet_network_ref
    ) {
        let topology = networkTopologyOverride ?? NetworkIdentity.vmnetTopology(for: instanceName)
        guard var subnetAddress = parseIPv4Address(topology.subnetIPv4),
              var subnetMask = parseIPv4Address(topology.subnetMaskIPv4),
              var reservedGuestAddress = parseIPv4Address(topology.guestIPv4) else {
            throw MSLRuntimeError("vmnet topology generation produced an invalid IPv4 address")
        }

        guard let macAddress = VZMACAddress(string: topology.guestMACAddress) else {
            throw MSLRuntimeError("invalid vmnet MAC address: \(topology.guestMACAddress)")
        }

        var status = vmnet_return_t(rawValue: 1000)!
        guard let configuration = vmnet_network_configuration_create(operating_modes_t(rawValue: 1001)!, &status) else {
            throw MSLRuntimeError("failed to create vmnet network configuration: \(describeVMNetStatus(status))")
        }
        defer { releaseVMNetObject(configuration) }

        let subnetStatus = vmnet_network_configuration_set_ipv4_subnet(configuration, &subnetAddress, &subnetMask)
        guard subnetStatus.rawValue == 1000 else {
            throw MSLRuntimeError("failed to configure vmnet IPv4 subnet: \(describeVMNetStatus(subnetStatus))")
        }

        var ethernetAddress = macAddress.ethernetAddress
        let reservationStatus = vmnet_network_configuration_add_dhcp_reservation(configuration, &ethernetAddress, &reservedGuestAddress)
        guard reservationStatus.rawValue == 1000 else {
            throw MSLRuntimeError("failed to reserve vmnet DHCP address: \(describeVMNetStatus(reservationStatus))")
        }

        guard let network = vmnet_network_create(configuration, &status) else {
            throw MSLRuntimeError("failed to create vmnet network: \(describeVMNetStatus(status))")
        }

        let attachment = VZVmnetNetworkDeviceAttachment(network: network)
        logger?.log("vmnet_network_created", fields: [
            "instance": instanceName,
            "subnet_ipv4": topology.subnetIPv4,
            "subnet_mask_ipv4": topology.subnetMaskIPv4,
            "host_ipv4": topology.hostIPv4,
            "guest_ipv4": topology.guestIPv4,
            "guest_mac": topology.guestMACAddress
        ])
        return (attachment, macAddress, topology, network)
    }

    private func parseIPv4Address(_ value: String) -> in_addr? {
        var address = in_addr()
        let result = value.withCString {
            inet_pton(AF_INET, $0, &address)
        }
        return result == 1 ? address : nil
    }

    private func releaseVMNetObject(_ object: OpaquePointer) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(object)).release()
    }

    private func describeVMNetStatus(_ status: vmnet_return_t) -> String {
        switch Int(status.rawValue) {
        case 1000: return "success"
        case 1001: return "failure"
        case 1002: return "memory_or_authorization_failure"
        case 1003: return "invalid_argument"
        case 1004: return "setup_incomplete"
        case 1005: return "invalid_access"
        case 1006: return "packet_too_big"
        case 1007: return "buffer_exhausted"
        case 1008: return "too_many_packets"
        case 1009: return "sharing_service_busy"
        case 1010: return "not_authorized"
        default: return "status_\(status.rawValue)"
        }
    }
    #endif

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

    private func initBinaryData() throws -> Data {
        guard let data = FileManager.default.contents(atPath: paths.mslHostInitBinaryFile.path) else {
            throw MSLRuntimeError("staged msl-init binary not found at \(paths.mslHostInitBinaryFile.path)")
        }
        return data
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

    private func performBootloaderTransfer(
        listenerDelegate: VsockListenerDelegate,
        timeoutSec: Int,
        metadata: RuntimeInstanceMetadata
    ) throws {
        let connection = try acquireInitVsockConnection(
            listenerDelegate: listenerDelegate,
            timeoutSec: timeoutSec,
            role: "bootloader"
        )
        guard connection.hello.role == "bootloader",
              let initMode = connection.hello.initMode else {
            throw MSLRuntimeError("invalid bootloader hello role: \(connection.hello.role)")
        }

        let payload = try initBinaryData()
        let hostEpochMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let hostTimeZoneID = TimeZone.current.identifier
        var metadataRecords: [MSLInitBootTransferProtocol.MetadataRecord] = [
            .init(
                targetKind: .bootloader,
                flags: MSLInitBootTransferProtocol.requiredFlag,
                entry: "clock.epoch_ms=\(hostEpochMs)"
            ),
            .init(
                targetKind: .execEnv,
                flags: 0,
                entry: "TZ=\(hostTimeZoneID)"
            )
        ]
        metadataRecords.append(contentsOf: ephemeralTmpMetadataRecords(metadata: metadata))
        let metadata = try MSLInitBootTransferProtocol.encodeMetadataBlock(records: metadataRecords)

        logger?.log("init_bootloader_hello_received", fields: [
            "version": connection.hello.version,
            "init_mode": initMode,
            "payload_size": String(payload.count)
        ])

        try writeAll(fd: connection.fd, data: metadata)
        logger?.log("init_bootloader_metadata_sent", fields: [
            "metadata_version": String(MSLInitBootTransferProtocol.metadataVersion),
            "record_count": String(metadataRecords.count)
        ])
        for record in metadataRecords {
            logger?.log("init_bootloader_metadata_record_sent", fields: [
                "target_kind": String(record.targetKind.rawValue),
                "flags": String(record.flags),
                "entry": record.entry
            ])
        }
        try writeAll(fd: connection.fd, data: payload)
        if shutdown(connection.fd, SHUT_WR) != 0 {
            let err = String(cString: strerror(errno))
            logger?.log("init_bootloader_shutdown_failed", fields: [
                "error": err
            ])
        } else {
            logger?.log("init_bootloader_write_shutdown", fields: [:])
        }

        logger?.log("init_bootloader_transfer_completed", fields: [
            "payload_size": String(payload.count),
            "metadata_version": String(MSLInitBootTransferProtocol.metadataVersion),
            "record_count": String(metadataRecords.count)
        ])
    }

    private func ephemeralTmpMetadataRecords(
        metadata: RuntimeInstanceMetadata
    ) -> [MSLInitBootTransferProtocol.MetadataRecord] {
        guard metadata.tmpStorage.mode == "ephemeral",
              let devicePath = metadata.ephemeralTmpDevicePath else {
            return []
        }
        var records: [MSLInitBootTransferProtocol.MetadataRecord] = [
            .init(targetKind: .execEnv, flags: 0, entry: "MSL_EPHEMERAL_TMP_MODE=ephemeral"),
            .init(targetKind: .execEnv, flags: 0, entry: "MSL_EPHEMERAL_TMP_DEVICE=\(devicePath)"),
            .init(targetKind: .execEnv, flags: 0, entry: "MSL_EPHEMERAL_TMP_SIZE_MIB=\(metadata.tmpStorage.sizeMiB)"),
            .init(
                targetKind: .execEnv,
                flags: 0,
                entry: "MSL_EPHEMERAL_TMP_RESET_ON_STOP=\(metadata.tmpStorage.resetOnStop ? "true" : "false")"
            )
        ]
        if let label = metadata.ephemeralTmpLabel, !label.isEmpty {
            records.append(.init(targetKind: .execEnv, flags: 0, entry: "MSL_EPHEMERAL_TMP_LABEL=\(label)"))
        }
        return records
    }

    private func readBootProtocolLine(fd: Int32, timeoutSec: Int) throws -> String {
        var bytes: [UInt8] = []
        let deadlineMs = monotonicMs() + Int64(timeoutSec * 1000)
        while monotonicMs() < deadlineMs {
            let remainingMs = max(1, Int(deadlineMs - monotonicMs()))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pfd, 1, Int32(remainingMs))
            if pollResult == 0 {
                throw MSLRuntimeError("boot protocol read timed out")
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw MSLRuntimeError("boot protocol poll failed: \(String(cString: strerror(errno)))")
            }
            var ch: UInt8 = 0
            let rc = Darwin.read(fd, &ch, 1)
            if rc == 1 {
                if ch == 0x0a {
                    return String(decoding: bytes, as: UTF8.self)
                }
                bytes.append(ch)
                if bytes.count > 4096 {
                    throw MSLRuntimeError("boot protocol line exceeded maximum length")
                }
                continue
            }
            if rc == 0 {
                break
            }
            let err = errno
            if err == EINTR {
                continue
            }
            throw MSLRuntimeError("boot protocol read failed: \(String(cString: strerror(err)))")
        }
        throw MSLRuntimeError("boot protocol read timed out")
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            var written = 0
            while written < data.count {
                let rc = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
                if rc > 0 {
                    written += rc
                    continue
                }
                let err = errno
                if err == EINTR {
                    continue
                }
                throw MSLRuntimeError("boot protocol write failed: \(String(cString: strerror(err)))")
            }
        }
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
        if let stateDiskURL = metadata.stateDiskURL,
           !FileManager.default.fileExists(atPath: stateDiskURL.path) {
            throw MSLRuntimeError("vm state disk not found at \(stateDiskURL.path); reinstall or rebuild the instance writable state image")
        }

        // Always log serial output in daemon mode
        let serialAttachment = try makeSerialLogAttachment()
        let diagnosticAttachment = makeDiagnosticAttachment(instanceName: metadata.instanceName)
        let configStartMs = monotonicMs()
        let configuration = try buildConfiguration(
            instanceName: metadata.instanceName,
            diskURL: diskURL,
            diskReadOnly: metadata.rootMode == .readonlyBaseCowState,
            stateDiskURL: metadata.stateDiskURL,
            machineIdentifierURL: metadata.machineIdentifierURL,
            efiVariableStoreURL: metadata.efiVariableStoreURL,
            serialAttachment: serialAttachment,
            diagnosticAttachment: diagnosticAttachment,
            extraWritableDisks: metadata.extraWritableDiskURLs()
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

        // Wait for bootloader/init vsock connections from the guest.
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
        let timeTunnelListener = VZVirtioSocketListener()
        let timeTunnelDelegate = DNSTunnelListenerDelegate { [weak self] fd in
            self?.handleTimeTunnelRequest(fd: fd)
        }
        timeTunnelListener.delegate = timeTunnelDelegate
        let codeOpenListener = VZVirtioSocketListener()
        let codeOpenDelegate = DNSTunnelListenerDelegate { [weak self] fd in
            self?.handleCodeOpenRequest(fd: fd)
        }
        codeOpenListener.delegate = codeOpenDelegate
        vmQueue.async {
            vsockDevice.setSocketListener(listener, forPort: 1024)
            vsockDevice.setSocketListener(dnsTunnelListener, forPort: 1053)
            vsockDevice.setSocketListener(timeTunnelListener, forPort: 1067)
            vsockDevice.setSocketListener(codeOpenListener, forPort: 5001)
        }

        let timeoutSec = resolveInitAttachTimeoutSec()
        let transferStartMs = monotonicMs()
        try performBootloaderTransfer(
            listenerDelegate: listenerDelegate,
            timeoutSec: timeoutSec,
            metadata: metadata
        )
        logStartupPhase(
            phase: "init_bootloader_transfer",
            elapsedMs: monotonicMs() - transferStartMs,
            instanceName: metadata.instanceName
        )

        let handshakeStartMs = monotonicMs()
        let (client, ping) = try makeVerifiedInitChannelClient(
            listenerDelegate: listenerDelegate,
            timeoutSec: timeoutSec,
            instanceName: metadata.instanceName
        )
        logStartupPhase(
            phase: "init_handshake_wait",
            elapsedMs: monotonicMs() - handshakeStartMs,
            instanceName: metadata.instanceName
        )
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
        self.initVsockListener = listener
        self.initVsockListenerDelegate = listenerDelegate
        self.dnsTunnelListener = dnsTunnelListener
        self.dnsTunnelListenerDelegate = dnsTunnelDelegate
        self.timeTunnelListener = timeTunnelListener
        self.timeTunnelListenerDelegate = timeTunnelDelegate
        self.codeOpenListener = codeOpenListener
        self.codeOpenListenerDelegate = codeOpenDelegate
        startBalloonController(client: client)

        return client
        #else
        throw MSLRuntimeError("Virtualization.framework is unavailable in this build")
        #endif
    }

    /// Stop a VM previously started via `startVMForDaemon()`.
    public func requestStopRunningVM() {
        #if canImport(Virtualization)
        stopBalloonController()
        guard let vm = runningVM, let queue = runningVMQueue else { return }
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
        }
        #endif
    }

    public func stopRunningVM() {
        #if canImport(Virtualization)
        stopBalloonController()
        guard let vm = runningVM, let queue = runningVMQueue, let delegate = runningDelegate else {
            clearRunningVMReferences()
            return
        }
        let requestSem = DispatchSemaphore(value: 0)
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
            requestSem.signal()
        }
        _ = requestSem.wait(timeout: .now() + .seconds(2))
        if !waitForRunningVMStop(delegate: delegate, timeoutMs: 5_000) {
            let forceSem = DispatchSemaphore(value: 0)
            queue.async {
                if vm.canStop {
                    vm.stop { _ in forceSem.signal() }
                } else {
                    forceSem.signal()
                }
            }
            _ = forceSem.wait(timeout: .now() + .seconds(5))
        }
        clearRunningVMReferences()
        logger?.log("vm_daemon_stopped")
        #endif
    }

    #if canImport(Virtualization)
    private func waitForRunningVMStop(delegate: VMDelegate, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        while Date() < deadline {
            if delegate.didStop {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return delegate.didStop
    }
    #endif

    private func clearRunningVMReferences() {
        self.runningVM = nil
        self.runningVMQueue = nil
        self.runningDelegate = nil
        self.acceptedVsockConnection = nil
        self.initVsockListener = nil
        self.initVsockListenerDelegate = nil
        self.dnsTunnelListener = nil
        self.dnsTunnelListenerDelegate = nil
        self.timeTunnelListener = nil
        self.timeTunnelListenerDelegate = nil
        self.codeOpenListener = nil
        self.codeOpenListenerDelegate = nil
        self.balloonDevice = nil
        self.balloonCurrentTargetBytes = nil
        self.balloonReturnedTotalBytes = 0
        activeNetworkTopology = nil
        #if canImport(vmnet)
        if let network = retainedVMNetNetwork {
            releaseVMNetObject(network)
            retainedVMNetNetwork = nil
        }
        #endif
        self.diagnosticCollector?.stop()
        self.diagnosticCollector = nil
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
        if let backgroundMemoryMaintenanceAllowed, backgroundMemoryMaintenanceAllowed() == false {
            return
        }
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
        let length = Int(readBigEndianU32(header))
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

    private func handleTimeTunnelRequest(fd: Int32) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
        }
        guard let header = readExact(handle: handle, count: 4), header.count == 4 else {
            return
        }
        let length = Int(readBigEndianU32(header))
        guard length > 0, length <= 16 * 1024,
              let body = readExact(handle: handle, count: length),
              (try? JSONDecoder().decode(TimeTunnelRequest.self, from: body)) != nil else {
            return
        }

        let unixMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let response = TimeTunnelResponse(ok: true, unixMs: unixMs, error: nil)
        guard let encoded = try? JSONEncoder().encode(response) else {
            return
        }
        var len = UInt32(encoded.count).bigEndian
        let lenData = Data(bytes: &len, count: 4)
        do {
            try handle.write(contentsOf: lenData)
            try handle.write(contentsOf: encoded)
        } catch {
            logger?.log("time_tunnel_write_failed", fields: ["error": String(describing: error)])
        }
    }

    private func readBigEndianU32(_ data: Data) -> UInt32 {
        precondition(data.count >= 4)
        return (UInt32(data[data.startIndex]) << 24)
            | (UInt32(data[data.startIndex + 1]) << 16)
            | (UInt32(data[data.startIndex + 2]) << 8)
            | UInt32(data[data.startIndex + 3])
    }

    private func handleCodeOpenRequest(fd: Int32) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return
        }
        guard var payload = String(data: data, encoding: .utf8) else {
            logger?.log("code_open_read_failed", fields: ["error": "payload_not_utf8"])
            return
        }
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return
        }
        codeOpenRequestHandler?(payload)
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
        instanceName: String,
        metadata: RuntimeInstanceMetadata
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
        let transferStartMs = monotonicMs()
        try performBootloaderTransfer(
            listenerDelegate: listenerDelegate,
            timeoutSec: timeoutSec,
            metadata: metadata
        )
        logStartupPhase(
            phase: "init_bootloader_transfer",
            elapsedMs: monotonicMs() - transferStartMs,
            instanceName: instanceName
        )

        let handshakeStartMs = monotonicMs()
        let (client, ping) = try makeVerifiedInitChannelClient(
            listenerDelegate: listenerDelegate,
            timeoutSec: timeoutSec,
            instanceName: instanceName
        )
        logStartupPhase(
            phase: "init_handshake_wait",
            elapsedMs: monotonicMs() - handshakeStartMs,
            instanceName: instanceName
        )

        // Verify the connection with a ping
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
        timeoutSec: Int,
        role: String = "control"
    ) throws -> InitChannelClient.SidebandConnection {
        let accepted = try acquireInitVsockConnection(listenerDelegate: listenerDelegate, timeoutSec: timeoutSec, role: role)
        return (fd: accepted.fd, retainedConnection: accepted.retainedConnection)
    }

    private func acquireInitVsockConnection(
        listenerDelegate: VsockListenerDelegate,
        timeoutSec: Int,
        role: String
    ) throws -> AcceptedInitVsockConnection {
        let initMode = bootProfile?.initMode ?? "direct-init"
        let serviceManager = bootProfile?.serviceManager ?? "-"
        let checkCommand = initHandshakeCheckCommand()

        if shouldEmitInitHandshakeStderrLogs() {
            fputs("msl: waiting for guest init vsock connection (role \(role), timeout \(timeoutSec)s)\n", stderr)
        }
        logger?.log("init_handshake_wait_started", fields: [
            "transport": "vsock_listener",
            "timeout_sec": String(timeoutSec),
            "init_mode": initMode,
            "service_manager": serviceManager
        ])

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        while Date() < deadline {
            let remaining = max(1, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            if let accepted = listenerDelegate.takeAcceptedConnection(role: role) {
                return accepted
            }
            guard let connection = listenerDelegate.takeConnection(timeoutSec: remaining) else {
                break
            }
            let line = try readBootProtocolLine(fd: connection.fileDescriptor, timeoutSec: remaining)
            guard let hello = MSLInitBootTransferProtocol.parseHelloLine(line) else {
                logger?.log("init_vsock_role_discarded", fields: [
                    "requested_role": role,
                    "reason": "invalid_hello",
                    "line": line
                ])
                continue
            }
            let accepted = AcceptedInitVsockConnection(
                fd: {
                    let duplicated = dup(connection.fileDescriptor)
                    guard duplicated >= 0 else {
                        logger?.log("init_vsock_fd_dup_failed", fields: [
                            "role": hello.role,
                            "errno": String(errno)
                        ])
                        return -1
                    }
                    return duplicated
                }(),
                retainedConnection: connection,
                hello: hello
            )
            guard accepted.fd >= 0 else {
                continue
            }
            logger?.log("init_vsock_role_received", fields: [
                "role": hello.role,
                "detail": hello.detail ?? "",
                "version": hello.version
            ])
            if hello.role == role {
                if role == "control" {
                    self.acceptedVsockConnection = connection
                }
                if shouldEmitInitHandshakeStderrLogs() {
                    fputs("msl: guest init connected via vsock (role \(role), fd=\(connection.fileDescriptor))\n", stderr)
                }
                logger?.log("init_vsock_connection_assigned", fields: [
                    "fd": String(connection.fileDescriptor),
                    "role": role
                ])
                logger?.log("init_service_ready", fields: [
                    "fd": String(connection.fileDescriptor),
                    "role": role,
                    "init_mode": initMode,
                    "service_manager": serviceManager
                ])
                logger?.log("init_handshake_ready", fields: [
                    "fd": String(connection.fileDescriptor),
                    "init_mode": initMode,
                    "service_manager": serviceManager
                ])
                return accepted
            }
            listenerDelegate.storeAcceptedConnection(accepted)
            logger?.log("init_vsock_role_queued", fields: [
                "requested_role": role,
                "received_role": hello.role,
                "detail": hello.detail ?? ""
            ])
        }

        logger?.log("init_handshake_timeout", fields: [
            "timeout_sec": String(timeoutSec),
            "serial_log": paths.serialConsoleLogFile.path,
            "init_mode": initMode,
            "service_manager": serviceManager,
            "check_command": checkCommand,
            "requested_role": role
        ])
        throw MSLRuntimeError(
            "init channel did not connect within \(timeoutSec)s; " +
            "requested_role=\(role), init_mode=\(initMode), service_manager=\(serviceManager). " +
            "check guest service with `\(checkCommand)` and inspect serial log at \(paths.serialConsoleLogFile.path)"
        )
    }

    private func shouldEmitInitHandshakeStderrLogs() -> Bool {
        ProcessInfo.processInfo.environment["MSL_DEBUG_INIT_HANDSHAKE"]?.isEmpty == false
    }

    private func makeVerifiedInitChannelClient(
        listenerDelegate: VsockListenerDelegate,
        timeoutSec: Int,
        instanceName: String
    ) throws -> (InitChannelClient, InitChannelResponse) {
        var lastError: Error?
        for attempt in 1...2 {
            let controlConnection = try waitForInitChannel(
                listenerDelegate: listenerDelegate,
                timeoutSec: timeoutSec,
                role: "control"
            )
            let client = InitChannelClient(
                socketPath: paths.initChannelSocketFile.path,
                handoffPath: paths.initChannelHandoffFile.path,
                ackPath: paths.initChannelAckFile.path,
                retryCount: 2,
                retryDelayMs: 50,
                timeoutMs: 400,
                vsockFD: controlConnection.fd,
                retainedVsockConnection: controlConnection.retainedConnection,
                sidebandConnector: { [weak listenerDelegate, weak self] in
                    guard let self, let listenerDelegate else {
                        throw MSLRuntimeError("init vsock broker unavailable")
                    }
                    let accepted = try self.acquireInitVsockConnection(
                        listenerDelegate: listenerDelegate,
                        timeoutSec: timeoutSec,
                        role: "sideband"
                    )
                    return (fd: accepted.fd, retainedConnection: accepted.retainedConnection)
                },
                sidebandSupported: true,
                allowStreamingOnVsock: false,
                traceLogger: { [weak logger] event, fields in
                    logger?.log(event, fields: fields)
                }
            )
            do {
                let ping = try client.ping()
                if !ping.ok {
                    throw MSLRuntimeError("init channel ping failed after vsock accept")
                }
                if attempt > 1 {
                    logger?.log("init_handshake_retry_succeeded", fields: [
                        "instance": instanceName,
                        "attempt": String(attempt)
                    ])
                }
                return (client, ping)
            } catch {
                lastError = error
                if attempt >= 2 {
                    break
                }
                acceptedVsockConnection = nil
                logger?.log("init_handshake_retry_after_ping_failure", fields: [
                    "instance": instanceName,
                    "attempt": String(attempt),
                    "error": String(describing: error)
                ])
            }
        }

        throw lastError ?? MSLRuntimeError("init channel ping failed after vsock accept")
    }

    private func initHandshakeCheckCommand() -> String {
        if bootProfile?.initMode == "service-managed-init" {
            switch bootProfile?.serviceManager {
            case "systemd":
                return "systemctl status msl-init.service --no-pager"
            case "openrc":
                return "rc-service msl-init status"
            default:
                return "ps -o pid,comm -p 1"
            }
        }
        return "cat /proc/cmdline"
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
        startupPhaseObserver?(phase)
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
    var rootMode: DistributionInstanceMetadata.RootMode
    var stateDiskURL: URL?
    var machineIdentifierURL: URL
    var efiVariableStoreURL: URL
    var tmpStorage: DistributionInstanceMetadata.TmpStoragePolicy
    var ephemeralTmpDiskURL: URL?
    var ephemeralTmpDevicePath: String?
    var ephemeralTmpLabel: String?

    func extraWritableDiskURLs() -> [URL] {
        var urls: [URL] = []
        if let ephemeralTmpDiskURL {
            urls.append(ephemeralTmpDiskURL)
        }
        return urls
    }
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
private struct AcceptedInitVsockConnection {
    var fd: Int32
    var retainedConnection: AnyObject?
    var hello: MSLInitBootTransferProtocol.Hello
}

private final class VsockListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var pendingConnections: [VZVirtioSocketConnection] = []
    private var acceptedConnectionsByRole: [String: [AcceptedInitVsockConnection]] = [:]

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        lock.lock()
        pendingConnections.append(connection)
        lock.unlock()
        semaphore.signal()
        return true
    }

    func takeConnection(timeoutSec: Int) -> VZVirtioSocketConnection? {
        let waitResult = semaphore.wait(timeout: .now() + .seconds(timeoutSec))
        guard waitResult != .timedOut else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return pendingConnections.isEmpty ? nil : pendingConnections.removeFirst()
    }

    func storeAcceptedConnection(_ connection: AcceptedInitVsockConnection) {
        lock.lock()
        acceptedConnectionsByRole[connection.hello.role, default: []].append(connection)
        lock.unlock()
    }

    func takeAcceptedConnection(role: String) -> AcceptedInitVsockConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard var connections = acceptedConnectionsByRole[role], !connections.isEmpty else {
            return nil
        }
        let accepted = connections.removeFirst()
        if connections.isEmpty {
            acceptedConnectionsByRole.removeValue(forKey: role)
        } else {
            acceptedConnectionsByRole[role] = connections
        }
        return accepted
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

private struct TimeTunnelRequest: Codable {
    var op: String?
}

private struct TimeTunnelResponse: Codable {
    var ok: Bool
    var unixMs: Int64
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

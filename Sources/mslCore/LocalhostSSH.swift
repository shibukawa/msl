import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public struct LocalhostSSHInfo: Codable, Equatable {
    public var instanceName: String
    public var alias: String
    public var host: String
    public var port: Int
    public var user: String
    public var sharedConfigPath: String
    public var configPath: String
    public var identityFile: String
    public var knownHostsFile: String
}

private struct LocalhostSSHInstanceState: Codable, Equatable {
    var port: Int
}

struct LocalhostSSHListenerHandle {
    let info: LocalhostSSHInfo
    let server: LocalhostSSHServer
}

final class LocalhostSSHManager {
    private let paths: MSLPaths
    private let lock: FileLock
    private let store: StateStore
    private let logger: MSLLogger
    private let fileManager: FileManager
    private let executablePath: String
    private let process = ProcessExecutor()

    init(
        paths: MSLPaths,
        lock: FileLock,
        store: StateStore,
        logger: MSLLogger,
        executablePath: String,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.lock = lock
        self.store = store
        self.logger = logger
        self.fileManager = fileManager
        self.executablePath = executablePath
    }

    func info(instanceName: String, requestedPort: Int?) throws -> LocalhostSSHInfo {
        try ensureDirectories()
        let alias = sshHostAlias(forInstance: instanceName)
        let hostKey = try loadOrCreateHostKey()
        let port = try resolvePort(instanceName: instanceName, requestedPort: requestedPort)
        let identityFile = try ensureClientKeyPair(instanceName: instanceName)
        let knownHostsFile = try writeKnownHosts(instanceName: instanceName, hostKey: hostKey, port: port)
        let configFile = try writeConfig(
            instanceName: instanceName,
            alias: alias,
            port: port,
            identityFile: identityFile,
            knownHostsFile: knownHostsFile
        )
        let sharedConfigFile = try writeSharedConfig()

        return LocalhostSSHInfo(
            instanceName: instanceName,
            alias: alias,
            host: "127.0.0.1",
            port: port,
            user: NSUserName(),
            sharedConfigPath: sharedConfigFile.path,
            configPath: configFile.path,
            identityFile: identityFile.path,
            knownHostsFile: knownHostsFile.path
        )
    }

    func start(instanceName: String, requestedPort: Int?, runtimeUser: String) throws -> LocalhostSSHListenerHandle {
        let initialInfo = try info(instanceName: instanceName, requestedPort: requestedPort)
        let server = try LocalhostSSHServer(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: executablePath,
            instanceName: instanceName,
            requestedPort: requestedPort ?? initialInfo.port,
            hostPrivateKey: try loadOrCreateHostKey(),
            authorizedClientKey: try loadClientPublicKey(instanceName: instanceName),
            runtimeUser: runtimeUser
        )
        let actualPort = try server.start()
        let finalInfo = try info(instanceName: instanceName, requestedPort: actualPort)
        if actualPort != initialInfo.port {
            logger.log("ssh_facade_port_updated", fields: [
                "instance": instanceName,
                "port": String(actualPort)
            ])
        }
        return LocalhostSSHListenerHandle(info: finalInfo, server: server)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: paths.sshDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.sshInstancesDir, withIntermediateDirectories: true)
    }

    private func resolvePort(instanceName: String, requestedPort: Int?) throws -> Int {
        if let requestedPort {
            guard requestedPort == 0 || (1...65535).contains(requestedPort) else {
                throw MSLRuntimeError("invalid ssh port \(requestedPort)")
            }
            try saveState(.init(port: requestedPort), instanceName: instanceName)
            return requestedPort
        }
        if let state = try loadState(instanceName: instanceName) {
            return state.port
        }
        let port = defaultPort(forInstance: instanceName)
        try saveState(.init(port: port), instanceName: instanceName)
        return port
    }

    private func loadState(instanceName: String) throws -> LocalhostSSHInstanceState? {
        let url = paths.sshInstanceStateFile(named: instanceName)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LocalhostSSHInstanceState.self, from: data)
    }

    private func saveState(_ state: LocalhostSSHInstanceState, instanceName: String) throws {
        let dir = paths.sshInstanceDirectory(named: instanceName)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: paths.sshInstanceStateFile(named: instanceName), options: .atomic)
    }

    private func loadOrCreateHostKey() throws -> Curve25519.Signing.PrivateKey {
        if fileManager.fileExists(atPath: paths.sshHostKeyFile.path) {
            let data = try Data(contentsOf: paths.sshHostKeyFile)
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.write(to: paths.sshHostKeyFile, options: .atomic)
        try chmod0600(paths.sshHostKeyFile.path)
        return key
    }

    private func ensureClientKeyPair(instanceName: String) throws -> URL {
        let instanceDir = paths.sshInstanceDirectory(named: instanceName)
        try fileManager.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let privateKeyFile = paths.sshInstanceClientPrivateKeyFile(named: instanceName)
        let publicKeyFile = paths.sshInstanceClientPublicKeyFile(named: instanceName)
        if fileManager.fileExists(atPath: privateKeyFile.path), fileManager.fileExists(atPath: publicKeyFile.path) {
            return privateKeyFile
        }
        guard let sshKeygen = process.findExecutable(["ssh-keygen"]) else {
            throw MSLRuntimeError("ssh-keygen not found")
        }
        if fileManager.fileExists(atPath: privateKeyFile.path) {
            try fileManager.removeItem(at: privateKeyFile)
        }
        if fileManager.fileExists(atPath: publicKeyFile.path) {
            try fileManager.removeItem(at: publicKeyFile)
        }
        let result = try process.run(
            sshKeygen,
            ["-q", "-t", "ed25519", "-N", "", "-f", privateKeyFile.path, "-C", "msl-\(instanceName)"],
            captureOutput: true
        )
        guard result.exitCode == 0 else {
            throw MSLRuntimeError("ssh-keygen failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try chmod0600(privateKeyFile.path)
        return privateKeyFile
    }

    private func loadClientPublicKey(instanceName: String) throws -> NIOSSHPublicKey {
        let publicKeyFile = paths.sshInstanceClientPublicKeyFile(named: instanceName)
        let text = try String(contentsOf: publicKeyFile, encoding: .utf8)
        return try NIOSSHPublicKey(openSSHPublicKey: text)
    }

    private func writeKnownHosts(
        instanceName: String,
        hostKey: Curve25519.Signing.PrivateKey,
        port: Int
    ) throws -> URL {
        let serialized = opensshEd25519PublicKeyString(publicKey: hostKey.publicKey)
        let line = "[127.0.0.1]:\(port) \(serialized)\n"
        let url = paths.sshInstanceKnownHostsFile(named: instanceName)
        try line.data(using: .utf8)?.write(to: url, options: .atomic)
        try chmod0600(url.path)
        return url
    }

    private func writeConfig(
        instanceName: String,
        alias: String,
        port: Int,
        identityFile: URL,
        knownHostsFile: URL
    ) throws -> URL {
        let url = paths.sshInstanceConfigFile(named: instanceName)
        let identityPath = sshConfigStringLiteral(identityFile.path)
        let knownHostsPath = sshConfigStringLiteral(knownHostsFile.path)
        let content = """
        Host \(alias)
          HostName 127.0.0.1
          Port \(port)
          User \(NSUserName())
          PubkeyAuthentication yes
          PreferredAuthentications publickey
          IdentitiesOnly yes
          IdentityFile \(identityPath)
          UserKnownHostsFile \(knownHostsPath)
          StrictHostKeyChecking yes
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          ChallengeResponseAuthentication no
          LogLevel ERROR

        """
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
        try chmod0600(url.path)
        return url
    }

    private func writeSharedConfig() throws -> URL {
        let includePattern = sshConfigPatternLiteral(
            paths.sshInstancesDir.appendingPathComponent("*", isDirectory: true).appendingPathComponent("ssh_config", isDirectory: false).path
        )
        let content = """
        Include \(includePattern)

        """
        try content.data(using: .utf8)?.write(to: paths.sshSharedConfigFile, options: .atomic)
        try chmod0600(paths.sshSharedConfigFile.path)
        return paths.sshSharedConfigFile
    }

    private func sshConfigStringLiteral(_ path: String) -> String {
        path.unicodeScalars.map { scalar in
            switch scalar {
            case " ", "\t", "\\", "\"":
                return "\\\(String(scalar))"
            default:
                return String(scalar)
            }
        }.joined()
    }

    private func sshConfigPatternLiteral(_ path: String) -> String {
        path.unicodeScalars.map { scalar in
            switch scalar {
            case " ", "\t", "\\", "\"":
                return "\\\(String(scalar))"
            default:
                return String(scalar)
            }
        }.joined()
    }

    private func opensshEd25519PublicKeyString(publicKey: Curve25519.Signing.PublicKey) -> String {
        var data = Data()
        appendSSHString("ssh-ed25519", to: &data)
        appendSSHBytes(publicKey.rawRepresentation, to: &data)
        let base64 = data.base64EncodedString()
        return "ssh-ed25519 \(base64)"
    }

    private func appendSSHString(_ string: String, to data: inout Data) {
        appendSSHBytes(Data(string.utf8), to: &data)
    }

    private func appendSSHBytes(_ bytes: some DataProtocol, to data: inout Data) {
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: bytes)
    }

    private func sshHostAlias(forInstance instanceName: String) -> String {
        let sanitized = instanceName.lowercased().replacingOccurrences(of: " ", with: "-")
        return "msl-\(sanitized)"
    }

    private func defaultPort(forInstance instanceName: String) -> Int {
        let base = 22000
        let spread = 1000
        let hash = abs(instanceName.unicodeScalars.reduce(0) { ($0 &* 33) &+ Int($1.value) })
        return base + (hash % spread)
    }

    private func chmod0600(_ path: String) throws {
        if chmod(path, S_IRUSR | S_IWUSR) != 0 {
            throw MSLRuntimeError("failed to chmod 0600 \(path): \(String(cString: strerror(errno)))")
        }
    }
}

private final class LocalhostSSHUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let allowedUsername: String
    let allowedPublicKey: NIOSSHPublicKey

    init(allowedUsername: String, allowedPublicKey: NIOSSHPublicKey) {
        self.allowedUsername = allowedUsername
        self.allowedPublicKey = allowedPublicKey
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        .publicKey
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == allowedUsername else {
            responsePromise.succeed(.failure)
            return
        }
        guard case .publicKey(let publicKeyRequest) = request.request else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(publicKeyRequest.publicKey == allowedPublicKey ? .success : .failure)
    }
}

final class LocalhostSSHServer {
    private let paths: MSLPaths
    private let lock: FileLock
    private let store: StateStore
    private let logger: MSLLogger
    private let executablePath: String
    private let instanceName: String
    private let requestedPort: Int
    private let hostPrivateKey: Curve25519.Signing.PrivateKey
    private let authorizedClientKey: NIOSSHPublicKey
    private let runtimeUser: String
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    init(
        paths: MSLPaths,
        lock: FileLock,
        store: StateStore,
        logger: MSLLogger,
        executablePath: String,
        instanceName: String,
        requestedPort: Int,
        hostPrivateKey: Curve25519.Signing.PrivateKey,
        authorizedClientKey: NIOSSHPublicKey,
        runtimeUser: String
    ) throws {
        self.paths = paths
        self.lock = lock
        self.store = store
        self.logger = logger
        self.executablePath = executablePath
        self.instanceName = instanceName
        self.requestedPort = requestedPort
        self.hostPrivateKey = hostPrivateKey
        self.authorizedClientKey = authorizedClientKey
        self.runtimeUser = runtimeUser
    }

    func start() throws -> Int {
        let authDelegate = LocalhostSSHUserAuthDelegate(
            allowedUsername: runtimeUser,
            allowedPublicKey: authorizedClientKey
        )
        let hostKey = NIOSSHPrivateKey(ed25519Key: hostPrivateKey)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: authDelegate)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { childChannel, channelType in
                            switch channelType {
                            case .session:
                                return childChannel.pipeline.addHandler(
                                    LocalhostSSHSessionHandler(
                                        paths: self.paths,
                                        lock: self.lock,
                                        store: self.store,
                                        logger: self.logger,
                                        executablePath: self.executablePath,
                                        instanceName: self.instanceName,
                                        runtimeUser: self.runtimeUser
                                    )
                                )
                            case .directTCPIP, .forwardedTCPIP:
                                return childChannel.eventLoop.makeFailedFuture(
                                    MSLRuntimeError("unsupported ssh channel type")
                                )
                            }
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: requestedPort).wait()
        self.channel = channel
        let actualPort = channel.localAddress?.port ?? requestedPort
        logger.log("ssh_facade_listening", fields: [
            "instance": instanceName,
            "port": String(actualPort)
        ])
        return actualPort
    }

    func wait() throws {
        defer {
            try? group.syncShutdownGracefully()
        }
        try channel?.closeFuture.wait()
    }

    func stop() {
        _ = channel?.close(mode: .all)
        channel = nil
        try? group.syncShutdownGracefully()
    }
}

private final class LocalhostSSHSessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let paths: MSLPaths
    private let lock: FileLock
    private let store: StateStore
    private let logger: MSLLogger
    private let executablePath: String
    private let instanceName: String
    private let runtimeUser: String
    private var environment: [String: String] = [:]
    private var ptyRequest: SSHChannelRequestEvent.PseudoTerminalRequest?
    private var daemonClient: DaemonClient?
    private var sessionID: String?
    private var ptyID: String?
    private var procID: String?
    private var readThread: Thread?
    private var exitSent = false
    private var runtimeClosed = false

    init(
        paths: MSLPaths,
        lock: FileLock,
        store: StateStore,
        logger: MSLLogger,
        executablePath: String,
        instanceName: String,
        runtimeUser: String
    ) {
        self.paths = paths
        self.lock = lock
        self.store = store
        self.logger = logger
        self.executablePath = executablePath
        self.instanceName = instanceName
        self.runtimeUser = runtimeUser
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closeRuntimeResources()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as SSHChannelRequestEvent.EnvironmentRequest:
            environment[event.name] = event.value
            replyIfNeeded(event.wantReply, success: true, context: context)
        case let event as SSHChannelRequestEvent.PseudoTerminalRequest:
            ptyRequest = event
            replyIfNeeded(event.wantReply, success: true, context: context)
        case let event as SSHChannelRequestEvent.ShellRequest:
            startShell(event: event, context: context)
        case let event as SSHChannelRequestEvent.ExecRequest:
            startExec(event: event, context: context)
        case let event as SSHChannelRequestEvent.WindowChangeRequest:
            resizePty(event: event)
        case let event as SSHChannelRequestEvent.SubsystemRequest:
            logger.log("ssh_facade_subsystem_rejected", fields: [
                "instance": instanceName,
                "subsystem": event.subsystem
            ])
            replyIfNeeded(event.wantReply, success: false, context: context)
            context.close(promise: nil)
        case ChannelEvent.inputClosed:
            closeInput()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = data.data else {
            return
        }
        guard let bytes = buffer.readData(length: buffer.readableBytes) else {
            return
        }
        if let ptyID, let sessionID {
            writePty(bytes: bytes, ptyID: ptyID, sessionID: sessionID)
        } else if let procID, let sessionID {
            writeProc(bytes: bytes, procID: procID, sessionID: sessionID)
        }
    }

    private func startShell(event: SSHChannelRequestEvent.ShellRequest, context: ChannelHandlerContext) {
        do {
            let (client, sessionID) = try connectRuntime()
            let open = try client.send(RuntimeControlRequest(
                op: "pty_open",
                rows: ptyRequest?.terminalRowHeight,
                cols: ptyRequest?.terminalCharacterWidth,
                sessionId: sessionID,
                envAdditions: environment.isEmpty ? nil : environment
            ))
            guard open.ok, let ptyID = open.ptyId else {
                throw MSLRuntimeError(open.error ?? "pty_open failed")
            }
            self.daemonClient = client
            self.sessionID = sessionID
            self.ptyID = ptyID
            replyIfNeeded(event.wantReply, success: true, context: context)
            startPtyReadLoop(context: context, ptyID: ptyID, sessionID: sessionID)
        } catch {
            replyIfNeeded(event.wantReply, success: false, context: context)
            context.fireErrorCaught(error)
            context.close(promise: nil)
        }
    }

    private func startExec(event: SSHChannelRequestEvent.ExecRequest, context: ChannelHandlerContext) {
        do {
            let (client, sessionID) = try connectRuntime()
            let argv = ["/bin/sh", "-lc", event.command]
            let open = try client.send(RuntimeControlRequest(
                op: "proc_open",
                argv: argv,
                runAsRoot: runtimeUser == "root",
                sessionId: sessionID,
                envAdditions: environment.isEmpty ? nil : environment
            ))
            guard open.ok, let procID = open.procId else {
                throw MSLRuntimeError(open.error ?? "proc_open failed")
            }
            self.daemonClient = client
            self.sessionID = sessionID
            self.procID = procID
            replyIfNeeded(event.wantReply, success: true, context: context)
            startProcReadLoop(context: context, procID: procID, sessionID: sessionID)
        } catch {
            replyIfNeeded(event.wantReply, success: false, context: context)
            context.fireErrorCaught(error)
            context.close(promise: nil)
        }
    }

    private func resizePty(event: SSHChannelRequestEvent.WindowChangeRequest) {
        guard let daemonClient, let ptyID, let sessionID else {
            return
        }
        _ = try? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
            op: "pty_resize",
            ptyId: ptyID,
            rows: event.terminalRowHeight,
            cols: event.terminalCharacterWidth,
            sessionId: sessionID
        ))
    }

    private func closeInput() {
        guard let daemonClient, let sessionID else {
            return
        }
        if let procID {
            _ = try? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                op: "proc_stdin_close",
                procId: procID,
                sessionId: sessionID
            ))
        }
    }

    private func connectRuntime() throws -> (DaemonClient, String) {
        let daemonClient = DaemonClient(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: executablePath
        )
        try daemonClient.ensureConnected(expectedInstanceName: instanceName)
        let reg = try daemonClient.send(RuntimeControlRequest(
            op: "session_register",
            instance: instanceName
        ))
        guard reg.ok, let sessionID = reg.sessionId else {
            throw MSLRuntimeError(reg.error ?? "failed to register ssh session")
        }
        return (daemonClient, sessionID)
    }

    private func startPtyReadLoop(context: ChannelHandlerContext, ptyID: String, sessionID: String) {
        let daemonClient = self.daemonClient
        readThread = Thread { [weak self, weak context] in
            guard let self, let daemonClient, let context else { return }
            do {
                let stream = try daemonClient.ptySubscribe(ptyId: ptyID)
                while let event = try stream.nextEvent() {
                    switch event.kind {
                    case .output:
                        self.writeToSSH(data: event.data, type: .channel, context: context)
                    case .exited:
                        self.finish(exitCode: event.exitCode ?? 0, context: context)
                        return
                    case .streamsClosed:
                        self.finish(exitCode: 0, context: context)
                        return
                    }
                }
                self.finish(exitCode: 0, context: context)
            } catch {
                context.fireErrorCaught(error)
                context.close(promise: nil)
            }
        }
        readThread?.name = "msl.ssh.pty.read"
        readThread?.start()
    }

    private func startProcReadLoop(context: ChannelHandlerContext, procID: String, sessionID: String) {
        let daemonClient = self.daemonClient
        readThread = Thread { [weak self, weak context] in
            guard let self, let daemonClient, let context else { return }
            do {
                let stream = try daemonClient.procSubscribe(procId: procID)
                while let event = try stream.nextEvent() {
                    switch event.kind {
                    case .stdout:
                        self.writeToSSH(data: event.data, type: .channel, context: context)
                    case .stderr:
                        self.writeToSSH(data: event.data, type: .stdErr, context: context)
                    case .exited:
                        self.finish(exitCode: event.exitCode ?? 0, context: context)
                        return
                    case .streamsClosed:
                        self.finish(exitCode: 0, context: context)
                        return
                    }
                }
                self.finish(exitCode: 0, context: context)
            } catch {
                context.fireErrorCaught(error)
                context.close(promise: nil)
            }
        }
        readThread?.name = "msl.ssh.proc.read"
        readThread?.start()
    }

    private func writePty(bytes: Data, ptyID: String, sessionID: String) {
        guard let daemonClient else {
            return
        }
        _ = try? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
            op: "pty_write",
            ptyId: ptyID,
            rawData: bytes,
            sessionId: sessionID
        ))
    }

    private func writeProc(bytes: Data, procID: String, sessionID: String) {
        guard let daemonClient else {
            return
        }
        _ = try? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
            op: "proc_write",
            procId: procID,
            rawData: bytes,
            sessionId: sessionID
        ))
    }

    private func writeToSSH(data: Data, type: SSHChannelData.DataType, context: ChannelHandlerContext) {
        context.eventLoop.execute {
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type: type, data: .byteBuffer(buffer))), promise: nil)
        }
    }

    private func finish(exitCode: Int32, context: ChannelHandlerContext) {
        guard !exitSent else {
            return
        }
        exitSent = true
        context.eventLoop.execute {
            context.channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExitStatus(exitStatus: Int(exitCode)),
                promise: nil
            )
            context.close(promise: nil)
        }
        closeRuntimeResources()
    }

    private func closeRuntimeResources() {
        guard !runtimeClosed else {
            return
        }
        runtimeClosed = true
        if let daemonClient, let sessionID {
            if let ptyID {
                _ = try? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                    op: "pty_close",
                    ptyId: ptyID,
                    sessionId: sessionID
                ))
            }
            if let procID {
                _ = try? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                    op: "proc_close",
                    procId: procID,
                    sessionId: sessionID
                ))
            }
            _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
            daemonClient.disconnect()
        }
    }

    private func replyIfNeeded(_ wantReply: Bool, success: Bool, context: ChannelHandlerContext) {
        guard wantReply else {
            return
        }
        context.eventLoop.execute {
            if success {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            } else {
                context.channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
        }
    }
}

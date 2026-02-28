import Foundation
import Darwin

final class GuestDiagnosticLogCollector {
    enum Channel: String, CaseIterable {
        case console
        case kernel
        case syslog
        case initlog

        var fileName: String {
            switch self {
            case .console: return "console.log"
            case .kernel: return "kernel.log"
            case .syslog: return "syslog.log"
            case .initlog: return "init.log"
            }
        }
    }

    private let logger: MSLLogger?
    private let fileManager: FileManager
    private let logDir: URL
    private let maxBytesPerFile: Int64
    private let maxGenerations: Int
    private var sinks: [Channel: RotatingLogFile] = [:]

    private var masterFD: Int32 = -1
    private var readerThread: Thread?
    private let stateLock = NSLock()
    private var stopping = false

    init(
        paths: MSLPaths,
        instanceName: String,
        logger: MSLLogger?,
        maxBytesPerFile: Int64 = 10 * 1024 * 1024,
        maxGenerations: Int = 5,
        fileManager: FileManager = .default
    ) {
        self.logger = logger
        self.fileManager = fileManager
        self.logDir = paths.diagnosticLogsDirectory(named: instanceName)
        self.maxBytesPerFile = max(1, maxBytesPerFile)
        self.maxGenerations = max(1, maxGenerations)
    }

    func makeSerialAttachment() throws -> (FileHandle, FileHandle) {
        try fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)

        var outMaster: Int32 = -1
        var outSlave: Int32 = -1
        if openpty(&outMaster, &outSlave, nil, nil, nil) != 0 {
            throw MSLRuntimeError("failed to allocate diagnostic serial PTY: \(String(cString: strerror(errno)))")
        }
        masterFD = outMaster
        setStopping(false)

        let currentFlags = fcntl(outMaster, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(outMaster, F_SETFL, currentFlags | O_NONBLOCK)
        }

        for channel in Channel.allCases {
            let logFile = logDir.appendingPathComponent(channel.fileName, isDirectory: false)
            sinks[channel] = RotatingLogFile(
                fileURL: logFile,
                logger: logger,
                maxBytes: maxBytesPerFile,
                maxGenerations: maxGenerations,
                fileManager: fileManager
            )
        }

        startReaderThread(fd: outMaster)
        logger?.log("guest_log_forwarder_started", fields: [
            "dir": logDir.path,
            "max_bytes": String(maxBytesPerFile),
            "max_generations": String(maxGenerations)
        ])

        let readHandle = FileHandle(fileDescriptor: outSlave, closeOnDealloc: false)
        let writeHandle = FileHandle(fileDescriptor: outSlave, closeOnDealloc: false)
        return (readHandle, writeHandle)
    }

    func stop() {
        setStopping(true)
        if masterFD >= 0 {
            _ = close(masterFD)
            masterFD = -1
        }
        if let readerThread {
            while !readerThread.isFinished {
                Thread.sleep(forTimeInterval: 0.01)
            }
            self.readerThread = nil
        }
    }

    private func startReaderThread(fd: Int32) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var lineBuffer = Data()
            while !self.isStopping() {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    lineBuffer.append(buffer, count: n)
                } else if n == 0 {
                    break
                } else {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        Thread.sleep(forTimeInterval: 0.01)
                        continue
                    }
                    break
                }
                while let newline = lineBuffer.firstIndex(of: 0x0A) {
                    let lineData = lineBuffer[..<newline]
                    lineBuffer.removeSubrange(...newline)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self.consume(line: line)
                    }
                }
            }
            if !lineBuffer.isEmpty, let trailing = String(data: lineBuffer, encoding: .utf8) {
                self.consume(line: trailing)
            }
        }
        thread.name = "msl.guest.diagnostic.log"
        thread.start()
        readerThread = thread
    }

    private func setStopping(_ newValue: Bool) {
        stateLock.lock()
        stopping = newValue
        stateLock.unlock()
    }

    private func isStopping() -> Bool {
        stateLock.lock()
        let value = stopping
        stateLock.unlock()
        return value
    }

    private func consume(line rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .newlines)
        if line.isEmpty { return }

        let channel: Channel
        let payload: String
        if line.hasPrefix("[kernel]") {
            channel = .kernel
            payload = String(line.dropFirst("[kernel]".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("[syslog]") {
            channel = .syslog
            payload = String(line.dropFirst("[syslog]".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("[init]") {
            channel = .initlog
            payload = String(line.dropFirst("[init]".count)).trimmingCharacters(in: .whitespaces)
        } else {
            channel = .console
            payload = line
        }

        guard let sink = sinks[channel] else { return }
        do {
            try sink.append(line: payload)
        } catch {
            logger?.log("guest_log_forwarder_error", fields: [
                "channel": channel.rawValue,
                "error": String(describing: error)
            ])
        }
    }
}

private final class RotatingLogFile {
    private let fileURL: URL
    private let logger: MSLLogger?
    private let maxBytes: Int64
    private let maxGenerations: Int
    private let fileManager: FileManager

    init(
        fileURL: URL,
        logger: MSLLogger?,
        maxBytes: Int64,
        maxGenerations: Int,
        fileManager: FileManager
    ) {
        self.fileURL = fileURL
        self.logger = logger
        self.maxBytes = max(1, maxBytes)
        self.maxGenerations = max(1, maxGenerations)
        self.fileManager = fileManager
    }

    func append(line: String) throws {
        let data = Data((line + "\n").utf8)
        try ensureParentDirectory()
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try rotateIfNeeded()
    }

    private func ensureParentDirectory() throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func rotateIfNeeded() throws {
        let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > maxBytes else { return }

        for generation in stride(from: maxGenerations, through: 1, by: -1) {
            let src = rotatedURL(generation: generation)
            let dst = rotatedURL(generation: generation + 1)
            if fileManager.fileExists(atPath: dst.path) {
                try fileManager.removeItem(at: dst)
            }
            if fileManager.fileExists(atPath: src.path) {
                try fileManager.moveItem(at: src, to: dst)
            }
        }

        let first = rotatedURL(generation: 1)
        if fileManager.fileExists(atPath: first.path) {
            try fileManager.removeItem(at: first)
        }
        try fileManager.moveItem(at: fileURL, to: first)
        fileManager.createFile(atPath: fileURL.path, contents: nil)

        let excess = rotatedURL(generation: maxGenerations + 1)
        if fileManager.fileExists(atPath: excess.path) {
            try fileManager.removeItem(at: excess)
        }

        logger?.log("guest_log_forwarder_rotate", fields: [
            "file": fileURL.path,
            "max_bytes": String(maxBytes),
            "max_generations": String(maxGenerations)
        ])
    }

    private func rotatedURL(generation: Int) -> URL {
        fileURL.appendingPathExtension(String(generation))
    }
}

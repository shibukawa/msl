import Foundation

public enum InstanceLifecycleState: String {
    case stopped = "Stopped"
    case booting = "Booting"
    case running = "Running"
    case stopping = "Stopping"
    case error = "Error"
}

public final class InstanceRuntimeContext {
    public let instanceName: String
    public var lifecycleState: InstanceLifecycleState = .stopped
    public var metadataURL: URL?
    public var vmRunner: VirtualMachineRunner?
    public var initClient: InitChannelClient?
    public var initWriteClient: InitChannelClient?
    public var initReadClient: InitChannelClient?
    public var housekeepingClient: InitChannelClient?
    public var runtimeUser: RuntimeUserState?
    public var runtimeDNSMeta: [String: String] = [:]
    public var lastError: String?

    private let bootCondition = NSCondition()
    private var bootInProgress = false
    private var bootCompleted = false
    private var lastBootError: Error?

    public init(instanceName: String) {
        self.instanceName = instanceName
    }

    public func runBootOnce(operation: () throws -> Void) throws {
        bootCondition.lock()
        while bootInProgress {
            bootCondition.wait()
        }
        if bootCompleted, lastBootError == nil {
            bootCondition.unlock()
            return
        }
        if let error = lastBootError {
            bootCondition.unlock()
            throw error
        }
        bootInProgress = true
        bootCompleted = false
        bootCondition.unlock()

        var capturedError: Error?
        do {
            try operation()
        } catch {
            capturedError = error
        }

        bootCondition.lock()
        bootInProgress = false
        lastBootError = capturedError
        bootCompleted = (capturedError == nil)
        bootCondition.broadcast()
        bootCondition.unlock()

        if let capturedError {
            throw capturedError
        }
    }

    public func clearBootError() {
        bootCondition.lock()
        lastBootError = nil
        bootCompleted = false
        bootCondition.unlock()
    }
}

public final class InstanceRuntimeRegistry {
    private let lock = NSLock()
    private var contexts: [String: InstanceRuntimeContext] = [:]

    public init() {}

    public func context(for instanceName: String) -> InstanceRuntimeContext {
        lock.lock()
        defer { lock.unlock() }
        if let existing = contexts[instanceName] {
            return existing
        }
        let created = InstanceRuntimeContext(instanceName: instanceName)
        contexts[instanceName] = created
        return created
    }

    public func allContexts() -> [InstanceRuntimeContext] {
        lock.lock()
        defer { lock.unlock() }
        return Array(contexts.values)
    }
}

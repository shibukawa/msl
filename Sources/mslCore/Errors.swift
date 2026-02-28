import Foundation

public struct MSLRuntimeError: Error, CustomStringConvertible {
    public let message: String
    public let exitCode: Int32

    public init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    public var description: String { message }
}

import XCTest

final class KernelBuildScriptTests: XCTestCase {
    func testBuildKernelAcceptsArbitraryProfileName() throws {
        let result = try runBuildKernelScript(env: [
            "KERNEL_SRC": "/tmp/nonexistent-kernel-src",
            "KERNEL_PROFILE": "slim"
        ])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.combinedOutput.contains("KERNEL_SRC does not exist"), result.combinedOutput)
        XCTAssertFalse(result.combinedOutput.contains("unsupported KERNEL_PROFILE"), result.combinedOutput)
    }

    func testBuildKernelUsesDefaultProfileAndFailsOnMissingSource() throws {
        let result = try runBuildKernelScript(env: [
            "KERNEL_SRC": "/tmp/nonexistent-kernel-src"
        ])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.combinedOutput.contains("KERNEL_SRC does not exist"), result.combinedOutput)
    }

    func testBuildKernelAcceptsMinimumDefconfigProfile() throws {
        let result = try runBuildKernelScript(env: [
            "KERNEL_SRC": "/tmp/nonexistent-kernel-src",
            "KERNEL_PROFILE": "minimum-defconfig"
        ])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.combinedOutput.contains("KERNEL_SRC does not exist"), result.combinedOutput)
        XCTAssertFalse(result.combinedOutput.contains("unsupported KERNEL_PROFILE"), result.combinedOutput)
    }

    private func runBuildKernelScript(env: [String: String]) throws -> CommandResult {
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/build-kernel.sh").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script]

        var mergedEnv = ProcessInfo.processInfo.environment
        for (key, value) in env {
            mergedEnv[key] = value
        }
        process.environment = mergedEnv

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, combinedOutput: out + err)
    }
}

private struct CommandResult {
    let exitCode: Int32
    let combinedOutput: String
}

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

    func testSlimKernelFragmentKeepsContainerPortPublishingNAT() throws {
        let fragment = try readKernelConfigFragment("msl-slim-defconfig.fragment")
        for symbol in [
            "CONFIG_NETFILTER=y",
            "CONFIG_NF_NAT=y",
            "CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y",
            "CONFIG_NETFILTER_XT_NAT=y",
            "CONFIG_NETFILTER_XT_TARGET_MASQUERADE=y",
            "CONFIG_NFT_CHAIN_NAT=y",
            "CONFIG_NFT_NAT=y",
            "CONFIG_IP_NF_NAT=y",
        ] {
            XCTAssertTrue(fragment.contains(symbol), "missing \(symbol)")
        }
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

    private func readKernelConfigFragment(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/kernel/config")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private struct CommandResult {
    let exitCode: Int32
    let combinedOutput: String
}

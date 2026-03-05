import XCTest
@testable import mslCore

final class SecurityScanTests: XCTestCase {
    func testVulnerabilityDBTargetResolverReturnsConfiguredTarget() throws {
        let entry = DistributionManifestEntry(
            id: "ubuntu-noble-arm64",
            distro: "ubuntu",
            version: "noble",
            arch: "arm64",
            tarballURL: "https://example.invalid/rootfs.tar.xz",
            sha256: "abc",
            signatureURL: "https://example.invalid/SHA256SUMS.asc",
            checksumURL: "https://example.invalid/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "DEADBEEF",
            supportState: .supported,
            vulnerabilityDBTarget: DistributionManifestEntry.VulnerabilityDBTarget(
                family: "ubuntu",
                release: "noble",
                dictionary: "goval"
            )
        )
        let resolved = try VulnerabilityDBTargetResolver().resolve(entry: entry)
        XCTAssertEqual(resolved.family, "ubuntu")
        XCTAssertEqual(resolved.release, "noble")
        XCTAssertEqual(resolved.dictionary, "goval")
    }

    func testVulnerabilityDBTargetResolverFailsWhenMissing() {
        let entry = DistributionManifestEntry(
            id: "custom-arm64",
            distro: "custom",
            version: "1",
            arch: "arm64",
            tarballURL: "https://example.invalid/rootfs.tar.xz",
            sha256: "abc",
            signatureURL: "https://example.invalid/SHA256SUMS.asc",
            checksumURL: "https://example.invalid/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "DEADBEEF",
            supportState: .supported
        )
        XCTAssertThrowsError(try VulnerabilityDBTargetResolver().resolve(entry: entry)) { error in
            guard let runtimeError = error as? MSLRuntimeError else {
                return XCTFail("unexpected error type: \(error)")
            }
            XCTAssertTrue(runtimeError.message.contains("security_db_target_not_configured"))
        }
    }

    func testSecurityPolicyEngineBlockBlocksWhenHighOrCriticalExists() {
        let counts = SecurityScanResult.VulnerabilityCounts(critical: 0, high: 1, medium: 0, low: 0, unknown: 0)
        let policy = SecurityPolicy(mode: .block)
        let result = SecurityPolicyEngine().evaluate(policy: policy, counts: counts)
        XCTAssertEqual(result.decision, "block")
    }

    func testSecurityPolicyEngineWarnWarnsWhenHighOrCriticalExists() {
        let counts = SecurityScanResult.VulnerabilityCounts(critical: 0, high: 2, medium: 1, low: 0, unknown: 0)
        let policy = SecurityPolicy(mode: .warn)
        let result = SecurityPolicyEngine().evaluate(policy: policy, counts: counts)
        XCTAssertEqual(result.decision, "warn")
    }

    func testSecurityPolicyEngineAllowAlwaysAllows() {
        let counts = SecurityScanResult.VulnerabilityCounts(critical: 5, high: 10, medium: 2, low: 1, unknown: 0)
        let policy = SecurityPolicy(mode: .allow)
        let result = SecurityPolicyEngine().evaluate(policy: policy, counts: counts)
        XCTAssertEqual(result.decision, "allow")
    }
}

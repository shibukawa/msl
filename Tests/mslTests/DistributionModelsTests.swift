import XCTest
@testable import mslCore

final class DistributionModelsTests: XCTestCase {
    func testWorkspacePolicyDefaultsToMslconfigPresenceMode() {
        let policy = WorkspacePolicy()
        XCTAssertEqual(policy.activationMode, "mslconfig_presence_only")
        XCTAssertEqual(policy.startupMountEnabled, true)
    }

    func testBundledToolManifestDecodesBundleVersion() throws {
        let raw = """
        {
          "bundleVersion": "darwin-arm64-regctl-v0.11.2_umoci-v0.6.0",
          "platform": "darwin-arm64",
          "generatedAtEpochMs": 100,
          "tools": [
            {
              "name": "regctl",
              "version": "v0.11.2",
              "checksum": "abc",
              "relativePath": "regctl"
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(BundledToolManifest.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.bundleVersion, "darwin-arm64-regctl-v0.11.2_umoci-v0.6.0")
        XCTAssertEqual(decoded.record(named: "regctl")?.version, "v0.11.2")
        XCTAssertNil(decoded.record(named: "umoci"))
    }

    func testDistributionInstanceMetadataDecodesWithoutWorkspacePolicy() throws {
        let raw = """
        {
          "name": "dev",
          "createdAtEpochMs": 100,
          "source": {
            "sourceType": "local",
            "distro": null,
            "version": null,
            "arch": null,
            "manifestId": null,
            "localPath": "/tmp/rootfs.tar.xz",
            "tarballFileName": "rootfs.tar.xz",
            "sha256": "abc",
            "verifiedAtEpochMs": 100
          },
          "diskPath": "/tmp/disk.raw",
          "kernelProfileRef": null,
          "userConvergencePolicy": null
        }
        """

        let decoded = try JSONDecoder().decode(DistributionInstanceMetadata.self, from: Data(raw.utf8))
        XCTAssertNil(decoded.workspacePolicy)
        XCTAssertNil(decoded.compressionPolicy)
        XCTAssertNil(decoded.cacheSharing)
      }

      func testDistributionInstanceMetadataRoundTripsCompressionPolicy() throws {
        let metadata = DistributionInstanceMetadata(
          name: "dev",
          createdAtEpochMs: 100,
          source: DistributionSourceRecord(
            sourceType: "manifest",
            distro: "ubuntu",
            version: "24.04",
            arch: "arm64",
            manifestId: "ubuntu-24.04",
            localPath: nil,
            tarballFileName: "rootfs.tar.xz",
            sha256: "abc",
            verifiedAtEpochMs: 100
          ),
          diskPath: "/tmp/disk.raw",
          kernelProfileRef: nil,
          userConvergencePolicy: nil,
          workspacePolicy: nil,
          compressionPolicy: DistributionCompressionPolicy(
            pathPolicies: [CompressionPathPolicyEntry(path: "/var/log", mode: "zstd:1")],
            cacheToggles: ["apt": true],
            catalogPath: "/tmp/catalog.json",
            resolvedAtEpochMs: 200
          )
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DistributionInstanceMetadata.self, from: data)
        XCTAssertEqual(decoded.compressionPolicy?.pathPolicies.first?.path, "/var/log")
        XCTAssertEqual(decoded.compressionPolicy?.cacheToggles["apt"], true)
      }

      func testMSLConfigDecodesStorageCacheToggles() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "storageCacheToggles": {
          "docker": false,
          "go": true,
          "apt": true,
          "apk": false
          }
        }
        """

        let decoded = try JSONDecoder().decode(MSLConfig.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.storageCacheToggles?["docker"], false)
        XCTAssertEqual(decoded.storageCacheToggles?["go"], true)
        XCTAssertEqual(decoded.storageCacheToggles?["apt"], true)
        XCTAssertEqual(decoded.storageCacheToggles?["apk"], false)
    }

    func testMSLConfigDecodesDNSNetworkConfig() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "network": {
            "dns": {
              "mode": "manual",
              "manualNameservers": ["9.9.9.9", "1.1.1.1"],
              "manualSearchDomains": ["corp.example"]
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(MSLConfig.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.network?.dns?.mode, "manual")
        XCTAssertEqual(decoded.network?.dns?.manualNameservers ?? [], ["9.9.9.9", "1.1.1.1"])
        XCTAssertEqual(decoded.network?.dns?.manualSearchDomains ?? [], ["corp.example"])
    }

    func testDistributionMetadataRoundTripsNetworkPolicy() throws {
        let metadata = DistributionInstanceMetadata(
            name: "dev",
            createdAtEpochMs: 100,
            source: DistributionSourceRecord(
                sourceType: "manifest",
                distro: "ubuntu",
                version: "24.04",
                arch: "arm64",
                manifestId: "ubuntu-24.04",
                localPath: nil,
                tarballFileName: "rootfs.tar.xz",
                sha256: "abc",
                verifiedAtEpochMs: 100
            ),
            diskPath: "/tmp/disk.raw",
            kernelProfileRef: nil,
            userConvergencePolicy: nil,
            workspacePolicy: nil,
            compressionPolicy: nil,
            networkPolicy: DistributionNetworkPolicy(
                dns: DistributionNetworkDNSPolicy(
                    mode: "unmanaged",
                    resolverBackend: "replace_resolv_conf",
                    manualNameservers: nil,
                    manualSearchDomains: nil
                )
            )
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DistributionInstanceMetadata.self, from: data)
        XCTAssertEqual(decoded.networkPolicy?.dns?.mode, "unmanaged")
    }

    func testDistributionMetadataRoundTripsCacheSharing() throws {
        let metadata = DistributionInstanceMetadata(
            name: "dev",
            createdAtEpochMs: 100,
            source: DistributionSourceRecord(
                sourceType: "manifest",
                distro: "ubuntu",
                version: "24.04",
                arch: "arm64",
                manifestId: "ubuntu-24.04",
                localPath: nil,
                tarballFileName: "rootfs.tar.xz",
                sha256: "abc",
                verifiedAtEpochMs: 100
            ),
            diskPath: "/tmp/disk.raw",
            kernelProfileRef: nil,
            userConvergencePolicy: nil,
            cacheSharing: CacheSharingConfig(enabled: true, apt: true, apk: false)
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DistributionInstanceMetadata.self, from: data)
        XCTAssertEqual(decoded.cacheSharing?.enabled, true)
        XCTAssertEqual(decoded.cacheSharing?.apt, true)
        XCTAssertEqual(decoded.cacheSharing?.apk, false)
    }

    func testManifestEntryRoundTripsCacheSharingDefaults() throws {
        let entry = DistributionManifestEntry(
            id: "ubuntu-24.04-arm64",
            distro: "ubuntu",
            version: "24.04",
            arch: "arm64",
            tarballURL: "https://example.com/rootfs.tar.xz",
            sha256: "abc",
            signatureURL: "https://example.com/SHA256SUMS.gpg",
            checksumURL: "https://example.com/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "DEADBEEF",
            supportState: .supported,
            userConvergenceTemplate: nil,
            cacheSharingDefaults: CacheSharingConfig(enabled: true, apt: true, apk: false)
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DistributionManifestEntry.self, from: data)
        XCTAssertEqual(decoded.cacheSharingDefaults?.enabled, true)
        XCTAssertEqual(decoded.cacheSharingDefaults?.apt, true)
        XCTAssertEqual(decoded.cacheSharingDefaults?.apk, false)
    }
}

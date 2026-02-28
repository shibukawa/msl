import XCTest
@testable import mslCore

final class DistributionModelsTests: XCTestCase {
    func testWorkspacePolicyDefaultsToMslconfigPresenceMode() {
        let policy = WorkspacePolicy()
        XCTAssertEqual(policy.activationMode, "mslconfig_presence_only")
        XCTAssertEqual(policy.startupMountEnabled, true)
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
}

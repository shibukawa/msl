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
          "generatedAtEpochMs": 100,
          "tools": [
            {
              "name": "regctl",
              "platform": "darwin-arm64",
              "version": "v0.11.2",
              "checksum": "abc",
              "relativePath": "regctl"
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(BundledToolManifest.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.bundleVersion, "darwin-arm64-regctl-v0.11.2_umoci-v0.6.0")
        XCTAssertEqual(decoded.record(named: "regctl", platform: "darwin-arm64")?.version, "v0.11.2")
        XCTAssertNil(decoded.record(named: "umoci", platform: "darwin-arm64"))
    }

    func testImagewriterExtraFilesManifestRoundTrips() throws {
        let manifest = ImagewriterExtraFilesManifest(
            files: [
                ImagewriterExtraFileEntry(
                    sourceRelativePath: "payload/umoci",
                    guestPath: "extras/umoci",
                    mode: "0755"
                )
            ]
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ImagewriterExtraFilesManifest.self, from: data)
        XCTAssertEqual(decoded.files.count, 1)
        XCTAssertEqual(decoded.files.first?.sourceRelativePath, "payload/umoci")
        XCTAssertEqual(decoded.files.first?.guestPath, "extras/umoci")
        XCTAssertEqual(decoded.files.first?.mode, "0755")
    }

    func testDefaultExecRoundTripsSource() throws {
        let metadata = DistributionInstanceMetadata(
            name: "python",
            createdAtEpochMs: 100,
            source: DistributionSourceRecord(
                sourceType: "container-remote",
                tarballFileName: "rootfs.oci",
                sha256: "abc",
                verifiedAtEpochMs: 100
            ),
            diskPath: "/tmp/disk.raw",
            kernelProfileRef: nil,
            userConvergencePolicy: nil,
            defaultExec: DistributionInstanceMetadata.DefaultExec(
                argv: ["/usr/bin/python3", "-i"],
                env: ["PYTHONUNBUFFERED=1"],
                source: "install-override"
            ),
            shellAvailable: false,
            startupMode: .processFirst,
            workloadKind: .containerRuntime
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DistributionInstanceMetadata.self, from: data)
        XCTAssertEqual(decoded.defaultExec?.argv, ["/usr/bin/python3", "-i"])
        XCTAssertEqual(decoded.defaultExec?.source, "install-override")
        XCTAssertEqual(decoded.startupMode, .processFirst)
        XCTAssertEqual(decoded.resolvedStartupMode(), .processFirst)
        XCTAssertEqual(decoded.workloadKind, .containerRuntime)
        XCTAssertEqual(decoded.resolvedWorkloadKind(), .containerRuntime)
    }

    func testDistributionInstanceMetadataDefaultsStartupModeToInteractive() throws {
        let raw = """
        {
          "name": "python",
          "createdAtEpochMs": 100,
          "source": {
            "sourceType": "container-remote",
            "tarballFileName": "rootfs.oci",
            "sha256": "abc",
            "verifiedAtEpochMs": 100
          },
          "diskPath": "/tmp/disk.raw",
          "kernelProfileRef": null,
          "userConvergencePolicy": null,
          "shellAvailable": false
        }
        """

        let decoded = try JSONDecoder().decode(DistributionInstanceMetadata.self, from: Data(raw.utf8))
        XCTAssertNil(decoded.startupMode)
        XCTAssertEqual(decoded.resolvedStartupMode(), .interactive)
        XCTAssertNil(decoded.workloadKind)
        XCTAssertEqual(decoded.resolvedWorkloadKind(), .generic)
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

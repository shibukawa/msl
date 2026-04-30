import XCTest
@testable import mslCore

final class RuntimeContainerMonitoringModelsTests: XCTestCase {
    func testContainerMonitoringModelsRoundTripThroughRuntimeControlResponse() throws {
        let response = RuntimeControlResponse(
            ok: true,
            containerRuntimeSummary: RuntimeContainerRuntimeSummary(
                containerdHealthy: true,
                buildkitdHealthy: true,
                containerCount: 1,
                imageCount: 2,
                sampledAtEpochMs: 123
            ),
            containers: [
                RuntimeContainerListItem(
                    id: "abc",
                    name: "web",
                    image: "nginx:latest",
                    command: "nginx",
                    created: "2026-04-29",
                    status: "Up",
                    state: "running",
                    ports: "0.0.0.0:8080->80/tcp",
                    labels: ["app": "web"],
                    size: "12MiB"
                )
            ],
            containerDetail: RuntimeContainerDetail(
                id: "abc",
                name: "web",
                image: "nginx:latest",
                state: "running",
                status: "running",
                created: "2026-04-29",
                command: "nginx",
                ports: ["80/tcp"],
                mounts: ["/data -> /data"],
                networks: ["bridge"],
                restartPolicy: "no",
                envCount: 3,
                labels: ["app": "web"]
            ),
            containerStats: RuntimeContainerStats(
                id: "abc",
                name: "web",
                cpuPercent: 1.5,
                memoryUsageBytes: 1024,
                memoryLimitBytes: 2048,
                memoryLimitUnlimited: false,
                networkRxBytes: 10,
                networkTxBytes: 20,
                blockReadBytes: 30,
                blockWriteBytes: 40,
                pids: 2,
                sampledAtEpochMs: 456
            ),
            containerStatsList: [
                RuntimeContainerStats(
                    id: "abc",
                    name: "web",
                    cpuPercent: 1.5,
                    memoryUsageBytes: 1024,
                    memoryLimitBytes: 2048,
                    memoryLimitUnlimited: false,
                    networkRxBytes: 10,
                    networkTxBytes: 20,
                    blockReadBytes: 30,
                    blockWriteBytes: 40,
                    pids: 2,
                    sampledAtEpochMs: 456
                )
            ],
            images: [
                RuntimeImageListItem(
                    id: "sha256:def",
                    repository: "nginx",
                    tag: "latest",
                    digest: "sha256:123",
                    created: "1 hour ago",
                    size: "50MiB"
                )
            ],
            imageDetail: RuntimeImageDetail(
                id: "sha256:def",
                repoTags: ["nginx:latest"],
                repoDigests: ["nginx@sha256:123"],
                architecture: "arm64",
                os: "linux",
                created: "2026-04-29",
                sizeBytes: 50,
                labels: ["maintainer": "msl"]
            )
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.containerRuntimeSummary?.containerCount, 1)
        XCTAssertEqual(decoded.containers?.first?.name, "web")
        XCTAssertEqual(decoded.containerDetail?.mounts.first, "/data -> /data")
        XCTAssertEqual(decoded.containerStats?.memoryLimitBytes, 2048)
        XCTAssertEqual(decoded.containerStatsList?.first?.id, "abc")
        XCTAssertEqual(decoded.images?.first?.repository, "nginx")
        XCTAssertEqual(decoded.imageDetail?.architecture, "arm64")
    }

    func testContainerStatsBatchRequestRoundTrip() throws {
        let request = RuntimeControlRequest(
            op: "container_stats_batch",
            instance: "_container",
            containerIDs: ["abc", "def"]
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)

        XCTAssertEqual(decoded.op, "container_stats_batch")
        XCTAssertEqual(decoded.instance, "_container")
        XCTAssertEqual(decoded.containerIDs, ["abc", "def"])
    }
}

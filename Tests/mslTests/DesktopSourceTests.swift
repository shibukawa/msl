import XCTest

final class DesktopSourceTests: XCTestCase {
    func testDesktopHidesInternalContainerInstance() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("\"_imagewriter\", \"_container\", \"_podman\""))
    }

    func testDesktopExposesSyntheticContainerNavigation() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("containerListSelection = \"__containers_list\""))
        XCTAssertTrue(source.contains("imageListSelection = \"__images_list\""))
        XCTAssertTrue(source.contains("containerRuntimeSelection = \"__containers_runtime\""))
        XCTAssertTrue(source.contains("containerMetricsSelection = \"__containers_metrics\""))
        XCTAssertTrue(source.contains("Section(\"Containers\")"))
        XCTAssertTrue(source.contains("ContainerSidebarRow("))
        XCTAssertTrue(source.contains("ContainerDashboardPageView"))
        XCTAssertTrue(source.contains("confirmDestructive"))
        XCTAssertTrue(source.contains("container_prune"))
        XCTAssertTrue(source.contains("image_prune"))
    }

    func testContainerMonitoringUsesWiderLayoutAndThrottledRefresh() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains(".frame(minWidth: 1360, minHeight: 760)"))
        XCTAssertTrue(source.contains(".frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity)"))
        XCTAssertTrue(source.contains(".frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity)"))
        XCTAssertTrue(source.contains("containerSummaryFetchInFlight"))
        XCTAssertTrue(source.contains("lastContainerSummaryUpdatedEpochMs"))
        XCTAssertTrue(source.contains("guard selectedContainerID != id else { return }"))
        XCTAssertTrue(source.contains("if self.containers != next"))
        XCTAssertTrue(source.contains("DetailMetricRow"))
        XCTAssertTrue(source.contains("DetailMetricRow(label: \"Btrfs dedupe\", value: containerDedupeStatusDisplay(summary))"))
        XCTAssertTrue(source.contains("formatContainerMemoryLimit"))
    }

    func testContainerMetricsRefreshIsSplitFromInventoryAndDetails() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("@Published var containerStatsByID: [String: RuntimeContainerStats] = [:]"))
        XCTAssertTrue(source.contains("private var selectedContainerMetricsFetchInFlight = false"))
        XCTAssertTrue(source.contains("fetchSelectedContainerMetricsIfPossible(force: force)"))
        XCTAssertTrue(source.contains("intervalMs: 2_000"))
        XCTAssertTrue(source.contains("intervalMs: 8_000"))
        XCTAssertTrue(source.contains("op: \"container_stats_batch\""))
        XCTAssertTrue(source.contains("let ids = containers.filter(isUpContainer).map(\\.id)"))
        XCTAssertTrue(source.contains("isUpContainer(selectedContainer)"))
        XCTAssertTrue(source.contains("Text(containerCPUDisplay(item, stats: model.containerStatsByID[item.id]))"))
        XCTAssertTrue(source.contains("Text(containerMemoryDisplay(item, stats: model.containerStatsByID[item.id]))"))
    }

    func testContainerSelectionIsCheapAndStaleDetailResultsAreDiscarded() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        guard let selectRange = source.range(of: "func selectContainer(id: String?)"),
              let nextFunction = source[selectRange.lowerBound...].range(of: "\n    func selectImage") else {
            return XCTFail("selectContainer source block not found")
        }
        let selectSource = String(source[selectRange.lowerBound..<nextFunction.lowerBound])
        XCTAssertTrue(selectSource.contains("guard selectedContainerID != id else { return }"))
        XCTAssertFalse(selectSource.contains("fetchContainerDetailIfPossible"))
        XCTAssertFalse(selectSource.contains("container_stats"))

        XCTAssertTrue(source.contains("guard self.selectedContainerID == id else { return }"))
    }

    func testContainerSidebarReceivesSmallImmutableState() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("ContainerSidebarRow(page: page)"))
        XCTAssertTrue(source.contains("let page: ContainerDesktopPage"))
        guard let rowRange = source.range(of: "private struct ContainerSidebarRow: View"),
              let nextStruct = source[rowRange.lowerBound...].range(of: "\nprivate struct ContainerDashboardPageView") else {
            return XCTFail("ContainerSidebarRow source block not found")
        }
        let rowSource = String(source[rowRange.lowerBound..<nextStruct.lowerBound])
        XCTAssertFalse(rowSource.contains("@ObservedObject"))
        XCTAssertFalse(rowSource.contains("AppManagerWorkerRecord"))
        XCTAssertFalse(rowSource.contains("RuntimeLifecycleState"))
        XCTAssertFalse(rowSource.contains("StatusBadge"))
        XCTAssertFalse(rowSource.contains("containerSummary"))
    }

    func testContainerMetricsPageShowsOnlyUpContainers() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("Table(containers.filter(isUpContainer))"))
        XCTAssertTrue(source.contains("private func isUpContainer(_ container: RuntimeContainerListItem) -> Bool"))
        XCTAssertTrue(source.contains("state == \"running\" || state == \"up\""))
        XCTAssertTrue(source.contains("status == \"up\" || status.hasPrefix(\"up \")"))
    }

    func testStoppedContainerRowsDoNotRenderOrFetchMetrics() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("private func containerCPUDisplay(_ container: RuntimeContainerListItem, stats: RuntimeContainerStats?) -> String"))
        XCTAssertTrue(source.contains("private func containerMemoryDisplay(_ container: RuntimeContainerListItem, stats: RuntimeContainerStats?) -> String"))
        XCTAssertTrue(source.contains("guard isUpContainer(container) else { return \"-\" }"))
        XCTAssertTrue(source.contains("let ids = containers.filter(isUpContainer).map(\\.id)"))
        XCTAssertTrue(source.contains("guard let worker = containerWorker, worker.lifecycleState == .running,\n              let selectedContainer = selectedContainer,\n              isUpContainer(selectedContainer)"))
    }

    func testContainerDetailDoesNotRenderMetricsSection() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        guard let panelRange = source.range(of: "private struct ContainerDetailPanel: View"),
              let nextPanel = source[panelRange.lowerBound...].range(of: "\nprivate struct ImageListPanel") else {
            return XCTFail("ContainerDetailPanel source block not found")
        }
        let panelSource = String(source[panelRange.lowerBound..<nextPanel.lowerBound])
        XCTAssertFalse(panelSource.contains("MetricSection(title: \"Metrics\")"))
        XCTAssertFalse(panelSource.contains("percentString(stats?.cpuPercent)"))
        XCTAssertFalse(panelSource.contains("formatContainerMemoryLimit(stats)"))
    }

    func testContainerRuntimeRPCsUseDetachedBackgroundTasks() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        for op in [
            "container_runtime_summary",
            "container_ls",
            "container_inspect",
            "container_stats_batch",
            "image_ls",
            "image_inspect",
            "image_storage_summary"
        ] {
            XCTAssertTrue(source.contains("op: \"\(op)\""), "missing request for \(op)")
        }
        XCTAssertTrue(source.contains("Task.detached"))
        XCTAssertTrue(source.contains("let socketPath = worker.controlSocketPath"))
        XCTAssertTrue(source.contains("let client = RuntimeControlClient(socketPath: socketPath)"))
        XCTAssertTrue(source.contains("await MainActor.run"))
        XCTAssertTrue(source.contains("nonisolated private func runRuntimeAction(socketPath: String, request: RuntimeControlRequest) async"))
    }

    func testContainerPagesCanRenderCachedDataWhileRuntimeIsStopped() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("func hasCachedContainerData(for page: ContainerDesktopPage) -> Bool"))
        XCTAssertTrue(source.contains("model.isContainerRuntimeRunning || model.hasCachedContainerData(for: page)"))
        XCTAssertTrue(source.contains("Showing cached data from"))
        XCTAssertTrue(source.contains(".disabled(model.selectedImageID == nil || !model.isContainerRuntimeRunning)"))
        XCTAssertTrue(source.contains(".disabled(!model.isContainerRuntimeRunning)"))
    }

    func testImageStorageSummaryRefreshIsManualAndLifecycleDriven() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("@Published var imageStorageSummary: RuntimeImageStorageSummary?"))
        XCTAssertTrue(source.contains("@Published var lastImageStorageSummaryUpdatedEpochMs: Int64?"))
        XCTAssertTrue(source.contains("private var wasContainerRuntimeRunning = false"))
        XCTAssertTrue(source.contains("refreshImageStorageSummaryOnLifecycleTransition(running: containerRuntimeIsRunning)"))
        XCTAssertTrue(source.contains("func refreshImages() {\n        fetchImagesIfPossible(force: true)\n        fetchImageStorageSummaryIfPossible(force: true)\n    }"))
        XCTAssertTrue(source.contains("ImageStorageSummaryPanel(summary: model.imageStorageSummary"))
        XCTAssertTrue(source.contains("Total Image Sizes:"))
        XCTAssertTrue(source.contains("Actual storage on macOS:"))
        XCTAssertTrue(source.contains("private func formatCompactBytes(_ value: UInt64) -> String"))
    }

    func testContainerTableStatusAndStateSpecificActions() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("TableColumn(\"Status\") { Text(containerStatusDisplay($0)) }"))
        XCTAssertTrue(source.contains("private func containerStatusDisplay(_ container: RuntimeContainerListItem) -> String"))
        XCTAssertTrue(source.contains("if model.isContainerRuntimeRunning, let selected = model.selectedContainer"))
        XCTAssertTrue(source.contains("if canStartContainer(selected)"))
        XCTAssertTrue(source.contains("if canStopContainer(selected)"))
        XCTAssertTrue(source.contains("private func canStartContainer(_ container: RuntimeContainerListItem) -> Bool"))
        XCTAssertTrue(source.contains("private func canStopContainer(_ container: RuntimeContainerListItem) -> Bool"))
        XCTAssertFalse(source.contains("Button(\"Start\") { model.performContainerAction(\"container_start\") }\n                    .disabled(model.selectedContainerID == nil)"))
    }
}

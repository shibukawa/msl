import AppKit
import SwiftUI
import mslCore

@main
struct MSLDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("MSL Desktop") {
            DashboardView(model: appDelegate.model)
                .frame(minWidth: 1360, minHeight: 760)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DashboardModel()
    private var statusItem: NSStatusItem?
    private var openWindowMenuItem: NSMenuItem?
    private var statusSummaryMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        model.setStatusItemUpdateHandler { [weak self] summary in
            self?.updateStatusItem(summary: summary)
        }
        model.startManager()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopManager()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.refresh()
        guard model.hasActiveWorkers else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit MSL Desktop?"
        let workerNames = model.activeWorkerNames
        if workerNames.isEmpty {
            alert.informativeText = "Running or starting VMs will be stopped before MSL Desktop quits."
        } else {
            alert.informativeText = "The following VMs are still active and will be stopped: \(workerNames.joined(separator: ", "))"
        }
        alert.addButton(withTitle: "Quit and Stop VMs")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()

        let summaryItem = NSMenuItem(title: "MSL: starting…", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open MSL Desktop", action: #selector(openDashboard), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshDashboard), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MSL Desktop", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "MSL Desktop")
            button.imagePosition = .imageLeading
            button.title = "MSL"
        }

        statusItem = item
        openWindowMenuItem = openItem
        statusSummaryMenuItem = summaryItem
    }

    private func updateStatusItem(summary: DashboardStatusSummary) {
        statusSummaryMenuItem?.title = summary.menuTitle
        openWindowMenuItem?.title = summary.runningCount > 0
            ? "Open MSL Desktop (\(summary.runningCount) running)"
            : "Open MSL Desktop"

        if let button = statusItem?.button {
            button.title = summary.buttonTitle
            button.appearsDisabled = summary.hasError
            button.toolTip = summary.toolTip
        }
    }

    @objc
    private func openDashboard() {
        model.showDashboard()
    }

    @objc
    private func refreshDashboard() {
        model.refresh()
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }
}

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case systemMetrics = "System Metrics"
    case storage = "Storage"
    case processes = "Processes"

    var id: String { rawValue }
}

enum ContainerDesktopPage: String, CaseIterable, Identifiable {
    case containers
    case images
    case runtime
    case metrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .images: return "Images"
        case .runtime: return "Runtime"
        case .metrics: return "Metrics"
        }
    }

    var systemImage: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .runtime: return "gauge.with.dots.needle.67percent"
        case .metrics: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct DashboardSelectionSummary {
    let instanceName: String
    let worker: AppManagerWorkerRecord?
}

@MainActor
final class DashboardModel: ObservableObject {
    fileprivate static let containerInstanceName = "_container"
    fileprivate static let containerListSelection = "__containers_list"
    fileprivate static let imageListSelection = "__images_list"
    fileprivate static let containerRuntimeSelection = "__containers_runtime"
    fileprivate static let containerMetricsSelection = "__containers_metrics"
    private static let hiddenInstanceNames: Set<String> = ["_imagewriter", "_container", "_podman"]

    @Published var workers: [AppManagerWorkerRecord] = []
    @Published var installedInstances: [String] = []
    @Published var managerError: String?
    @Published var selectedInstanceName: String?
    @Published var selectedTab: DashboardTab = .overview
    @Published var detail: RuntimeInstanceDetail?
    @Published var metrics: RuntimeInstanceMetrics?
    @Published var storage: RuntimeInstanceStorage?
    @Published var processes: [RuntimeProcessSnapshotItem] = []
    @Published var containerSummary: RuntimeContainerRuntimeSummary?
    @Published var containers: [RuntimeContainerListItem] = []
    @Published var containerDetail: RuntimeContainerDetail?
    @Published var containerStats: RuntimeContainerStats?
    @Published var containerStatsByID: [String: RuntimeContainerStats] = [:]
    @Published var images: [RuntimeImageListItem] = []
    @Published var imageDetail: RuntimeImageDetail?
    @Published var imageStorageSummary: RuntimeImageStorageSummary?
    @Published var selectedContainerID: String?
    @Published var selectedImageID: String?
    @Published var lastContainersUpdatedEpochMs: Int64?
    @Published var lastImagesUpdatedEpochMs: Int64?
    @Published var lastContainerSummaryUpdatedEpochMs: Int64?
    @Published var lastContainerMetricsUpdatedEpochMs: Int64?
    @Published var lastImageStorageSummaryUpdatedEpochMs: Int64?
    @Published var isLoadingProcesses = false
    @Published var selectedTabError: String?
    @Published var lastMetricsUpdatedEpochMs: Int64?
    @Published var lastStorageUpdatedEpochMs: Int64?
    @Published var lastProcessesUpdatedEpochMs: Int64?

    private let fileManager = FileManager.default
    private let paths = MSLPaths()
    private var timer: Timer?
    private var manager: AppManager?
    private var statusItemUpdateHandler: ((DashboardStatusSummary) -> Void)?
    private var detailFetchInFlight = false
    private var metricsFetchInFlight = false
    private var storageFetchInFlight = false
    private var processesFetchInFlight = false
    private var containersFetchInFlight = false
    private var imagesFetchInFlight = false
    private var containerDetailFetchInFlight = false
    private var imageDetailFetchInFlight = false
    private var imageStorageSummaryFetchInFlight = false
    private var containerSummaryFetchInFlight = false
    private var containerMetricsFetchInFlight = false
    private var selectedContainerMetricsFetchInFlight = false
    private var lastSelectedContainerMetricsUpdatedEpochMs: Int64?
    private var wasContainerRuntimeRunning = false

    var selectedContainer: RuntimeContainerListItem? {
        guard let selectedContainerID else { return nil }
        return containers.first { $0.id == selectedContainerID }
    }

    func hasCachedContainerData(for page: ContainerDesktopPage) -> Bool {
        switch page {
        case .containers:
            return lastContainersUpdatedEpochMs != nil || !containers.isEmpty
        case .images:
            return lastImagesUpdatedEpochMs != nil || !images.isEmpty || imageStorageSummary != nil
        case .runtime:
            return containerSummary != nil
        case .metrics:
            return lastContainerMetricsUpdatedEpochMs != nil || !containerStatsByID.isEmpty
        }
    }

    func cachedContainerUpdatedEpochMs(for page: ContainerDesktopPage) -> Int64? {
        switch page {
        case .containers:
            return lastContainersUpdatedEpochMs
        case .images:
            return [lastImagesUpdatedEpochMs, lastImageStorageSummaryUpdatedEpochMs].compactMap { $0 }.max()
        case .runtime:
            return lastContainerSummaryUpdatedEpochMs
        case .metrics:
            return lastContainerMetricsUpdatedEpochMs
        }
    }

    var containerWorker: AppManagerWorkerRecord? {
        workers.first(where: { $0.instanceName == Self.containerInstanceName })
    }

    var hasContainerRuntime: Bool {
        containerWorker != nil || fileManager.fileExists(atPath: paths.distroDirectory(named: Self.containerInstanceName).path)
    }

    var isContainerRuntimeRunning: Bool {
        containerWorker?.lifecycleState == .running
    }

    var selectedContainerPage: ContainerDesktopPage? {
        switch selectedInstanceName {
        case Self.containerListSelection:
            return .containers
        case Self.imageListSelection:
            return .images
        case Self.containerRuntimeSelection:
            return .runtime
        case Self.containerMetricsSelection:
            return .metrics
        default:
            return nil
        }
    }

    var activeWorkers: [AppManagerWorkerRecord] {
        workers.filter { $0.lifecycleState == .running || $0.lifecycleState == .starting }
    }

    var hasActiveWorkers: Bool {
        !activeWorkers.isEmpty
    }

    var activeWorkerNames: [String] {
        activeWorkers.map(\.instanceName).sorted()
    }

    var selectedSummary: DashboardSelectionSummary? {
        guard let selectedInstanceName else { return nil }
        return DashboardSelectionSummary(
            instanceName: selectedInstanceName,
            worker: workers.first(where: { $0.instanceName == selectedInstanceName })
        )
    }

    func setStatusItemUpdateHandler(_ handler: @escaping (DashboardStatusSummary) -> Void) {
        statusItemUpdateHandler = handler
    }

    func startManager() {
        let logger = MSLLogger(
            logFile: paths.appLogs.appendingPathComponent("desktop.log", isDirectory: false),
            fileManager: fileManager
        )
        let executablePath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/msl", isDirectory: false)
            .path
        let manager = AppManager(paths: paths, fileManager: fileManager, logger: logger, executablePath: executablePath)
        manager.setShowWindowHandler { [weak self] in
            self?.showWindow()
        }
        self.manager = manager
        do {
            try manager.start()
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        } catch {
            managerError = String(describing: error)
        }
    }

    func refresh() {
        installedInstances = (try? fileManager.contentsOfDirectory(at: paths.distrosDir, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
            .map(\.lastPathComponent)
            .filter { !Self.hiddenInstanceNames.contains($0) }
            .sorted()) ?? []
        workers = manager?.snapshot().workers ?? []
        let containerRuntimeWasRunning = wasContainerRuntimeRunning
        let containerRuntimeIsRunning = isContainerRuntimeRunning
        wasContainerRuntimeRunning = containerRuntimeIsRunning
        syncSelection()
        statusItemUpdateHandler?(statusSummary())
        if containerRuntimeWasRunning != containerRuntimeIsRunning {
            refreshImageStorageSummaryOnLifecycleTransition(running: containerRuntimeIsRunning)
        }
        refreshSelectedDataIfNeeded(force: false)
    }

    func select(instanceName: String) {
        guard selectedInstanceName != instanceName else { return }
        selectedInstanceName = instanceName
        detail = nil
        metrics = nil
        storage = nil
        processes = []
        selectedTabError = nil
        lastMetricsUpdatedEpochMs = nil
        lastStorageUpdatedEpochMs = nil
        lastProcessesUpdatedEpochMs = nil
        selectedContainerID = nil
        selectedImageID = nil
        containerDetail = nil
        containerStats = nil
        imageDetail = nil
        refreshSelectedDataIfNeeded(force: true)
    }

    func setSelectedTab(_ tab: DashboardTab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        selectedTabError = nil
        refreshSelectedDataIfNeeded(force: true)
    }

    func start(instanceName: String) {
        Task {
            do {
                let client = ManagerControlClient(socketPath: paths.managerSocketFile.path)
                _ = try client.send(ManagerControlRequest(op: "ensure_instance", instance: instanceName))
                refresh()
            } catch {
                managerError = String(describing: error)
                statusItemUpdateHandler?(statusSummary())
            }
        }
    }

    func stop(instanceName: String) {
        Task {
            do {
                let client = ManagerControlClient(socketPath: paths.managerSocketFile.path)
                _ = try client.send(ManagerControlRequest(op: "stop_instance", instance: instanceName))
                refresh()
            } catch {
                managerError = String(describing: error)
                statusItemUpdateHandler?(statusSummary())
            }
        }
    }

    func refreshProcesses() {
        refreshSelectedDataIfNeeded(force: true, only: .processes)
    }

    func refreshContainers() {
        fetchContainersIfPossible(force: true)
    }

    func refreshImages() {
        fetchImagesIfPossible(force: true)
        fetchImageStorageSummaryIfPossible(force: true)
    }

    func startContainerRuntime() {
        start(instanceName: Self.containerInstanceName)
    }

    func selectContainer(id: String?) {
        guard selectedContainerID != id else { return }
        selectedContainerID = id
        containerDetail = nil
        containerStats = nil
    }

    func selectImage(id: String?) {
        guard selectedImageID != id else { return }
        selectedImageID = id
        imageDetail = nil
        fetchImageDetailIfPossible(force: true)
    }

    func showDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    func stopManager() {
        timer?.invalidate()
        timer = nil
        manager?.stop()
        manager = nil
    }

    private func showWindow() {
        showDashboard()
    }

    private func syncSelection() {
        if selectedInstanceName == nil {
            selectedInstanceName = installedInstances.first
            return
        }
        guard let selectedInstanceName else { return }
        if selectedContainerPage != nil {
            return
        }
        if !installedInstances.contains(selectedInstanceName) {
            self.selectedInstanceName = installedInstances.first
        }
    }

    private func refreshSelectedDataIfNeeded(force: Bool, only tab: DashboardTab? = nil) {
        if selectedContainerPage != nil {
            refreshSelectedContainerDataIfNeeded(force: force)
            return
        }
        guard let selectedInstanceName else { return }
        let selectedWorker = workers.first(where: { $0.instanceName == selectedInstanceName })

        if (tab == nil || tab == .overview), !detailFetchInFlight {
            detailFetchInFlight = true
            Task {
                await fetchDetail(instanceName: selectedInstanceName, worker: selectedWorker)
                await MainActor.run {
                    self.detailFetchInFlight = false
                }
            }
        }

        guard let selectedWorker else {
            return
        }
        let now = nowEpochMs()
        switch tab ?? selectedTab {
        case .overview:
            break
        case .systemMetrics:
            if force || shouldFetch(lastUpdatedEpochMs: lastMetricsUpdatedEpochMs, now: now, intervalMs: 2_000) {
                fetchMetricsIfPossible(instanceName: selectedInstanceName, worker: selectedWorker)
            }
        case .storage:
            if force || shouldFetch(lastUpdatedEpochMs: lastStorageUpdatedEpochMs, now: now, intervalMs: 5_000) {
                fetchStorageIfPossible(instanceName: selectedInstanceName, worker: selectedWorker)
            }
        case .processes:
            if force || shouldFetch(lastUpdatedEpochMs: lastProcessesUpdatedEpochMs, now: now, intervalMs: 4_000) {
                fetchProcessesIfPossible(instanceName: selectedInstanceName, worker: selectedWorker)
            }
        }
    }

    private func refreshSelectedContainerDataIfNeeded(force: Bool) {
        switch selectedContainerPage {
        case .containers:
            fetchContainerSummaryIfPossible()
            fetchContainersIfPossible(force: force)
            fetchContainerDetailIfPossible(force: force)
            fetchSelectedContainerMetricsIfPossible(force: force)
            fetchContainerMetricsIfPossible(force: force, selectedOnly: false)
        case .images:
            fetchContainerSummaryIfPossible()
            fetchImagesIfPossible(force: force)
            fetchImageDetailIfPossible(force: force)
            if force {
                fetchImageStorageSummaryIfPossible(force: true)
            }
        case .runtime:
            fetchContainerSummaryIfPossible()
        case .metrics:
            fetchContainerSummaryIfPossible()
            fetchContainersIfPossible(force: force)
            fetchContainerMetricsIfPossible(force: force, selectedOnly: false)
        case nil:
            break
        }
    }

    private func shouldFetch(lastUpdatedEpochMs: Int64?, now: Int64, intervalMs: Int64) -> Bool {
        guard let lastUpdatedEpochMs else { return true }
        return (now - lastUpdatedEpochMs) >= intervalMs
    }

    private func fetchDetail(instanceName: String, worker: AppManagerWorkerRecord?) async {
        do {
            if let worker {
                let client = RuntimeControlClient(socketPath: worker.controlSocketPath)
                let response = try client.send(RuntimeControlRequest(op: "instance_detail", instance: instanceName))
                await MainActor.run {
                    self.detail = response.detail
                    self.selectedTabError = response.ok ? self.selectedTabError : (response.error ?? "failed to load details")
                }
            } else {
                await MainActor.run {
                    self.detail = RuntimeInstanceDetail(
                        instance: instanceName,
                        vmState: "Stopped",
                        lifecycleState: "stopped",
                        activeSessionCount: 0,
                        uptimeSeconds: nil,
                        guestIPv4: nil,
                        portForwardCount: 0,
                        lastError: nil,
                        lastTransitionEpochMs: nowEpochMs()
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.selectedTabError = String(describing: error)
            }
        }
    }

    private func fetchMetricsIfPossible(instanceName: String, worker: AppManagerWorkerRecord) {
        guard worker.lifecycleState == .running, !metricsFetchInFlight else { return }
        metricsFetchInFlight = true
        Task {
            do {
                let client = RuntimeControlClient(socketPath: worker.controlSocketPath)
                let response = try client.send(RuntimeControlRequest(op: "instance_metrics", instance: instanceName))
                await MainActor.run {
                    self.metrics = response.metrics
                    self.lastMetricsUpdatedEpochMs = response.metrics?.sampledAtEpochMs
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.metricsFetchInFlight = false
            }
        }
    }

    private func fetchStorageIfPossible(instanceName: String, worker: AppManagerWorkerRecord) {
        guard worker.lifecycleState == .running, !storageFetchInFlight else { return }
        storageFetchInFlight = true
        Task {
            do {
                let client = RuntimeControlClient(socketPath: worker.controlSocketPath)
                let response = try client.send(RuntimeControlRequest(op: "instance_storage", instance: instanceName))
                await MainActor.run {
                    self.storage = response.storage
                    self.lastStorageUpdatedEpochMs = nowEpochMs()
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.storageFetchInFlight = false
            }
        }
    }

    private func fetchProcessesIfPossible(instanceName: String, worker: AppManagerWorkerRecord) {
        guard worker.lifecycleState == .running, !processesFetchInFlight else { return }
        processesFetchInFlight = true
        isLoadingProcesses = true
        Task {
            defer {
                Task { @MainActor in
                    self.processesFetchInFlight = false
                    self.isLoadingProcesses = false
                }
            }
            do {
                let client = RuntimeControlClient(socketPath: worker.controlSocketPath)
                let response = try client.send(RuntimeControlRequest(op: "instance_processes", instance: instanceName))
                await MainActor.run {
                    self.processes = response.processes ?? []
                    self.lastProcessesUpdatedEpochMs = nowEpochMs()
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
        }
    }

    private func fetchContainerSummaryIfPossible() {
        guard let worker = containerWorker, worker.lifecycleState == .running, !containerSummaryFetchInFlight else { return }
        let now = nowEpochMs()
        guard shouldFetch(lastUpdatedEpochMs: lastContainerSummaryUpdatedEpochMs, now: now, intervalMs: 5_000) else { return }
        containerSummaryFetchInFlight = true
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(op: "container_runtime_summary", instance: Self.containerInstanceName)
        Task.detached {
            do {
                let client = RuntimeControlClient(socketPath: socketPath)
                let response = try client.send(request)
                await MainActor.run {
                    if self.containerSummary != response.containerRuntimeSummary {
                        self.containerSummary = response.containerRuntimeSummary
                    }
                    self.lastContainerSummaryUpdatedEpochMs = response.containerRuntimeSummary?.sampledAtEpochMs ?? nowEpochMs()
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.containerSummaryFetchInFlight = false
            }
        }
    }

    private func fetchContainersIfPossible(force: Bool) {
        guard let worker = containerWorker, worker.lifecycleState == .running, !containersFetchInFlight else { return }
        let now = nowEpochMs()
        guard force || shouldFetch(lastUpdatedEpochMs: lastContainersUpdatedEpochMs, now: now, intervalMs: 5_000) else { return }
        containersFetchInFlight = true
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(op: "container_ls", instance: Self.containerInstanceName)
        Task.detached {
            do {
                let client = RuntimeControlClient(socketPath: socketPath)
                let response = try client.send(request)
                await MainActor.run {
                    let next = response.containers ?? []
                    if self.containers != next {
                        self.containers = next
                    }
                    self.lastContainersUpdatedEpochMs = nowEpochMs()
                    if self.selectedContainerID == nil {
                        self.selectedContainerID = self.containers.first?.id
                    }
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.containersFetchInFlight = false
            }
        }
    }

    private func fetchContainerDetailIfPossible(force: Bool) {
        guard let worker = containerWorker, worker.lifecycleState == .running,
              let id = selectedContainerID, !containerDetailFetchInFlight else { return }
        containerDetailFetchInFlight = true
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(op: "container_inspect", instance: Self.containerInstanceName, containerID: id)
        Task.detached {
            do {
                let client = RuntimeControlClient(socketPath: socketPath)
                let detailResponse = try client.send(request)
                await MainActor.run {
                    guard self.selectedContainerID == id else { return }
                    self.containerDetail = detailResponse.containerDetail
                    self.containerStats = self.containerStatsByID[id]
                    if let error = detailResponse.error, !detailResponse.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.containerDetailFetchInFlight = false
            }
        }
    }

    private func fetchContainerMetricsIfPossible(force: Bool, selectedOnly: Bool) {
        guard let worker = containerWorker, worker.lifecycleState == .running, !containerMetricsFetchInFlight else { return }
        let now = nowEpochMs()
        guard force || shouldFetch(lastUpdatedEpochMs: lastContainerMetricsUpdatedEpochMs, now: now, intervalMs: 8_000) else { return }
        let ids = containers.filter(isUpContainer).map(\.id)
        guard !ids.isEmpty else { return }
        containerMetricsFetchInFlight = true
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(
            op: "container_stats_batch",
            instance: Self.containerInstanceName,
            containerIDs: ids
        )
        Task.detached {
            do {
                let client = RuntimeControlClient(socketPath: socketPath)
                let response = try client.send(request)
                await MainActor.run {
                    var next = self.containerStatsByID
                    for stats in response.containerStatsList ?? [] {
                        next[stats.id] = stats
                    }
                    if next != self.containerStatsByID {
                        self.containerStatsByID = next
                    }
                    if let selected = self.selectedContainerID {
                        self.containerStats = next[selected]
                    }
                    self.lastContainerMetricsUpdatedEpochMs = nowEpochMs()
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.containerMetricsFetchInFlight = false
            }
        }
    }

    private func fetchSelectedContainerMetricsIfPossible(force: Bool) {
        guard let worker = containerWorker, worker.lifecycleState == .running,
              let selectedContainer = selectedContainer,
              isUpContainer(selectedContainer),
              let id = selectedContainerID,
              !selectedContainerMetricsFetchInFlight else { return }
        let now = nowEpochMs()
        guard force || shouldFetch(lastUpdatedEpochMs: lastSelectedContainerMetricsUpdatedEpochMs, now: now, intervalMs: 2_000) else { return }
        selectedContainerMetricsFetchInFlight = true
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(
            op: "container_stats_batch",
            instance: Self.containerInstanceName,
            containerIDs: [id]
        )
        Task.detached {
            do {
                let client = RuntimeControlClient(socketPath: socketPath)
                let response = try client.send(request)
                await MainActor.run {
                    guard self.selectedContainerID == id else { return }
                    var next = self.containerStatsByID
                    for stats in response.containerStatsList ?? [] {
                        next[stats.id] = stats
                    }
                    if next != self.containerStatsByID {
                        self.containerStatsByID = next
                    }
                    self.containerStats = next[id]
                    self.lastSelectedContainerMetricsUpdatedEpochMs = nowEpochMs()
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.selectedContainerMetricsFetchInFlight = false
            }
        }
    }

    private func fetchImagesIfPossible(force: Bool) {
        guard let worker = containerWorker, worker.lifecycleState == .running, !imagesFetchInFlight else { return }
        let now = nowEpochMs()
        guard force || shouldFetch(lastUpdatedEpochMs: lastImagesUpdatedEpochMs, now: now, intervalMs: 5_000) else { return }
        imagesFetchInFlight = true
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(op: "image_ls", instance: Self.containerInstanceName)
        Task.detached {
            do {
                let client = RuntimeControlClient(socketPath: socketPath)
                let response = try client.send(request)
                await MainActor.run {
                    let next = response.images ?? []
                    if self.images != next {
                        self.images = next
                    }
                    self.lastImagesUpdatedEpochMs = nowEpochMs()
                    if self.selectedImageID == nil {
                        self.selectedImageID = self.images.first?.id
                    }
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.imagesFetchInFlight = false
            }
        }
    }

    private func fetchImageDetailIfPossible(force: Bool) {
        guard let worker = containerWorker, worker.lifecycleState == .running,
              let id = selectedImageID, !imageDetailFetchInFlight else { return }
        imageDetailFetchInFlight = true
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(op: "image_inspect", instance: Self.containerInstanceName, imageID: id)
        Task.detached {
            do {
                let client = RuntimeControlClient(socketPath: socketPath)
                let response = try client.send(request)
                await MainActor.run {
                    guard self.selectedImageID == id else { return }
                    self.imageDetail = response.imageDetail
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.imageDetailFetchInFlight = false
            }
        }
    }

    private func fetchImageStorageSummaryIfPossible(force: Bool) {
        guard let worker = containerWorker, worker.lifecycleState == .running, !imageStorageSummaryFetchInFlight else { return }
        let now = nowEpochMs()
        guard force || shouldFetch(lastUpdatedEpochMs: lastImageStorageSummaryUpdatedEpochMs, now: now, intervalMs: 60_000) else { return }
        imageStorageSummaryFetchInFlight = true
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(op: "image_storage_summary", instance: Self.containerInstanceName)
        Task.detached {
            do {
                let client = RuntimeControlClient(socketPath: socketPath)
                let response = try client.send(request)
                await MainActor.run {
                    if let summary = response.imageStorageSummary {
                        self.imageStorageSummary = summary
                        self.lastImageStorageSummaryUpdatedEpochMs = summary.sampledAtEpochMs
                    }
                    if let error = response.error, !response.ok {
                        self.selectedTabError = error
                    }
                }
            } catch {
                await MainActor.run {
                    self.selectedTabError = String(describing: error)
                }
            }
            await MainActor.run {
                self.imageStorageSummaryFetchInFlight = false
            }
        }
    }

    private func refreshImageStorageSummaryOnLifecycleTransition(running: Bool) {
        if running {
            fetchImageStorageSummaryIfPossible(force: true)
        } else {
            refreshHostImageStorageSummaryFromDisk()
        }
    }

    private func refreshHostImageStorageSummaryFromDisk() {
        let diskURLs = [
            paths.distroBaseDiskFile(named: Self.containerInstanceName),
            paths.distroStateDiskFile(named: Self.containerInstanceName),
            paths.distroStateTemplateDiskFile(named: Self.containerInstanceName),
            paths.distroDiskFile(named: Self.containerInstanceName)
        ]
        let existing = diskURLs.filter { fileManager.fileExists(atPath: $0.path) }
        let logicalValues = existing.compactMap { logicalBytes(of: $0).flatMap(UInt64.init) }
        let allocatedValues = existing.compactMap { allocatedBytes(of: $0).flatMap(UInt64.init) }
        let sampledAt = nowEpochMs()
        imageStorageSummary = RuntimeImageStorageSummary(
            guestImageTotalBytes: imageStorageSummary?.guestImageTotalBytes,
            hostLogicalBytes: logicalValues.isEmpty ? imageStorageSummary?.hostLogicalBytes : logicalValues.reduce(0, +),
            hostAllocatedBytes: allocatedValues.isEmpty ? imageStorageSummary?.hostAllocatedBytes : allocatedValues.reduce(0, +),
            sampledAtEpochMs: sampledAt
        )
        lastImageStorageSummaryUpdatedEpochMs = sampledAt
    }

    private func allocatedBytes(of fileURL: URL) -> Int64? {
        let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if let total = values?.totalFileAllocatedSize {
            return Int64(total)
        }
        if let allocated = values?.fileAllocatedSize {
            return Int64(allocated)
        }
        return nil
    }

    private func logicalBytes(of fileURL: URL) -> Int64? {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize else {
            return nil
        }
        return Int64(size)
    }

    func performContainerAction(_ op: String) {
        guard let worker = containerWorker, let id = selectedContainerID else { return }
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(op: op, instance: Self.containerInstanceName, containerID: id)
        Task.detached {
            await self.runRuntimeAction(socketPath: socketPath, request: request)
            await MainActor.run { self.refreshContainers() }
        }
    }

    func performImageAction(_ op: String) {
        guard let worker = containerWorker, let id = selectedImageID else { return }
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(op: op, instance: Self.containerInstanceName, imageID: id)
        Task.detached {
            await self.runRuntimeAction(socketPath: socketPath, request: request)
            await MainActor.run { self.refreshImages() }
        }
    }

    func performPrune(_ op: String) {
        guard let worker = containerWorker else { return }
        let socketPath = worker.controlSocketPath
        let request = RuntimeControlRequest(op: op, instance: Self.containerInstanceName)
        Task.detached {
            await self.runRuntimeAction(socketPath: socketPath, request: request)
            await MainActor.run {
                self.refreshContainers()
                self.refreshImages()
            }
        }
    }

    nonisolated private func runRuntimeAction(socketPath: String, request: RuntimeControlRequest) async {
        do {
            let client = RuntimeControlClient(socketPath: socketPath)
            let response = try client.send(request)
            await MainActor.run {
                if !response.ok {
                    self.selectedTabError = response.error ?? "container action failed"
                } else if let reclaimed = response.meta?["reclaimed"], !reclaimed.isEmpty {
                    self.selectedTabError = reclaimed
                }
            }
        } catch {
            await MainActor.run {
                self.selectedTabError = String(describing: error)
            }
        }
    }

    private func statusSummary() -> DashboardStatusSummary {
        let runningCount = workers.filter { $0.lifecycleState == .running }.count
        let bootingCount = workers.filter { $0.lifecycleState == .starting }.count
        let hasError = managerError != nil || workers.contains { $0.lastErrorMessage?.isEmpty == false }
        let statusText: String
        if hasError {
            statusText = "error"
        } else if runningCount > 0 {
            statusText = "\(runningCount) running"
        } else if bootingCount > 0 {
            statusText = "\(bootingCount) starting"
        } else {
            statusText = "idle"
        }
        let toolTip = managerError ?? "Installed: \(installedInstances.count), Running: \(runningCount), Starting: \(bootingCount)"
        return DashboardStatusSummary(
            runningCount: runningCount,
            menuTitle: "MSL status: \(statusText)",
            buttonTitle: runningCount > 0 ? "MSL \(runningCount)" : "MSL",
            toolTip: toolTip,
            hasError: hasError
        )
    }
}

struct DashboardStatusSummary {
    let runningCount: Int
    let menuTitle: String
    let buttonTitle: String
    let toolTip: String
    let hasError: Bool
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.selectedInstanceName },
                set: { newValue in
                    if let newValue {
                        model.select(instanceName: newValue)
                    }
                }
            )) {
                ForEach(model.installedInstances, id: \.self) { name in
                    SidebarRow(
                        name: name,
                        worker: model.workers.first(where: { $0.instanceName == name }),
                        onStart: { model.start(instanceName: name) },
                        onStop: { model.stop(instanceName: name) }
                    )
                    .tag(name)
                }
                if model.hasContainerRuntime {
                    Section("Containers") {
                        ForEach(ContainerDesktopPage.allCases) { page in
                            ContainerSidebarRow(page: page)
                            .tag(selectionKey(for: page))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                if let managerError = model.managerError {
                    Text(managerError)
                        .foregroundStyle(.red)
                }
                if let page = model.selectedContainerPage {
                    ContainerDashboardPageView(model: model, page: page)
                } else if let selected = model.selectedSummary {
                    DetailHeader(summary: selected, detail: model.detail)
                    Picker("Tab", selection: Binding(
                        get: { model.selectedTab },
                        set: { model.setSelectedTab($0) }
                    )) {
                        ForEach(DashboardTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)

                    if let selectedTabError = model.selectedTabError {
                        Text(selectedTabError)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }

                    Group {
                        switch model.selectedTab {
                        case .overview:
                            OverviewTab(detail: model.detail)
                        case .systemMetrics:
                            SystemMetricsTab(metrics: model.metrics, updatedEpochMs: model.lastMetricsUpdatedEpochMs)
                        case .storage:
                            StorageTab(storage: model.storage, updatedEpochMs: model.lastStorageUpdatedEpochMs)
                        case .processes:
                            ProcessesTab(
                                processes: model.processes,
                                isLoading: model.isLoadingProcesses,
                                updatedEpochMs: model.lastProcessesUpdatedEpochMs,
                                onRefresh: { model.refreshProcesses() }
                            )
                        }
                    }
                    Spacer()
                } else {
                    VStack(alignment: .center, spacing: 12) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No VM Selected")
                            .font(.title3.weight(.semibold))
                        Text("Choose an installed VM from the sidebar.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(20)
        }
        .navigationTitle("MSL Desktop")
    }
}

@MainActor
private func selectionKey(for page: ContainerDesktopPage) -> String {
    switch page {
    case .containers: return DashboardModel.containerListSelection
    case .images: return DashboardModel.imageListSelection
    case .runtime: return DashboardModel.containerRuntimeSelection
    case .metrics: return DashboardModel.containerMetricsSelection
    }
}

private struct SidebarRow: View {
    let name: String
    let worker: AppManagerWorkerRecord?
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name)
                    .font(.headline)
                Spacer()
                StatusBadge(text: worker?.lifecycleState.rawValue.capitalized ?? "Stopped")
            }
            Text(worker?.lastErrorMessage ?? "No recent errors")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Button("Start", action: onStart)
                    .disabled(worker?.lifecycleState == .running || worker?.lifecycleState == .starting)
                Button("Stop", action: onStop)
                    .disabled(worker == nil || worker?.lifecycleState == .stopped || worker?.lifecycleState == .stopping)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }
}

private struct ContainerSidebarRow: View {
    let page: ContainerDesktopPage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(page.title, systemImage: page.systemImage)
                .font(.headline)
        }
        .padding(.vertical, 6)
    }
}

private struct ContainerDashboardPageView: View {
    @ObservedObject var model: DashboardModel
    let page: ContainerDesktopPage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(page.title)
                        .font(.largeTitle.weight(.semibold))
                }
                Spacer()
                if model.containerWorker?.lifecycleState != .running {
                    Button("Start Runtime") { model.startContainerRuntime() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let selectedTabError = model.selectedTabError {
                Text(selectedTabError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            let canShowPanel = model.isContainerRuntimeRunning || model.hasCachedContainerData(for: page)
            if !model.isContainerRuntimeRunning, let updated = model.cachedContainerUpdatedEpochMs(for: page) {
                Text("Showing cached data from \(formatDate(epochMs: updated)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if canShowPanel {
                switch page {
                case .containers:
                    ContainerListPanel(model: model)
                case .images:
                    ImageListPanel(model: model)
                case .runtime:
                    ContainerRuntimePanel(summary: model.containerSummary)
                case .metrics:
                    ContainerMetricsPanel(containers: model.containers, statsByID: model.containerStatsByID, updatedEpochMs: model.lastContainerMetricsUpdatedEpochMs)
                }
            } else {
                Text("Start the internal container runtime to inspect containers and images.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

private struct ContainerListPanel: View {
    @ObservedObject var model: DashboardModel
    @State private var sortOrder = [KeyPathComparator(\RuntimeContainerListItem.name)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                UpdatedAtView(epochMs: model.lastContainersUpdatedEpochMs)
                Spacer()
                Button("Refresh") { model.refreshContainers() }
                if model.isContainerRuntimeRunning, let selected = model.selectedContainer {
                    if canStartContainer(selected) {
                        Button("Start") { model.performContainerAction("container_start") }
                    }
                    if canStopContainer(selected) {
                        Button("Stop") { model.performContainerAction("container_stop") }
                        Button("Restart") { model.performContainerAction("container_restart") }
                    }
                    Button("Remove") {
                        if confirmDestructive(title: "Remove Container?", text: "This removes the selected container.") {
                            model.performContainerAction("container_rm")
                        }
                    }
                }
                Button("Prune") {
                    if confirmDestructive(title: "Prune Stopped Containers?", text: "This removes all stopped containers.") {
                        model.performPrune("container_prune")
                    }
                }
                .disabled(!model.isContainerRuntimeRunning)
            }
            .buttonStyle(.bordered)
            HSplitView {
                Table(model.containers.sorted(using: sortOrder), selection: Binding(
                    get: { model.selectedContainerID },
                    set: { model.selectContainer(id: $0) }
                ), sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Image", value: \.image)
                    TableColumn("Status") { Text(containerStatusDisplay($0)) }
                        .width(min: 92, ideal: 120, max: 160)
                    TableColumn("CPU") { item in
                        Text(containerCPUDisplay(item, stats: model.containerStatsByID[item.id]))
                    }
                    .width(min: 56, ideal: 70, max: 82)
                    TableColumn("Memory") { item in
                        Text(containerMemoryDisplay(item, stats: model.containerStatsByID[item.id]))
                    }
                    .width(min: 80, ideal: 96, max: 120)
                    TableColumn("Ports") { Text($0.ports ?? "-").lineLimit(1) }
                }
                .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity)
                ContainerDetailPanel(detail: model.containerDetail)
                    .frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity)
            }
        }
    }
}

private struct ContainerRuntimePanel: View {
    let summary: RuntimeContainerRuntimeSummary?

    var body: some View {
        MetricSection(title: "Runtime") {
            DetailMetricRow(label: "containerd", value: summary?.containerdHealthy == true ? "healthy" : "unavailable")
            DetailMetricRow(label: "buildkit", value: summary?.buildkitdHealthy == true ? "healthy" : "unavailable")
            DetailMetricRow(label: "Btrfs dedupe", value: containerDedupeStatusDisplay(summary))
            DetailMetricRow(label: "Containers", value: summary?.containerCount.map(String.init) ?? "-")
            DetailMetricRow(label: "Images", value: summary?.imageCount.map(String.init) ?? "-")
            DetailMetricRow(label: "Updated", value: summary.map { formatDate(epochMs: $0.sampledAtEpochMs) } ?? "-")
        }
        Spacer()
    }
}

private func containerDedupeStatusDisplay(_ summary: RuntimeContainerRuntimeSummary?) -> String {
    guard let summary else { return "-" }
    if summary.dedupeEnabled != true {
        return "disabled"
    }
    if summary.dedupeHealthy == true {
        return "healthy"
    }
    return summary.dedupeDetail ?? "unavailable"
}

private struct ContainerMetricsPanel: View {
    let containers: [RuntimeContainerListItem]
    let statsByID: [String: RuntimeContainerStats]
    let updatedEpochMs: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UpdatedAtView(epochMs: updatedEpochMs)
            Table(containers.filter(isUpContainer)) {
                TableColumn("Name", value: \.name)
                TableColumn("CPU") { item in
                    Text(percentString(statsByID[item.id]?.cpuPercent))
                }
                TableColumn("Memory") { item in
                    Text(statsByID[item.id]?.memoryUsageBytes.map(formatBytes) ?? "-")
                }
                TableColumn("Memory Limit") { item in
                    Text(formatContainerMemoryLimit(statsByID[item.id]))
                }
                TableColumn("Network RX") { item in
                    Text(statsByID[item.id]?.networkRxBytes.map(formatBytes) ?? "-")
                }
                TableColumn("Network TX") { item in
                    Text(statsByID[item.id]?.networkTxBytes.map(formatBytes) ?? "-")
                }
            }
        }
    }
}

private func isUpContainer(_ container: RuntimeContainerListItem) -> Bool {
    if let state = normalizedContainerLifecycleText(container.state),
       state == "running" || state == "up" {
        return true
    }
    guard let status = normalizedContainerLifecycleText(container.status) else {
        return false
    }
    return status == "up" || status.hasPrefix("up ")
}

private func containerStatusDisplay(_ container: RuntimeContainerListItem) -> String {
    let status = container.status?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let status, !status.isEmpty {
        return status
    }
    let state = container.state?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let state, !state.isEmpty {
        return state
    }
    return "-"
}

private func containerCPUDisplay(_ container: RuntimeContainerListItem, stats: RuntimeContainerStats?) -> String {
    guard isUpContainer(container) else { return "-" }
    return percentString(stats?.cpuPercent)
}

private func containerMemoryDisplay(_ container: RuntimeContainerListItem, stats: RuntimeContainerStats?) -> String {
    guard isUpContainer(container) else { return "-" }
    return stats?.memoryUsageBytes.map(formatBytes) ?? "-"
}

private func canStartContainer(_ container: RuntimeContainerListItem) -> Bool {
    guard let state = normalizedContainerLifecycleText(container.state) ?? normalizedContainerLifecycleText(container.status) else {
        return true
    }
    return !(state == "running" || state == "up" || state.hasPrefix("up "))
}

private func canStopContainer(_ container: RuntimeContainerListItem) -> Bool {
    guard let state = normalizedContainerLifecycleText(container.state) ?? normalizedContainerLifecycleText(container.status) else {
        return false
    }
    return state == "running" || state == "up" || state.hasPrefix("up ")
}

private func normalizedContainerLifecycleText(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let trimmed, !trimmed.isEmpty, trimmed != "-" else { return nil }
    return trimmed
}

private struct ContainerDetailPanel: View {
    let detail: RuntimeContainerDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let detail {
                    MetricSection(title: detail.name) {
                        DetailMetricRow(label: "ID", value: detail.id)
                        DetailMetricRow(label: "Image", value: detail.image ?? "-")
                        DetailMetricRow(label: "State", value: detail.state ?? "-")
                        DetailMetricRow(label: "Command", value: detail.command ?? "-")
                        DetailMetricRow(label: "Created", value: detail.created ?? "-")
                    }
                    stringListSection("Ports", detail.ports)
                    stringListSection("Storage / Mounts", detail.mounts)
                    stringListSection("Networks", detail.networks)
                    keyValueSection("Labels", detail.labels)
                } else {
                    Text("Select a container to inspect details.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 12)
        }
    }
}

private struct ImageListPanel: View {
    @ObservedObject var model: DashboardModel
    @State private var sortOrder = [KeyPathComparator(\RuntimeImageListItem.repository)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                UpdatedAtView(epochMs: model.lastImagesUpdatedEpochMs)
                Spacer()
                Button("Refresh") { model.refreshImages() }
                Button("Remove Image") {
                    if confirmDestructive(title: "Remove Image?", text: "This removes the selected image if no container depends on it.") {
                        model.performImageAction("image_rm")
                    }
                }
                .disabled(model.selectedImageID == nil || !model.isContainerRuntimeRunning)
                Button("Prune Unused") {
                    if confirmDestructive(title: "Prune Unused Images?", text: "This removes unused images from the container runtime.") {
                        model.performPrune("image_prune")
                    }
                }
                .disabled(!model.isContainerRuntimeRunning)
            }
            .buttonStyle(.bordered)
            ImageStorageSummaryPanel(summary: model.imageStorageSummary)
            HSplitView {
                Table(model.images.sorted(using: sortOrder), selection: Binding(
                    get: { model.selectedImageID },
                    set: { model.selectImage(id: $0) }
                ), sortOrder: $sortOrder) {
                    TableColumn("Repository", value: \.repository)
                    TableColumn("Tag", value: \.tag)
                    TableColumn("Image ID", value: \.id) { Text($0.id).lineLimit(1) }
                    TableColumn("Created") { Text($0.created ?? "-") }
                    TableColumn("Size") { Text($0.size ?? "-") }
                        .width(min: 80, ideal: 96, max: 120)
                }
                .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity)
                ImageDetailPanel(detail: model.imageDetail)
                    .frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity)
            }
        }
    }
}

private struct ImageStorageSummaryPanel: View {
    let summary: RuntimeImageStorageSummary?

    var body: some View {
        Text("Total Image Sizes: \(summary?.guestImageTotalBytes.map(formatCompactBytes) ?? "-") / Capacity \(summary?.hostLogicalBytes.map(formatCompactBytes) ?? "-") (Actual storage on macOS: \(summary?.hostAllocatedBytes.map(formatCompactBytes) ?? "-"))")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .textSelection(.enabled)
    }
}

private struct ImageDetailPanel: View {
    let detail: RuntimeImageDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let detail {
                    MetricSection(title: "Image") {
                        DetailMetricRow(label: "ID", value: detail.id)
                        DetailMetricRow(label: "Architecture", value: detail.architecture ?? "-")
                        DetailMetricRow(label: "OS", value: detail.os ?? "-")
                        DetailMetricRow(label: "Created", value: detail.created ?? "-")
                        DetailMetricRow(label: "Size", value: detail.sizeBytes.map(formatBytes) ?? "-")
                    }
                    stringListSection("Tags", detail.repoTags)
                    stringListSection("Digests", detail.repoDigests)
                    keyValueSection("Labels", detail.labels)
                } else {
                    Text("Select an image to inspect details.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 12)
        }
    }
}

private struct DetailHeader: View {
    let summary: DashboardSelectionSummary
    let detail: RuntimeInstanceDetail?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.instanceName)
                    .font(.largeTitle.weight(.semibold))
                Text("State: \(detail?.lifecycleState.capitalized ?? summary.worker?.lifecycleState.rawValue.capitalized ?? "Stopped")")
                    .foregroundStyle(.secondary)
                if let uptimeSeconds = detail?.uptimeSeconds {
                    Text("Uptime: \(formatDuration(seconds: uptimeSeconds))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let guestIPv4 = detail?.guestIPv4 {
                    Text("Guest IP: \(guestIPv4)")
                        .font(.callout.monospacedDigit())
                }
                Text("Port forwards: \(detail?.portForwardCount ?? 0)")
                    .font(.callout.monospacedDigit())
            }
        }
    }
}

private struct OverviewTab: View {
    let detail: RuntimeInstanceDetail?

    var body: some View {
        if let detail {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                gridRow("VM State", detail.vmState)
                gridRow("Lifecycle", detail.lifecycleState)
                gridRow("Active Sessions", "\(detail.activeSessionCount)")
                gridRow("Uptime", detail.uptimeSeconds.map(formatDuration(seconds:)) ?? "-")
                gridRow("Guest IPv4", detail.guestIPv4 ?? "-")
                gridRow("Port Forwards", "\(detail.portForwardCount)")
                gridRow("Last Error", detail.lastError ?? "-")
            }
        } else {
            Text("Select a VM to inspect details.")
                .foregroundStyle(.secondary)
        }
    }

    private func gridRow(_ label: String, _ value: String) -> GridRow<some View> {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private struct SystemMetricsTab: View {
    let metrics: RuntimeInstanceMetrics?
    let updatedEpochMs: Int64?

    var body: some View {
        if let metrics {
            let memoryGraph = MemoryGraphModel(memory: metrics.memory)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    UpdatedAtView(epochMs: updatedEpochMs)
                    MetricSection(title: "CPU") {
                        MetricRow(label: "Usage", value: percentString(metrics.cpu.usagePercent))
                        MetricRow(label: "Logical CPUs", value: metrics.cpu.logicalCPUCount.map(String.init) ?? "-")
                    }
                    MetricSection(title: "Memory") {
                        MemoryCompositionView(memory: metrics.memory)
                        MetricRow(label: "Visible Memory", value: formatBytes(memoryGraph.linuxVisibleBytes))
                        MetricRow(label: "Available Memory", value: formatBytes(memoryGraph.availableMemoryBytes))
                        MetricRow(label: "Guest Used", value: formatBytes(memoryGraph.guestUsedBytes))
                        MetricRow(label: "Kernel Buffer", value: formatBytes(metrics.memory.kernelBufferCacheBytes))
                        MetricRow(label: "Kernel", value: formatBytes(metrics.memory.kernelOtherBytes))
                        MetricRow(label: "Host VMM", value: formatBytes(memoryGraph.hostVMMBytes))
                        MetricRow(label: "Balloon Max", value: formatBytes(metrics.memory.balloonMaxBytes))
                        MetricRow(label: "Balloon Returned Total", value: formatBytes(metrics.memory.balloonReturnedTotalBytes))
                    }
                    MetricSection(title: "Network") {
                        MetricRow(label: "Primary Interface", value: metrics.network.primaryInterface ?? "-")
                        MetricRow(label: "RX Total", value: formatBytes(metrics.network.rxBytes))
                        MetricRow(label: "TX Total", value: formatBytes(metrics.network.txBytes))
                        MetricRow(label: "RX Bandwidth", value: formatRate(metrics.network.rxBytesPerSecond))
                        MetricRow(label: "TX Bandwidth", value: formatRate(metrics.network.txBytesPerSecond))
                    }
                }
            }
        } else {
            Text("System metrics will appear once the selected VM is running.")
                .foregroundStyle(.secondary)
        }
    }
}

struct MemoryGraphSegment: Identifiable {
    enum Kind: String, Equatable {
        case hostVMM
        case kernel
        case kernelBuffer
        case guestUsed
        case returned
    }

    let kind: Kind
    let label: String
    let value: UInt64
    let color: Color
    let startFraction: Double
    let endFraction: Double

    var id: Kind { kind }
}

struct MemoryRangeGuide: Equatable {
    enum Placement: Equatable {
        case top
        case bottom
    }

    let label: String
    let startFraction: Double
    let endFraction: Double
    let placement: Placement
}

struct MemoryGraphModel {
    let hostVMMBytes: UInt64
    let kernelBytes: UInt64
    let kernelBufferBytes: UInt64
    let guestUsedBytes: UInt64
    let returnedBytes: UInt64
    let availableMemoryBytes: UInt64
    let linuxVisibleBytes: UInt64
    let macUsageBytes: UInt64
    let hostResidentBytes: UInt64?
    let totalBytes: UInt64
    let segments: [MemoryGraphSegment]
    let linuxGuide: MemoryRangeGuide
    let macGuide: MemoryRangeGuide

    init(memory: RuntimeMemoryBreakdown) {
        let kernelBytes = memory.kernelOtherBytes
        let kernelBufferBytes = memory.kernelBufferCacheBytes
        let kernelTotal = kernelBytes + kernelBufferBytes
        let guestUsedBytes = memory.guestUsedBytes > kernelTotal ? (memory.guestUsedBytes - kernelTotal) : 0
        let returnedBytes = memory.balloonMaxBytes > memory.balloonTargetBytes ? (memory.balloonMaxBytes - memory.balloonTargetBytes) : 0
        let hostVMMBytes = memory.hostResidentMemoryBytes ?? 0

        self.hostVMMBytes = hostVMMBytes
        self.kernelBytes = kernelBytes
        self.kernelBufferBytes = kernelBufferBytes
        self.guestUsedBytes = guestUsedBytes
        self.returnedBytes = returnedBytes
        self.availableMemoryBytes = returnedBytes
        self.linuxVisibleBytes = kernelBytes + kernelBufferBytes + guestUsedBytes + returnedBytes
        self.macUsageBytes = hostVMMBytes + kernelBytes + kernelBufferBytes + guestUsedBytes
        self.hostResidentBytes = memory.hostResidentMemoryBytes
        let totalBytes = max(hostVMMBytes + kernelBytes + kernelBufferBytes + guestUsedBytes + returnedBytes, 1)
        self.totalBytes = totalBytes

        let rawSegments: [(MemoryGraphSegment.Kind, String, UInt64, Color)] = [
            (.hostVMM, "Host VMM", hostVMMBytes, Color(red: 0.78, green: 0.70, blue: 0.86)),
            (.kernel, "Kernel", kernelBytes, Color(red: 0.94, green: 0.73, blue: 0.73)),
            (.kernelBuffer, "Kernel Buffer", kernelBufferBytes, Color(red: 0.98, green: 0.87, blue: 0.67)),
            (.guestUsed, "Guest Used", guestUsedBytes, Color(red: 0.72, green: 0.80, blue: 0.92)),
            (.returned, "Returned Memory", returnedBytes, Color(red: 0.77, green: 0.87, blue: 0.76))
        ]

        var cursor: UInt64 = 0
        self.segments = rawSegments.map { kind, label, value, color in
            let start = totalBytes > 0 ? Double(cursor) / Double(totalBytes) : 0
            cursor += value
            let end = totalBytes > 0 ? Double(cursor) / Double(totalBytes) : 1
            return MemoryGraphSegment(
                kind: kind,
                label: label,
                value: value,
                color: color,
                startFraction: start,
                endFraction: end
            )
        }

        let linuxStart = totalBytes > 0 ? Double(hostVMMBytes) / Double(totalBytes) : 0
        let macEnd = totalBytes > 0 ? Double(macUsageBytes) / Double(totalBytes) : 1
        self.macGuide = MemoryRangeGuide(
            label: "Memory Usage in macOS: \(formatBytes(memory.hostResidentMemoryBytes ?? 0)) / Linux VM: \(formatBytes(self.macUsageBytes)) (macOS point of view)",
            startFraction: 0,
            endFraction: macEnd,
            placement: .bottom
        )
        self.linuxGuide = MemoryRangeGuide(
            label: "Visible Memory: \(formatBytes(self.linuxVisibleBytes)) / Available Memory: \(formatBytes(self.availableMemoryBytes)) (Linux point of view)",
            startFraction: linuxStart,
            endFraction: 1,
            placement: .top
        )
    }

    func visualWidths(totalWidth: CGFloat, minimumWidth: CGFloat) -> [MemoryGraphSegment.Kind: CGFloat] {
        let rawWidths = Dictionary(uniqueKeysWithValues: segments.map { segment in
            (segment.kind, totalWidth * CGFloat(segment.endFraction - segment.startFraction))
        })

        let positiveSegments = segments.filter { $0.value > 0 }
        let smallKinds = positiveSegments
            .filter { (rawWidths[$0.kind] ?? 0) < minimumWidth }
            .map(\.kind)
        let smallWidthTotal = CGFloat(smallKinds.count) * minimumWidth
        let largeSegments = positiveSegments.filter { !smallKinds.contains($0.kind) }
        let largeRawTotal = largeSegments.reduce(CGFloat(0)) { $0 + (rawWidths[$1.kind] ?? 0) }
        let remainingWidth = max(totalWidth - smallWidthTotal, 0)

        var widths: [MemoryGraphSegment.Kind: CGFloat] = [:]
        for segment in segments {
            guard segment.value > 0 else {
                widths[segment.kind] = 0
                continue
            }
            if smallKinds.contains(segment.kind) {
                widths[segment.kind] = minimumWidth
            } else if largeRawTotal > 0 {
                widths[segment.kind] = (rawWidths[segment.kind] ?? 0) / largeRawTotal * remainingWidth
            } else {
                widths[segment.kind] = 0
            }
        }
        return widths
    }

    func visualFrames(totalWidth: CGFloat, minimumWidth: CGFloat) -> [MemoryGraphSegment.Kind: (start: CGFloat, end: CGFloat)] {
        let widths = visualWidths(totalWidth: totalWidth, minimumWidth: minimumWidth)
        var cursor: CGFloat = 0
        var frames: [MemoryGraphSegment.Kind: (start: CGFloat, end: CGFloat)] = [:]

        for segment in segments {
            let width = widths[segment.kind] ?? 0
            frames[segment.kind] = (start: cursor, end: cursor + width)
            cursor += width
        }
        return frames
    }
}

private struct MemoryCompositionView: View {
    let memory: RuntimeMemoryBreakdown

    private var graph: MemoryGraphModel {
        MemoryGraphModel(memory: memory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let barHeight: CGFloat = 56
                let topGuideY: CGFloat = 18
                let barTopY: CGFloat = 34
                let bottomGuideY = barTopY + barHeight + 22
                let visualWidths = graph.visualWidths(totalWidth: proxy.size.width, minimumWidth: 8)
                let visualFrames = graph.visualFrames(totalWidth: proxy.size.width, minimumWidth: 8)
                let linuxStartX = visualFrames[.kernel]?.start ?? 0
                let linuxEndX = visualFrames[.returned]?.end ?? proxy.size.width
                let macStartX = visualFrames[.hostVMM]?.start ?? 0
                let macEndX =
                    visualFrames[.guestUsed]?.end ??
                    visualFrames[.kernelBuffer]?.end ??
                    visualFrames[.kernel]?.end ??
                    visualFrames[.hostVMM]?.end ??
                    0

                ZStack(alignment: .topLeading) {
                    RangeGuideLine(
                        label: graph.linuxGuide.label,
                        startX: linuxStartX,
                        endX: linuxEndX,
                        placement: .top,
                        barTopY: barTopY,
                        barBottomY: barTopY + barHeight,
                        guideY: topGuideY
                    )
                    RangeGuideLine(
                        label: graph.macGuide.label,
                        startX: macStartX,
                        endX: macEndX,
                        placement: .bottom,
                        barTopY: barTopY,
                        barBottomY: barTopY + barHeight,
                        guideY: bottomGuideY
                    )

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .frame(height: barHeight)
                        HStack(spacing: 0) {
                            ForEach(graph.segments.filter { $0.value > 0 }) { segment in
                                let width = visualWidths[segment.kind] ?? 0
                                Rectangle()
                                    .fill(segment.color)
                                    .frame(width: width, height: barHeight)
                                    .overlay(alignment: .center) {
                                        if width > 84 {
                                            Text(segment.label)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.black.opacity(0.75))
                                                .lineLimit(1)
                                                .padding(.horizontal, 4)
                                        }
                                    }
                            }
                        }
                    }
                    .frame(height: barHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
                    .offset(y: barTopY)
                }
            }
            .frame(height: 138)

            HStack(alignment: .top, spacing: 12) {
                ForEach(graph.segments) { segment in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segment.color)
                            .frame(width: 10, height: 10)
                        Text("\(segment.label): \(formatBytes(segment.value))")
                            .font(.caption)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

private struct RangeGuideLine: View {
    let label: String
    let startX: CGFloat
    let endX: CGFloat
    let placement: MemoryRangeGuide.Placement
    let barTopY: CGFloat
    let barBottomY: CGFloat
    let guideY: CGFloat

    var body: some View {
        let extensionTargetY = placement == .top ? barTopY : barBottomY
        let labelY = placement == .top ? max(0, guideY - 16) : guideY + 6
        let labelX = min(startX + 2, max(endX - 220, startX + 2))
        let arrowSize: CGFloat = 5

        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: startX, y: guideY))
                path.addLine(to: CGPoint(x: endX, y: guideY))
                path.move(to: CGPoint(x: startX, y: guideY))
                path.addLine(to: CGPoint(x: startX + arrowSize, y: guideY - arrowSize / 2))
                path.move(to: CGPoint(x: startX, y: guideY))
                path.addLine(to: CGPoint(x: startX + arrowSize, y: guideY + arrowSize / 2))
                path.move(to: CGPoint(x: endX, y: guideY))
                path.addLine(to: CGPoint(x: endX - arrowSize, y: guideY - arrowSize / 2))
                path.move(to: CGPoint(x: endX, y: guideY))
                path.addLine(to: CGPoint(x: endX - arrowSize, y: guideY + arrowSize / 2))
                path.move(to: CGPoint(x: startX, y: guideY))
                path.addLine(to: CGPoint(x: startX, y: extensionTargetY))
                path.move(to: CGPoint(x: endX, y: guideY))
                path.addLine(to: CGPoint(x: endX, y: extensionTargetY))
            }
            .stroke(Color.secondary.opacity(0.8), lineWidth: 1)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: labelX, y: labelY)
        }
    }
}

private struct StorageTab: View {
    let storage: RuntimeInstanceStorage?
    let updatedEpochMs: Int64?

    var body: some View {
        if let storage {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    UpdatedAtView(epochMs: updatedEpochMs)
                    MetricSection(title: "Linux Filesystem") {
                        MetricRow(label: "Filesystem", value: storage.filesystem ?? "-")
                        MetricRow(label: "Mount Point", value: storage.mountPoint ?? "-")
                        MetricRow(label: "Total", value: storage.totalBytes.map(formatBytes) ?? "-")
                        MetricRow(label: "Used", value: storage.usedBytes.map(formatBytes) ?? "-")
                        MetricRow(label: "Available", value: storage.availableBytes.map(formatBytes) ?? "-")
                    }
                    MetricSection(title: "macOS Disk Image") {
                        MetricRow(label: "Host Allocated", value: storage.hostAllocatedBytes.map(formatBytes) ?? "-")
                        MetricRow(label: "Host Logical", value: storage.hostLogicalBytes.map(formatBytes) ?? "-")
                        MetricRow(label: "Host Apparent", value: storage.hostApparentBytes.map(formatBytes) ?? "-")
                    }
                    MetricSection(title: "Compression / Sparse") {
                        MetricRow(label: "Space Saved", value: storage.compression.spaceSavingBytes.map(formatBytes) ?? "-")
                        MetricRow(label: "Space Saving Ratio", value: percentString(storage.compression.spaceSavingRatio.map { $0 * 100.0 }))
                        MetricRow(label: "Compression Cache", value: storage.compression.compressionCacheBytes.map(formatBytes) ?? "-")
                    }
                }
            }
        } else {
            Text("Storage details will appear once the selected VM is running.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProcessesTab: View {
    let processes: [RuntimeProcessSnapshotItem]
    let isLoading: Bool
    let updatedEpochMs: Int64?
    let onRefresh: () -> Void
    @State private var sortOrder = [
        KeyPathComparator(\RuntimeProcessSnapshotItem.cpuPercent, order: .reverse)
    ]

    private var sortedProcesses: [RuntimeProcessSnapshotItem] {
        processes.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                UpdatedAtView(epochMs: updatedEpochMs)
                Spacer()
                Button("Refresh", action: onRefresh)
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
            }
            if isLoading && processes.isEmpty {
                ProgressView()
            } else if processes.isEmpty {
                Text("Open this tab while the VM is running to load a process snapshot.")
                    .foregroundStyle(.secondary)
            } else {
                Table(sortedProcesses, sortOrder: $sortOrder) {
                    TableColumn("PID", value: \.pid) { item in
                        Text("\(item.pid)")
                    }
                    .width(min: 56, ideal: 64, max: 72)
                    TableColumn("User", value: \.user) { item in
                        Text(item.user)
                    }
                    .width(min: 72, ideal: 90, max: 110)
                    TableColumn("CPU %", value: \.cpuPercent) { item in
                        Text(percentString(item.cpuPercent))
                    }
                    .width(min: 56, ideal: 68, max: 76)
                    TableColumn("Mem", value: \.memoryResidentBytes) { item in
                        Text(formatProcessMemory(item.memoryResidentBytes))
                    }
                    .width(min: 72, ideal: 84, max: 96)
                    TableColumn("Command") { item in
                        Text(item.command)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func sshSummary(for worker: AppManagerWorkerRecord) -> String {
        guard let sshInfo = worker.sshInfo else {
            if let state = worker.sshListenerState {
                return "listener \(state)"
            }
            return "unavailable"
        }
        return "\(sshInfo.alias) -> \(sshInfo.host):\(sshInfo.port)"
    }
}

@ViewBuilder
private func stringListSection(_ title: String, _ values: [String]) -> some View {
    MetricSection(title: title) {
        if values.isEmpty {
            DetailMetricRow(label: "Items", value: "-")
        } else {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.callout.monospaced())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

@ViewBuilder
private func keyValueSection(_ title: String, _ values: [String: String]) -> some View {
    MetricSection(title: title) {
        if values.isEmpty {
            DetailMetricRow(label: "Items", value: "-")
        } else {
            ForEach(values.keys.sorted(), id: \.self) { key in
                DetailMetricRow(label: key, value: values[key] ?? "")
            }
        }
    }
}

private func confirmDestructive(title: String, text: String) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = text
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

private struct MetricSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }
}

private struct DetailMetricRow: View {
    let label: String
    let value: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow(alignment: .top) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                Text(value)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct UpdatedAtView: View {
    let epochMs: Int64?

    var body: some View {
        Text("Updated: \(epochMs.map(formatDate(epochMs:)) ?? "-")")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct StatusBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
    }
}

private func formatBytes(_ value: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .binary
    formatter.includesUnit = true
    return formatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))))
}

private func formatCompactBytes(_ value: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var scaled = Double(value)
    var unitIndex = 0
    while scaled >= 1000, unitIndex < units.count - 1 {
        scaled /= 1000
        unitIndex += 1
    }
    if unitIndex == 0 {
        return "\(value)B"
    }
    if scaled >= 100 {
        return "\(String(format: "%.0f", scaled))\(units[unitIndex])"
    }
    if scaled >= 10 {
        return "\(String(format: "%.1f", scaled))\(units[unitIndex])"
    }
    return "\(String(format: "%.2f", scaled))\(units[unitIndex])"
}

private func formatRate(_ value: Double?) -> String {
    guard let value else { return "-" }
    return "\(formatBytes(UInt64(max(value, 0))))/s"
}

private func percentString(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%.1f%%", value)
}

private func formatProcessMemory(_ bytes: UInt64) -> String {
    let mebibytes = Double(bytes) / 1_048_576
    if mebibytes >= 1024 {
        let gibibytes = mebibytes / 1024
        if gibibytes < 10 {
            return String(format: "%.1f GB", gibibytes)
        }
        return String(format: "%.2f GB", gibibytes)
    }
    if mebibytes >= 10 {
        return String(format: "%.0f MB", mebibytes)
    }
    if mebibytes >= 1 {
        return String(format: "%.1f MB", mebibytes)
    }
    return String(format: "%.2f MB", mebibytes)
}

private func formatContainerMemoryLimit(_ stats: RuntimeContainerStats?) -> String {
    guard let stats else { return "-" }
    if stats.memoryLimitUnlimited == true {
        return "Unlimited"
    }
    return stats.memoryLimitBytes.map(formatBytes) ?? "-"
}

private func formatDuration(seconds: Int64) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let secs = seconds % 60
    if hours > 0 {
        return "\(hours)h \(minutes)m \(secs)s"
    }
    if minutes > 0 {
        return "\(minutes)m \(secs)s"
    }
    return "\(secs)s"
}

private func formatDate(epochMs: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000.0))
}

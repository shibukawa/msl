import AppKit
import SwiftUI
import mslCore

@main
struct MSLDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("MSL Desktop") {
            DashboardView(model: appDelegate.model)
                .frame(minWidth: 880, minHeight: 520)
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
            let summary = workerNames.joined(separator: ", ")
            alert.informativeText = "The following VMs are still active and will be stopped: \(summary)"
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

final class DashboardModel: ObservableObject {
    @Published var workers: [AppManagerWorkerRecord] = []
    @Published var installedInstances: [String] = []
    @Published var managerError: String?

    private let fileManager = FileManager.default
    private let paths = MSLPaths()
    private var timer: Timer?
    private var manager: AppManager?
    private var statusItemUpdateHandler: ((DashboardStatusSummary) -> Void)?

    var activeWorkers: [AppManagerWorkerRecord] {
        workers.filter { worker in
            worker.lifecycleState == .running || worker.lifecycleState == .starting
        }
    }

    var hasActiveWorkers: Bool {
        !activeWorkers.isEmpty
    }

    var activeWorkerNames: [String] {
        activeWorkers.map(\.instanceName).sorted()
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
            .sorted()) ?? []
        workers = manager?.snapshot().workers ?? []
        statusItemUpdateHandler?(statusSummary())
    }

    func start(instanceName: String) {
        let managerSocketPath = paths.managerSocketFile.path
        Task.detached {
            do {
                let client = ManagerControlClient(socketPath: managerSocketPath)
                _ = try client.send(ManagerControlRequest(op: "ensure_instance", instance: instanceName))
                await MainActor.run { self.refresh() }
            } catch {
                await MainActor.run {
                    self.managerError = String(describing: error)
                    self.statusItemUpdateHandler?(self.statusSummary())
                }
            }
        }
    }

    func stop(instanceName: String) {
        let managerSocketPath = paths.managerSocketFile.path
        Task.detached {
            do {
                let client = ManagerControlClient(socketPath: managerSocketPath)
                _ = try client.send(ManagerControlRequest(op: "stop_instance", instance: instanceName))
                await MainActor.run { self.refresh() }
            } catch {
                await MainActor.run {
                    self.managerError = String(describing: error)
                    self.statusItemUpdateHandler?(self.statusSummary())
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("MSL Desktop")
                .font(.largeTitle.weight(.semibold))
            if let managerError = model.managerError {
                Text(managerError)
                    .foregroundStyle(.red)
            }
            List(model.installedInstances, id: \.self) { name in
                let worker = model.workers.first(where: { $0.instanceName == name })
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.headline)
                        Text("Lifecycle: \(worker?.lifecycleState.rawValue ?? "stopped")")
                        Text("PID: \(worker.map { String($0.pid) } ?? "-")")
                        Text("Socket: \(worker?.controlSocketPath ?? "-")")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("SSH: \(worker.flatMap { sshSummary(for: $0) } ?? "-")")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("SSH config: \(worker?.sshInfo?.configPath ?? "-")")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Last error: \(worker?.lastErrorMessage ?? "-")")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    HStack {
                        Button("Start") {
                            model.start(instanceName: name)
                        }
                        Button("Stop") {
                            model.stop(instanceName: name)
                        }
                    }
                }
            }
        }
        .padding(20)
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

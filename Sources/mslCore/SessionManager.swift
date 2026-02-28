import Foundation
import Darwin

public final class SessionManager {
    private let store: StateStore

    public init(store: StateStore) {
        self.store = store
    }

    public func reconcile() throws -> [SessionEntry] {
        let sessions = try store.loadSessions()
        let alive = sessions.filter { isAlive(pid: $0.pid) }
        if alive.count != sessions.count {
            try store.saveSessions(alive)
        }
        return alive
    }

    public func addSession(_ entry: SessionEntry) throws -> [SessionEntry] {
        var sessions = try reconcile()
        sessions.append(entry)
        try store.saveSessions(sessions)
        return sessions
    }

    public func removeSession(id: String) throws -> [SessionEntry] {
        var sessions = try reconcile()
        sessions.removeAll { $0.id == id }
        try store.saveSessions(sessions)
        return sessions
    }

    public func clearAllAndTerminate() throws {
        let sessions = try reconcile()
        for s in sessions {
            _ = kill(s.pid, SIGTERM)
        }
        try store.saveSessions([])
    }

    private func isAlive(pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

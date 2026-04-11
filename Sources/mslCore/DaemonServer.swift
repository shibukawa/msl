import Foundation
import Darwin

struct AttachedCodeOpenRequest: Equatable {
    let targetPath: String

    static func parse(_ raw: String) -> AttachedCodeOpenRequest? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("OPEN:") else { return nil }
        let payload = String(trimmed.dropFirst("OPEN:".count))
        guard !payload.isEmpty else { return nil }
        guard payload.hasPrefix("/") else { return nil }
        guard payload.utf8.count <= 4096 else { return nil }
        guard !payload.contains("\u{0000}") else { return nil }
        guard payload.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0.value == 0x09 }) else { return nil }
        guard isAllowedGuestPath(payload) else { return nil }
        return AttachedCodeOpenRequest(targetPath: payload)
    }

    private static func isAllowedGuestPath(_ path: String) -> Bool {
        let prefixes = ["/home", "/mnt/macos", "/mnt/msl"]
        for prefix in prefixes {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }
}

enum AttachedOpenForwardError: Error {
    case codeCLINotFound
    case codeCommandFailed(exitCode: Int32)
    case processLaunchFailed(String)

    var reasonCode: String {
        switch self {
        case .codeCLINotFound:
            return "code_cli_not_found"
        case .codeCommandFailed:
            return "code_command_failed"
        case .processLaunchFailed:
            return "process_launch_failed"
        }
    }
}

struct AttachedContainerRemoteAuthorityConfig: Codable {
    var containerName: String
    var settings: [String: String]?
}

struct AttachedOpenLaunchTarget: Equatable {
    var instanceName: String
    var vmID: String
    var socketPath: String
}

func resolveAttachedOpenInstanceName(
    sourceInstance: String?,
    currentRuntimeInstanceName: String
) -> String {
    let trimmed = sourceInstance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? currentRuntimeInstanceName : trimmed
}

func resolveAttachedOpenLaunchTarget(
    sourceInstance: String?,
    currentRuntimeInstanceName: String
) -> AttachedOpenLaunchTarget {
    let instanceName = resolveAttachedOpenInstanceName(
        sourceInstance: sourceInstance,
        currentRuntimeInstanceName: currentRuntimeInstanceName
    )
    return AttachedOpenLaunchTarget(
        instanceName: instanceName,
        vmID: AttachedContainerIdentity.vmID(forInstance: instanceName),
        socketPath: AttachedContainerIdentity.socketPath(forInstance: instanceName)
    )
}

func buildAttachedContainerAuthorityString(
    vmID: String,
    socketPath: String
) throws -> String {
    let containerName = vmID.hasPrefix("/") ? vmID : "/\(vmID)"
    let payload = AttachedContainerRemoteAuthorityConfig(
        containerName: containerName,
        settings: ["host": "unix://\(socketPath)"]
    )
    let json = try JSONEncoder().encode(payload)
    let hex = json.map { String(format: "%02x", $0) }.joined()
    return "attached-container+\(hex)"
}

/// VMオーナーデーモンプロセス。VM の起動・保持、vsock 管理、
/// control socket でCLI からのリクエストを受け付ける。
public final class DaemonServer {
    private enum HostProcEvent {
        case stdout(Data)
        case stderr(Data)
        case exited(Int32, String?)
        case streamsClosed
        case failed(String)
    }

    private enum HostPtyEvent {
        case output(Data)
        case exited(Int32, String?)
        case streamsClosed
        case failed(String)
    }

    private final class HostProcEventBuffer {
        private let condition = NSCondition()
        private var events: [HostProcEvent] = []
        private var exitCode: Int32?
        private var exitReason: String?
        private var streamsClosed = false
        private var failure: String?

        func push(_ event: HostProcEvent) {
            condition.lock()
            switch event {
            case .exited(let code, let reason):
                exitCode = code
                exitReason = reason
            case .streamsClosed:
                streamsClosed = true
            case .failed(let message):
                failure = message
            default:
                break
            }
            events.append(event)
            condition.broadcast()
            condition.unlock()
        }

        func collect(timeoutMs: Int) -> (events: [HostProcEvent], exitCode: Int32?, exitReason: String?, finalize: Bool, failure: String?) {
            condition.lock()
            defer { condition.unlock() }

            if events.isEmpty && failure == nil && !(streamsClosed && exitCode != nil) {
                if timeoutMs > 0 {
                    _ = condition.wait(until: Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0))
                } else {
                    condition.wait()
                }
            }

            let drained = events
            events.removeAll(keepingCapacity: true)
            let finalize = streamsClosed && exitCode != nil && events.isEmpty
            return (drained, exitCode, exitReason, finalize, failure)
        }
    }

    private final class HostPtyEventBuffer {
        private let condition = NSCondition()
        private var events: [HostPtyEvent] = []
        private var exitCode: Int32?
        private var exitReason: String?
        private var streamsClosed = false
        private var failure: String?

        func push(_ event: HostPtyEvent) {
            condition.lock()
            switch event {
            case .exited(let code, let reason):
                exitCode = code
                exitReason = reason
            case .streamsClosed:
                streamsClosed = true
            case .failed(let message):
                failure = message
            default:
                break
            }
            events.append(event)
            condition.broadcast()
            condition.unlock()
        }

        func collect(timeoutMs: Int, maxBytes: Int) -> (payload: Data, exitCode: Int32?, exitReason: String?, finalize: Bool, failure: String?) {
            condition.lock()
            defer { condition.unlock() }

            if events.isEmpty && failure == nil && !(streamsClosed && exitCode != nil) {
                if timeoutMs > 0 {
                    _ = condition.wait(until: Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0))
                } else {
                    condition.wait()
                }
            }

            var payload = Data()
            var drainedCount = 0
            for event in events {
                switch event {
                case .output(let data):
                    if payload.count + data.count > maxBytes && !payload.isEmpty {
                        break
                    }
                    payload.append(data)
                    drainedCount += 1
                case .exited, .streamsClosed, .failed:
                    drainedCount += 1
                }
                if payload.count >= maxBytes {
                    break
                }
            }
            if drainedCount > 0 {
                events.removeFirst(drainedCount)
            }
            let finalize = streamsClosed && exitCode != nil && events.isEmpty
            return (payload, exitCode, exitReason, finalize, failure)
        }
    }

    private struct ConvergedRuntimeUserResult {
        var runtimeUser: RuntimeUserState
        var adminGroup: String
    }

    private let paths: MSLPaths
    private let fileManager: FileManager
    private let lock: FileLock
    private let store: StateStore
    private let bootstrap: BootstrapManager
    private let sessions: SessionManager
    private let logger: MSLLogger
    private let executablePath: String
    private let explicitInstanceName: String?
    private let distributionManager: DistributionManager
    private let defaultInstanceStore: DefaultInstanceStore
    private let instanceRegistry = InstanceRuntimeRegistry()
    private let launchOriginTracker = LaunchOriginTracker()
    private let logRouter: RuntimeLogRouter
    private let sessionEventLock = NSLock()
    private var procEventBuffers: [String: HostProcEventBuffer] = [:]
    private var ptyEventBuffers: [String: HostPtyEventBuffer] = [:]
    private var procSubscriptionSources: [String: DispatchSourceRead] = [:]
    private var ptySubscriptionSources: [String: DispatchSourceRead] = [:]
    private var activeInstanceName: String?

    private var initClient: InitChannelClient?
    private var vmRunner: VirtualMachineRunner?
    private var controlServer: RuntimeControlServer?
    private var eventBus: DaemonEventBus?
    private var sshListener: LocalhostSSHServer?
    private var sshInfo: LocalhostSSHInfo?
    private var attachedContainerDaemons: [String: AttachedContainerDaemon] = [:]
    private var forwarder: PortForwardingManager?
    private var runtimeMetadataURL: URL?
    private let dnsStateLock = NSLock()
    private let dnsReconcileLock = NSLock()
    private var runtimeDNSMeta: [String: String] = [
        "configured_network_mode": ConfiguredNetworkMode.auto.rawValue,
        "effective_network_mode": EffectiveNetworkMode.nat.rawValue,
        "network_mode": EffectiveNetworkMode.nat.rawValue,
        "network_mode_reason": "network mode unresolved",
        "shared_subnet_ipv4": "-",
        "shared_subnet_mask_ipv4": "-",
        "host_gateway_ipv4": "-",
        "dns_mode": "host",
        "dns_status": "unknown",
        "dns_action": "-",
        "dns_source": "-",
        "host_alias": "-",
        "host_hosts_status": "unmanaged",
        "guest_hosts_status": "unmanaged",
        "nameserver_count": "0",
        "search_domain_count": "0",
        "last_reconcile_epoch_ms": "0"
    ]
    private let housekeepingQueue = DispatchQueue(label: "msl.daemon.housekeeping")
    private var dnsMonitorTimer: DispatchSourceTimer?
    private var lastHostResolverSnapshotHash: String?
    private var backgroundDNSReconcileRunning = false
    private var backgroundDNSReconcilePendingSource: String?

    private let stopSemaphore = DispatchSemaphore(value: 0)
    private var idleTimerSources: [String: DispatchSourceTimer] = [:]
    private let idleTimerQueue = DispatchQueue(label: "msl.daemon.idle")
    private let memoryReclaimQueue = DispatchQueue(label: "msl.daemon.memory-reclaim")
    private let reclaimStateQueue = DispatchQueue(label: "msl.daemon.memory-reclaim.state")
    private var memoryReclaimTimer: DispatchSourceTimer?
#if canImport(Darwin)
    private var hostMemoryPressureSource: DispatchSourceMemoryPressure?
#endif
    private var memoryReclaimPolicy: ResolvedMemoryReclaimPolicy = .defaultPolicy
    private var lastGuestActivityEpochMs: Int64 = nowEpochMs()
    private var lastShortIdleReclaimEpochMs: Int64?
    private var lastLongIdleReclaimEpochMs: Int64?
    private var lastHostPressureReclaimEpochMs: Int64?
    private var lastCacheCapReclaimEpochMs: Int64?
    private var cacheOverCapActive: Bool = false
    private var autoPortTimer: DispatchSourceTimer?
    private let portMappingsSnapshotLock = NSLock()
    private var effectivePortMappingsSnapshot: EffectivePortMappings = .empty
    private var autoPortErrorsByHostPort: [Int: String] = [:]
    private var autoPortNextAllowedEpochMs: Int64 = 0
    private var cacheShareEnvAdditions: [String: String] = [:]
    private let autoImageCompactThresholdBytes: Int64
    private let autoImageCompactThresholdPercent: Double
    private let autoImageCompactCooldownMs: Int64
    private static let autoTrimScript = """
    set -eu
    if ! command -v fstrim >/dev/null 2>&1; then
      echo "fstrim_missing" >&2
      exit 127
    fi
    fstrim -av >/dev/null 2>&1 || fstrim -a >/dev/null 2>&1
    """
    private static let inspectSnapshotScript = """
    set -eu
    if command -v du >/dev/null 2>&1; then
      apparent_kib="$(du -sx --apparent-size / 2>/dev/null | awk '{print $1}' || true)"
      actual_kib="$(du -sx / 2>/dev/null | awk '{print $1}' || true)"
      case "$apparent_kib" in ''|*[!0-9]*) apparent_kib='' ;; esac
      case "$actual_kib" in ''|*[!0-9]*) actual_kib='' ;; esac
      if [ -n "$apparent_kib" ]; then
        echo "du_apparent_bytes=$((apparent_kib * 1024))"
      fi
      if [ -n "$actual_kib" ]; then
        echo "du_actual_bytes=$((actual_kib * 1024))"
      fi
    fi
    """
    private static let tmpStoragePrepareScript = """
    set -eu
    label="$1"
    phase="resolve"
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    is_device_mounted() {
      dev="$1"
      awk -v d="$dev" '$1 == d { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts
    }
    dev="$(blkid -L "$label" 2>/dev/null || true)"
    if [ -z "$dev" ]; then
      dev="$(blkid -t LABEL="$label" -o device 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "$dev" ]; then
      for cand in /dev/vd[b-z] /dev/sd[b-z] /dev/xvd[b-z]; do
        [ -b "$cand" ] || continue
        [ -n "$root_src" ] && [ "$cand" = "$root_src" ] && continue
        if is_device_mounted "$cand"; then
          continue
        fi
        dev="$cand"
        break
      done
    fi
    if [ -z "$dev" ]; then
      echo "phase=resolve label=$label device_not_found" >&2
      exit 41
    fi
    mkdir -p /run/msl/tmp
    if mountpoint -q /run/msl/tmp; then
      umount /run/msl/tmp >/dev/null 2>&1 || true
    fi
    phase="mkfs_check"
    fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    if [ "$fstype" != "ext4" ]; then
      phase="mount_probe"
      mount_error=""
      probe_try=0
      while [ "$probe_try" -lt 10 ]; do
        if mount -t ext4 -o rw,nosuid,nodev "$dev" /run/msl/tmp >/tmp/msl-tmp-mount.out 2>/tmp/msl-tmp-mount.err; then
          fstype="ext4"
          break
        fi
        mount_error="$(cat /tmp/msl-tmp-mount.err 2>/dev/null || true)"
        probe_try=$((probe_try + 1))
        sleep 0.2
      done
      rm -f /tmp/msl-tmp-mount.out /tmp/msl-tmp-mount.err >/dev/null 2>&1 || true
      if [ "$fstype" != "ext4" ]; then
        phase="mkfs"
        mkfs_cmd=""
        if command -v mkfs.ext4 >/dev/null 2>&1; then
          mkfs_cmd="mkfs.ext4"
        elif command -v mke2fs >/dev/null 2>&1; then
          mkfs_cmd="mke2fs"
        else
          echo "phase=mkfs mkfs_ext4_not_found mount_probe_error=${mount_error:-none}" >&2
          exit 127
        fi
        "$mkfs_cmd" -q -F -L "$label" -E lazy_itable_init=1,lazy_journal_init=1 "$dev" >/dev/null
      fi
    fi
    phase="mount"
    if ! mountpoint -q /run/msl/tmp; then
      mount -t ext4 -o rw,nosuid,nodev "$dev" /run/msl/tmp
    fi
    chmod 1777 /run/msl/tmp
    phase="bind"
    mkdir -p /tmp
    if mountpoint -q /tmp; then
      umount /tmp >/dev/null 2>&1 || true
    fi
    mount --bind /run/msl/tmp /tmp
    chmod 1777 /tmp
    root_fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
    if [ "$root_fstype" = "erofs" ]; then
      phase="ephemeral_state"
      mkdir -p /run/msl/tmp/var /run/msl/tmp/etc
      if [ -d /var ]; then
        cp -a /var/. /run/msl/tmp/var/ >/dev/null 2>&1 || true
      fi
      mkdir -p /run/msl/tmp/var/log /run/msl/tmp/var/tmp /run/msl/tmp/var/devcontainer
      chmod 1777 /run/msl/tmp/var/tmp
      if ! mountpoint -q /var; then
        mount --bind /run/msl/tmp/var /var
      fi
      chmod 1777 /var/tmp >/dev/null 2>&1 || true
      for etc_name in hosts resolv.conf; do
        src="/etc/$etc_name"
        dst="/run/msl/tmp/etc/$etc_name"
        if [ -f "$src" ]; then
          cp -f "$src" "$dst" >/dev/null 2>&1 || true
        else
          : > "$dst"
        fi
        if [ -e "$src" ]; then
          mount --bind "$dst" "$src"
        fi
      done
    fi
    echo "phase=done"
    """
    private static let legacyHostSharePrepareScript = """
    set -eu
    share_root="$1"
    workspace="$2"
    applied=0

    is_mount_target() {
      awk -v target="$1" '$5 == target { found=1 } END { exit(found ? 0 : 1) }' /proc/self/mountinfo
    }

    if ! is_mount_target "/mnt/macos"; then
      mkdir -p /mnt/macos
      mount -t virtiofs macos /mnt/macos
      applied=1
    fi

    if [ "$share_root" != "/" ]; then
      source_root="/mnt/macos$share_root"
      if [ ! -d "$source_root" ]; then
        echo "host share source is not accessible: $source_root" >&2
        exit 2
      fi
      mkdir -p "$share_root"
      if ! is_mount_target "$share_root"; then
        mount -o bind "$source_root" "$share_root"
        applied=1
      fi
    fi

    if [ "$share_root" = "/" ]; then
      source_workspace="/mnt/macos$workspace"
      if [ ! -e "$source_workspace" ]; then
        echo "workspace source is not accessible: $source_workspace" >&2
        exit 2
      fi
      mkdir -p "$workspace"
      if ! is_mount_target "$workspace"; then
        mount -o bind "$source_workspace" "$workspace"
        applied=1
      fi
    fi

    if [ "$applied" -eq 1 ]; then
      printf "applied"
    else
      printf "reused"
    fi
    """
    static let cacheSharePrepareScript = """
    set -eu
    cache_root="$1"; shift
    runtime_home="$1"; shift
    host_home_guest="$1"; shift
    enable_apt="$1"; shift
    enable_apk="$1"; shift
    enable_zypper="$1"; shift
    enable_dnf="$1"; shift
    enable_go="$1"; shift
    enable_python="$1"; shift
    enable_npm="$1"; shift
    enable_pnpm="$1"; shift
    enable_yarn="$1"; shift
    enable_maven="$1"; shift
    enable_gradle="$1"; shift
    enable_composer="$1"; shift
    enable_scala="$1"; shift
    enable_ruby="$1"; shift
    enable_rust="$1"; shift
    enable_deno="$1"; shift
    enable_bun="$1"; shift
    enable_nuget="$1"; shift

    applied=0
    fallback=0
    fallback_reasons=""

    is_mount_target() {
      awk -v target="$1" '$5 == target { found=1 } END { exit(found ? 0 : 1) }' /proc/self/mountinfo
    }

    add_fallback_reason() {
      reason="$1"
      if [ -z "$fallback_reasons" ]; then
        fallback_reasons="$reason"
      else
        fallback_reasons="$fallback_reasons,$reason"
      fi
    }

    ensure_dir() {
      path="$1"
      if mkdir -p "$path" 2>/dev/null; then
        return 0
      fi
      if command -v sudo >/dev/null 2>&1; then
        sudo -n mkdir -p "$path" 2>/dev/null && return 0
      fi
      return 1
    }

    bind_mount() {
      src="$1"
      dst="$2"
      if mount -o bind "$src" "$dst" 2>/dev/null; then
        return 0
      fi
      if command -v sudo >/dev/null 2>&1; then
        sudo -n mount -o bind "$src" "$dst" 2>/dev/null && return 0
      fi
      return 1
    }

    unmount_target() {
      target="$1"
      if umount "$target" 2>/dev/null; then
        return 0
      fi
      if command -v sudo >/dev/null 2>&1; then
        sudo -n umount "$target" 2>/dev/null && return 0
      fi
      return 1
    }

    ensure_writable_dir() {
      dir="$1"
      probe="$dir/.msl-write-test.$$"
      if : > "$probe" 2>/dev/null; then
        rm -f "$probe" 2>/dev/null || true
        return 0
      fi
      if command -v sudo >/dev/null 2>&1; then
        if sudo -n sh -c ': > "$1" && rm -f "$1"' sh "$probe" 2>/dev/null; then
          return 0
        fi
      fi
      return 1
    }

    ensure_bind_mount() {
      src="$1"
      dst="$2"
      reason="${3:-bind_mount_failed}"
      if [ ! -e "$src" ]; then
        fallback=$((fallback+1))
        add_fallback_reason "$reason:source_missing"
        return 0
      fi
      if ! ensure_dir "$dst"; then
        fallback=$((fallback+1))
        add_fallback_reason "$reason:target_unavailable"
        return 0
      fi
      if is_mount_target "$dst"; then
        return 0
      fi
      if bind_mount "$src" "$dst"; then
        applied=1
      else
        fallback=$((fallback+1))
        add_fallback_reason "$reason"
      fi
      return 0
    }

    if [ -z "$runtime_home" ] || [ "${runtime_home#/}" = "$runtime_home" ]; then
      runtime_home="/root"
    fi

    if [ -z "$host_home_guest" ] || [ "${host_home_guest#/}" = "$host_home_guest" ]; then
      host_home_guest="/__msl_host_home_unavailable__"
    fi

    prefer_existing_dir() {
      fallback_path="$1"; shift
      for candidate_path in "$@"; do
        if [ -n "$candidate_path" ] && [ -d "$candidate_path" ]; then
          printf "%s" "$candidate_path"
          return 0
        fi
      done
      printf "%s" "$fallback_path"
    }

    mkdir -p "$cache_root" 2>/dev/null || true

    os_id=""
    version_id=""
    if [ -r /etc/os-release ]; then
      os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
      version_id="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
    fi

    if [ "$enable_apt" = "1" ] && command -v apt-get >/dev/null 2>&1; then
      release_key="ubuntu-${version_id:-unknown}"
      archives_src="$cache_root/apt/$release_key/archives"
      mkdir -p "$archives_src/partial" 2>/dev/null || true
      ensure_bind_mount "$archives_src" "/var/cache/apt/archives" "apt_archives_bind_failed"
      if is_mount_target "/var/cache/apt/archives"; then
        if ! ensure_writable_dir "/var/cache/apt/archives/partial"; then
          fallback=$((fallback+1))
          if unmount_target "/var/cache/apt/archives"; then
            add_fallback_reason "apt_archives_unwritable"
          else
            add_fallback_reason "apt_archives_unwritable_unmount_failed"
          fi
        fi
      fi
    fi

    if [ "$enable_apk" = "1" ] && command -v apk >/dev/null 2>&1; then
      apk_src="$cache_root/apk/cache"
      mkdir -p "$apk_src" 2>/dev/null || true
      ensure_bind_mount "$apk_src" "/var/cache/apk"
    fi

    if [ "$enable_zypper" = "1" ] && command -v zypper >/dev/null 2>&1; then
      zypper_src="$cache_root/zypper/cache"
      mkdir -p "$zypper_src" 2>/dev/null || true
      ensure_bind_mount "$zypper_src" "/var/cache/zypp"
    fi

    if [ "$enable_dnf" = "1" ] && command -v dnf >/dev/null 2>&1; then
      dnf_src="$cache_root/dnf/cache"
      mkdir -p "$dnf_src" 2>/dev/null || true
      ensure_bind_mount "$dnf_src" "/var/cache/dnf"
    fi

    if [ "$enable_go" = "1" ]; then
      mkdir -p "$cache_root/go/modcache" "$cache_root/go/sumdb" 2>/dev/null || true
      go_mod_src="$(prefer_existing_dir "$cache_root/go/modcache" "$host_home_guest/go/pkg/mod")"
      go_sumdb_src="$(prefer_existing_dir "$cache_root/go/sumdb" "$host_home_guest/go/pkg/sumdb")"
      ensure_bind_mount "$go_mod_src" "$runtime_home/go/pkg/mod"
      ensure_bind_mount "$go_sumdb_src" "$runtime_home/go/pkg/sumdb"
    fi
    if [ "$enable_python" = "1" ]; then
      mkdir -p "$cache_root/python/pip" 2>/dev/null || true
      python_pip_src="$(prefer_existing_dir "$cache_root/python/pip" "$host_home_guest/Library/Caches/pip" "$host_home_guest/.cache/pip")"
      ensure_bind_mount "$python_pip_src" "$runtime_home/.cache/pip"
    fi
    if [ "$enable_npm" = "1" ]; then
      mkdir -p "$cache_root/node/npm" 2>/dev/null || true
      npm_src="$(prefer_existing_dir "$cache_root/node/npm" "$host_home_guest/.npm")"
      ensure_bind_mount "$npm_src" "$runtime_home/.npm"
    fi
    if [ "$enable_pnpm" = "1" ]; then
      mkdir -p "$cache_root/node/pnpm-store" 2>/dev/null || true
      pnpm_src="$(prefer_existing_dir "$cache_root/node/pnpm-store" "$host_home_guest/Library/pnpm/store" "$host_home_guest/.local/share/pnpm/store")"
      ensure_bind_mount "$pnpm_src" "$runtime_home/.local/share/pnpm/store"
    fi
    if [ "$enable_yarn" = "1" ]; then
      mkdir -p "$cache_root/node/yarn" 2>/dev/null || true
      yarn_src="$(prefer_existing_dir "$cache_root/node/yarn" "$host_home_guest/Library/Caches/Yarn" "$host_home_guest/.cache/yarn")"
      ensure_bind_mount "$yarn_src" "$runtime_home/.cache/yarn"
    fi
    if [ "$enable_maven" = "1" ]; then
      mkdir -p "$cache_root/java/maven-repo" 2>/dev/null || true
      maven_src="$(prefer_existing_dir "$cache_root/java/maven-repo" "$host_home_guest/.m2/repository")"
      ensure_bind_mount "$maven_src" "$runtime_home/.m2/repository"
    fi
    if [ "$enable_gradle" = "1" ]; then
      mkdir -p "$cache_root/java/gradle" 2>/dev/null || true
      gradle_src="$(prefer_existing_dir "$cache_root/java/gradle" "$host_home_guest/.gradle/caches")"
      ensure_bind_mount "$gradle_src" "$runtime_home/.gradle/caches"
    fi
    if [ "$enable_composer" = "1" ]; then
      mkdir -p "$cache_root/php/composer" 2>/dev/null || true
      composer_src="$(prefer_existing_dir "$cache_root/php/composer" "$host_home_guest/Library/Caches/composer" "$host_home_guest/.cache/composer")"
      ensure_bind_mount "$composer_src" "$runtime_home/.cache/composer"
    fi
    if [ "$enable_scala" = "1" ]; then
      mkdir -p "$cache_root/scala/coursier" "$cache_root/scala/ivy2" 2>/dev/null || true
      scala_coursier_src="$(prefer_existing_dir "$cache_root/scala/coursier" "$host_home_guest/Library/Caches/Coursier/v1" "$host_home_guest/.cache/coursier")"
      scala_ivy_src="$(prefer_existing_dir "$cache_root/scala/ivy2" "$host_home_guest/.ivy2/cache")"
      ensure_bind_mount "$scala_coursier_src" "$runtime_home/.cache/coursier"
      ensure_bind_mount "$scala_ivy_src" "$runtime_home/.ivy2/cache"
    fi
    if [ "$enable_ruby" = "1" ]; then
      mkdir -p "$cache_root/ruby/bundle" 2>/dev/null || true
      ruby_bundle_src="$(prefer_existing_dir "$cache_root/ruby/bundle" "$host_home_guest/.bundle/cache")"
      ensure_bind_mount "$ruby_bundle_src" "$runtime_home/.bundle/cache"
    fi
    if [ "$enable_rust" = "1" ]; then
      mkdir -p "$cache_root/rust/cargo-home/registry" "$cache_root/rust/cargo-home/git" 2>/dev/null || true
      rust_registry_src="$(prefer_existing_dir "$cache_root/rust/cargo-home/registry" "$host_home_guest/.cargo/registry")"
      rust_git_src="$(prefer_existing_dir "$cache_root/rust/cargo-home/git" "$host_home_guest/.cargo/git")"
      ensure_bind_mount "$rust_registry_src" "$runtime_home/.cargo/registry"
      ensure_bind_mount "$rust_git_src" "$runtime_home/.cargo/git"
    fi
    if [ "$enable_deno" = "1" ]; then
      mkdir -p "$cache_root/deno/dir" 2>/dev/null || true
      deno_src="$(prefer_existing_dir "$cache_root/deno/dir" "$host_home_guest/Library/Caches/deno" "$host_home_guest/.cache/deno")"
      ensure_bind_mount "$deno_src" "$runtime_home/.cache/deno"
    fi
    if [ "$enable_bun" = "1" ]; then
      mkdir -p "$cache_root/bun/cache" 2>/dev/null || true
      bun_src="$(prefer_existing_dir "$cache_root/bun/cache" "$host_home_guest/.bun/install/cache")"
      ensure_bind_mount "$bun_src" "$runtime_home/.bun/install/cache"
    fi
    if [ "$enable_nuget" = "1" ]; then
      mkdir -p "$cache_root/dotnet/nuget-packages" "$cache_root/dotnet/nuget-http" 2>/dev/null || true
      nuget_packages_src="$(prefer_existing_dir "$cache_root/dotnet/nuget-packages" "$host_home_guest/.nuget/packages")"
      nuget_http_src="$(prefer_existing_dir "$cache_root/dotnet/nuget-http" "$host_home_guest/Library/Caches/NuGet/v3-cache" "$host_home_guest/.local/share/NuGet/v3-cache")"
      ensure_bind_mount "$nuget_packages_src" "$runtime_home/.nuget/packages"
      ensure_bind_mount "$nuget_http_src" "$runtime_home/.local/share/NuGet/v3-cache"
    fi

    status="reused"
    if [ "$applied" -eq 1 ] && [ "$fallback" -gt 0 ]; then
      status="partial"
    elif [ "$applied" -eq 1 ]; then
      status="applied"
    elif [ "$fallback" -gt 0 ]; then
      status="fallback"
    fi
    printf "status=%s\n" "$status"
    if [ -n "$fallback_reasons" ]; then
      printf "reason=%s\n" "$fallback_reasons"
    fi
    """

    public init(
        executablePath: String,
        explicitInstanceName: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let runtimeRootOverride = ProcessInfo.processInfo.environment["MSL_RUNTIME_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let homeOverride = ProcessInfo.processInfo.environment["MSL_HOME"], !homeOverride.isEmpty {
            self.paths = MSLPaths(
                homeDirectoryURL: URL(fileURLWithPath: homeOverride),
                runtimeRootURL: runtimeRootOverride
            )
        } else {
            self.paths = MSLPaths(
                homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
                runtimeRootURL: runtimeRootOverride
            )
        }

        try fileManager.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.appLogs, withIntermediateDirectories: true)

        self.logger = MSLLogger(logFile: paths.logs.appendingPathComponent("msl.log", isDirectory: false), fileManager: fileManager)
        self.lock = try FileLock(path: paths.lockFile.path)
        self.store = StateStore(paths: paths, fileManager: fileManager)
        self.bootstrap = BootstrapManager(paths: paths, logger: logger, fileManager: fileManager)
        self.distributionManager = DistributionManager(paths: paths, logger: logger, fileManager: fileManager)
        self.defaultInstanceStore = DefaultInstanceStore(paths: paths, fileManager: fileManager)
        self.sessions = SessionManager(store: store)
        self.logRouter = RuntimeLogRouter(paths: paths, fileManager: fileManager)
        self.executablePath = executablePath
        self.explicitInstanceName = explicitInstanceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.autoImageCompactThresholdBytes = 0
        self.autoImageCompactThresholdPercent = 0
        self.autoImageCompactCooldownMs = 0
    }

    /// Main daemon entry point. Blocks until idle timeout or explicit stop.
    public func run() throws -> Never {
        logger.log("daemon_started", fields: ["pid": String(getpid())])
        let startupStartMs = daemonMonotonicMs()
        let startupEpochMs = nowEpochMs()
        let bootstrapInstanceName = explicitInstanceName ?? "default"

        updateStateStarting(step: .daemonLaunch, instanceName: bootstrapInstanceName, startupEpochMs: startupEpochMs)

        // 1. Bootstrap
        let bootstrapStartMs = daemonMonotonicMs()
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }
        logger.log("startup_phase_duration_ms", fields: [
            "phase": "bootstrap_total",
            "elapsed_ms": String(max(0, daemonMonotonicMs() - bootstrapStartMs))
        ])
        updateStateStepCompleted(step: .daemonLaunch, instanceName: bootstrapInstanceName)
        updateStateStarting(step: .startupRecovery, instanceName: bootstrapInstanceName)
        try performStartupRecovery()
        updateStateStepCompleted(step: .startupRecovery, instanceName: bootstrapInstanceName)

        let metadataResolveStartMs = daemonMonotonicMs()
        updateStateStarting(step: .runtimeMetadataResolve, instanceName: bootstrapInstanceName, startupEpochMs: startupEpochMs)
        let metadataURL = try resolveRuntimeMetadataURL(explicitInstanceName: explicitInstanceName)
        let instanceName = metadataURL.deletingLastPathComponent().lastPathComponent
        let instanceContext = instanceRegistry.context(for: instanceName)
        instanceContext.metadataURL = metadataURL
        instanceContext.lifecycleState = .booting
        activeInstanceName = instanceName
        launchOriginTracker.record(
            instance: instanceName,
            callerCwd: ProcessInfo.processInfo.environment["MSL_DAEMON_LAUNCH_CWD"]
        )
        let initialMetadata = try distributionManager.readOrRebuildInstanceMetadata(at: metadataURL)
        self.runtimeMetadataURL = metadataURL
        logger.log("startup_phase_duration_ms", fields: [
            "phase": "runtime_metadata_resolve",
            "elapsed_ms": String(max(0, daemonMonotonicMs() - metadataResolveStartMs)),
            "instance": instanceName
        ])
        logger.log("runtime_target_resolved", fields: [
            "instance": instanceName,
            "metadata": metadataURL.path
        ])
        logRouter.logVM(
            instance: instanceName,
            event: "daemon_instance_boot_start",
            fields: ["op": "boot", "result": "started"]
        )
        publishInstanceStateEvent(instance: instanceName, state: "Booting", reason: "boot_started")
        let bootProfile = try resolveBootProfile(metadataURL: metadataURL, instanceName: instanceName)
        logger.log("init_mode_selected", fields: [
            "instance": instanceName,
            "init_mode": bootProfile.initMode,
            "service_manager": bootProfile.serviceManager ?? "-",
            "source": bootProfile.profileSource
        ])
        updateStateStepCompleted(step: .runtimeMetadataResolve, instanceName: instanceName)
        updateStateStarting(step: .vmConfigurationBuild, instanceName: instanceName)

        // 2. Start VM and get init channel client
        var activeBootStep: StartupStep = .vmConfigurationBuild
        var resolvedNetworkMode = resolveConfiguredNetworkMode()
        applyResolvedNetworkMode(resolvedNetworkMode, to: instanceContext, instanceName: instanceName)
        let makeRunner = { (_ resolved: ResolvedNetworkMode) -> VirtualMachineRunner in
            self.makeVirtualMachineRunner(
                metadataURL: metadataURL,
                bootProfile: bootProfile,
                instanceName: instanceName,
                resolvedNetworkMode: resolved,
                startupPhaseObserver: { [weak self] phase in
                    guard let self else { return }
                    switch phase {
                    case "vm_configuration_build":
                        activeBootStep = .vmStart
                        self.updateStateStepCompleted(step: .vmConfigurationBuild, instanceName: instanceName)
                        self.updateStateStarting(step: .vmStart, instanceName: instanceName)
                    case "vm_start":
                        activeBootStep = .initHandshakeWait
                        self.updateStateStepCompleted(step: .vmStart, instanceName: instanceName)
                        self.updateStateStarting(step: .initHandshakeWait, instanceName: instanceName)
                    case "init_handshake_wait":
                        self.updateStateStepCompleted(step: .initHandshakeWait, instanceName: instanceName)
                    default:
                        break
                    }
                }
            )
        }
        var runner = makeRunner(resolvedNetworkMode)
        self.vmRunner = runner
        instanceContext.vmRunner = runner

        let client: InitChannelClient
        do {
            var resolvedClient: InitChannelClient?
            try instanceContext.runBootOnce {
                resolvedClient = try runner.startVMForDaemon()
            }
            guard let resolvedClient else {
                throw MSLRuntimeError("instance boot did not provide init channel")
            }
            client = resolvedClient
        } catch {
            if NetworkModeResolver.shouldFallbackToNAT(configured: resolvedNetworkMode.configured, error: error),
               resolvedNetworkMode.effective == .vmnetShared {
                resolvedNetworkMode = NetworkModeResolver.fallbackToNAT(
                    from: resolvedNetworkMode,
                    reason: "vmnet unavailable at startup: \(error)"
                )
                applyResolvedNetworkMode(resolvedNetworkMode, to: instanceContext, instanceName: instanceName)
                runner = makeRunner(resolvedNetworkMode)
                self.vmRunner = runner
                instanceContext.vmRunner = runner
                do {
                    var fallbackClient: InitChannelClient?
                    try instanceContext.runBootOnce {
                        fallbackClient = try runner.startVMForDaemon()
                    }
                    guard let fallbackClient else {
                        throw MSLRuntimeError("instance boot did not provide init channel")
                    }
                    client = fallbackClient
                } catch {
                    let bootFailureCode: String
                    switch activeBootStep {
                    case .vmConfigurationBuild:
                        bootFailureCode = "vm_configuration_build_failed"
                    case .vmStart:
                        bootFailureCode = "vm_start_failed"
                    case .initHandshakeWait:
                        bootFailureCode = "init_handshake_wait_failed"
                    default:
                        bootFailureCode = "vm_start_failed"
                    }
                    updateStateBootFailed(
                        step: activeBootStep,
                        instanceName: instanceName,
                        code: bootFailureCode,
                        message: String(describing: error)
                    )
                    logger.log("daemon_vm_start_failed", fields: ["error": String(describing: error)])
                    logRouter.logVM(
                        instance: instanceName,
                        event: "daemon_instance_boot_failed",
                        fields: ["op": "boot", "result": "failed", "error": String(describing: error)]
                    )
                    publishInstanceStateEvent(
                        instance: instanceName,
                        state: "Error",
                        reason: "boot_failed",
                        error: String(describing: error)
                    )
                    instanceContext.lifecycleState = .error
                    instanceContext.lastError = String(describing: error)
                    updateStateStopped(lastError: String(describing: error))
                    Foundation.exit(1)
                }
            } else {
            let bootFailureCode: String
            switch activeBootStep {
            case .vmConfigurationBuild:
                bootFailureCode = "vm_configuration_build_failed"
            case .vmStart:
                bootFailureCode = "vm_start_failed"
            case .initHandshakeWait:
                bootFailureCode = "init_handshake_wait_failed"
            default:
                bootFailureCode = "vm_start_failed"
            }
            updateStateBootFailed(
                step: activeBootStep,
                instanceName: instanceName,
                code: bootFailureCode,
                message: String(describing: error)
            )
            logger.log("daemon_vm_start_failed", fields: ["error": String(describing: error)])
            logRouter.logVM(
                instance: instanceName,
                event: "daemon_instance_boot_failed",
                fields: ["op": "boot", "result": "failed", "error": String(describing: error)]
            )
            publishInstanceStateEvent(
                instance: instanceName,
                state: "Error",
                reason: "boot_failed",
                error: String(describing: error)
            )
            instanceContext.lifecycleState = .error
            instanceContext.lastError = String(describing: error)
            updateStateStopped(lastError: String(describing: error))
            Foundation.exit(1)
            }
        }
        self.initClient = client
        instanceContext.initClient = client
        instanceContext.networkTopology = runner.activeNetworkTopology
        if client.supportsDedicatedSideband {
            instanceContext.initWriteClient = client.makeSidebandClient()
            instanceContext.initReadClient = client.makeSidebandClient()
            instanceContext.housekeepingClient = instanceContext.initReadClient?.makeSidebandClient()
        } else {
            instanceContext.initWriteClient = nil
            instanceContext.initReadClient = nil
            instanceContext.housekeepingClient = nil
        }

        logger.log("daemon_startup_step_started", fields: [
            "instance": instanceName,
            "step": "tmp_storage_prepare"
        ])
        do {
            try prepareTmpStorageOnStartup(client: client, metadataURL: metadataURL, instanceName: instanceName)
        } catch {
            logger.log("daemon_vm_start_failed", fields: ["error": String(describing: error)])
            logRouter.logVM(
                instance: instanceName,
                event: "daemon_instance_boot_failed",
                fields: ["op": "tmp_storage_prepare", "result": "failed", "error": String(describing: error)]
            )
            publishInstanceStateEvent(
                instance: instanceName,
                state: "Error",
                reason: "tmp_storage_prepare_failed",
                error: String(describing: error)
            )
            instanceContext.lifecycleState = .error
            instanceContext.lastError = String(describing: error)
            runner.stopRunningVM()
            updateStateStopped(lastError: String(describing: error))
            Foundation.exit(1)
        }
        logger.log("daemon_startup_step_completed", fields: [
            "instance": instanceName,
            "step": "tmp_storage_prepare"
        ])
        logger.log("daemon_startup_step_started", fields: [
            "instance": instanceName,
            "step": "host_share_prepare"
        ])
        prepareHostShareRootMountOnStartup(client: client)
        logger.log("daemon_startup_step_completed", fields: [
            "instance": instanceName,
            "step": "host_share_prepare"
        ])
        logger.log("daemon_startup_step_started", fields: [
            "instance": instanceName,
            "step": "clock_sync"
        ])
        syncGuestClockAtStartup(client: client, instanceName: instanceName)
        logger.log("daemon_startup_step_completed", fields: [
            "instance": instanceName,
            "step": "clock_sync"
        ])
        logger.log("startup_total_duration_ms", fields: [
            "elapsed_ms": String(max(0, daemonMonotonicMs() - startupStartMs)),
            "instance": instanceName
        ])

        // 3. Converge runtime user (Step9)
        logger.log("daemon_startup_step_started", fields: [
            "instance": instanceName,
            "step": "user_converge"
        ])
        updateStateStarting(step: .userConverge, instanceName: instanceName)
        do {
            let firstBootPending = initialMetadata.bootstrap?.firstBootPending ?? true
            logger.log("su_bootstrap_started", fields: [
                "instance": instanceName,
                "first_boot": firstBootPending ? "true" : "false",
                "bootstrap_version": String(initialMetadata.bootstrap?.privilegeBootstrapVersion ?? 1)
            ])

            let resolved = try convergeRuntimeUser(
                client: client,
                metadataURL: metadataURL,
                instanceName: instanceName
            )
            instanceContext.runtimeUser = resolved.runtimeUser
            try distributionManager.writeBootstrapResult(
                metadataURL: metadataURL,
                result: "success",
                runtimeUser: resolved.runtimeUser,
                fallbackAdminGroup: resolved.adminGroup
            )
            logger.log("su_bootstrap_validation_passed", fields: [
                "instance": instanceName,
                "user": resolved.runtimeUser.name,
                "uid": String(resolved.runtimeUser.uid),
                "gid": String(resolved.runtimeUser.gid)
            ])
        } catch {
            updateStateBootFailed(
                step: .userConverge,
                instanceName: instanceName,
                code: "user_converge_failed",
                message: String(describing: error)
            )
            logger.log("user_convergence_failed", fields: [
                "instance": instanceName,
                "metadata": metadataURL.path,
                "error": String(describing: error)
            ])
            try? distributionManager.writeBootstrapResult(
                metadataURL: metadataURL,
                result: "failed",
                runtimeUser: nil,
                fallbackAdminGroup: nil
            )
            logger.log("su_bootstrap_failed", fields: [
                "instance": instanceName,
                "error": String(describing: error)
            ])
            logRouter.logVM(
                instance: instanceName,
                event: "daemon_instance_boot_failed",
                fields: ["op": "user_converge", "result": "failed", "error": String(describing: error)]
            )
            publishInstanceStateEvent(
                instance: instanceName,
                state: "Error",
                reason: "user_converge_failed",
                error: String(describing: error)
            )
            instanceContext.lifecycleState = .error
            instanceContext.lastError = String(describing: error)
            runner.stopRunningVM()
            updateStateStopped()
            Foundation.exit(1)
        }
        updateStateStepCompleted(step: .userConverge, instanceName: instanceName)
        logger.log("daemon_startup_step_completed", fields: [
            "instance": instanceName,
            "step": "user_converge"
        ])
        configureMemoryReclaimPolicy()
        ensureGuestMSLCommandAlias(client: client)
        logger.log("daemon_startup_step_started", fields: [
            "instance": instanceName,
            "step": "vscode_root_state"
        ])
        updateStateStarting(step: .vscodeRootState, instanceName: instanceName)
        ensureRootVSCodeServerDirectories(client: client, instanceName: instanceName)
        updateStateStepCompleted(step: .vscodeRootState, instanceName: instanceName)
        logger.log("daemon_startup_step_completed", fields: [
            "instance": instanceName,
            "step": "vscode_root_state"
        ])
        updateStateStarting(step: .dnsReconcile, instanceName: instanceName)
        scheduleBackgroundDNSReconcile(instanceName: instanceName, source: "startup")
        updateStateStepCompleted(step: .dnsReconcile, instanceName: instanceName)
        startDNSMonitorLoop()

        // 4. Set up port forwarding
        let guestIPHint = forwardingGuestIPHint(for: instanceContext)
            ?? ProcessInfo.processInfo.environment["MSL_GUEST_IP"]
        let guestIPResolver = GuestIPResolver(explicitIP: guestIPHint)
        let portForwarder = PortForwardingManager(
            logger: logger,
            guestIPResolver: guestIPResolver,
            exposeVMNetEndpoints: instanceContext.resolvedNetworkMode.effective == .vmnetShared
        )
        self.forwarder = portForwarder

        syncEffectivePortMappings(autoHostPorts: [], reason: "startup")

        // 5. Start control socket server
        let controlSocketPath = paths.runtimeControlSocketFile.path
        let eventSocketPath = paths.runtimeEventSocketFile.path
        let server = RuntimeControlServer(
            socketPath: controlSocketPath,
            handler: { [weak self] request in
                self?.handleControlRequest(request) ?? RuntimeControlResponse(ok: false, error: "daemon unavailable")
            },
            streamHandler: { [weak self] request, fd in
                self?.handleControlStreamRequest(request, fd: fd) ?? false
            }
        )
        self.controlServer = server
        let bus = DaemonEventBus(socketPath: eventSocketPath, logger: logger)
        self.eventBus = bus
        do {
            updateStateStarting(step: .controlSocketStart, instanceName: instanceName)
            try server.start()
            logger.log("daemon_control_socket_started", fields: ["path": controlSocketPath])
            updateStateStepCompleted(step: .controlSocketStart, instanceName: instanceName)
        } catch {
            updateStateBootFailed(
                step: .controlSocketStart,
                instanceName: instanceName,
                code: "control_socket_start_failed",
                message: String(describing: error)
            )
            logger.log("daemon_control_socket_failed", fields: ["error": String(describing: error)])
            runner.stopRunningVM()
            Foundation.exit(1)
        }
        do {
            updateStateStarting(step: .eventSocketStart, instanceName: instanceName)
            try bus.start()
            logger.log("daemon_event_socket_started", fields: ["path": eventSocketPath])
            updateStateStepCompleted(step: .eventSocketStart, instanceName: instanceName)
            let runtimeUser = instanceContext.runtimeUser?.name ?? "root"
            let sshManager = LocalhostSSHManager(
                paths: paths,
                lock: lock,
                store: store,
                logger: logger,
                executablePath: executablePath,
                fileManager: fileManager
            )
            let listener = try sshManager.start(
                instanceName: instanceName,
                requestedPort: nil,
                runtimeUser: runtimeUser
            )
            sshListener = listener.server
            sshInfo = listener.info
            registerWorkerWithManagerIfNeeded(
                instanceName: instanceName,
                controlSocketPath: controlSocketPath,
                eventSocketPath: eventSocketPath,
                sshInfo: listener.info
            )
        } catch {
            updateStateBootFailed(
                step: .eventSocketStart,
                instanceName: instanceName,
                code: "event_socket_start_failed",
                message: String(describing: error)
            )
            logger.log("daemon_event_socket_failed", fields: ["error": String(describing: error)])
            server.stop()
            runner.stopRunningVM()
            Foundation.exit(1)
        }
        do {
            updateStateStarting(step: .attachedDaemonStart, instanceName: instanceName)
            try ensureAttachedContainerDaemonStarted(instanceName: instanceName)
            updateStateStepCompleted(step: .attachedDaemonStart, instanceName: instanceName)
        } catch {
            updateStateBootFailed(
                step: .attachedDaemonStart,
                instanceName: instanceName,
                code: "attached_daemon_start_failed",
                message: String(describing: error)
            )
            bus.stop()
            server.stop()
            runner.stopRunningVM()
            Foundation.exit(1)
        }

        // 6. Update state
        updateStateRunning(instanceName: instanceName, controlSocketPath: controlSocketPath, eventSocketPath: eventSocketPath)
        instanceContext.lifecycleState = .running
        instanceContext.lastError = nil
        instanceContext.clearBootError()
        reconcileHostManagedHostnames(reason: "instance_start")
        logRouter.logVM(
            instance: instanceName,
            event: "daemon_instance_boot_ready",
            fields: ["op": "boot", "result": "ok"]
        )
        publishInstanceStateEvent(instance: instanceName, state: "Running", reason: "boot_ready")

        // 7. Arm initial idle timer (VM has no sessions yet)
        startAutoPortForwardLoop()
        armIdleTimer(for: instanceName)
        startMemoryReclaimLoop()

        logger.log("daemon_ready")

        // 8. Wait for stop signal
        stopSemaphore.wait()

        // 9. Cleanup
        shutdown()
        Foundation.exit(0)
    }

    private func performStartupRecovery() throws {
        let targetInstanceName = explicitInstanceName
            ?? (try? defaultInstanceStore.loadDefaultInstanceName())
            ?? "default"
        let otherDaemons = (try? DaemonClient.listDaemonProcesses())?.filter { process in
            process.isDaemon
                && process.pid != getpid()
                && (targetInstanceName.isEmpty || process.instanceName == targetInstanceName)
                && (kill(process.pid, 0) == 0 || errno == EPERM)
        } ?? []
        if let existingDaemon = otherDaemons.first {
            logger.log("daemon_startup_recovery_existing_daemon_detected", fields: [
                "instance": targetInstanceName,
                "existing_pid": String(existingDaemon.pid),
                "current_pid": String(getpid())
            ])
            throw MSLRuntimeError("daemon already running for instance \(targetInstanceName)")
        }

        let staleSessions = try sessions.reconcile()
        if !staleSessions.isEmpty {
            try sessions.clearAllAndTerminate()
        }

        let nowMs = nowEpochMs()
        let summary = try lock.withExclusiveLock { () throws -> DaemonStartupStateNormalizationSummary in
            var state = try store.loadState()
            let result = DaemonStartupStateNormalizer.normalizeForDaemonStart(state: &state, nowMs: nowMs)
            if result.legacyStateReset || !result.normalizedInstances.isEmpty {
                try store.saveState(state)
            }
            return result
        }

        let controlSocketPath = paths.runtimeControlSocketFile.path
        let eventSocketPath = paths.runtimeEventSocketFile.path
        var removedSocket = false
        if FileManager.default.fileExists(atPath: controlSocketPath) {
            do {
                try FileManager.default.removeItem(atPath: controlSocketPath)
                removedSocket = true
            } catch {
                logger.log("daemon_startup_recovery_socket_remove_failed", fields: [
                    "path": controlSocketPath,
                    "error": String(describing: error)
                ])
            }
        }
        var removedEventSocket = false
        if FileManager.default.fileExists(atPath: eventSocketPath) {
            do {
                try FileManager.default.removeItem(atPath: eventSocketPath)
                removedEventSocket = true
            } catch {
                logger.log("daemon_startup_recovery_socket_remove_failed", fields: [
                    "path": eventSocketPath,
                    "error": String(describing: error)
                ])
            }
        }

        if !staleSessions.isEmpty || summary.legacyStateReset || !summary.normalizedInstances.isEmpty || removedSocket || removedEventSocket {
            logger.log("daemon_startup_recovery_applied", fields: [
                "stale_session_count": String(staleSessions.count),
                "legacy_state_reset": summary.legacyStateReset ? "true" : "false",
                "normalized_instances": summary.normalizedInstances.joined(separator: ","),
                "removed_control_socket": removedSocket ? "true" : "false",
                "removed_event_socket": removedEventSocket ? "true" : "false"
            ])
        } else {
            logger.log("daemon_startup_recovery_clean")
        }
    }

    private func publishInstanceStateEvent(
        instance: String,
        state: String,
        reason: String,
        error: String? = nil
    ) {
        var meta: [String: String] = ["reason": reason]
        if let error, !error.isEmpty {
            meta["error"] = error
        }
        eventBus?.publish(
            topic: "instance_state",
            type: "instance_state_changed",
            instance: instance,
            state: state,
            meta: meta
        )
    }

    private func resolveRuntimeMetadataURL(explicitInstanceName: String?) throws -> URL {
        let configured = try defaultInstanceStore.loadDefaultInstanceName()
        return try distributionManager.runtimeMetadataURL(
            explicitInstanceName: explicitInstanceName,
            defaultInstanceName: configured
        )
    }

    private func currentRuntimeInstanceName() -> String {
        if let activeInstanceName, !activeInstanceName.isEmpty {
            return activeInstanceName
        }
        if let runtimeMetadataURL {
            let name = runtimeMetadataURL.deletingLastPathComponent().lastPathComponent
            if !name.isEmpty {
                return name
            }
        }
        return explicitInstanceName ?? "default"
    }

    private func handleGuestCodeOpenPayload(_ payload: String, sourceInstance: String? = nil) {
        logger.log("attached_open_requested", fields: [
            "raw": payload,
            "source_instance": sourceInstance ?? "-"
        ])
        guard let request = AttachedCodeOpenRequest.parse(payload) else {
            logger.log("attached_open_rejected", fields: ["reason": "invalid_payload"])
            return
        }

        let currentInstanceName = currentRuntimeInstanceName()
        let launchTarget = resolveAttachedOpenLaunchTarget(
            sourceInstance: sourceInstance,
            currentRuntimeInstanceName: currentInstanceName
        )

        do {
            try launchHostVSCodeAttachedOpen(
                vmID: launchTarget.vmID,
                targetPath: request.targetPath,
                socketPath: launchTarget.socketPath
            )
            logger.log("attached_open_completed", fields: [
                "instance": launchTarget.instanceName,
                "current_instance": currentInstanceName,
                "source_instance": sourceInstance ?? "-",
                "vm_id": launchTarget.vmID,
                "target": request.targetPath
            ])
        } catch {
            let reason = (error as? AttachedOpenForwardError)?.reasonCode ?? "open_forward_failed"
            logger.log("attached_open_failed", fields: [
                "instance": launchTarget.instanceName,
                "current_instance": currentInstanceName,
                "source_instance": sourceInstance ?? "-",
                "vm_id": launchTarget.vmID,
                "target": request.targetPath,
                "reason": reason,
                "error": String(describing: error)
            ])
        }
    }

    private func launchHostVSCodeAttachedOpen(
        vmID: String,
        targetPath: String,
        socketPath: String
    ) throws {
        let attemptID = UUID().uuidString.lowercased()
        let processExecutor = ProcessExecutor()
        guard let codePath = processExecutor.findExecutable(["code"]) else {
            throw AttachedOpenForwardError.codeCLINotFound
        }

        let authority = try buildAttachedContainerAuthority(
            vmID: vmID,
            socketPath: socketPath
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codePath)
        process.arguments = ["--remote", authority, targetPath]
        process.standardInput = nil
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var env = ProcessInfo.processInfo.environment
        env["DOCKER_HOST"] = "unix://\(socketPath)"
        env["MSL_ATTACHED_OPEN_ATTEMPT_ID"] = attemptID
        process.environment = env
        let outputState = AttachedOpenOutputState()
        attachAttachedOpenPipeLogger(
            pipe: stdoutPipe,
            attemptID: attemptID,
            vmID: vmID,
            stream: "stdout",
            state: outputState,
            logger: logger
        )
        attachAttachedOpenPipeLogger(
            pipe: stderrPipe,
            attemptID: attemptID,
            vmID: vmID,
            stream: "stderr",
            state: outputState,
            logger: logger
        )
        process.terminationHandler = { [logger] proc in
            logger.log("attached_open_forward_exited", fields: [
                "attempt_id": attemptID,
                "vm_id": vmID,
                "termination_status": String(proc.terminationStatus),
                "termination_reason": String(proc.terminationReason.rawValue),
                "stdout_preview": outputState.preview(for: "stdout"),
                "stderr_preview": outputState.preview(for: "stderr"),
                "stdout_bytes": String(outputState.byteCount(for: "stdout")),
                "stderr_bytes": String(outputState.byteCount(for: "stderr"))
            ])
        }

        logger.log("attached_open_forward_started", fields: [
            "attempt_id": attemptID,
            "vm_id": vmID,
            "target": targetPath,
            "socket": socketPath,
            "authority": authority,
            "code_path": codePath
        ])
        do {
            try process.run()
        } catch {
            throw AttachedOpenForwardError.processLaunchFailed(String(describing: error))
        }
        logger.log("attached_open_forward_spawned", fields: [
            "attempt_id": attemptID,
            "vm_id": vmID,
            "pid": String(process.processIdentifier)
        ])
        logger.log("attached_open_forward_completed", fields: [
            "attempt_id": attemptID,
            "vm_id": vmID,
            "target": targetPath,
            "spawn_mode": "detached"
        ])
    }

    private func attachAttachedOpenPipeLogger(
        pipe: Pipe,
        attemptID: String,
        vmID: String,
        stream: String,
        state: AttachedOpenOutputState,
        logger: MSLLogger
    ) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                readable.readabilityHandler = nil
                return
            }
            state.append(data, for: stream)
            logger.log("attached_open_forward_stream", fields: [
                "attempt_id": attemptID,
                "vm_id": vmID,
                "stream": stream,
                "bytes": String(data.count),
                "preview": String(decoding: data.prefix(256), as: UTF8.self)
            ])
        }
    }

    private final class AttachedOpenOutputState {
        private let lock = NSLock()
        private var previews: [String: Data] = [:]
        private var counts: [String: Int] = [:]
        private let maxPreviewBytes = 512

        func append(_ data: Data, for stream: String) {
            lock.lock()
            defer { lock.unlock() }
            counts[stream, default: 0] += data.count
            var preview = previews[stream] ?? Data()
            if preview.count < maxPreviewBytes {
                let remaining = maxPreviewBytes - preview.count
                preview.append(data.prefix(remaining))
                previews[stream] = preview
            }
        }

        func preview(for stream: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            let data = previews[stream] ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        func byteCount(for stream: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[stream] ?? 0
        }
    }

    private func buildAttachedContainerAuthority(
        vmID: String,
        socketPath: String
    ) throws -> String {
        try buildAttachedContainerAuthorityString(vmID: vmID, socketPath: socketPath)
    }

    private func legacyVMState(for lifecycle: InstanceLifecycleState) -> VMState {
        switch lifecycle {
        case .running:
            return .running
        default:
            return .stopped
        }
    }

    private enum StartupStep: Int {
        case daemonLaunch = 1
        case startupRecovery = 2
        case runtimeMetadataResolve = 3
        case vmConfigurationBuild = 4
        case vmStart = 5
        case initHandshakeWait = 6
        case userConverge = 7
        case vscodeRootState = 8
        case dnsReconcile = 9
        case controlSocketStart = 10
        case eventSocketStart = 11
        case attachedDaemonStart = 12
        case ready = 13

        var name: String {
            switch self {
            case .daemonLaunch: return "daemon_launch"
            case .startupRecovery: return "startup_recovery"
            case .runtimeMetadataResolve: return "runtime_metadata_resolve"
            case .vmConfigurationBuild: return "vm_configuration_build"
            case .vmStart: return "vm_start"
            case .initHandshakeWait: return "init_handshake_wait"
            case .userConverge: return "user_converge"
            case .vscodeRootState: return "vscode_root_state"
            case .dnsReconcile: return "dns_reconcile"
            case .controlSocketStart: return "control_socket_start"
            case .eventSocketStart: return "event_socket_start"
            case .attachedDaemonStart: return "attached_daemon_start"
            case .ready: return "ready"
            }
        }
    }

    private func updateStateStarting(step: StartupStep, instanceName: String, startupEpochMs: Int64? = nil) {
        do {
            try lock.withExclusiveLock {
                var state = try store.loadState()
                let epoch = startupEpochMs ?? state.startupEpochMs ?? nowEpochMs()
                state.distro = instanceName
                state.vmState = .stopped
                state.lifecycleState = .starting
                state.startupEpochMs = epoch
                state.startupStep = step.rawValue
                state.startupStepName = step.name
                state.startupStepStatus = .inProgress
                state.lastErrorCode = nil
                state.lastErrorMessage = nil
                state.lastTransitionEpochMs = nowEpochMs()
                upsertInstanceState(
                    &state,
                    instanceName: instanceName,
                    lifecycleState: .booting,
                    activeSessionCount: 0,
                    idleTimer: IdleTimerState(armed: false, deadlineEpochMs: nil),
                    runtimeHostPid: Int32(getpid()),
                    runtimeControlSocket: nil,
                    runtimeUser: nil,
                    initChannel: state.initChannel,
                    lastError: nil,
                    lastErrorCode: nil,
                    lastErrorMessage: nil,
                    startupEpochMs: epoch,
                    startupStep: step.rawValue,
                    startupStepName: step.name,
                    startupStepStatus: .inProgress
                )
                try store.saveState(state)
            }
        } catch {
            logger.log("daemon_state_update_error", fields: ["error": String(describing: error), "step": step.name])
        }
    }

    private func updateStateStepCompleted(step: StartupStep, instanceName: String) {
        do {
            try lock.withExclusiveLock {
                var state = try store.loadState()
                state.startupStep = step.rawValue
                state.startupStepName = step.name
                state.startupStepStatus = .completed
                state.lastTransitionEpochMs = nowEpochMs()
                upsertInstanceState(
                    &state,
                    instanceName: instanceName,
                    lifecycleState: .booting,
                    activeSessionCount: 0,
                    idleTimer: IdleTimerState(armed: false, deadlineEpochMs: nil),
                    runtimeHostPid: Int32(getpid()),
                    runtimeControlSocket: nil,
                    runtimeUser: instanceRegistry.context(for: instanceName).runtimeUser,
                    initChannel: state.initChannel,
                    lastError: nil,
                    lastErrorCode: nil,
                    lastErrorMessage: nil,
                    startupEpochMs: state.startupEpochMs,
                    startupStep: step.rawValue,
                    startupStepName: step.name,
                    startupStepStatus: .completed
                )
                try store.saveState(state)
            }
        } catch {
            logger.log("daemon_state_update_error", fields: ["error": String(describing: error), "step": step.name])
        }
    }

    private func updateStateBootFailed(
        step: StartupStep,
        instanceName: String,
        code: String,
        message: String
    ) {
        do {
            try lock.withExclusiveLock {
                var state = try store.loadState()
                state.distro = instanceName
                state.vmState = .stopped
                state.lifecycleState = .error
                state.activeSessionCount = 0
                state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                state.runtimeHostPid = nil
                state.runtimeControlSocket = nil
                state.daemonHostPid = nil
                state.daemonControlSocket = nil
                state.daemonEventSocket = nil
                state.runtimeUser = nil
                state.startupStep = step.rawValue
                state.startupStepName = step.name
                state.startupStepStatus = .failed
                state.lastErrorCode = code
                state.lastErrorMessage = message
                state.lastTransitionEpochMs = nowEpochMs()
                upsertInstanceState(
                    &state,
                    instanceName: instanceName,
                    lifecycleState: .error,
                    activeSessionCount: 0,
                    idleTimer: state.idleTimer,
                    runtimeHostPid: nil,
                    runtimeControlSocket: nil,
                    runtimeUser: nil,
                    initChannel: state.initChannel,
                    lastError: message,
                    lastErrorCode: code,
                    lastErrorMessage: message,
                    startupEpochMs: state.startupEpochMs,
                    startupStep: step.rawValue,
                    startupStepName: step.name,
                    startupStepStatus: .failed
                )
                try store.saveState(state)
            }
        } catch {
            logger.log("daemon_state_update_error", fields: ["error": String(describing: error), "step": step.name])
        }
    }

    private func updateStateRunning(instanceName: String, controlSocketPath: String, eventSocketPath: String) {
        do {
            try lock.withExclusiveLock {
                var state = try store.loadState()
                let runtimeUser = instanceRegistry.context(for: instanceName).runtimeUser
                state.vmState = .running
                state.lifecycleState = .running
                state.distro = instanceName
                state.lastTransitionEpochMs = nowEpochMs()
                state.runtimeHostPid = Int32(getpid())
                state.runtimeControlSocket = controlSocketPath
                state.daemonHostPid = Int32(getpid())
                state.daemonControlSocket = controlSocketPath
                state.daemonEventSocket = eventSocketPath
                state.activeSessionCount = 0
                state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                state.runtimeUser = runtimeUser
                state.startupStep = StartupStep.ready.rawValue
                state.startupStepName = StartupStep.ready.name
                state.startupStepStatus = .completed
                state.lastErrorCode = nil
                state.lastErrorMessage = nil
                upsertInstanceState(
                    &state,
                    instanceName: instanceName,
                    lifecycleState: .running,
                    activeSessionCount: 0,
                    idleTimer: state.idleTimer,
                    runtimeHostPid: state.runtimeHostPid,
                    runtimeControlSocket: state.runtimeControlSocket,
                    runtimeUser: runtimeUser,
                    initChannel: state.initChannel,
                    lastError: nil,
                    lastErrorCode: nil,
                    lastErrorMessage: nil,
                    startupEpochMs: state.startupEpochMs,
                    startupStep: StartupStep.ready.rawValue,
                    startupStepName: StartupStep.ready.name,
                    startupStepStatus: .completed
                )
                try store.saveState(state)
            }
        } catch {
            logger.log("daemon_state_update_error", fields: ["error": String(describing: error), "step": StartupStep.ready.name])
        }
    }

    private func upsertInstanceState(
        _ state: inout RuntimeState,
        instanceName: String,
        lifecycleState: InstanceLifecycleState,
        activeSessionCount: Int,
        idleTimer: IdleTimerState,
        runtimeHostPid: Int32?,
        runtimeControlSocket: String?,
        runtimeUser: RuntimeUserState?,
        initChannel: InitChannelState?,
        lastError: String?,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil,
        startupEpochMs: Int64? = nil,
        startupStep: Int? = nil,
        startupStepName: String? = nil,
        startupStepStatus: StartupStepStatus? = nil
    ) {
        var entries = state.instances ?? []
        if let existingIndex = entries.firstIndex(where: { $0.instance == instanceName }) {
            entries[existingIndex].vmState = legacyVMState(for: lifecycleState)
            entries[existingIndex].lifecycleState = {
                switch lifecycleState {
                case .running: return .running
                case .booting: return .starting
                case .stopping: return .stopping
                case .error: return .error
                case .stopped: return .stopped
                }
            }()
            entries[existingIndex].activeSessionCount = activeSessionCount
            entries[existingIndex].idleTimer = idleTimer
            entries[existingIndex].runtimeHostPid = runtimeHostPid
            entries[existingIndex].runtimeControlSocket = runtimeControlSocket
            entries[existingIndex].runtimeUser = runtimeUser
            entries[existingIndex].initChannel = initChannel
            entries[existingIndex].lastError = lastError
            entries[existingIndex].lastErrorCode = lastErrorCode
            entries[existingIndex].lastErrorMessage = lastErrorMessage ?? lastError
            entries[existingIndex].startupEpochMs = startupEpochMs
            entries[existingIndex].startupStep = startupStep
            entries[existingIndex].startupStepName = startupStepName
            entries[existingIndex].startupStepStatus = startupStepStatus
            entries[existingIndex].lastTransitionEpochMs = nowEpochMs()
        } else {
            entries.append(
                RuntimeInstanceState(
                    instance: instanceName,
                    vmState: legacyVMState(for: lifecycleState),
                    lifecycleState: {
                        switch lifecycleState {
                        case .running: return .running
                        case .booting: return .starting
                        case .stopping: return .stopping
                        case .error: return .error
                        case .stopped: return .stopped
                        }
                    }(),
                    activeSessionCount: activeSessionCount,
                    idleTimer: idleTimer,
                    runtimeUser: runtimeUser,
                    initChannel: initChannel,
                    runtimeHostPid: runtimeHostPid,
                    runtimeControlSocket: runtimeControlSocket,
                    lastError: lastError,
                    lastErrorCode: lastErrorCode,
                    lastErrorMessage: lastErrorMessage ?? lastError,
                    startupEpochMs: startupEpochMs,
                    startupStep: startupStep,
                    startupStepName: startupStepName,
                    startupStepStatus: startupStepStatus,
                    lastTransitionEpochMs: nowEpochMs()
                )
            )
        }
        entries.sort { $0.instance < $1.instance }
        state.instances = entries
    }

    private func syncGuestClockAtStartup(client: InitChannelClient, instanceName: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let utc = formatter.string(from: Date())
        let script = "date -u -s '\(utc)' >/dev/null 2>&1 || busybox date -u -s '\(utc)' >/dev/null 2>&1"
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                timeoutMs: 3_000
            ))
            if response.ok, (response.exitCode ?? 1) == 0 {
                logger.log("clock_sync_startup_succeeded", fields: [
                    "instance": instanceName,
                    "utc": utc
                ])
            } else {
                logger.log("clock_sync_startup_failed", fields: [
                    "instance": instanceName,
                    "utc": utc,
                    "error": response.error?.message ?? response.stderr ?? "failed"
                ])
            }
        } catch {
            logger.log("clock_sync_startup_failed", fields: [
                "instance": instanceName,
                "utc": utc,
                "error": String(describing: error)
            ])
        }
    }

    private func resolveBootProfile(metadataURL: URL, instanceName: String) throws -> RuntimeBootProfile {
        let configKernel = try defaultInstanceStore.loadDefaultKernelProfileRef()
        let resolver = RuntimeBootProfileResolver(
            paths: paths,
            logger: logger,
            environment: ProcessInfo.processInfo.environment
        )
        return try resolver.resolve(
            metadataURL: metadataURL,
            instanceName: instanceName,
            defaultKernelProfileRef: configKernel
        )
    }

    // MARK: - Control Socket Request Handler

    private func handleControlRequest(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        switch request.op {
        // --- exec ---
        case "exec":
            return handleExec(request)
        case "workspace_prepare":
            return handleWorkspacePrepare(request)
        case "cache_share_prepare":
            return handleCacheSharePrepare()

        case "provision_status":
            return handleProvisionStatus(request)

        // --- PTY ops ---
        case "pty_open":
            return handlePtyOpen(request)
        case "pty_read":
            return handlePtyRead(request)
        case "pty_write":
            return handlePtyWrite(request)
        case "pty_resize":
            return handlePtyResize(request)
        case "pty_close":
            return handlePtyClose(request)
        case "proc_open":
            return handleProcOpen(request)
        case "proc_read":
            return handleProcRead(request)
        case "proc_write":
            return handleProcWrite(request)
        case "proc_stdin_close":
            return handleProcStdinClose(request)
        case "proc_close":
            return handleProcClose(request)

        // --- session management ---
        case "session_register":
            return handleSessionRegister(request)
        case "session_unregister":
            return handleSessionUnregister(request)

        // --- port forwarding (existing) ---
        case "port_add":
            return handlePortAdd(request)
        case "port_rm":
            return handlePortRemove(request)
        case "port_ls":
            return handlePortList(request)
        case "memory_status":
            return handleMemoryStatus(request)
        case "dns_reconcile":
            return handleDNSReconcile(request)
        case "dns_status":
            return handleDNSStatus(request)
        case "instance_ls":
            return handleInstanceList()
        case "instance_status":
            return handleInstanceStatus(request)
        case "instance_stop":
            return handleInstanceStop(request)

        // --- stop ---
        case "stop":
            return handleInstanceStop(request)

        default:
            return RuntimeControlResponse(ok: false, error: "unsupported op: \(request.op)")
        }
    }

    private func handleControlStreamRequest(_ request: RuntimeControlRequest, fd: Int32) -> Bool {
        switch request.op {
        case "proc_subscribe":
            return handleProcSubscribeStream(request, fd: fd)
        case "pty_subscribe":
            return handlePtySubscribeStream(request, fd: fd)
        default:
            return false
        }
    }

    // MARK: - exec

    private func resolveTargetInstanceName(_ request: RuntimeControlRequest) -> String {
        if let explicit = request.instance?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        if let sessionID = request.sessionId,
           let entry = sessionEntry(id: sessionID) {
            return entry.instance
        }
        return currentRuntimeInstanceName()
    }

    private func resolveContext(for request: RuntimeControlRequest) -> InstanceRuntimeContext? {
        let instanceName = resolveTargetInstanceName(request)
        let context = instanceRegistry.context(for: instanceName)
        if context.lifecycleState == .running {
            return context
        }
        if instanceName == currentRuntimeInstanceName(), context.initClient != nil {
            return context
        }
        return nil
    }

    private func ensureInstanceRunning(instanceName: String, callerCwd: String?) throws -> InstanceRuntimeContext {
        let context = instanceRegistry.context(for: instanceName)
        if context.lifecycleState == .running, context.initClient != nil {
            return context
        }

        let metadataURL = try resolveRuntimeMetadataURL(explicitInstanceName: instanceName)
        context.metadataURL = metadataURL
        context.lifecycleState = .booting
        launchOriginTracker.record(instance: instanceName, callerCwd: callerCwd)
        publishInstanceStateEvent(instance: instanceName, state: "Booting", reason: "boot_started")

        let bootProfile = try resolveBootProfile(metadataURL: metadataURL, instanceName: instanceName)
        var resolvedNetworkMode = resolveConfiguredNetworkMode()
        applyResolvedNetworkMode(resolvedNetworkMode, to: context, instanceName: instanceName)
        let makeRunner = { (_ resolved: ResolvedNetworkMode) -> VirtualMachineRunner in
            self.makeVirtualMachineRunner(
                metadataURL: metadataURL,
                bootProfile: bootProfile,
                instanceName: instanceName,
                resolvedNetworkMode: resolved,
                startupPhaseObserver: nil
            )
        }
        var runner = makeRunner(resolvedNetworkMode)
        context.vmRunner = runner

        do {
            var resolvedClient: InitChannelClient?
            try context.runBootOnce {
                resolvedClient = try runner.startVMForDaemon()
            }
            guard let resolvedClient else {
                throw MSLRuntimeError("instance boot did not provide init channel")
            }
            return try finalizeBootedInstance(
                context: context,
                instanceName: instanceName,
                metadataURL: metadataURL,
                client: resolvedClient,
                runner: runner
            )
        } catch {
            if NetworkModeResolver.shouldFallbackToNAT(configured: resolvedNetworkMode.configured, error: error),
               resolvedNetworkMode.effective == .vmnetShared {
                context.vmRunner?.stopRunningVM()
                resolvedNetworkMode = NetworkModeResolver.fallbackToNAT(
                    from: resolvedNetworkMode,
                    reason: "vmnet unavailable at startup: \(error)"
                )
                applyResolvedNetworkMode(resolvedNetworkMode, to: context, instanceName: instanceName)
                runner = makeRunner(resolvedNetworkMode)
                context.vmRunner = runner
                do {
                    var resolvedClient: InitChannelClient?
                    try context.runBootOnce {
                        resolvedClient = try runner.startVMForDaemon()
                    }
                    guard let resolvedClient else {
                        throw MSLRuntimeError("instance boot did not provide init channel")
                    }
                    return try finalizeBootedInstance(
                        context: context,
                        instanceName: instanceName,
                        metadataURL: metadataURL,
                        client: resolvedClient,
                        runner: runner
                    )
                } catch {
                    context.lifecycleState = .error
                    context.lastError = String(describing: error)
                    context.vmRunner?.stopRunningVM()
                    context.vmRunner = nil
                    context.initClient = nil
                    context.initWriteClient = nil
                    context.initReadClient = nil
                    context.housekeepingClient = nil
                    publishInstanceStateEvent(
                        instance: instanceName,
                        state: "Error",
                        reason: "boot_failed",
                        error: String(describing: error)
                    )
                    throw error
                }
            }
            context.lifecycleState = .error
            context.lastError = String(describing: error)
            context.vmRunner?.stopRunningVM()
            context.vmRunner = nil
            context.initClient = nil
            context.initWriteClient = nil
            context.initReadClient = nil
            context.housekeepingClient = nil
            publishInstanceStateEvent(
                instance: instanceName,
                state: "Error",
                reason: "boot_failed",
                error: String(describing: error)
            )
            throw error
        }
    }

    private func handleExec(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let argv = request.argv, !argv.isEmpty else {
            return RuntimeControlResponse(ok: false, error: "missing argv")
        }
        let execTarget = resolveCWDForwarding(argv: argv, cwd: request.cwd)
        let envAdditions = mergedExecEnvAdditions(request.envAdditions)

        noteGuestActivity()
        // 0 means no timeout for guest exec.
        let timeoutMs = request.timeoutMs ?? 0
        logger.log("run_command_started", fields: ["argv0": argv[0]])
        logSessionScopedEvent(
            sessionID: request.sessionId,
            fallbackInstance: context.instanceName,
            event: "session_exec_started",
            fields: ["op": "exec", "argv0": argv[0], "timeout_ms": String(timeoutMs)]
        )

        do {
            let initReq = InitChannelRequest(
                op: "exec",
                argv: execTarget.argv,
                envAdditions: envAdditions,
                runAsRoot: request.runAsRoot,
                cwd: execTarget.cwd,
                timeoutMs: timeoutMs
            )
            let initResp = try client.send(initReq)

            if initResp.ok {
                logger.log("run_command_completed", fields: [
                    "argv0": argv[0],
                    "exit_code": String(initResp.exitCode ?? 0)
                ])
                logSessionScopedEvent(
                    sessionID: request.sessionId,
                    fallbackInstance: context.instanceName,
                    event: "session_exec_completed",
                    fields: [
                        "op": "exec",
                        "result": "ok",
                        "exit_code": String(initResp.exitCode ?? 0),
                        "stdout_len": String(initResp.stdout?.count ?? 0),
                        "stderr_len": String(initResp.stderr?.count ?? 0)
                    ]
                )
                return RuntimeControlResponse(
                    ok: true,
                    stdout: initResp.stdout,
                    stderr: initResp.stderr,
                    exitCode: initResp.exitCode
                )
            } else {
                let errMsg = initResp.error?.message ?? "exec failed"
                logSessionScopedEvent(
                    sessionID: request.sessionId,
                    fallbackInstance: context.instanceName,
                    event: "session_exec_failed",
                    fields: ["op": "exec", "result": "failed", "error": errMsg]
                )
                return RuntimeControlResponse(ok: false, error: errMsg)
            }
        } catch {
            logger.log("run_command_error", fields: [
                "argv0": argv[0],
                "error": String(describing: error)
            ])
            logSessionScopedEvent(
                sessionID: request.sessionId,
                fallbackInstance: context.instanceName,
                event: "session_exec_failed",
                fields: ["op": "exec", "result": "failed", "error": String(describing: error)]
            )
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleProvisionStatus(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }

        do {
            let resp = try client.convergeStatus()
            return RuntimeControlResponse(
                ok: true,
                meta: ["convergence": resp.meta?["convergence"] ?? "unknown"]
            )
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleWorkspacePrepare(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        guard let workspacePath = request.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspacePath.isEmpty,
              workspacePath.hasPrefix("/") else {
            return RuntimeControlResponse(ok: false, error: "missing or invalid cwd")
        }
        let hostShareRoot: String
        if let rawRoot = request.hostShareRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawRoot.isEmpty {
            hostShareRoot = rawRoot
        } else {
            hostShareRoot = "/"
        }
        guard hostShareRoot.hasPrefix("/") else {
            return RuntimeControlResponse(ok: false, error: "invalid hostShareRoot")
        }

        do {
            let response = try client.send(InitChannelRequest(
                op: "host_share_prepare",
                cwd: workspacePath,
                hostShareRoot: hostShareRoot,
                timeoutMs: 4_000
            ))
            if response.error?.code == .unsupportedOp {
                logger.log("mount_entry_fallback_legacy", fields: [
                    "source_type": "workspace",
                    "host_real_path": hostShareRoot,
                    "guest_target": workspacePath
                ])
                if isWorkspaceVisibleInGuest(client: client, workspacePath: workspacePath) {
                    logger.log("mount_entry_reused", fields: [
                        "source_type": "workspace",
                        "host_real_path": hostShareRoot,
                        "guest_target": workspacePath,
                        "mode": "rw",
                        "required": "false"
                    ])
                    return RuntimeControlResponse(ok: true, meta: ["status": "reused"])
                }
                return handleLegacyWorkspacePrepare(
                    client: client,
                    workspacePath: workspacePath,
                    hostShareRoot: hostShareRoot
                )
            }

            let exitCode = response.exitCode ?? 0
            if response.ok, exitCode == 0 {
                let status = response.stdout?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "reused" || response.meta?["status"] == "reused" ? "reused" : "applied"
                logger.log(status == "reused" ? "mount_entry_reused" : "mount_entry_applied", fields: [
                    "source_type": "workspace",
                    "host_real_path": hostShareRoot,
                    "guest_target": workspacePath,
                    "mode": "rw",
                    "required": "false"
                ])
                return RuntimeControlResponse(ok: true, meta: ["status": status])
            }

            let errorMessage = response.error?.message ?? response.stderr ?? "workspace_prepare failed"
            logger.log("mount_entry_failed", fields: [
                "source_type": "workspace",
                "host_real_path": hostShareRoot,
                "guest_target": workspacePath,
                "mode": "rw",
                "required": "false",
                "error": errorMessage,
                "exit_code": String(exitCode)
            ])
            return RuntimeControlResponse(ok: false, error: errorMessage)
        } catch {
            logger.log("mount_entry_failed", fields: [
                "source_type": "workspace",
                "host_real_path": hostShareRoot,
                "guest_target": workspacePath,
                "mode": "rw",
                "required": "false",
                "error": String(describing: error)
            ])
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleCacheSharePrepare() -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }

        let policyConfig: CacheSharingConfig?
        let policySource: String
        if let metadataURL = runtimeMetadataURL,
           let metadata = try? distributionManager.readOrRebuildInstanceMetadata(at: metadataURL) {
            policyConfig = metadata.cacheSharing ?? CacheSharingPolicyResolver.defaultConfigForDistroFamily(
                metadata.distroFamily
                    ?? metadata.source.distro
                    ?? DistributionManager.inferDistroFamilyStatic(from: metadata.source.manifestId)
            )
            policySource = metadata.cacheSharing == nil ? "metadata_inferred" : "metadata"
        } else {
            policyConfig = nil
            policySource = "unavailable"
        }

        let policy = CacheSharingPolicyResolver.resolve(config: policyConfig)
        guard policy.enabled else {
            logger.log("cache_share_skipped", fields: [
                "reason": "disabled",
                "policy_source": policySource
            ])
            cacheShareEnvAdditions = [:]
            return RuntimeControlResponse(ok: true, meta: ["status": "skipped", "reason": "disabled"])
        }

        let hostShareRoot = resolveConfiguredHostShareRoot()
        let hostHome = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let hostCacheRoot = CacheSharingPolicyResolver.hostCacheRootPath(hostHome: hostHome)
        let guestHostHome = CacheSharingPolicyResolver.guestPathForHostPath(hostPath: hostHome, hostShareRoot: hostShareRoot) ?? ""
        guard let guestCacheRoot = CacheSharingPolicyResolver.guestPathForHostPath(hostPath: hostCacheRoot, hostShareRoot: hostShareRoot) else {
            logger.log("cache_share_fallback_local", fields: [
                "reason": "host_cache_outside_share_root",
                "host_cache_root": hostCacheRoot,
                "host_share_root": hostShareRoot
            ])
            cacheShareEnvAdditions = [:]
            return RuntimeControlResponse(ok: true, meta: [
                "status": "skipped",
                "reason": "host_cache_outside_share_root",
            ])
        }

        let flags = CacheSharingPolicyResolver.toolFlagList(policy: policy)
        let runtimeHome = instanceRegistry.context(for: currentRuntimeInstanceName()).runtimeUser?.home ?? "/root"
        let enabledToolCount = flags.values.filter { $0 }.count
        let argv = [
            "/bin/sh",
            "-lc",
            Self.cacheSharePrepareScript,
            "msl-cache-share-prepare",
            guestCacheRoot,
            runtimeHome,
            guestHostHome,
            flags["apt"] == true ? "1" : "0",
            flags["apk"] == true ? "1" : "0",
            flags["zypper"] == true ? "1" : "0",
            flags["dnf"] == true ? "1" : "0",
            flags["go"] == true ? "1" : "0",
            flags["python"] == true ? "1" : "0",
            flags["npm"] == true ? "1" : "0",
            flags["pnpm"] == true ? "1" : "0",
            flags["yarn"] == true ? "1" : "0",
            flags["maven"] == true ? "1" : "0",
            flags["gradle"] == true ? "1" : "0",
            flags["composer"] == true ? "1" : "0",
            flags["scala"] == true ? "1" : "0",
            flags["ruby"] == true ? "1" : "0",
            flags["rust"] == true ? "1" : "0",
            flags["deno"] == true ? "1" : "0",
            flags["bun"] == true ? "1" : "0",
            flags["nuget"] == true ? "1" : "0",
        ]

        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: argv,
                runAsRoot: true,
                timeoutMs: 4_000
            ))
            let exitCode = response.exitCode ?? 0
            if response.ok, exitCode == 0 {
                cacheShareEnvAdditions = CacheSharingPolicyResolver.environment(
                    guestCacheRoot: guestCacheRoot,
                    policy: policy
                )
                var status: String?
                var reason: String?
                if let stdout = response.stdout {
                    for line in stdout.split(separator: "\n") {
                        let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("status=") {
                            status = String(trimmed.dropFirst("status=".count)).lowercased()
                        } else if trimmed.hasPrefix("reason=") {
                            reason = String(trimmed.dropFirst("reason=".count))
                        }
                    }
                }
                let resolvedStatus: String
                if status == "applied" || status == "reused" || status == "partial" || status == "fallback" {
                    resolvedStatus = status ?? "applied"
                } else {
                    resolvedStatus = "applied"
                }
                var fields: [String: String] = [
                    "status": resolvedStatus,
                    "policy_source": policySource,
                    "guest_cache_root": guestCacheRoot,
                    "host_cache_root": hostCacheRoot,
                    "enabled_tools": String(enabledToolCount),
                    "runtime_home": runtimeHome
                ]
                if let reason, !reason.isEmpty {
                    fields["reason"] = reason
                }
                logger.log("cache_share_applied", fields: fields)
                var meta: [String: String] = [
                    "status": resolvedStatus,
                    "guest_cache_root": guestCacheRoot,
                    "host_cache_root": hostCacheRoot,
                    "enabled_tools": String(enabledToolCount),
                    "runtime_home": runtimeHome,
                ]
                if let reason, !reason.isEmpty {
                    meta["reason"] = reason
                }
                return RuntimeControlResponse(ok: true, meta: meta)
            }

            let errorMessage = response.error?.message ?? response.stderr ?? "cache_share_prepare failed"
            logger.log("cache_share_fallback_local", fields: [
                "reason": "guest_apply_failed",
                "policy_source": policySource,
                "error": errorMessage,
                "exit_code": String(exitCode)
            ])
            cacheShareEnvAdditions = [:]
            return RuntimeControlResponse(ok: true, meta: [
                "status": "partial",
                "reason": "guest_apply_failed",
            ])
        } catch {
            logger.log("cache_share_fallback_local", fields: [
                "reason": "request_error",
                "policy_source": policySource,
                "error": String(describing: error)
            ])
            cacheShareEnvAdditions = [:]
            return RuntimeControlResponse(ok: true, meta: [
                "status": "partial",
                "reason": "request_error",
            ])
        }
    }

    // MARK: - PTY ops

    private func handlePtyOpen(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        let readClient = context.initReadClient ?? context.initClient ?? initClient
        let defaultShell = context.runtimeUser?.shell ?? "/bin/sh"
        let argv = request.argv ?? [defaultShell, "-l"]
        let ptyTarget = resolveCWDForwarding(argv: argv, cwd: request.cwd)
        let envAdditions = mergedExecEnvAdditions(request.envAdditions)
        do {
            let resp = try client.ptyOpen(
                argv: ptyTarget.argv,
                cwd: ptyTarget.cwd,
                envAdditions: envAdditions,
                runAsRoot: request.runAsRoot,
                rows: request.rows,
                cols: request.cols,
                timeoutMs: 3_000
            )
            if resp.ok, let ptyId = resp.ptyId {
                _ = registerPtyEventBuffer(ptyId: ptyId)
                if let readClient {
                    startPtySubscription(
                        client: readClient,
                        ptyId: ptyId,
                        instanceName: context.instanceName,
                        sessionId: request.sessionId
                    )
                }
                logSessionScopedEvent(
                    sessionID: request.sessionId,
                    fallbackInstance: context.instanceName,
                    event: "session_pty_opened",
                    fields: ["op": "pty_open", "pty_id": ptyId]
                )
                return RuntimeControlResponse(ok: true, ptyId: ptyId)
            }
            return RuntimeControlResponse(ok: false, error: resp.error?.message ?? "pty_open failed")
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handlePtyRead(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request) else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let ptyId = request.ptyId else {
            return RuntimeControlResponse(ok: false, error: "missing ptyId")
        }
        guard let buffer = lookupPtyEventBuffer(ptyId: ptyId) else {
            return RuntimeControlResponse(ok: false, error: "unknown ptyId")
        }
        if !hasPtySubscriptionSource(ptyId: ptyId),
           let client = context.initClient ?? initClient {
            do {
                let resp = try client.ptyRead(ptyId: ptyId, timeoutMs: request.timeoutMs ?? 1_000)
                return RuntimeControlResponse(
                    ok: resp.ok,
                    error: resp.error?.message,
                    exitCode: resp.exitCode,
                    dataBase64: resp.dataBase64,
                    meta: resp.meta,
                    rawData: resp.rawData
                )
            } catch {
                return RuntimeControlResponse(ok: false, error: String(describing: error))
            }
        }
        let outcome = buffer.collect(timeoutMs: request.timeoutMs ?? 1_000, maxBytes: 16 * 1024)
        if let failure = outcome.failure {
            return RuntimeControlResponse(ok: false, error: failure)
        }
        if !outcome.payload.isEmpty {
            logSessionScopedEvent(
                sessionID: request.sessionId,
                fallbackInstance: context.instanceName,
                event: "session_pty_output",
                fields: ["op": "pty_read", "pty_id": ptyId, "bytes": String(outcome.payload.count)]
            )
        }
        if outcome.finalize {
            removePtyEventBuffer(ptyId: ptyId)
        }
        var meta: [String: String]? = nil
        if let exitCode = outcome.exitCode {
            meta = ["exitCode": String(exitCode)]
            if let exitReason = outcome.exitReason {
                meta?["exitReason"] = exitReason
            }
        }
        return RuntimeControlResponse(
            ok: true,
            exitCode: outcome.exitCode,
            dataBase64: outcome.payload.isEmpty ? nil : outcome.payload.base64EncodedString(),
            meta: meta,
            rawData: outcome.payload.isEmpty ? nil : outcome.payload
        )
    }

    private func resolveCWDForwarding(argv: [String], cwd: String?) -> (argv: [String], cwd: String?) {
        guard let cwdRaw = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwdRaw.isEmpty,
              cwdRaw.hasPrefix("/") else {
            return (argv, cwd)
        }
        return (
            [
                "/bin/sh",
                "-lc",
                "cd \"$1\" && shift && exec \"$@\"",
                "msl-cwd",
                cwdRaw
            ] + argv,
            nil
        )
    }

    private func mergedExecEnvAdditions(_ requestEnvAdditions: [String: String]?) -> [String: String]? {
        var merged = cacheShareEnvAdditions
        if let requestEnvAdditions {
            for (key, value) in requestEnvAdditions {
                merged[key] = value
            }
        }
        return merged.isEmpty ? nil : merged
    }

    private func handleLegacyWorkspacePrepare(
        client: InitChannelClient,
        workspacePath: String,
        hostShareRoot: String
    ) -> RuntimeControlResponse {
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: [
                    "/bin/sh",
                    "-lc",
                    Self.legacyHostSharePrepareScript,
                    "msl-workspace-prepare",
                    hostShareRoot,
                    workspacePath
                ],
                runAsRoot: true,
                timeoutMs: 4_000
            ))

            let exitCode = response.exitCode ?? 0
            if response.ok, exitCode == 0 {
                let status = response.stdout?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "reused" ? "reused" : "applied"
                logger.log(status == "reused" ? "mount_entry_reused" : "mount_entry_applied", fields: [
                    "source_type": "workspace",
                    "host_real_path": hostShareRoot,
                    "guest_target": workspacePath,
                    "mode": "rw",
                    "required": "false"
                ])
                return RuntimeControlResponse(ok: true, meta: ["status": status])
            }

            let errorMessage = response.error?.message ?? response.stderr ?? "workspace_prepare failed"
            logger.log("mount_entry_failed", fields: [
                "source_type": "workspace",
                "host_real_path": hostShareRoot,
                "guest_target": workspacePath,
                "mode": "rw",
                "required": "false",
                "error": errorMessage,
                "exit_code": String(exitCode)
            ])
            return RuntimeControlResponse(ok: false, error: errorMessage)
        } catch {
            logger.log("mount_entry_failed", fields: [
                "source_type": "workspace",
                "host_real_path": hostShareRoot,
                "guest_target": workspacePath,
                "mode": "rw",
                "required": "false",
                "error": String(describing: error)
            ])
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func isWorkspaceVisibleInGuest(client: InitChannelClient, workspacePath: String) -> Bool {
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: [
                    "/bin/sh",
                    "-lc",
                    "[ -d \"$1\" ]",
                    "msl-workspace-visible",
                    workspacePath
                ],
                timeoutMs: 1_000
            ))
            return response.ok && (response.exitCode ?? 1) == 0
        } catch {
            return false
        }
    }

    private func prepareHostShareRootMountOnStartup(client: InitChannelClient) {
        let hostShareRoot = resolveConfiguredHostShareRoot()
        do {
            let response = try client.send(InitChannelRequest(
                op: "host_share_prepare",
                hostShareRoot: hostShareRoot,
                timeoutMs: 4_000
            ))
            if response.error?.code == .unsupportedOp {
                logger.log("mount_entry_fallback_legacy", fields: [
                    "source_type": "workspace",
                    "host_real_path": hostShareRoot,
                    "guest_target": "/"
                ])
                let fallback = handleLegacyWorkspacePrepare(
                    client: client,
                    workspacePath: "/",
                    hostShareRoot: hostShareRoot
                )
                if fallback.ok {
                    logger.log("host_share_root_prepared", fields: [
                        "host_real_path": hostShareRoot,
                        "status": fallback.meta?["status"] ?? "applied",
                        "mode": "startup"
                    ])
                } else {
                    logger.log("host_share_root_prepare_failed", fields: [
                        "host_real_path": hostShareRoot,
                        "error": fallback.error ?? "legacy_prepare_failed"
                    ])
                }
                return
            }

            let exitCode = response.exitCode ?? 0
            if response.ok, exitCode == 0 {
                let status = response.stdout?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "reused" || response.meta?["status"] == "reused" ? "reused" : "applied"
                logger.log("host_share_root_prepared", fields: [
                    "host_real_path": hostShareRoot,
                    "status": status,
                    "mode": "startup"
                ])
                return
            }

            let errorMessage = response.error?.message ?? response.stderr ?? "host_share_prepare failed"
            logger.log("host_share_root_prepare_failed", fields: [
                "host_real_path": hostShareRoot,
                "error": errorMessage,
                "exit_code": String(exitCode)
            ])
        } catch {
            logger.log("host_share_root_prepare_failed", fields: [
                "host_real_path": hostShareRoot,
                "error": String(describing: error)
            ])
        }
    }

    private func prepareTmpStorageOnStartup(
        client: InitChannelClient,
        metadataURL: URL,
        instanceName: String
    ) throws {
        let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: metadataURL)
        let policy = try metadata.resolveValidatedTmpStoragePolicy()
        guard policy.mode == "ephemeral" else { return }
        let label = tmpStorageLabel(instanceName: instanceName)
        let response = try client.send(InitChannelRequest(
            op: "exec",
            argv: ["/bin/sh", "-lc", Self.tmpStoragePrepareScript, "msl-tmp-prepare", label],
            runAsRoot: true,
            timeoutMs: 15_000
        ))
        let exitCode = response.exitCode ?? 0
        if response.ok, exitCode == 0 {
            logger.log("tmp_mount_succeeded", fields: [
                "instance": instanceName,
                "mode": policy.mode,
                "size_mib": String(policy.sizeMiB)
            ])
            return
        }
        let detail = response.error?.message ?? response.stderr ?? "tmp prepare failed"
        logger.log("tmp_mount_failed", fields: [
            "instance": instanceName,
            "phase": "mount",
            "exit_code": String(exitCode),
            "detail": detail
        ])
        throw MSLRuntimeError("tmp mount failed for instance '\(instanceName)': \(detail)")
    }

    private func resetTmpStorageAfterStop(metadataURL: URL?, instanceName: String) {
        guard let metadataURL else { return }
        do {
            let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: metadataURL)
            let policy = try metadata.resolveValidatedTmpStoragePolicy()
            guard policy.mode == "ephemeral", policy.resetOnStop else { return }
            let tmpDiskURL = paths.distroEphemeralTmpDiskFile(named: instanceName)
            if FileManager.default.fileExists(atPath: tmpDiskURL.path) {
                try FileManager.default.removeItem(at: tmpDiskURL)
            }
            logger.log("tmp_reset_succeeded", fields: [
                "instance": instanceName,
                "path": tmpDiskURL.path
            ])
        } catch {
            logger.log("tmp_reset_failed", fields: [
                "instance": instanceName,
                "error": String(describing: error)
            ])
        }
    }

    private func tmpStorageLabel(instanceName: String) -> String {
        let mapped = instanceName.lowercased().map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                return ch
            }
            return "-"
        }
        return "msl-\(String(mapped))-tmp"
    }

    private func resolveConfiguredHostShareRoot() -> String {
        let raw = ProcessInfo.processInfo.environment["MSL_HOST_SHARE_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty, raw.hasPrefix("/") else {
            return "/"
        }
        return raw
    }

    private func parseKeyValueLines(_ text: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueText = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, let value = Int64(valueText) else { continue }
            result[key] = value
        }
        return result
    }

    private func guestVisibleHostPath(hostPath: String, hostShareRoot: String) -> String? {
        guard hostPath.hasPrefix("/") else {
            return nil
        }
        let normalizedRoot = hostShareRoot.hasSuffix("/") && hostShareRoot.count > 1
            ? String(hostShareRoot.dropLast())
            : hostShareRoot
        if normalizedRoot == "/" {
            return "/mnt/macos" + hostPath
        }
        if hostPath == normalizedRoot {
            return "/mnt/macos"
        }
        if hostPath.hasPrefix(normalizedRoot + "/") {
            let suffix = String(hostPath.dropFirst(normalizedRoot.count))
            return "/mnt/macos" + suffix
        }
        return nil
    }

    private func guestVisibleHostPathCandidates(hostPath: String, hostShareRoot: String) -> [String] {
        guard hostPath.hasPrefix("/") else {
            return []
        }
        var candidates: [String] = []
        if let mapped = guestVisibleHostPath(hostPath: hostPath, hostShareRoot: hostShareRoot) {
            candidates.append(mapped)
        }
        if hostShareRoot != "/" {
            if !candidates.contains(hostPath) {
                candidates.append(hostPath)
            }
        }
        return candidates
    }

    private func isInitSourceMissing(_ response: InitChannelResponse) -> Bool {
        if response.exitCode == 20 {
            return true
        }
        if let message = response.error?.message.lowercased(), message.contains("source_missing") {
            return true
        }
        if let stderr = response.stderr?.lowercased(), stderr.contains("source_missing") {
            return true
        }
        return false
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

    private func handlePtyWrite(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let ptyId = request.ptyId else {
            return RuntimeControlResponse(ok: false, error: "missing ptyId")
        }
        let data = request.rawData ?? {
            guard let b64 = request.dataBase64 else { return nil }
            return Data(base64Encoded: b64)
        }()
        guard let data else {
            return RuntimeControlResponse(ok: false, error: "missing ptyId or data")
        }
        noteGuestActivity()
        do {
            let resp = try client.ptyWrite(ptyId: ptyId, data: data, timeoutMs: request.timeoutMs ?? 2_000)
            if resp.ok {
                logSessionScopedEvent(
                    sessionID: request.sessionId,
                    fallbackInstance: context.instanceName,
                    event: "session_pty_input",
                    fields: ["op": "pty_write", "pty_id": ptyId, "bytes": String(data.count)]
                )
            }
            return RuntimeControlResponse(ok: resp.ok, error: resp.error?.message)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handlePtyResize(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let ptyId = request.ptyId, let rows = request.rows, let cols = request.cols else {
            return RuntimeControlResponse(ok: false, error: "missing ptyId/rows/cols")
        }
        do {
            let resp = try client.ptyResize(ptyId: ptyId, rows: rows, cols: cols, timeoutMs: 300)
            if resp.ok {
                logSessionScopedEvent(
                    sessionID: request.sessionId,
                    fallbackInstance: context.instanceName,
                    event: "session_pty_resized",
                    fields: ["op": "pty_resize", "pty_id": ptyId, "rows": String(rows), "cols": String(cols)]
                )
            }
            return RuntimeControlResponse(ok: resp.ok, error: resp.error?.message)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handlePtyClose(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let ptyId = request.ptyId else {
            return RuntimeControlResponse(ok: false, error: "missing ptyId")
        }
        do {
            let resp = try client.ptyClose(ptyId: ptyId, timeoutMs: 500)
            logSessionScopedEvent(
                sessionID: request.sessionId,
                fallbackInstance: context.instanceName,
                event: "session_pty_closed",
                fields: ["op": "pty_close", "pty_id": ptyId, "result": resp.ok ? "ok" : "failed"]
            )
            removePtyEventBuffer(ptyId: ptyId)
            return RuntimeControlResponse(ok: resp.ok, error: resp.error?.message, exitCode: resp.exitCode)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func registerProcEventBuffer(procId: String) -> HostProcEventBuffer {
        let buffer = HostProcEventBuffer()
        sessionEventLock.lock()
        procEventBuffers[procId] = buffer
        sessionEventLock.unlock()
        return buffer
    }

    private func registerPtyEventBuffer(ptyId: String) -> HostPtyEventBuffer {
        let buffer = HostPtyEventBuffer()
        sessionEventLock.lock()
        ptyEventBuffers[ptyId] = buffer
        sessionEventLock.unlock()
        return buffer
    }

    private func lookupProcEventBuffer(procId: String) -> HostProcEventBuffer? {
        sessionEventLock.lock()
        defer { sessionEventLock.unlock() }
        return procEventBuffers[procId]
    }

    private func lookupPtyEventBuffer(ptyId: String) -> HostPtyEventBuffer? {
        sessionEventLock.lock()
        defer { sessionEventLock.unlock() }
        return ptyEventBuffers[ptyId]
    }

    private func hasProcSubscriptionSource(procId: String) -> Bool {
        sessionEventLock.lock()
        defer { sessionEventLock.unlock() }
        return procSubscriptionSources[procId] != nil
    }

    private func hasPtySubscriptionSource(ptyId: String) -> Bool {
        sessionEventLock.lock()
        defer { sessionEventLock.unlock() }
        return ptySubscriptionSources[ptyId] != nil
    }

    private func removeProcEventBuffer(procId: String) {
        sessionEventLock.lock()
        procEventBuffers.removeValue(forKey: procId)
        let source = procSubscriptionSources.removeValue(forKey: procId)
        sessionEventLock.unlock()
        source?.cancel()
    }

    private func removePtyEventBuffer(ptyId: String) {
        sessionEventLock.lock()
        ptyEventBuffers.removeValue(forKey: ptyId)
        let source = ptySubscriptionSources.removeValue(forKey: ptyId)
        sessionEventLock.unlock()
        source?.cancel()
    }

    private func removeProcSubscriptionSource(procId: String) {
        sessionEventLock.lock()
        let source = procSubscriptionSources.removeValue(forKey: procId)
        sessionEventLock.unlock()
        source?.cancel()
    }

    private func removePtySubscriptionSource(ptyId: String) {
        sessionEventLock.lock()
        let source = ptySubscriptionSources.removeValue(forKey: ptyId)
        sessionEventLock.unlock()
        source?.cancel()
    }

    private func storeProcSubscriptionSource(_ source: DispatchSourceRead, procId: String) {
        sessionEventLock.lock()
        procSubscriptionSources[procId] = source
        sessionEventLock.unlock()
    }

    private func storePtySubscriptionSource(_ source: DispatchSourceRead, ptyId: String) {
        sessionEventLock.lock()
        ptySubscriptionSources[ptyId] = source
        sessionEventLock.unlock()
    }

    private func startProcSubscription(
        client: InitChannelClient,
        procId: String,
        instanceName: String,
        sessionId: String?
    ) {
        guard let buffer = lookupProcEventBuffer(procId: procId) else { return }
        do {
            let stream = try client.procSubscribe(procId: procId)
            let queue = DispatchQueue(label: "msl.proc-subscribe.\(procId)")
            let source = DispatchSource.makeReadSource(fileDescriptor: stream.fileDescriptor, queue: queue)
            storeProcSubscriptionSource(source, procId: procId)
            logger.log("attached_exec_subscribe_started", fields: [
                "proc_id": procId,
                "instance": instanceName
            ])
            source.setEventHandler { [weak self, source] in
                guard let self else { return }
                var sawExit = false
                var sawStreamsClosed = false
                do {
                    while let event = try stream.nextEvent() {
                        self.logger.log("session_proc_event", fields: [
                            "proc_id": procId,
                            "instance": instanceName,
                            "kind": event.kind.rawValue,
                            "bytes": String(event.data.count),
                            "exit_code": event.exitCode.map(String.init) ?? ""
                        ])
                        switch event.kind {
                        case .stdout:
                            buffer.push(.stdout(event.data))
                        case .stderr:
                            buffer.push(.stderr(event.data))
                        case .exited:
                            sawExit = true
                            buffer.push(.exited(event.exitCode ?? 0, event.text))
                        case .streamsClosed:
                            sawStreamsClosed = true
                            buffer.push(.streamsClosed)
                        }
                        if sawExit && sawStreamsClosed {
                            self.removeProcSubscriptionSource(procId: procId)
                            source.cancel()
                            return
                        }
                    }
                    self.removeProcSubscriptionSource(procId: procId)
                    source.cancel()
                } catch {
                    buffer.push(.failed(String(describing: error)))
                    self.logger.log("session_proc_event", fields: [
                        "proc_id": procId,
                        "instance": instanceName,
                        "kind": "failed",
                        "error": String(describing: error)
                    ])
                    self.removeProcSubscriptionSource(procId: procId)
                    source.cancel()
                }
            }
            source.resume()
        } catch {
            logger.log("session_proc_event", fields: [
                "proc_id": procId,
                "instance": instanceName,
                "transport": "compat_proc_read",
                "kind": "subscribe_failed_fallback",
                "error": String(describing: error)
            ])
            logger.log("attached_exec_transport_fallback_used", fields: [
                "instance": instanceName,
                "proc_id": procId,
                "transport": "compat_proc_read"
            ])
        }
    }

    private func handleProcSubscribeStream(_ request: RuntimeControlRequest, fd: Int32) -> Bool {
        guard let context = resolveContext(for: request),
              let procId = request.procId,
              let buffer = lookupProcEventBuffer(procId: procId) else {
            return false
        }
        logger.log("attached_exec_subscribe_started", fields: [
            "proc_id": procId,
            "instance": context.instanceName,
            "transport": "runtime_control"
        ])
        while true {
            let outcome = buffer.collect(timeoutMs: 1_000)
            if let failure = outcome.failure {
                logger.log("session_proc_event", fields: [
                    "proc_id": procId,
                    "instance": context.instanceName,
                    "kind": "runtime_control_failed",
                    "error": failure
                ])
                return false
            }
            for event in outcome.events {
                let frame: Data
                do {
                    switch event {
                    case .stdout(let data):
                        frame = try encodeRuntimeControlProcEventFrame(procId: procId, kind: .stdout, payload: data)
                    case .stderr(let data):
                        frame = try encodeRuntimeControlProcEventFrame(procId: procId, kind: .stderr, payload: data)
                    case .exited(let code, let reason):
                        frame = try encodeRuntimeControlProcEventFrame(procId: procId, kind: .exited, payload: Data(), exitCode: code, text: reason)
                    case .streamsClosed:
                        frame = try encodeRuntimeControlProcEventFrame(procId: procId, kind: .streamsClosed, payload: Data())
                    case .failed(let message):
                        logger.log("session_proc_event", fields: [
                            "proc_id": procId,
                            "instance": context.instanceName,
                            "kind": "runtime_control_failed",
                            "error": message
                        ])
                        return false
                    }
                    try runtimeControlWriteAll(fd: fd, data: frame)
                } catch {
                    logger.log("session_proc_event", fields: [
                        "proc_id": procId,
                        "instance": context.instanceName,
                        "kind": "runtime_control_stream_write_failed",
                        "error": String(describing: error)
                    ])
                    return false
                }
            }
            if outcome.finalize {
                removeProcEventBuffer(procId: procId)
                return true
            }
        }
    }

    private func startPtySubscription(
        client: InitChannelClient,
        ptyId: String,
        instanceName: String,
        sessionId: String?
    ) {
        guard let buffer = lookupPtyEventBuffer(ptyId: ptyId) else { return }
        do {
            let stream = try client.ptySubscribe(ptyId: ptyId)
            let queue = DispatchQueue(label: "msl.pty-subscribe.\(ptyId)")
            let source = DispatchSource.makeReadSource(fileDescriptor: stream.fileDescriptor, queue: queue)
            storePtySubscriptionSource(source, ptyId: ptyId)
            logger.log("attached_exec_subscribe_started", fields: [
                "pty_id": ptyId,
                "instance": instanceName
            ])
            source.setEventHandler { [weak self, source] in
                guard let self else { return }
                var sawExit = false
                var sawStreamsClosed = false
                do {
                    while let event = try stream.nextEvent() {
                        self.logger.log("session_pty_event", fields: [
                            "pty_id": ptyId,
                            "instance": instanceName,
                            "kind": event.kind.rawValue,
                            "bytes": String(event.data.count),
                            "exit_code": event.exitCode.map(String.init) ?? ""
                        ])
                        switch event.kind {
                        case .output:
                            buffer.push(.output(event.data))
                        case .exited:
                            sawExit = true
                            buffer.push(.exited(event.exitCode ?? 0, event.text))
                        case .streamsClosed:
                            sawStreamsClosed = true
                            buffer.push(.streamsClosed)
                        }
                        if sawExit && sawStreamsClosed {
                            self.removePtySubscriptionSource(ptyId: ptyId)
                            source.cancel()
                            return
                        }
                    }
                    self.removePtySubscriptionSource(ptyId: ptyId)
                    source.cancel()
                } catch {
                    self.logger.log("session_pty_event", fields: [
                        "pty_id": ptyId,
                        "instance": instanceName,
                        "kind": "failed",
                        "error": String(describing: error)
                    ])
                    self.logger.log("attached_exec_transport_fallback_used", fields: [
                        "instance": instanceName,
                        "pty_id": ptyId,
                        "transport": "compat_pty_read_after_subscribe_failure"
                    ])
                    self.removePtySubscriptionSource(ptyId: ptyId)
                    source.cancel()
                }
            }
            source.resume()
        } catch {
            logger.log("session_pty_event", fields: [
                "pty_id": ptyId,
                "instance": instanceName,
                "transport": "compat_pty_read",
                "kind": "subscribe_failed_fallback",
                "error": String(describing: error)
            ])
            logger.log("attached_exec_transport_fallback_used", fields: [
                "instance": instanceName,
                "pty_id": ptyId,
                "transport": "compat_pty_read"
            ])
        }
    }

    private func handlePtySubscribeStream(_ request: RuntimeControlRequest, fd: Int32) -> Bool {
        guard let context = resolveContext(for: request),
              let ptyId = request.ptyId,
              let buffer = lookupPtyEventBuffer(ptyId: ptyId) else {
            return false
        }
        logger.log("attached_exec_subscribe_started", fields: [
            "pty_id": ptyId,
            "instance": context.instanceName,
            "transport": "runtime_control"
        ])
        var didEmitExit = false
        while true {
            let outcome = buffer.collect(timeoutMs: 1_000, maxBytes: 64 * 1024)
            if let failure = outcome.failure {
                logger.log("session_pty_event", fields: [
                    "pty_id": ptyId,
                    "instance": context.instanceName,
                    "kind": "runtime_control_failed",
                    "error": failure
                ])
                return false
            }
            if !outcome.payload.isEmpty {
                do {
                    let frame = try encodeRuntimeControlPtyEventFrame(ptyId: ptyId, kind: .output, payload: outcome.payload)
                    try runtimeControlWriteAll(fd: fd, data: frame)
                } catch {
                    logger.log("session_pty_event", fields: [
                        "pty_id": ptyId,
                        "instance": context.instanceName,
                        "kind": "runtime_control_stream_write_failed",
                        "error": String(describing: error)
                    ])
                    return false
                }
            }
            if let exitCode = outcome.exitCode, !didEmitExit {
                do {
                    let frame = try encodeRuntimeControlPtyEventFrame(
                        ptyId: ptyId,
                        kind: .exited,
                        payload: Data(),
                        exitCode: exitCode,
                        text: outcome.exitReason
                    )
                    try runtimeControlWriteAll(fd: fd, data: frame)
                    didEmitExit = true
                } catch {
                    logger.log("session_pty_event", fields: [
                        "pty_id": ptyId,
                        "instance": context.instanceName,
                        "kind": "runtime_control_stream_write_failed",
                        "error": String(describing: error)
                    ])
                    return false
                }
            }
            if outcome.finalize {
                do {
                    let closed = try encodeRuntimeControlPtyEventFrame(ptyId: ptyId, kind: .streamsClosed, payload: Data())
                    try runtimeControlWriteAll(fd: fd, data: closed)
                } catch {
                    logger.log("session_pty_event", fields: [
                        "pty_id": ptyId,
                        "instance": context.instanceName,
                        "kind": "runtime_control_stream_write_failed",
                        "error": String(describing: error)
                    ])
                    return false
                }
                removePtyEventBuffer(ptyId: ptyId)
                return true
            }
        }
    }

    private func encodeRuntimeControlProcEventFrame(
        procId: String,
        kind: RuntimeControlProcEventKind,
        payload: Data,
        exitCode: Int32? = nil,
        text: String? = nil
    ) throws -> Data {
        let header = RuntimeControlEventHeader(
            kind: kind.rawValue,
            ptyId: nil,
            procId: procId,
            exitCode: exitCode,
            text: text
        )
        return try runtimeControlEncodeFrame(
            opcode: .procEvent,
            header: try JSONEncoder().encode(header),
            payload: payload
        )
    }

    private func encodeRuntimeControlPtyEventFrame(
        ptyId: String,
        kind: RuntimeControlPtyEventKind,
        payload: Data,
        exitCode: Int32? = nil,
        text: String? = nil
    ) throws -> Data {
        let header = RuntimeControlEventHeader(
            kind: kind.rawValue,
            ptyId: ptyId,
            procId: nil,
            exitCode: exitCode,
            text: text
        )
        return try runtimeControlEncodeFrame(
            opcode: .ptyEvent,
            header: try JSONEncoder().encode(header),
            payload: payload
        )
    }

    private func handleProcOpen(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let readClient = context.initReadClient ?? context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let argv = request.argv, !argv.isEmpty else {
            return RuntimeControlResponse(ok: false, error: "missing argv")
        }
        let procTarget = resolveCWDForwarding(argv: argv, cwd: request.cwd)
        let envAdditions = mergedExecEnvAdditions(request.envAdditions)
        logSessionScopedEvent(
            sessionID: request.sessionId,
            fallbackInstance: context.instanceName,
            event: "proc_open_send_started",
            fields: [
                "argv0": argv[0],
                "transport": "control",
                "run_as_root": request.runAsRoot == true ? "true" : "false"
            ]
        )
        do {
            let resp = try client.procOpen(
                argv: procTarget.argv,
                cwd: procTarget.cwd,
                envAdditions: envAdditions,
                runAsRoot: request.runAsRoot,
                timeoutMs: 3_000
            )
            logSessionScopedEvent(
                sessionID: request.sessionId,
                fallbackInstance: context.instanceName,
                event: "proc_open_response_received",
                fields: [
                    "argv0": argv[0],
                    "transport": "control",
                    "ok": resp.ok ? "true" : "false",
                    "proc_id": resp.procId ?? "",
                    "error": resp.error?.message ?? ""
                ]
            )
            if resp.ok, let procId = resp.procId {
                _ = registerProcEventBuffer(procId: procId)
                startProcSubscription(
                    client: readClient,
                    procId: procId,
                    instanceName: context.instanceName,
                    sessionId: request.sessionId
                )
                logSessionScopedEvent(
                    sessionID: request.sessionId,
                    fallbackInstance: context.instanceName,
                    event: "session_proc_opened",
                    fields: ["op": "proc_open", "proc_id": procId]
                )
                return RuntimeControlResponse(ok: true, procId: procId)
            }
            return RuntimeControlResponse(ok: false, error: resp.error?.message ?? "proc_open failed")
        } catch {
            let message = String(describing: error)
            logSessionScopedEvent(
                sessionID: request.sessionId,
                fallbackInstance: context.instanceName,
                event: "proc_open_send_failed",
                fields: [
                    "argv0": argv[0],
                    "transport": "control",
                    "error": message
                ]
            )
            invalidateTransportIfNeeded(
                context: context,
                sessionID: request.sessionId,
                reason: "proc_open_transport_failed",
                message: message
            )
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleProcRead(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request) else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let procId = request.procId else {
            return RuntimeControlResponse(ok: false, error: "missing procId")
        }
        guard let buffer = lookupProcEventBuffer(procId: procId) else {
            return RuntimeControlResponse(ok: false, error: "unknown procId")
        }
        if !hasProcSubscriptionSource(procId: procId),
           let client = context.initClient ?? initClient {
            do {
                let resp = try client.procRead(procId: procId, timeoutMs: request.timeoutMs ?? 200)
                let mappedChunks = resp.chunks?.map { chunk in
                    var mapped = RuntimeControlStreamChunk(stream: chunk.stream, dataBase64: chunk.dataBase64)
                    mapped.rawData = chunk.rawData
                    return mapped
                }
                return RuntimeControlResponse(
                    ok: resp.ok,
                    error: resp.error?.message,
                    exitCode: resp.exitCode,
                    stdoutBase64: resp.stdoutBase64,
                    stderrBase64: resp.stderrBase64,
                    chunks: mappedChunks,
                    meta: resp.meta,
                    rawStdout: resp.rawStdout,
                    rawStderr: resp.rawStderr
                )
            } catch {
                return RuntimeControlResponse(ok: false, error: String(describing: error))
            }
        }
        let outcome = buffer.collect(timeoutMs: request.timeoutMs ?? 200)
        if let failure = outcome.failure {
            return RuntimeControlResponse(ok: false, error: failure)
        }
        var stdout = Data()
        var stderr = Data()
        var chunks: [RuntimeControlStreamChunk] = []
        for event in outcome.events {
            switch event {
            case .stdout(let data):
                stdout.append(data)
                var chunk = RuntimeControlStreamChunk(stream: "stdout", dataBase64: data.base64EncodedString())
                chunk.rawData = data
                chunks.append(chunk)
            case .stderr(let data):
                stderr.append(data)
                var chunk = RuntimeControlStreamChunk(stream: "stderr", dataBase64: data.base64EncodedString())
                chunk.rawData = data
                chunks.append(chunk)
            case .exited, .streamsClosed, .failed:
                break
            }
        }
        if !stdout.isEmpty || !stderr.isEmpty || !chunks.isEmpty {
            var fields: [String: String] = ["op": "proc_read", "proc_id": procId]
            if !stdout.isEmpty { fields["stdout_len"] = String(stdout.count) }
            if !stderr.isEmpty { fields["stderr_len"] = String(stderr.count) }
            if !chunks.isEmpty { fields["chunk_count"] = String(chunks.count) }
            if let exitCode = outcome.exitCode { fields["exit_code"] = String(exitCode) }
            if let exitReason = outcome.exitReason { fields["exit_reason"] = exitReason }
            logSessionScopedEvent(
                sessionID: request.sessionId,
                fallbackInstance: context.instanceName,
                event: "session_proc_output",
                fields: fields
            )
        }
        if outcome.finalize {
            removeProcEventBuffer(procId: procId)
        }
        var meta: [String: String]? = nil
        if let exitCode = outcome.exitCode {
            meta = ["exitCode": String(exitCode)]
            if let exitReason = outcome.exitReason {
                meta?["exitReason"] = exitReason
            }
        }
        return RuntimeControlResponse(
            ok: true,
            exitCode: outcome.exitCode,
            stdoutBase64: stdout.isEmpty ? nil : stdout.base64EncodedString(),
            stderrBase64: stderr.isEmpty ? nil : stderr.base64EncodedString(),
            chunks: chunks.isEmpty ? nil : chunks,
            meta: meta,
            rawStdout: stdout.isEmpty ? nil : stdout,
            rawStderr: stderr.isEmpty ? nil : stderr
        )
    }

    private func handleProcWrite(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initWriteClient ?? context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let procId = request.procId else {
            return RuntimeControlResponse(ok: false, error: "missing procId")
        }
        let data = request.rawData ?? {
            guard let b64 = request.dataBase64 else { return nil }
            return Data(base64Encoded: b64)
        }()
        guard let data else {
            return RuntimeControlResponse(ok: false, error: "missing procId or data")
        }
        noteGuestActivity()
        let startedAt = Date()
        do {
            let resp = try client.procWrite(procId: procId, data: data, timeoutMs: request.timeoutMs ?? 10_000)
            if resp.ok {
                var fields: [String: String] = [
                    "op": "proc_write",
                    "proc_id": procId,
                    "bytes": String(data.count),
                    "init_channel_ms": String(Int(Date().timeIntervalSince(startedAt) * 1000))
                ]
                if let meta = resp.meta {
                    if let queueSendMs = meta["queueSendMs"] {
                        fields["guest_queue_send_ms"] = queueSendMs
                    }
                    if let bytes = meta["bytes"] {
                        fields["guest_bytes"] = bytes
                    }
                }
                logSessionScopedEvent(
                    sessionID: request.sessionId,
                    fallbackInstance: context.instanceName,
                    event: "session_proc_input",
                    fields: fields
                )
            }
            return RuntimeControlResponse(ok: resp.ok, error: resp.error?.message)
        } catch {
            invalidateTransportIfNeeded(
                context: context,
                sessionID: request.sessionId,
                reason: "proc_write_transport_failed",
                message: String(describing: error)
            )
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleProcStdinClose(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initWriteClient ?? context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let procId = request.procId else {
            return RuntimeControlResponse(ok: false, error: "missing procId")
        }
        do {
            let resp = try client.procStdinClose(procId: procId, timeoutMs: 500)
            if resp.ok {
                var fields: [String: String] = ["op": "proc_stdin_close", "proc_id": procId]
                if let meta = resp.meta {
                    if let alreadyClosed = meta["alreadyClosed"] {
                        fields["already_closed"] = alreadyClosed
                    }
                    if let childAlive = meta["childAlive"] {
                        fields["child_alive"] = childAlive
                    }
                    if let closeReason = meta["closeReason"] {
                        fields["close_reason"] = closeReason
                    }
                    if let closed = meta["closed"] {
                        fields["closed"] = closed
                    }
                }
                logSessionScopedEvent(
                    sessionID: request.sessionId,
                    fallbackInstance: context.instanceName,
                    event: "session_proc_stdin_closed",
                    fields: fields
                )
            }
            return RuntimeControlResponse(ok: resp.ok, error: resp.error?.message, meta: resp.meta)
        } catch {
            invalidateTransportIfNeeded(
                context: context,
                sessionID: request.sessionId,
                reason: "proc_stdin_close_transport_failed",
                message: String(describing: error)
            )
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func isTransportFailureMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("broken pipe")
            || lowered.contains("connection closed")
            || lowered.contains("unexpected eof")
            || lowered.contains("eof")
            || lowered.contains("pollhup")
            || lowered.contains("pollerr")
            || lowered.contains("read timeout")
            || lowered.contains("timeout")
    }

    private func invalidateTransportIfNeeded(
        context: InstanceRuntimeContext,
        sessionID: String?,
        reason: String,
        message: String
    ) {
        guard isTransportFailureMessage(message) else {
            return
        }
        invalidateInstanceTransport(
            context: context,
            sessionID: sessionID,
            reason: reason,
            message: message
        )
    }

    private func invalidateInstanceTransport(
        context: InstanceRuntimeContext,
        sessionID: String?,
        reason: String,
        message: String
    ) {
        logSessionScopedEvent(
            sessionID: sessionID,
            fallbackInstance: context.instanceName,
            event: "instance_transport_invalidated",
            fields: [
                "reason": reason,
                "error": message
            ]
        )
        context.lastError = message
        context.initClient = nil
        context.initWriteClient = nil
        context.initReadClient = nil
        context.housekeepingClient = nil
        context.lifecycleState = .error
        context.vmRunner?.stopRunningVM()
        context.vmRunner = nil
        context.clearBootError()
        publishInstanceStateEvent(
            instance: context.instanceName,
            state: "Error",
            reason: reason,
            error: message
        )
        try? lock.withExclusiveLock {
            var state = try store.loadState()
            let existing = state.instances?.first(where: { $0.instance == context.instanceName })
            upsertInstanceState(
                &state,
                instanceName: context.instanceName,
                lifecycleState: .error,
                activeSessionCount: existing?.activeSessionCount ?? 0,
                idleTimer: existing?.idleTimer ?? IdleTimerState(armed: false, deadlineEpochMs: nil),
                runtimeHostPid: existing?.runtimeHostPid ?? state.runtimeHostPid,
                runtimeControlSocket: existing?.runtimeControlSocket ?? state.runtimeControlSocket,
                runtimeUser: existing?.runtimeUser,
                initChannel: existing?.initChannel,
                lastError: message
            )
            try store.saveState(state)
        }
    }

    private func handleProcClose(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initWriteClient ?? context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let procId = request.procId else {
            return RuntimeControlResponse(ok: false, error: "missing procId")
        }
        do {
            let resp = try client.procClose(procId: procId, timeoutMs: 500)
            var fields: [String: String] = ["op": "proc_close", "proc_id": procId, "result": resp.ok ? "ok" : "failed"]
            if let meta = resp.meta {
                if let exitCode = meta["exitCode"] {
                    fields["exit_code"] = exitCode
                }
                if let exitReason = meta["exitReason"] {
                    fields["exit_reason"] = exitReason
                }
                if let closeAction = meta["closeAction"] {
                    fields["close_action"] = closeAction
                }
                if let closed = meta["closed"] {
                    fields["closed"] = closed
                }
            }
            logSessionScopedEvent(
                sessionID: request.sessionId,
                fallbackInstance: context.instanceName,
                event: "session_proc_closed",
                fields: fields
            )
            removeProcEventBuffer(procId: procId)
            return RuntimeControlResponse(ok: resp.ok, error: resp.error?.message, exitCode: resp.exitCode, meta: resp.meta)
        } catch {
            let message = String(describing: error)
            logSessionScopedEvent(
                sessionID: request.sessionId,
                fallbackInstance: context.instanceName,
                event: "session_proc_closed",
                fields: [
                    "op": "proc_close",
                    "proc_id": procId,
                    "result": "transport_failed",
                    "error": message
                ]
            )
            removeProcEventBuffer(procId: procId)
            return RuntimeControlResponse(ok: false, error: message)
        }
    }

    // MARK: - Session Management

    private func sessionEntry(id: String) -> SessionEntry? {
        do {
            return try lock.withExclusiveLock(timeoutSec: 2) {
                try store.loadSessions().first { $0.id == id }
            }
        } catch {
            return nil
        }
    }

    private func logSessionScopedEvent(
        sessionID: String?,
        fallbackInstance: String,
        event: String,
        fields: [String: String] = [:]
    ) {
        guard let sessionID, !sessionID.isEmpty else {
            logRouter.logVM(instance: fallbackInstance, event: event, fields: fields)
            return
        }
        if let entry = sessionEntry(id: sessionID) {
            if let logPath = entry.logPath, !logPath.isEmpty {
                logRouter.appendToLogPath(logPath, instance: entry.instance, sessionID: sessionID, event: event, fields: fields)
            } else {
                logRouter.logSession(instance: entry.instance, sessionID: sessionID, event: event, fields: fields)
            }
            return
        }
        logRouter.logVM(instance: fallbackInstance, event: event, fields: fields)
    }

    private func handleSessionRegister(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        let sessionID = UUID().uuidString
        do {
            let instanceName = resolveTargetInstanceName(request)
            _ = try ensureInstanceRunning(instanceName: instanceName, callerCwd: request.callerCwd)
            let logPath = try logRouter.ensureSessionLogFile(instance: instanceName, sessionID: sessionID).path
            try lock.withExclusiveLock {
                let session = SessionEntry(
                    id: sessionID,
                    instance: instanceName,
                    logPath: logPath,
                    pid: Int32(getpid()),
                    startedAtEpochMs: nowEpochMs()
                )
                let updated = try sessions.addSession(session)
                let instanceSessionCount = updated.filter { $0.instance == instanceName }.count
                var state = try store.loadState()
                var targetIdleTimer = state.instances?.first(where: { $0.instance == instanceName })?.idleTimer
                    ?? IdleTimerState(armed: false, deadlineEpochMs: nil)
                if instanceName == currentRuntimeInstanceName() {
                    state.activeSessionCount = instanceSessionCount
                    targetIdleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                    state.idleTimer = targetIdleTimer
                }
                let targetEntry = state.instances?.first(where: { $0.instance == instanceName })
                upsertInstanceState(
                    &state,
                    instanceName: instanceName,
                    lifecycleState: .running,
                    activeSessionCount: instanceSessionCount,
                    idleTimer: targetIdleTimer,
                    runtimeHostPid: targetEntry?.runtimeHostPid ?? state.runtimeHostPid,
                    runtimeControlSocket: targetEntry?.runtimeControlSocket ?? state.runtimeControlSocket,
                    runtimeUser: targetEntry?.runtimeUser,
                    initChannel: targetEntry?.initChannel ?? state.initChannel,
                    lastError: nil
                )
                try store.saveState(state)
            }
            noteGuestActivity()
            disarmIdleTimer(for: instanceName)
            logger.log("daemon_client_connected", fields: ["session": sessionID, "instance": instanceName])
            logRouter.logSession(
                instance: instanceName,
                sessionID: sessionID,
                event: "daemon_session_log_opened",
                fields: ["op": "session_register", "result": "ok", "log_path": logPath]
            )
            return RuntimeControlResponse(ok: true, sessionId: sessionID)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleSessionUnregister(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let sessionID = request.sessionId else {
            return RuntimeControlResponse(ok: false, error: "missing sessionId")
        }
        let detachedEntry = sessionEntry(id: sessionID)
        let targetInstance = detachedEntry?.instance ?? resolveTargetInstanceName(request)
        do {
            let remainingCount: Int = try lock.withExclusiveLock {
                let updated = try sessions.removeSession(id: sessionID)
                let remainingForInstance = updated.filter { $0.instance == targetInstance }.count
                var state = try store.loadState()
                var targetIdleTimer = state.instances?.first(where: { $0.instance == targetInstance })?.idleTimer
                    ?? IdleTimerState(armed: false, deadlineEpochMs: nil)
                if targetInstance == currentRuntimeInstanceName() {
                    state.activeSessionCount = remainingForInstance
                    if remainingForInstance == 0 {
                        let timeoutMs = resolveIdleTimeoutMs()
                        let deadline = nowEpochMs() + timeoutMs
                        state.idleTimer = IdleTimerState(armed: true, deadlineEpochMs: deadline)
                        targetIdleTimer = state.idleTimer
                    } else {
                        state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                        targetIdleTimer = state.idleTimer
                    }
                }
                let targetEntry = state.instances?.first(where: { $0.instance == targetInstance })
                upsertInstanceState(
                    &state,
                    instanceName: targetInstance,
                    lifecycleState: .running,
                    activeSessionCount: remainingForInstance,
                    idleTimer: targetIdleTimer,
                    runtimeHostPid: targetEntry?.runtimeHostPid ?? state.runtimeHostPid,
                    runtimeControlSocket: targetEntry?.runtimeControlSocket ?? state.runtimeControlSocket,
                    runtimeUser: targetEntry?.runtimeUser,
                    initChannel: targetEntry?.initChannel ?? state.initChannel,
                    lastError: nil
                )
                try store.saveState(state)
                return remainingForInstance
            }
            logger.log("daemon_client_disconnected", fields: ["session": sessionID, "instance": targetInstance])
            if let detachedEntry, let logPath = detachedEntry.logPath, !logPath.isEmpty {
                logRouter.appendToLogPath(
                    logPath,
                    instance: detachedEntry.instance,
                    sessionID: sessionID,
                    event: "daemon_session_log_closed",
                    fields: ["op": "session_unregister", "result": "ok"]
                )
            }

            // Check if we should arm idle timer
            if remainingCount == 0 && targetInstance == currentRuntimeInstanceName() {
                armIdleTimer(for: targetInstance)
            }

            return RuntimeControlResponse(ok: true)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    // MARK: - Port Forwarding

    private func handlePortAdd(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let hostPort = request.hostPort, let guestPort = request.guestPort,
              let fw = forwarder else {
            return RuntimeControlResponse(ok: false, error: "missing hostPort/guestPort")
        }
        let instanceName = resolveTargetInstanceName(request)
        guard instanceName == currentRuntimeInstanceName() else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running: \(instanceName)")
        }
        let response = fw.add(PortMapping(hostPort: hostPort, guestPort: guestPort, instance: instanceName))
        schedulePortMappingsRefresh(reason: "manual_add")
        return response
    }

    private func handlePortRemove(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let hostPort = request.hostPort, let fw = forwarder else {
            return RuntimeControlResponse(ok: false, error: "missing hostPort")
        }
        let instanceName = resolveTargetInstanceName(request)
        guard instanceName == currentRuntimeInstanceName() else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running: \(instanceName)")
        }
        let response = fw.remove(hostPort: hostPort, ownerInstance: instanceName)
        schedulePortMappingsRefresh(reason: "manual_remove")
        return response
    }

    private func handlePortList(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        let instanceName = resolveTargetInstanceName(request)
        if instanceName == currentRuntimeInstanceName() {
            guard let fw = forwarder else {
                return RuntimeControlResponse(ok: false, error: "forwarder unavailable")
            }
            let snapshot = currentEffectivePortMappingsSnapshot()
            return fw.list(mappings: snapshot.mappings)
        }

        do {
            let context = instanceRegistry.context(for: instanceName)
            let exposeVMNetEndpoints = context.resolvedNetworkMode.effective == .vmnetShared
            let mappings = try lock.withExclusiveLock(timeoutSec: 1) {
                try store.loadPortMappings().mappings
                    .filter { $0.instance == instanceName }
                    .sorted { $0.hostPort < $1.hostPort }
            }
            let items = mappings.map { mapping in
                RuntimePortStatusItem(
                    instance: mapping.instance,
                    hostPort: mapping.hostPort,
                    guestPort: mapping.guestPort,
                    bindAddress: mapping.bindAddress,
                    source: mapping.source,
                    active: false,
                    ownerInstance: nil,
                    guestAddress: nil,
                    localhostEndpoint: "\(mapping.bindAddress):\(mapping.hostPort)",
                    hostnameEndpoint: exposeVMNetEndpoints && mapping.bindAddress == "127.0.0.1"
                        ? "\(NetworkIdentity.serviceHostname(for: mapping.instance)):\(mapping.hostPort)"
                        : nil,
                    directEndpoint: nil,
                    error: nil
                )
            }
            return RuntimeControlResponse(ok: true, items: items)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleMemoryStatus(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let context = resolveContext(for: request),
              let client = context.initClient ?? initClient else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        guard let balloon = context.vmRunner?.memoryBalloonRuntimeStats() else {
            return RuntimeControlResponse(ok: false, error: "balloon stats unavailable")
        }

        let reclaim = readGuestMemoryReclaimStats(client: client)
        return RuntimeControlResponse(ok: true, meta: [
            "allocated_bytes": String(balloon.allocatedBytes),
            "max_bytes": String(balloon.maxBytes),
            "returned_total_bytes": String(balloon.returnedTotalBytes),
            "compact_count": String(reclaim.compactCount),
            "compact_last_epoch_ms": reclaim.compactLastEpochMs.map(String.init) ?? "",
            "drop_cache_count": String(reclaim.dropCacheCount),
            "drop_cache_last_epoch_ms": reclaim.dropCacheLastEpochMs.map(String.init) ?? ""
        ])
    }

    private func handleDNSStatus(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        let instanceName = resolveTargetInstanceName(request)
        let context = instanceRegistry.context(for: instanceName)
        var meta = context.runtimeDNSMeta.isEmpty ? runtimeDNSMeta : context.runtimeDNSMeta
        applyNetworkModeMeta(&meta, resolved: context.resolvedNetworkMode, instanceName: instanceName, topology: context.networkTopology)
        meta["host_hosts_status"] = meta["host_hosts_status"] ?? "unknown"
        meta["guest_hosts_status"] = meta["guest_hosts_status"] ?? "unknown"
        if context.resolvedNetworkMode.effective == .vmnetShared,
           let topology = probeGuestNetworkAddressInfo(instanceName: instanceName, preferredClient: context.housekeepingClient ?? context.initClient ?? initClient) {
            mergeNetworkTopologyMeta(&meta, topology: topology)
        }
        return RuntimeControlResponse(ok: true, meta: meta)
    }

    private func handleDNSReconcile(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        dnsReconcileLock.lock()
        defer { dnsReconcileLock.unlock() }
        let instanceName = resolveTargetInstanceName(request)
        let dnsSource = request.dnsSource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.dnsSource!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "manual"
        let isBackgroundRequest = ["startup", "host_change", "stale_guard"].contains(dnsSource)
        guard let context = resolveContext(for: RuntimeControlRequest(
            op: request.op,
            instance: instanceName,
            sessionId: request.sessionId
        )) else {
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        let client = isBackgroundRequest
            ? housekeepingClient(for: instanceName)
            : (context.initClient ?? initClient)
        guard let client else {
            if isBackgroundRequest {
                logger.log("housekeeping_client_unavailable", fields: [
                    "instance": instanceName,
                    "request_source": "housekeeping",
                    "kind": "dns_reconcile",
                    "source": dnsSource
                ])
                return updateDNSStateAndRespond(
                    instanceName: instanceName,
                    mode: currentDNSMetaSnapshot(instanceName: instanceName)["dns_mode"] ?? "host",
                    status: "deferred",
                    action: "skipped",
                    source: dnsSource,
                    nameserverCount: 0,
                    searchDomainCount: 0,
                    snapshotHash: "",
                    errorClass: "housekeeping_unavailable",
                    error: "housekeeping client unavailable"
                )
            }
            return RuntimeControlResponse(ok: false, error: "instance_not_running")
        }
        let metadataURL = context.metadataURL
            ?? (try? resolveRuntimeMetadataURL(explicitInstanceName: instanceName))
        guard let metadataURL else {
            return RuntimeControlResponse(ok: false, error: "runtime metadata unavailable")
        }
        logger.log("dns_reconcile_started", fields: [
            "dns_source": dnsSource,
            "request_source": isBackgroundRequest ? "housekeeping" : "user"
        ])

        do {
            let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: metadataURL)
            let config = try defaultInstanceStore.loadConfig()
            let snapshot = HostResolverSnapshotProvider().capture()
            let policy = try DNSPolicyResolver().resolve(
                instancePolicy: metadata.networkPolicy?.dns,
                globalConfig: config.network?.dns,
                hostSnapshot: snapshot
            )
            if policy.mode == .manual {
                logger.log("dns_override_applied", fields: [
                    "dns_mode": "manual",
                    "nameserver_count": String(policy.nameservers.count),
                    "search_domain_count": String(policy.searchDomains.count)
                ])
            }

            if policy.mode == .unmanaged {
                lastHostResolverSnapshotHash = snapshot.hash
                return updateDNSStateAndRespond(
                    instanceName: instanceName,
                    mode: policy.mode.rawValue,
                    status: "healthy",
                    action: "policy_skip",
                    source: dnsSource,
                    nameserverCount: 0,
                    searchDomainCount: 0,
                    snapshotHash: snapshot.hash,
                    errorClass: nil,
                    error: nil
                )
            }

            let applyResp = try client.send(InitChannelRequest(
                op: "dns_reconcile",
                timeoutMs: 3_000,
                dnsMode: policy.mode.rawValue,
                dnsNameservers: policy.nameservers,
                dnsSearchDomains: policy.searchDomains,
                dnsResolverBackend: policy.resolverBackend,
                dnsSource: dnsSource,
                dnsProxyUpstreams: policy.mode == .host ? policy.nameservers : nil,
                dnsProxyListenAddress: policy.mode == .host ? "127.0.0.1" : nil,
                dnsProxyListenPort: policy.mode == .host ? 53 : nil
            ))
            let applyResult: Bool
            let applyError: String?
            if applyResp.error?.code == .unsupportedOp {
                let fallback = applyDNSReconcileLegacy(client: client, policy: policy)
                applyResult = fallback.ok
                applyError = fallback.error
            } else {
                applyResult = applyResp.ok
                applyError = applyResp.error?.message
            }

            if !applyResult {
                return updateDNSStateAndRespond(
                    instanceName: instanceName,
                    mode: policy.mode.rawValue,
                    status: "failed",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: "init_channel",
                    error: applyError ?? "dns_reconcile failed"
                )
            }

            let transportReady = ensureGuestTransportReadyViaExec(
                client: client,
                topology: context.networkTopology
            )
            if !transportReady.ok {
                return updateDNSStateAndRespond(
                    instanceName: instanceName,
                    mode: policy.mode.rawValue,
                    status: "degraded",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: "network_transport",
                    error: transportReady.error ?? "guest transport bootstrap failed"
                )
            }

            let healthResp = try client.send(InitChannelRequest(
                op: "dns_healthcheck",
                timeoutMs: 2_000,
                dnsMode: policy.mode.rawValue,
                dnsSource: dnsSource
            ))
            let healthResult: Bool
            let healthError: String?
            if healthResp.error?.code == .unsupportedOp {
                let fallback = runDNSHealthcheckLegacy(client: client)
                healthResult = fallback.ok
                healthError = fallback.error
            } else {
                healthResult = healthResp.ok
                healthError = healthResp.error?.message
            }
            if !healthResult {
                let healthErrorClass = classifyDNSHealthcheckError(healthError)
                logger.log("dns_healthcheck_failed", fields: [
                    "dns_mode": policy.mode.rawValue,
                    "dns_source": dnsSource,
                    "error_class": healthErrorClass,
                    "error": healthError ?? "dns healthcheck failed"
                ])
                return updateDNSStateAndRespond(
                    instanceName: instanceName,
                    mode: policy.mode.rawValue,
                    status: "degraded",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: healthErrorClass,
                    error: healthError ?? "dns healthcheck failed"
                )
            }

            if context.resolvedNetworkMode.effective != .vmnetShared {
                return updateDNSStateAndRespond(
                    instanceName: instanceName,
                    mode: policy.mode.rawValue,
                    status: "healthy",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: nil,
                    error: nil
                )
            }

            guard let topology = probeGuestNetworkAddressInfo(instanceName: instanceName, preferredClient: client) else {
                return updateDNSStateAndRespond(
                    instanceName: instanceName,
                    mode: policy.mode.rawValue,
                    status: "degraded",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: "network_topology",
                    error: "network topology unavailable: failed to resolve guest/private IPv4 endpoints"
                )
            }
            guard let hostGatewayIPv4 = topology.hostGatewayIPv4, !hostGatewayIPv4.isEmpty else {
                return updateDNSStateAndRespond(
                    instanceName: instanceName,
                    mode: policy.mode.rawValue,
                    status: "degraded",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: "host_alias",
                    error: "host alias unavailable: missing host gateway IPv4"
                )
            }

            let hostAliasResult = ensureGuestHostAlias(
                client: client,
                hostGatewayIPv4: hostGatewayIPv4
            )
            if !hostAliasResult.ok {
                return updateDNSStateAndRespond(
                    instanceName: instanceName,
                    mode: policy.mode.rawValue,
                    status: "degraded",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: "host_alias",
                    error: hostAliasResult.error ?? "host alias update failed"
                )
            }

            return updateDNSStateAndRespond(
                instanceName: instanceName,
                mode: policy.mode.rawValue,
                status: "healthy",
                action: "applied",
                source: dnsSource,
                nameserverCount: policy.nameservers.count,
                searchDomainCount: policy.searchDomains.count,
                snapshotHash: snapshot.hash,
                errorClass: nil,
                error: nil
            )
        } catch {
            logger.log("dns_override_invalid", fields: [
                "dns_source": dnsSource,
                "error": String(describing: error)
            ])
            return updateDNSStateAndRespond(
                instanceName: instanceName,
                mode: "unknown",
                status: "failed",
                action: "-",
                source: dnsSource,
                nameserverCount: 0,
                searchDomainCount: 0,
                snapshotHash: "",
                errorClass: "config_invalid",
                error: String(describing: error)
            )
        }
    }

    private func updateDNSStateAndRespond(
        instanceName: String,
        mode: String,
        status: String,
        action: String,
        source: String,
        nameserverCount: Int,
        searchDomainCount: Int,
        snapshotHash: String,
        errorClass: String?,
        error: String?
    ) -> RuntimeControlResponse {
        let now = nowEpochMs()
        let context = instanceRegistry.context(for: instanceName)
        var meta: [String: String] = [
            "dns_mode": mode,
            "dns_status": status,
            "dns_action": action,
            "dns_source": source,
            "host_hosts_status": currentDNSMetaSnapshot(instanceName: instanceName)["host_hosts_status"] ?? "unknown",
            "guest_hosts_status": currentDNSMetaSnapshot(instanceName: instanceName)["guest_hosts_status"] ?? "unknown",
            "nameserver_count": String(nameserverCount),
            "search_domain_count": String(searchDomainCount),
            "snapshot_hash": snapshotHash,
            "last_reconcile_epoch_ms": String(now)
        ]
        if let errorClass, !errorClass.isEmpty {
            meta["error_class"] = errorClass
        }
        if let error, !error.isEmpty {
            meta["error"] = error
        }
        applyNetworkModeMeta(&meta, resolved: context.resolvedNetworkMode, instanceName: instanceName, topology: context.networkTopology)
        if !snapshotHash.isEmpty {
            lastHostResolverSnapshotHash = snapshotHash
        }
        if context.resolvedNetworkMode.effective == .vmnetShared,
           let topology = probeGuestNetworkAddressInfo(instanceName: instanceName, preferredClient: housekeepingClient(for: instanceName) ?? context.initClient ?? initClient) {
            mergeNetworkTopologyMeta(&meta, topology: topology)
        }
        context.runtimeDNSMeta = meta
        if instanceName == currentRuntimeInstanceName() {
            dnsStateLock.lock()
            runtimeDNSMeta = meta
            dnsStateLock.unlock()
        }

        let event: String
        if action == "policy_skip" {
            event = "dns_reconcile_skipped"
        } else if status == "healthy" {
            event = "dns_reconcile_succeeded"
        } else {
            event = "dns_reconcile_failed"
        }
        logger.log(event, fields: meta)
        return RuntimeControlResponse(ok: status != "failed", error: error, meta: meta)
    }

    private func mergeNetworkTopologyMeta(_ meta: inout [String: String], topology: GuestNetworkAddressInfo) {
        if let guestIPv4 = topology.guestIPv4, !guestIPv4.isEmpty {
            meta["guest_private_ipv4"] = guestIPv4
        }
        if let hostGatewayIPv4 = topology.hostGatewayIPv4, !hostGatewayIPv4.isEmpty {
            meta["host_gateway_ipv4"] = hostGatewayIPv4
            meta["host_alias_endpoint"] = "\(NetworkIdentity.hostAlias):<port> (\(hostGatewayIPv4))"
        }
    }

    private func resolveConfiguredNetworkMode() -> ResolvedNetworkMode {
        let config = try? defaultInstanceStore.loadConfig()
        let configured = NetworkModeResolver.configuredMode(from: config)
        return NetworkModeResolver.resolve(configured: configured, executablePath: executablePath)
    }

    private func applyResolvedNetworkMode(
        _ resolved: ResolvedNetworkMode,
        to context: InstanceRuntimeContext,
        instanceName: String
    ) {
        context.resolvedNetworkMode = resolved
        if resolved.effective == .vmnetShared {
            context.networkTopology = plannedNetworkTopology(for: instanceName)
        } else {
            context.networkTopology = nil
        }
        var meta = context.runtimeDNSMeta
        applyNetworkModeMeta(&meta, resolved: resolved, instanceName: instanceName, topology: context.networkTopology)
        context.runtimeDNSMeta = meta
    }

    private func applyNetworkModeMeta(
        _ meta: inout [String: String],
        resolved: ResolvedNetworkMode,
        instanceName: String,
        topology: VMNetNetworkTopology?
    ) {
        meta["configured_network_mode"] = resolved.configured.rawValue
        meta["effective_network_mode"] = resolved.effective.rawValue
        meta["network_mode"] = resolved.effective.rawValue
        meta["network_mode_reason"] = resolved.reason ?? ""
        if resolved.effective == .vmnetShared {
            let sharedNetwork = NetworkIdentity.sharedNetwork()
            meta["shared_subnet_ipv4"] = sharedNetwork.subnetIPv4
            meta["shared_subnet_mask_ipv4"] = sharedNetwork.subnetMaskIPv4
            meta["host_alias"] = NetworkIdentity.hostAlias
            meta["service_host_pattern"] = NetworkIdentity.serviceHostnamePatternDescription(for: instanceName)
            meta["service_hostname"] = NetworkIdentity.serviceHostname(for: instanceName)
            if let topology {
                meta["guest_private_ipv4"] = topology.guestIPv4
                meta["host_gateway_ipv4"] = topology.hostIPv4
                meta["host_alias_endpoint"] = "\(NetworkIdentity.hostAlias):<port> (\(topology.hostIPv4))"
            } else {
                meta["guest_private_ipv4"] = "-"
                meta["host_gateway_ipv4"] = sharedNetwork.hostGatewayIPv4
                meta["host_alias_endpoint"] = "\(NetworkIdentity.hostAlias):<port> (\(sharedNetwork.hostGatewayIPv4))"
            }
        } else {
            meta["shared_subnet_ipv4"] = "-"
            meta["shared_subnet_mask_ipv4"] = "-"
            meta["guest_private_ipv4"] = "-"
            meta["host_gateway_ipv4"] = "-"
            meta["host_alias"] = "-"
            meta["host_alias_endpoint"] = "-"
            meta["service_host_pattern"] = "-"
            meta["service_hostname"] = "-"
            meta["host_hosts_status"] = "unmanaged"
            meta["guest_hosts_status"] = "unmanaged"
        }
    }

    private func makeVirtualMachineRunner(
        metadataURL: URL,
        bootProfile: RuntimeBootProfile,
        instanceName: String,
        resolvedNetworkMode: ResolvedNetworkMode,
        startupPhaseObserver: ((String) -> Void)?
    ) -> VirtualMachineRunner {
        VirtualMachineRunner(
            paths: paths,
            metadataURL: metadataURL,
            bootProfile: bootProfile,
            logger: logger,
            initProbeHandler: { [weak self] probe in
                self?.updateInitChannelState(probe)
            },
            codeOpenRequestHandler: { [weak self] payload in
                self?.handleGuestCodeOpenPayload(payload, sourceInstance: instanceName)
            },
            backgroundMemoryMaintenanceAllowed: { [weak self] in
                !(self?.isBackgroundMemoryMaintenanceSuspended(instanceName: instanceName) ?? false)
            },
            startupPhaseObserver: startupPhaseObserver,
            networkMode: resolvedNetworkMode.effective,
            networkTopologyOverride: resolvedNetworkMode.effective == .vmnetShared ? plannedNetworkTopology(for: instanceName) : nil
        )
    }

    private func finalizeBootedInstance(
        context: InstanceRuntimeContext,
        instanceName: String,
        metadataURL: URL,
        client: InitChannelClient,
        runner: VirtualMachineRunner
    ) throws -> InstanceRuntimeContext {
        context.initClient = client
        if client.supportsDedicatedSideband {
            context.initWriteClient = client.makeSidebandClient()
            context.initReadClient = client.makeSidebandClient()
            context.housekeepingClient = context.initReadClient?.makeSidebandClient()
        } else {
            context.initWriteClient = nil
            context.initReadClient = nil
            context.housekeepingClient = nil
        }
        context.networkTopology = runner.activeNetworkTopology
        applyResolvedNetworkMode(context.resolvedNetworkMode, to: context, instanceName: instanceName)

        try prepareTmpStorageOnStartup(
            client: client,
            metadataURL: metadataURL,
            instanceName: instanceName
        )
        prepareHostShareRootMountOnStartup(client: client)
        syncGuestClockAtStartup(client: client, instanceName: instanceName)
        let resolved = try convergeRuntimeUser(
            client: client,
            metadataURL: metadataURL,
            instanceName: instanceName
        )
        context.runtimeUser = resolved.runtimeUser
        ensureGuestMSLCommandAlias(client: client)

        try lock.withExclusiveLock {
            var state = try store.loadState()
            upsertInstanceState(
                &state,
                instanceName: instanceName,
                lifecycleState: .running,
                activeSessionCount: state.instances?.first(where: { $0.instance == instanceName })?.activeSessionCount ?? 0,
                idleTimer: state.instances?.first(where: { $0.instance == instanceName })?.idleTimer
                    ?? IdleTimerState(armed: false, deadlineEpochMs: nil),
                runtimeHostPid: Int32(getpid()),
                runtimeControlSocket: paths.runtimeControlSocketFile.path,
                runtimeUser: resolved.runtimeUser,
                initChannel: state.instances?.first(where: { $0.instance == instanceName })?.initChannel,
                lastError: nil
            )
            try store.saveState(state)
        }
        try ensureAttachedContainerDaemonStarted(instanceName: instanceName)
        context.lifecycleState = .running
        context.lastError = nil
        publishInstanceStateEvent(instance: instanceName, state: "Running", reason: "boot_ready")
        return context
    }

    private func plannedNetworkTopology(for instanceName: String) -> VMNetNetworkTopology {
        let reserved = Set(
            instanceRegistry.allContexts()
                .filter { $0.instanceName != instanceName }
                .compactMap(\.networkTopology?.guestIPv4)
        )
        return NetworkIdentity.vmnetTopology(for: instanceName, reservedGuestIPv4s: reserved)
    }

    private func probeGuestNetworkAddressInfo(
        instanceName: String,
        preferredClient: InitChannelClient?
    ) -> GuestNetworkAddressInfo? {
        guard let client = preferredClient ?? housekeepingClient(for: instanceName) else {
            return nil
        }
        let script = """
        set -eu
        guest=""
        gateway=""
        if command -v ip >/dev/null 2>&1; then
          gateway="$(ip -4 route show default 2>/dev/null | awk '/default/ { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')"
          guest="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
          if [ -z "$guest" ]; then
            guest="$(ip -4 -o addr show scope global up 2>/dev/null | awk '{ split($4, addr, \"/\"); print addr[1]; exit }')"
          fi
        fi
        printf 'guest_ipv4=%s\\n' "$guest"
        printf 'host_gateway_ipv4=%s\\n' "$gateway"
        """
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                timeoutMs: 2_000
            ))
            guard response.ok else {
                return nil
            }
            let info = NetworkIdentity.parseGuestAddressProbeOutput(response.stdout ?? "")
            if info.guestIPv4 == nil, info.hostGatewayIPv4 == nil {
                return nil
            }
            return info
        } catch {
            logger.log("network_topology_probe_failed", fields: [
                "instance": instanceName,
                "error": String(describing: error)
            ])
            return nil
        }
    }

    private func forwardingGuestIPHint(for context: InstanceRuntimeContext) -> String? {
        if let guestIPv4 = context.networkTopology?.guestIPv4, !guestIPv4.isEmpty {
            return guestIPv4
        }
        if let guestIPv4 = context.runtimeDNSMeta["guest_private_ipv4"],
           !guestIPv4.isEmpty,
           guestIPv4 != "-" {
            return guestIPv4
        }
        return probeGuestNetworkAddressInfo(
            instanceName: context.instanceName,
            preferredClient: context.housekeepingClient ?? context.initClient ?? initClient
        )?.guestIPv4
    }

    private func reconcileHostManagedHostnames(reason: String) {
        let desiredTopologies = instanceRegistry.allContexts()
            .filter { $0.lifecycleState == .running && $0.resolvedNetworkMode.effective == .vmnetShared }
            .compactMap(\.networkTopology)

        if desiredTopologies.isEmpty {
            updateHostHostsMeta(status: "unmanaged", error: nil)
            return
        }

        do {
            let existing = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
            let render = NetworkIdentity.reconcileHostHostsFile(existing: existing, topologies: desiredTopologies)
            if render.rendered != existing {
                try writeHostHostsFile(render.rendered)
            }
            let status = render.conflicts.isEmpty ? "managed" : "degraded"
            updateHostHostsMeta(
                status: status,
                error: render.conflicts.isEmpty ? nil : "unmanaged hostname conflicts: \(render.conflicts.joined(separator: ","))"
            )
            logger.log("host_hosts_reconciled", fields: [
                "reason": reason,
                "instance_count": String(desiredTopologies.count),
                "status": status
            ])
        } catch {
            updateHostHostsMeta(status: "degraded", error: String(describing: error))
            logger.log("host_hosts_reconcile_failed", fields: [
                "reason": reason,
                "error": String(describing: error)
            ])
        }
    }

    private func writeHostHostsFile(_ rendered: String) throws {
        if FileManager.default.isWritableFile(atPath: "/etc/hosts") {
            try rendered.write(toFile: "/etc/hosts", atomically: true, encoding: .utf8)
            return
        }

        let tempURL = paths.runtime.appendingPathComponent("hosts.msl.tmp", isDirectory: false)
        try rendered.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if try runHostCommand("/usr/bin/sudo", arguments: ["-n", "/usr/bin/install", "-m", "644", tempURL.path, "/etc/hosts"]) {
            return
        }

        let shellCommand = "/usr/bin/install -m 644 '\(escapeSingleQuotes(tempURL.path))' /etc/hosts"
        let script = "do shell script \"\(escapeAppleScript(shellCommand))\" with administrator privileges"
        let success = try runHostCommand("/usr/bin/osascript", arguments: ["-e", script])
        guard success else {
            throw MSLRuntimeError("failed to update host /etc/hosts with administrator privileges")
        }
    }

    private func runHostCommand(_ executable: String, arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = nil
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func escapeSingleQuotes(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func updateHostHostsMeta(status: String, error: String?) {
        for context in instanceRegistry.allContexts() where context.lifecycleState == .running {
            if context.resolvedNetworkMode.effective == .vmnetShared {
                context.runtimeDNSMeta["host_hosts_status"] = status
                if let error, !error.isEmpty {
                    context.runtimeDNSMeta["host_hosts_error"] = error
                } else {
                    context.runtimeDNSMeta.removeValue(forKey: "host_hosts_error")
                }
            } else {
                context.runtimeDNSMeta["host_hosts_status"] = "unmanaged"
                context.runtimeDNSMeta.removeValue(forKey: "host_hosts_error")
            }
        }
        dnsStateLock.lock()
        if instanceRegistry.context(for: currentRuntimeInstanceName()).resolvedNetworkMode.effective == .vmnetShared {
            runtimeDNSMeta["host_hosts_status"] = status
            if let error, !error.isEmpty {
                runtimeDNSMeta["host_hosts_error"] = error
            } else {
                runtimeDNSMeta.removeValue(forKey: "host_hosts_error")
            }
        } else {
            runtimeDNSMeta["host_hosts_status"] = "unmanaged"
            runtimeDNSMeta.removeValue(forKey: "host_hosts_error")
        }
        dnsStateLock.unlock()
    }

    private func ensureGuestHostAlias(
        client: InitChannelClient,
        hostGatewayIPv4: String
    ) -> (ok: Bool, error: String?) {
        if instanceRegistry.context(for: currentRuntimeInstanceName()).resolvedNetworkMode.effective != .vmnetShared {
            dnsStateLock.lock()
            runtimeDNSMeta["guest_hosts_status"] = "unmanaged"
            runtimeDNSMeta.removeValue(forKey: "guest_hosts_error")
            dnsStateLock.unlock()
            return (true, nil)
        }
        do {
            let readResponse = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/etc/hosts"],
                timeoutMs: 1_000
            ))
            guard readResponse.ok else {
                return (false, readResponse.error?.message ?? readResponse.stderr ?? "failed to read /etc/hosts")
            }

            let renderedHosts = NetworkIdentity.renderGuestHostsFile(
                existing: readResponse.stdout ?? "",
                hostGatewayIPv4: hostGatewayIPv4
            )
            let marker = "__MSL_HOSTS_EOF__"
            let script = """
            set -eu
            tmp=/etc/hosts.msl.tmp
            cat > "$tmp" <<'\(marker)'
            \(renderedHosts)
            \(marker)
            mv "$tmp" /etc/hosts
            """
            let writeResponse = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                runAsRoot: true,
                timeoutMs: 2_000
            ))
            guard writeResponse.ok, (writeResponse.exitCode ?? 0) == 0 else {
                return (false, writeResponse.error?.message ?? writeResponse.stderr ?? "failed to update /etc/hosts")
            }
            if let activeInstanceName {
                instanceRegistry.context(for: activeInstanceName).runtimeDNSMeta["guest_hosts_status"] = "managed"
                instanceRegistry.context(for: activeInstanceName).runtimeDNSMeta.removeValue(forKey: "guest_hosts_error")
            }
            dnsStateLock.lock()
            runtimeDNSMeta["guest_hosts_status"] = "managed"
            runtimeDNSMeta.removeValue(forKey: "guest_hosts_error")
            dnsStateLock.unlock()
            return (true, nil)
        } catch {
            if let activeInstanceName {
                instanceRegistry.context(for: activeInstanceName).runtimeDNSMeta["guest_hosts_status"] = "degraded"
                instanceRegistry.context(for: activeInstanceName).runtimeDNSMeta["guest_hosts_error"] = String(describing: error)
            }
            dnsStateLock.lock()
            runtimeDNSMeta["guest_hosts_status"] = "degraded"
            runtimeDNSMeta["guest_hosts_error"] = String(describing: error)
            dnsStateLock.unlock()
            return (false, String(describing: error))
        }
    }

    private func classifyDNSHealthcheckError(_ error: String?) -> String {
        guard let error else {
            return "dns_resolution"
        }
        let lowered = error.lowercased()
        if lowered.contains("network transport unavailable")
            || lowered.contains("missing default route")
            || lowered.contains("network is unreachable") {
            return "network_transport"
        }
        return "dns_resolution"
    }

    private func currentDNSMetaSnapshot(instanceName: String) -> [String: String] {
        let context = instanceRegistry.context(for: instanceName)
        if !context.runtimeDNSMeta.isEmpty {
            return context.runtimeDNSMeta
        }
        dnsStateLock.lock()
        defer { dnsStateLock.unlock() }
        return runtimeDNSMeta
    }

    static func makeGuestTransportReadyScript(topology: VMNetNetworkTopology?) -> String {
        let expectedGuestIPv4 = topology?.guestIPv4 ?? ""
        let expectedGatewayIPv4 = topology?.hostIPv4 ?? ""
        let prefixLength = topology.map { ipv4PrefixLength(mask: $0.subnetMaskIPv4) } ?? 24
        return """
        set -eu
        expected_guest_ipv4='\(expectedGuestIPv4)'
        expected_gateway_ipv4='\(expectedGatewayIPv4)'
        expected_prefix_len='\(prefixLength)'
        UDHCP_SCRIPT="$(mktemp /tmp/msl-udhcpc-script.XXXXXX)"
        trap 'rm -f "$UDHCP_SCRIPT"' EXIT
        cat > "$UDHCP_SCRIPT" <<'EOF'
        #!/bin/sh
        set -eu
        case "$1" in
          deconfig)
            if command -v ifconfig >/dev/null 2>&1; then
              ifconfig "$interface" 0.0.0.0 up >/dev/null 2>&1 || true
            elif command -v busybox >/dev/null 2>&1; then
              busybox ifconfig "$interface" 0.0.0.0 up >/dev/null 2>&1 || true
            else
              ip link set dev "$interface" up >/dev/null 2>&1 || true
              ip -4 addr flush dev "$interface" scope global >/dev/null 2>&1 || true
            fi
            ;;
          renew|bound)
            if command -v ifconfig >/dev/null 2>&1; then
              ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}" up >/dev/null 2>&1 || true
            elif command -v busybox >/dev/null 2>&1; then
              busybox ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}" up >/dev/null 2>&1 || true
            else
              ip link set dev "$interface" up >/dev/null 2>&1 || true
              ip -4 addr flush dev "$interface" scope global >/dev/null 2>&1 || true
              ip -4 addr add "$ip/24" dev "$interface" >/dev/null 2>&1 || true
            fi
            ip route del default dev "$interface" >/dev/null 2>&1 || true
            for r in $router; do
              ip route add default via "$r" dev "$interface" >/dev/null 2>&1 && break
            done
            ;;
        esac
        exit 0
        EOF
        chmod 0755 "$UDHCP_SCRIPT"
        has_transport() {
          if ip -4 route show default 2>/dev/null | grep -q '^default' \
            && ip -4 -o addr show scope global 2>/dev/null | grep -q 'inet '; then
            return 0
          fi
          if ip -6 route show default 2>/dev/null | grep -q '^default' \
            && ip -6 -o addr show scope global 2>/dev/null | grep -v ' tentative ' | grep -q 'inet6 '; then
            return 0
          fi
          return 1
        }
        repair_static_transport() {
          iface="$1"
          [ -n "$expected_guest_ipv4" ] || return 1
          [ -n "$expected_gateway_ipv4" ] || return 1
          ip link set dev "$iface" up >/dev/null 2>&1 || true
          if ! ip -4 -o addr show dev "$iface" 2>/dev/null | grep -q "inet $expected_guest_ipv4/"; then
            ip -4 addr flush dev "$iface" scope global >/dev/null 2>&1 || true
            ip -4 addr add "$expected_guest_ipv4/$expected_prefix_len" dev "$iface" >/dev/null 2>&1 || true
          fi
          ip route replace default via "$expected_gateway_ipv4" dev "$iface" >/dev/null 2>&1 || true
          has_transport
        }
        repair_dynamic_transport() {
          iface="$1"
          [ -n "$expected_guest_ipv4" ] && return 1
          if command -v sysctl >/dev/null 2>&1; then
            sysctl -w "net.ipv6.conf.${iface}.accept_ra=2" >/dev/null 2>&1 || true
            sysctl -w "net.ipv6.conf.${iface}.autoconf=1" >/dev/null 2>&1 || true
          fi
          if command -v networkctl >/dev/null 2>&1; then
            unit_name="$(printf '%s' "$iface" | tr -c 'A-Za-z0-9_.-' '_')"
            unit_path="/run/systemd/network/90-msl-${unit_name}.network"
            cat > "$unit_path" <<EOF
        [Match]
        Name=$iface

        [Network]
        DHCP=ipv4
        IPv6AcceptRA=yes
        LinkLocalAddressing=ipv6

        [DHCP]
        ClientIdentifier=mac
        EOF
            networkctl reload >/dev/null 2>&1 || true
            networkctl reconfigure "$iface" >/dev/null 2>&1 || systemctl restart systemd-networkd >/dev/null 2>&1 || true
            sleep 1
            has_transport && return 0
          fi
          return 1
        }
        has_transport && exit 0
        for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -Ev '^(lo|sit|ip6tnl)' || true); do
          ip link set dev "$iface" up >/dev/null 2>&1 || true
          if ip -4 -o addr show dev "$iface" scope global 2>/dev/null | grep -q 'inet '; then
            if repair_static_transport "$iface"; then
              exit 0
            fi
            continue
          fi
          if command -v udhcpc >/dev/null 2>&1; then
            udhcpc -i "$iface" -n -q -t 3 -T 1 -s "$UDHCP_SCRIPT" >/dev/null 2>&1 || true
          elif command -v busybox >/dev/null 2>&1; then
            busybox udhcpc -i "$iface" -n -q -t 3 -T 1 -s "$UDHCP_SCRIPT" >/dev/null 2>&1 || true
          elif command -v dhclient >/dev/null 2>&1; then
            dhclient -4 -1 "$iface" >/dev/null 2>&1 || true
          fi
          if repair_static_transport "$iface"; then
            exit 0
          fi
          if repair_dynamic_transport "$iface"; then
            exit 0
          fi
          has_transport && exit 0
        done
        has_transport
        """
    }

    static var guestTransportReadyScript: String {
        makeGuestTransportReadyScript(topology: nil)
    }

    private static func ipv4PrefixLength(mask: String) -> Int {
        let octets = mask.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else {
            return 24
        }
        return octets.reduce(0) { $0 + Int($1.nonzeroBitCount) }
    }

    static func makeVSCodeServerDirectoriesCommand(home: String) -> String {
        let safeHome = home.isEmpty ? "/root" : home
        return """
    mkdir -p '\(safeHome)/.vscode-server/extensionsCache' '\(safeHome)/.vscode-server/extensions' '\(safeHome)/.vscode-server/data/Machine'
    if [ -d '\(safeHome)/.vscode-server/bin' ]; then
      find '\(safeHome)/.vscode-server/bin' -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
        if [ -e "$dir/product.json" ] && ! cat "$dir/product.json" >/dev/null 2>&1; then
          rm -rf "$dir"
        fi
      done
    fi
    root_fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
    if [ "$root_fstype" = "btrfs" ]; then
      if [ -f /etc/fstab ]; then
        tmp="$(mktemp /tmp/msl-fstab.XXXXXX)"
        awk '
          BEGIN { root_done=0 }
          /^[[:space:]]*#/ || NF < 2 { print; next }
          {
            if ($2 == "/") {
              if (root_done == 0) {
                print "/dev/vda / auto defaults,nodiscard 0 1"
                root_done = 1
              }
              next
            }
            print
          }
        ' /etc/fstab > "$tmp"
        cat "$tmp" > /etc/fstab
        rm -f "$tmp"
      fi
      mount -o remount,nodiscard / >/dev/null 2>&1 || true
    fi
    """
    }

    static func makeVSCodeRuntimeStateDirectoriesCommand() -> String {
        return """
    mkdir -p /var/devcontainer
    """
    }

    static func makeVSCodeRootStateMarkerCreateCommand(location: String) -> String {
        let safeLocation = shellSingleQuote(location)
        let safeDirectory = shellSingleQuote((location as NSString).deletingLastPathComponent)
        return "test ! -f \(safeLocation) && set -o noclobber && mkdir -p \(safeDirectory) && { > \(safeLocation) ; } 2> /dev/null"
    }

    static func makeVSCodePatchEtcEnvironmentCommand(env: [String: String]) -> String {
        let lines = env.keys.sorted().map { key -> String in
            let value = env[key] ?? ""
            let escapedValue = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\(key)=\"\(escapedValue)\""
        }
        return """
    root_fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
    if [ "$root_fstype" = "erofs" ]; then
      exit 0
    fi
    cat >> /etc/environment <<'etcEnvironmentEOF'

    \(lines.joined(separator: "\n"))
    etcEnvironmentEOF
    """
    }

    static func makeVSCodePatchEtcProfileCommand() -> String {
        """
    root_fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
    if [ "$root_fstype" = "erofs" ]; then
      exit 0
    fi
    sed -i -E 's/((^|\\\\s)PATH=)([^\\\\$]*)$/\\\\1\\${PATH:-\\\\3}/g' /etc/profile || true
    """
    }

    static func makeVSCodeRuntimeEnvironment(user: String, home: String, shell: String) -> [String: String] {
        [
            "HOME": home.isEmpty ? "/root" : home,
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "SHELL": shell.isEmpty ? "/bin/sh" : shell,
            "USER": user.isEmpty ? "root" : user
        ]
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private struct VSCodeRootShellCommandResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private func ensureVSCodeRootState(
        client: InitChannelClient,
        instanceName: String,
        runtimeHome: String,
        runtimeUser: String,
        runtimeShell: String
    ) {
        let rootEnv = Self.makeVSCodeRuntimeEnvironment(
            user: runtimeUser,
            home: runtimeHome,
            shell: runtimeShell
        )
        let environmentMarker = "/var/devcontainer/.patchEtcEnvironmentMarker"
        let profileMarker = "/var/devcontainer/.patchEtcProfileMarker"

        do {
            let prepare = try runVSCodeRootCommand(
                client: client,
                command: Self.makeVSCodeRuntimeStateDirectoriesCommand(),
                timeoutMs: 2_000
            )
            guard prepare.exitCode == 0 else {
                logger.log("root_state_prepare_failed", fields: [
                    "instance": instanceName,
                    "exit_code": String(prepare.exitCode),
                    "stderr": Self.nonEmpty(prepare.stderr) ?? Self.nonEmpty(prepare.stdout) ?? "unknown"
                ])
                return
            }
            logger.log("vscode_runtime_state_dirs_ensured", fields: [
                "instance": instanceName,
                "scope": "root",
                "home": runtimeHome,
                "devcontainer_dir": "/var/devcontainer"
            ])
        } catch {
            logger.log("root_state_prepare_failed", fields: [
                "instance": instanceName,
                "error": String(describing: error)
            ])
            return
        }

        ensureVSCodeRootPatch(
            client: client,
            instanceName: instanceName,
            markerPath: environmentMarker,
            patchCommand: Self.makeVSCodePatchEtcEnvironmentCommand(env: rootEnv),
            logName: "patchEtcEnvironment"
        )
        ensureVSCodeRootPatch(
            client: client,
            instanceName: instanceName,
            markerPath: profileMarker,
            patchCommand: Self.makeVSCodePatchEtcProfileCommand(),
            logName: "patchEtcProfile"
        )
    }

    private func ensureVSCodeRootPatch(
        client: InitChannelClient,
        instanceName: String,
        markerPath: String,
        patchCommand: String,
        logName: String
    ) {
        do {
            let exists = try runVSCodeRootCommand(
                client: client,
                command: "test -f \(Self.shellSingleQuote(markerPath))",
                timeoutMs: 2_000
            )
            if exists.exitCode == 0 {
                logger.log("vscode_root_patch_skipped", fields: [
                    "instance": instanceName,
                    "marker": markerPath,
                    "patch": logName,
                    "reason": "marker_exists"
                ])
                return
            }

            let create = try runVSCodeRootCommand(
                client: client,
                command: Self.makeVSCodeRootStateMarkerCreateCommand(location: markerPath),
                timeoutMs: 2_000
            )
            guard create.exitCode == 0 else {
                logger.log("root_patch_exec_failed", fields: [
                    "instance": instanceName,
                    "marker": markerPath,
                    "patch": logName,
                    "phase": "create_marker",
                    "exit_code": String(create.exitCode),
                    "stderr": Self.nonEmpty(create.stderr) ?? Self.nonEmpty(create.stdout) ?? "unknown"
                ])
                return
            }

            let patch = try runVSCodeRootCommand(
                client: client,
                command: patchCommand,
                timeoutMs: 4_000
            )
            guard patch.exitCode == 0 else {
                logger.log("root_patch_exec_failed", fields: [
                    "instance": instanceName,
                    "marker": markerPath,
                    "patch": logName,
                    "phase": "apply_patch",
                    "exit_code": String(patch.exitCode),
                    "stderr": Self.nonEmpty(patch.stderr) ?? Self.nonEmpty(patch.stdout) ?? "unknown"
                ])
                return
            }

            logger.log("vscode_root_patch_applied", fields: [
                "instance": instanceName,
                "marker": markerPath,
                "patch": logName
            ])
        } catch {
            logger.log("root_patch_exec_failed", fields: [
                "instance": instanceName,
                "marker": markerPath,
                "patch": logName,
                "error": String(describing: error)
            ])
        }
    }

    private func runVSCodeRootCommand(
        client: InitChannelClient,
        command: String,
        timeoutMs: Int
    ) throws -> VSCodeRootShellCommandResult {
        let response = try client.send(InitChannelRequest(
            op: "exec",
            argv: ["/bin/sh", "-lc", command],
            runAsRoot: true,
            timeoutMs: timeoutMs
        ))
        return VSCodeRootShellCommandResult(
            exitCode: response.exitCode ?? (response.ok ? 0 : 1),
            stdout: response.stdout ?? "",
            stderr: response.stderr ?? response.error?.message ?? ""
        )
    }

    private func ensureGuestTransportReadyViaExec(
        client: InitChannelClient,
        topology: VMNetNetworkTopology?
    ) -> (ok: Bool, error: String?) {
        let script = Self.makeGuestTransportReadyScript(topology: topology)

        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                runAsRoot: true,
                timeoutMs: 8_000
            ))
            if response.ok, (response.exitCode ?? 1) == 0 {
                return (true, nil)
            }
            let error = response.error?.message ?? response.stderr ?? "missing default route or global ipv4/ipv6 address"
            return (false, "network transport unavailable: \(error)")
        } catch {
            return (false, "network transport bootstrap init_channel error: \(error)")
        }
    }

    private func ensureRootVSCodeServerDirectories(client: InitChannelClient, instanceName: String) {
        let runtime = instanceRegistry.context(for: instanceName).runtimeUser
        let runtimeHome = runtime?.home ?? "/root"
        let runtimeUser = runtime?.name ?? "root"
        let runtimeShell = runtime?.shell ?? "/bin/sh"
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", Self.makeVSCodeServerDirectoriesCommand(home: runtimeHome)],
                runAsRoot: runtimeUser == "root",
                timeoutMs: 2_000
            ))
            let exitCode = response.exitCode ?? 0
            if response.ok, exitCode == 0 {
                logger.log("vscode_server_dirs_ensured", fields: [
                    "instance": instanceName,
                    "scope": runtimeUser,
                    "home": runtimeHome
                ])
            } else {
                logger.log("vscode_server_dirs_ensure_failed", fields: [
                    "instance": instanceName,
                    "scope": runtimeUser,
                    "home": runtimeHome,
                    "exit_code": String(exitCode),
                    "error": response.error?.message ?? response.stderr ?? "unknown"
                ])
            }
        } catch {
            logger.log("vscode_server_dirs_ensure_failed", fields: [
                "instance": instanceName,
                "scope": runtimeUser,
                "home": runtimeHome,
                "error": String(describing: error)
            ])
        }
        ensureVSCodeRootState(
            client: client,
            instanceName: instanceName,
            runtimeHome: runtimeHome,
            runtimeUser: runtimeUser,
            runtimeShell: runtimeShell
        )
    }

    private func housekeepingClient(for instanceName: String) -> InitChannelClient? {
        let context = instanceRegistry.context(for: instanceName)
        return context.housekeepingClient
    }

    private func scheduleBackgroundDNSReconcile(instanceName: String, source: String) {
        housekeepingQueue.async { [weak self] in
            guard let self else { return }
            if self.backgroundDNSReconcileRunning {
                self.backgroundDNSReconcilePendingSource = source
                self.logger.log("housekeeping_exec_skipped", fields: [
                    "instance": instanceName,
                    "request_source": "housekeeping",
                    "kind": "dns_reconcile",
                    "reason": "coalesced",
                    "source": source
                ])
                return
            }
            self.backgroundDNSReconcileRunning = true
            defer {
                self.backgroundDNSReconcileRunning = false
                if let pendingSource = self.backgroundDNSReconcilePendingSource {
                    self.backgroundDNSReconcilePendingSource = nil
                    self.scheduleBackgroundDNSReconcile(instanceName: instanceName, source: pendingSource)
                }
            }

            self.logger.log("housekeeping_exec_started", fields: [
                "instance": instanceName,
                "request_source": "housekeeping",
                "kind": "dns_reconcile",
                "source": source
            ])
            let response = self.handleDNSReconcile(RuntimeControlRequest(
                op: "dns_reconcile",
                instance: instanceName,
                dnsSource: source
            ))
            if !response.ok {
                self.logger.log("dns_reconcile_deferred", fields: [
                    "instance": instanceName,
                    "request_source": "housekeeping",
                    "source": source,
                    "error": response.error ?? "unknown"
                ])
            }
        }
    }

    private func startDNSMonitorLoop() {
        stopDNSMonitorLoop()
        let source = DispatchSource.makeTimerSource(queue: housekeepingQueue)
        source.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let instanceName = self.currentRuntimeInstanceName()
            let meta = self.currentDNSMetaSnapshot(instanceName: instanceName)
            if meta["dns_mode"] == "unmanaged" {
                return
            }
            let snapshot = HostResolverSnapshotProvider().capture()
            if self.lastHostResolverSnapshotHash == nil {
                self.lastHostResolverSnapshotHash = snapshot.hash
                return
            }
            if self.lastHostResolverSnapshotHash != snapshot.hash {
                self.scheduleBackgroundDNSReconcile(instanceName: instanceName, source: "host_change")
                self.lastHostResolverSnapshotHash = snapshot.hash
                return
            }
            let now = nowEpochMs()
            let lastReconcileMs = Int64(meta["last_reconcile_epoch_ms"] ?? "0") ?? 0
            if now - lastReconcileMs >= 60_000 {
                self.scheduleBackgroundDNSReconcile(instanceName: instanceName, source: "stale_guard")
            }
        }
        source.resume()
        dnsMonitorTimer = source
    }

    private func stopDNSMonitorLoop() {
        dnsMonitorTimer?.cancel()
        dnsMonitorTimer = nil
    }

    private func applyDNSReconcileLegacy(client: InitChannelClient, policy: ResolvedDNSPolicy) -> (ok: Bool, error: String?) {
        var lines: [String] = [
            "# Generated by msl (step21)",
            "# mode: \(policy.mode.rawValue)"
        ]
        for ns in policy.nameservers {
            lines.append("nameserver \(ns)")
        }
        if !policy.searchDomains.isEmpty {
            lines.append("search \(policy.searchDomains.joined(separator: " "))")
        }
        let payload = lines
            .map { $0.replacingOccurrences(of: "'", with: "'\\''") }
            .joined(separator: "\\n")
        let writeCmd = "tmp=/etc/resolv.conf.msl.tmp; printf '%b\\n' '\(payload)' > \\\"$tmp\\\"; mv \\\"$tmp\\\" /etc/resolv.conf"
        let script = """
        set -eu
        if command -v sudo >/dev/null 2>&1; then
          sudo -n sh -c '\(writeCmd)'
        elif command -v su >/dev/null 2>&1; then
          su -c '\(writeCmd)'
        else
          sh -c '\(writeCmd)'
        fi
        """

        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                timeoutMs: 4_000
            ))
            if response.ok, (response.exitCode ?? 1) == 0 {
                return (true, nil)
            }
            return (false, response.error?.message ?? response.stderr ?? "legacy dns apply failed")
        } catch {
            return (false, String(describing: error))
        }
    }

    private func runDNSHealthcheckLegacy(client: InitChannelClient) -> (ok: Bool, error: String?) {
        let script = """
        set -eu
        for domain in www.msftconnecttest.com archive.ubuntu.com dl-cdn.alpinelinux.org; do
          if getent hosts "$domain" >/dev/null 2>&1; then
            exit 0
          fi
        done
        exit 1
        """
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                timeoutMs: 2_000
            ))
            if response.ok, (response.exitCode ?? 1) == 0 {
                return (true, nil)
            }
            return (false, response.error?.message ?? response.stderr ?? "dns healthcheck failed")
        } catch {
            return (false, String(describing: error))
        }
    }

    // MARK: - Instance Status / Stop

    private func handleInstanceList() -> RuntimeControlResponse {
        do {
            let state = try lock.withExclusiveLock(timeoutSec: 2) { try store.loadState() }
            let fallback = RuntimeInstanceState(
                instance: state.distro,
                vmState: state.vmState,
                activeSessionCount: state.activeSessionCount,
                idleTimer: state.idleTimer,
                runtimeUser: state.runtimeUser,
                initChannel: state.initChannel,
                runtimeHostPid: state.runtimeHostPid,
                runtimeControlSocket: state.runtimeControlSocket,
                lastError: nil,
                lastTransitionEpochMs: state.lastTransitionEpochMs
            )
            let entries = (state.instances?.isEmpty == false ? state.instances! : [fallback]).sorted {
                $0.instance < $1.instance
            }
            let items = entries.map { entry in
                RuntimeInstanceStatusItem(
                    instance: entry.instance,
                    vmState: entry.vmState.rawValue,
                    activeSessionCount: entry.activeSessionCount,
                    idleTimerArmed: entry.idleTimer.armed,
                    idleDeadlineEpochMs: entry.idleTimer.deadlineEpochMs,
                    runtimeHostPid: entry.runtimeHostPid,
                    lastError: entry.lastError,
                    lastTransitionEpochMs: entry.lastTransitionEpochMs
                )
            }
            return RuntimeControlResponse(ok: true, instances: items)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleInstanceStatus(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        let list = handleInstanceList()
        guard list.ok else { return list }
        guard let instance = request.instance?.trimmingCharacters(in: .whitespacesAndNewlines), !instance.isEmpty else {
            return RuntimeControlResponse(ok: false, error: "instance_required")
        }
        let matched = list.instances?.filter { $0.instance == instance } ?? []
        if matched.isEmpty {
            return RuntimeControlResponse(ok: false, error: "instance_not_found: \(instance)")
        }
        return RuntimeControlResponse(ok: true, instances: matched)
    }

    private func handleInstanceStop(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        let instanceName = currentRuntimeInstanceName()
        let running = runningInstanceNames()

        if request.all == true {
            if running.isEmpty {
                return RuntimeControlResponse(ok: true, meta: ["stopped_count": "0"])
            }
            for target in running where target != instanceName {
                let context = instanceRegistry.context(for: target)
                guard context.lifecycleState == .running else { continue }
                disarmIdleTimer(for: target)
                stopInstanceRuntime(instanceName: target, reason: "explicit_stop_all")
            }
            if instanceRegistry.context(for: instanceName).lifecycleState == .running {
                return scheduleDaemonStop(reason: "explicit_stop_all", resolvedInstance: instanceName)
            }
            stopSemaphore.signal()
            return RuntimeControlResponse(ok: true, meta: ["stopped_count": String(running.count)])
        }

        switch StopTargetResolver.resolve(
            explicitInstance: request.instance,
            runningInstances: running,
            callerCwd: request.callerCwd,
            launchOrigins: launchOriginTracker.snapshot()
        ) {
        case .success(let target):
            logger.log("daemon_stop_target_resolved", fields: [
                "target": target,
                "caller_cwd": request.callerCwd ?? "",
                "running": running.joined(separator: ",")
            ])
            if target != instanceName {
                let context = instanceRegistry.context(for: target)
                guard context.lifecycleState == .running else {
                    return RuntimeControlResponse(ok: false, error: "instance_not_running: \(target)")
                }
                disarmIdleTimer(for: target)
                stopInstanceRuntime(instanceName: target, reason: "explicit_stop")
                return RuntimeControlResponse(ok: true, meta: ["stopped_instance": target])
            }
            let remainingRunning = running.filter { $0 != target }
            if !remainingRunning.isEmpty {
                disarmIdleTimer(for: target)
                stopInstanceRuntime(instanceName: target, reason: "explicit_stop")
                if let promoted = remainingRunning.first(where: { instanceRegistry.context(for: $0).lifecycleState == .running }) {
                    promotePrimaryRuntime(to: promoted)
                }
                return RuntimeControlResponse(ok: true, meta: ["stopped_instance": target])
            }
            return scheduleDaemonStop(reason: "explicit_stop", resolvedInstance: target)

        case .failure(.noRunningInstances):
            return RuntimeControlResponse(ok: true, meta: ["stopped_count": "0"])

        case .failure(.targetNotRunning(let target)):
            return RuntimeControlResponse(ok: false, error: "instance_not_running: \(target)")

        case .failure(.ambiguous(let candidates)):
            logger.log("daemon_stop_target_ambiguous", fields: [
                "caller_cwd": request.callerCwd ?? "",
                "candidates": candidates.joined(separator: ",")
            ])
            return RuntimeControlResponse(
                ok: false,
                error: "stop_target_ambiguous: specify --instance (candidates=\(candidates.joined(separator: ",")))"
            )
        }
    }

    private func scheduleDaemonStop(reason: String, resolvedInstance: String) -> RuntimeControlResponse {
        logger.log("daemon_stopping", fields: [
            "reason": reason,
            "instance": resolvedInstance
        ])
        publishInstanceStateEvent(instance: resolvedInstance, state: "Stopping", reason: reason)
        logRouter.logVM(
            instance: resolvedInstance,
            event: "daemon_instance_stop_start",
            fields: ["op": "stop", "result": "started", "reason": reason]
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.stopSemaphore.signal()
        }
        return RuntimeControlResponse(ok: true, meta: ["stopped_instance": resolvedInstance])
    }

    private func runningInstanceNames() -> [String] {
        do {
            let state = try lock.withExclusiveLock(timeoutSec: 2) { try store.loadState() }
            var result = Set<String>()
            if state.vmState == .running {
                result.insert(state.distro)
            }
            for entry in state.instances ?? [] where entry.vmState == .running {
                result.insert(entry.instance)
            }
            return Array(result).sorted()
        } catch {
            if let activeInstanceName, instanceRegistry.context(for: activeInstanceName).lifecycleState == .running {
                return [activeInstanceName]
            }
            return []
        }
    }

    // MARK: - Idle Timer

    private func armIdleTimer(for instanceName: String) {
        disarmIdleTimer(for: instanceName)
        let timeoutMs = resolveIdleTimeoutMs()
        logger.log("idle_timer_armed", fields: ["timeout_ms": String(timeoutMs), "instance": instanceName])

        let source = DispatchSource.makeTimerSource(queue: idleTimerQueue)
        source.schedule(deadline: .now() + .milliseconds(Int(timeoutMs)))
        source.setEventHandler { [weak self] in
            self?.handleIdleExpiry(instanceName: instanceName)
        }
        source.resume()
        idleTimerSources[instanceName] = source
    }

    private func disarmIdleTimer(for instanceName: String) {
        idleTimerSources[instanceName]?.cancel()
        idleTimerSources[instanceName] = nil
    }

    private func disarmAllIdleTimers() {
        for (_, source) in idleTimerSources {
            source.cancel()
        }
        idleTimerSources.removeAll()
    }

    private func handleIdleExpiry(instanceName: String) {
        do {
            let shouldStop = try lock.withExclusiveLock { () -> Bool in
                let alive = try sessions.reconcile()
                let aliveForInstance = alive.filter { $0.instance == instanceName }
                if !aliveForInstance.isEmpty {
                    // Sessions appeared, cancel
                    var state = try store.loadState()
                    let targetIdle = IdleTimerState(armed: false, deadlineEpochMs: nil)
                    if instanceName == currentRuntimeInstanceName() {
                        state.activeSessionCount = aliveForInstance.count
                        state.idleTimer = targetIdle
                    }
                    let targetEntry = state.instances?.first(where: { $0.instance == instanceName })
                    upsertInstanceState(
                        &state,
                        instanceName: instanceName,
                        lifecycleState: .running,
                        activeSessionCount: aliveForInstance.count,
                        idleTimer: targetIdle,
                        runtimeHostPid: targetEntry?.runtimeHostPid ?? state.runtimeHostPid,
                        runtimeControlSocket: targetEntry?.runtimeControlSocket ?? state.runtimeControlSocket,
                        runtimeUser: targetEntry?.runtimeUser,
                        initChannel: targetEntry?.initChannel ?? state.initChannel,
                        lastError: nil
                    )
                    try store.saveState(state)
                    return false
                }
                return true
            }
            if shouldStop {
                if instanceName == currentRuntimeInstanceName() {
                    logger.log("daemon_stopping", fields: ["reason": "idle_timeout", "instance": instanceName])
                    stopSemaphore.signal()
                } else {
                    stopInstanceRuntime(instanceName: instanceName, reason: "idle_timeout")
                }
            }
        } catch {
            logger.log("idle_timer_check_error", fields: ["error": String(describing: error)])
        }
    }

    // MARK: - Shutdown

    private func stopInstanceRuntime(instanceName: String, reason: String) {
        let context = instanceRegistry.context(for: instanceName)
        let metadataURL = context.metadataURL
        context.lifecycleState = .stopping
        context.vmRunner?.stopRunningVM()
        resetTmpStorageAfterStop(
            metadataURL: metadataURL,
            instanceName: instanceName
        )
        context.vmRunner = nil
        context.initClient = nil
        context.initWriteClient = nil
        context.initReadClient = nil
        context.housekeepingClient = nil
        context.runtimeUser = nil
        context.networkTopology = nil
        context.lifecycleState = .stopped
        context.lastError = nil
        context.clearBootError()
        if let attachedDaemon = attachedContainerDaemons.removeValue(forKey: instanceName) {
            attachedDaemon.stop()
        }

        do {
            try lock.withExclusiveLock {
                var state = try store.loadState()
                let idle = IdleTimerState(armed: false, deadlineEpochMs: nil)
                if instanceName == currentRuntimeInstanceName() {
                    state.vmState = .stopped
                    state.activeSessionCount = 0
                    state.idleTimer = idle
                    state.lastTransitionEpochMs = nowEpochMs()
                    state.runtimeHostPid = nil
                    state.runtimeControlSocket = nil
                    state.runtimeUser = nil
                }
                upsertInstanceState(
                    &state,
                    instanceName: instanceName,
                    lifecycleState: .stopped,
                    activeSessionCount: 0,
                    idleTimer: idle,
                    runtimeHostPid: nil,
                    runtimeControlSocket: nil,
                    runtimeUser: nil,
                    initChannel: nil,
                    lastError: nil
                )
                try store.saveState(state)
            }
        } catch {
            logger.log("instance_stop_state_update_failed", fields: [
                "instance": instanceName,
                "reason": reason,
                "error": String(describing: error)
            ])
        }
        logRouter.logVM(
            instance: instanceName,
            event: "daemon_instance_stop_done",
            fields: ["op": "stop", "result": "ok", "reason": reason]
        )
        reconcileHostManagedHostnames(reason: reason)
        publishInstanceStateEvent(instance: instanceName, state: "Stopped", reason: reason)
    }

    private func promotePrimaryRuntime(to instanceName: String) {
        let context = instanceRegistry.context(for: instanceName)
        activeInstanceName = instanceName
        runtimeMetadataURL = context.metadataURL
        vmRunner = context.vmRunner
        initClient = context.initClient

        do {
            try lock.withExclusiveLock {
                var state = try store.loadState()
                state.distro = instanceName
                state.vmState = .running
                state.lastTransitionEpochMs = nowEpochMs()
                state.runtimeHostPid = Int32(getpid())
                state.runtimeControlSocket = paths.runtimeControlSocketFile.path
                state.daemonHostPid = Int32(getpid())
                state.daemonControlSocket = paths.runtimeControlSocketFile.path
                state.daemonEventSocket = paths.runtimeEventSocketFile.path
                if let entry = state.instances?.first(where: { $0.instance == instanceName }) {
                    state.activeSessionCount = entry.activeSessionCount
                    state.idleTimer = entry.idleTimer
                    state.runtimeUser = entry.runtimeUser
                }
                try store.saveState(state)
            }
        } catch {
            logger.log("primary_instance_promote_failed", fields: [
                "instance": instanceName,
                "error": String(describing: error)
            ])
        }
    }

    private func shutdown() {
        unregisterWorkerWithManagerIfNeeded(instanceName: currentRuntimeInstanceName())
        stopDNSMonitorLoop()
        stopAutoPortForwardLoop()
        stopMemoryReclaimLoop()
        disarmAllIdleTimers()
        sshListener?.stop()
        sshListener = nil
        sshInfo = nil
        controlServer?.stop()
        eventBus?.stop()
        for daemon in attachedContainerDaemons.values {
            daemon.stop()
        }
        attachedContainerDaemons.removeAll()
        forwarder?.stopAll()
        if let activeInstanceName {
            instanceRegistry.context(for: activeInstanceName).lifecycleState = .stopping
        }
        vmRunner?.stopRunningVM()
        if let activeInstanceName {
            let context = instanceRegistry.context(for: activeInstanceName)
            context.lifecycleState = .stopped
            context.vmRunner = nil
            context.initClient = nil
            context.runtimeUser = nil
            context.networkTopology = nil
            context.lastError = nil
        }
        reconcileHostManagedHostnames(reason: "daemon_shutdown")
        updateStateStopped()
        logger.log("daemon_stopped")
    }

    private func registerWorkerWithManagerIfNeeded(
        instanceName: String,
        controlSocketPath: String,
        eventSocketPath: String,
        sshInfo: LocalhostSSHInfo?
    ) {
        guard let managerSocketPath = ProcessInfo.processInfo.environment["MSL_MANAGER_SOCKET"],
              !managerSocketPath.isEmpty else {
            return
        }
        let client = ManagerControlClient(socketPath: managerSocketPath)
        let response = try? client.send(
            ManagerControlRequest(
                op: "worker_register",
                instance: instanceName,
                pid: Int32(getpid()),
                runtimeRoot: paths.runtimeRoot.path,
                controlSocketPath: controlSocketPath,
                eventSocketPath: eventSocketPath,
                sshInfo: sshInfo,
                sshListenerState: sshInfo == nil ? "error" : "running",
                sshLastErrorMessage: sshInfo == nil ? "ssh listener did not start" : nil,
                lifecycleState: .running
            )
        )
        if response?.ok != true {
            logger.log("worker_register_failed", fields: [
                "instance": instanceName,
                "error": response?.error ?? "unknown"
            ])
        }
    }

    private func unregisterWorkerWithManagerIfNeeded(instanceName: String) {
        guard let managerSocketPath = ProcessInfo.processInfo.environment["MSL_MANAGER_SOCKET"],
              !managerSocketPath.isEmpty else {
            return
        }
        let client = ManagerControlClient(socketPath: managerSocketPath)
        _ = try? client.send(
            ManagerControlRequest(
                op: "worker_unregister",
                instance: instanceName
            )
        )
    }

    private func updateStateStopped(lastError: String? = nil, clearError: Bool? = nil) {
        do {
            try lock.withExclusiveLock {
                var state = try store.loadState()
                let instanceName = currentRuntimeInstanceName()
                let shouldClearError = clearError ?? (lastError == nil)
                state.vmState = .stopped
                state.lifecycleState = shouldClearError ? .stopped : .error
                state.activeSessionCount = 0
                state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                state.lastTransitionEpochMs = nowEpochMs()
                state.runtimeHostPid = nil
                state.runtimeControlSocket = nil
                state.daemonHostPid = nil
                state.daemonControlSocket = nil
                state.daemonEventSocket = nil
                state.runtimeUser = nil
                if shouldClearError {
                    state.startupEpochMs = nil
                    state.startupStep = nil
                    state.startupStepName = nil
                    state.startupStepStatus = nil
                    state.lastErrorCode = nil
                    state.lastErrorMessage = nil
                } else {
                    state.lastErrorMessage = lastError
                }
                upsertInstanceState(
                    &state,
                    instanceName: instanceName,
                    lifecycleState: shouldClearError ? .stopped : .error,
                    activeSessionCount: 0,
                    idleTimer: state.idleTimer,
                    runtimeHostPid: nil,
                    runtimeControlSocket: nil,
                    runtimeUser: nil,
                    initChannel: state.initChannel,
                    lastError: shouldClearError ? nil : lastError,
                    lastErrorCode: shouldClearError ? nil : state.lastErrorCode,
                    lastErrorMessage: shouldClearError ? nil : state.lastErrorMessage,
                    startupEpochMs: state.startupEpochMs,
                    startupStep: state.startupStep,
                    startupStepName: state.startupStepName,
                    startupStepStatus: shouldClearError ? nil : state.startupStepStatus
                )
                try store.saveState(state)
                try sessions.clearAllAndTerminate()
            }
        } catch {
            logger.log("daemon_state_cleanup_error", fields: ["error": String(describing: error)])
        }
        if let activeInstanceName {
            let context = instanceRegistry.context(for: activeInstanceName)
            context.lifecycleState = .stopped
            context.clearBootError()
        }
        let instanceName = currentRuntimeInstanceName()
        logRouter.logVM(
            instance: instanceName,
            event: "daemon_instance_stop_done",
            fields: ["op": "stop", "result": "ok"]
        )
        publishInstanceStateEvent(instance: instanceName, state: "Stopped", reason: "daemon_shutdown")
    }

    private func ensureAttachedContainerDaemonStarted(instanceName: String) throws {
        if let existing = attachedContainerDaemons[instanceName] {
            try existing.start()
            logger.log("daemon_attached_socket_started", fields: [
                "path": existing.socketPath,
                "instance": instanceName
            ])
            return
        }

        let attachedDaemon = AttachedContainerDaemon(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: executablePath,
            explicitInstanceName: instanceName,
            distributionManager: distributionManager
        )
        try attachedDaemon.start()
        attachedContainerDaemons[instanceName] = attachedDaemon
        logger.log("daemon_attached_socket_started", fields: [
            "path": attachedDaemon.socketPath,
            "instance": instanceName
        ])
    }

    private func convergeRuntimeUser(
        client: InitChannelClient,
        metadataURL: URL,
        instanceName: String
    ) throws -> ConvergedRuntimeUserResult {
        let policy = try distributionManager.resolveUserConvergencePolicy(metadataURL: metadataURL)
        let hostUser = resolveHostUserContext(policy: policy, instanceName: instanceName)

        logger.log("user_convergence_started", fields: [
            "instance": instanceName,
            "metadata": metadataURL.path,
            "template_id": policy.templateId,
            "command_family": policy.commandFamily,
            "username": hostUser.username,
            "uid": String(hostUser.uid),
            "gid": String(hostUser.gid)
        ])

        let response = try client.convergeUser(
            spec: hostUser,
            policy: policy,
            instanceName: instanceName,
            timeoutMs: 20_000
        )
        guard response.ok else {
            let code = response.error?.code.rawValue ?? "internal_error"
            let message = response.error?.message ?? "converge_user failed"
            throw MSLRuntimeError("user convergence failed (\(code)): \(message)")
        }

        let meta = response.meta ?? [:]
        let name = meta["resolved_user"] ?? hostUser.username
        let uid = Int(meta["resolved_uid"] ?? "") ?? hostUser.uid
        let gid = Int(meta["resolved_gid"] ?? "") ?? hostUser.gid
        let home = meta["resolved_home"] ?? hostUser.home
        let shell = meta["resolved_shell"] ?? (policy.shellFallbacks.first ?? "/bin/sh")
        let resolvedTemplateID = meta["policy_template_id"] ?? policy.templateId

        if let warnings = meta["warnings"], !warnings.isEmpty {
            logger.log("user_convergence_degraded", fields: [
                "instance": instanceName,
                "warnings": warnings
            ])
        }
        logger.log("user_convergence_succeeded", fields: [
            "instance": instanceName,
            "resolved_user": name,
            "resolved_uid": String(uid),
            "resolved_gid": String(gid),
            "resolved_shell": shell,
            "template_id": resolvedTemplateID
        ])
        logger.log("runtime_user_selected", fields: [
            "instance": instanceName,
            "username": name,
            "uid": String(uid),
            "gid": String(gid),
            "home": home,
            "shell": shell
        ])

        let runtimeUser = RuntimeUserState(
            name: name,
            uid: uid,
            gid: gid,
            home: home,
            shell: shell,
            policyTemplateID: resolvedTemplateID,
            lastConvergedEpochMs: nowEpochMs()
        )
        return ConvergedRuntimeUserResult(runtimeUser: runtimeUser, adminGroup: policy.adminGroup)
    }

    private func resolveHostUserContext(
        policy: UserConvergencePolicy,
        instanceName: String
    ) -> InitConvergeUserSpec {
        let env = ProcessInfo.processInfo.environment
        let forceRoot = env["MSL_RUNTIME_USER_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let forceRootRequested = forceRoot == "1" || forceRoot == "true" || forceRoot == "yes"
        let forceRootAll = env["MSL_RUNTIME_USER_ROOT_SCOPE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "all"
        let internalInstance = distributionManager.isReservedInternalInstanceName(instanceName)

        if forceRootRequested && (internalInstance || forceRootAll) {
            return InitConvergeUserSpec(
                username: "root",
                uid: 0,
                gid: 0,
                home: "/root",
                preferredShell: "/bin/sh",
                failOnUIDConflict: false
            )
        }
        if forceRootRequested && !internalInstance && !forceRootAll {
            logger.log("runtime_user_force_root_ignored", fields: [
                "instance": instanceName,
                "reason": "non_internal_instance",
                "hint": "set MSL_RUNTIME_USER_ROOT_SCOPE=all to force root for all instances"
            ])
        }
        let envUser = env["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = (envUser?.isEmpty == false ? envUser! : NSUserName())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeUser = userName.isEmpty ? "msl" : userName
        let home = "/home/\(safeUser)"
        let preferredShell = policy.shellFallbacks.first

        return InitConvergeUserSpec(
            username: safeUser,
            uid: Int(getuid()),
            gid: Int(getgid()),
            home: home,
            preferredShell: preferredShell,
            failOnUIDConflict: true
        )
    }

    // MARK: - Helpers

    private func startAutoPortForwardLoop() {
        stopAutoPortForwardLoop()

        let timer = DispatchSource.makeTimerSource(queue: housekeepingQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.syncAutoPortMappingsTick()
        }
        timer.resume()
        autoPortTimer = timer

        housekeepingQueue.async { [weak self] in
            self?.syncAutoPortMappingsTick()
        }
    }

    private func autoPortProbeClient() -> InitChannelClient? {
        let instanceName = currentRuntimeInstanceName()
        let context = instanceRegistry.context(for: instanceName)
        return context.housekeepingClient
    }

    private func stopAutoPortForwardLoop() {
        autoPortTimer?.cancel()
        autoPortTimer = nil
        portMappingsSnapshotLock.lock()
        autoPortErrorsByHostPort.removeAll()
        portMappingsSnapshotLock.unlock()
        autoPortNextAllowedEpochMs = 0
    }

    private func syncAutoPortMappingsTick() {
        let now = nowEpochMs()
        if now < autoPortNextAllowedEpochMs {
            return
        }
        guard let client = autoPortProbeClient() else {
            logger.log("auto_port_probe_deferred", fields: [
                "instance": currentRuntimeInstanceName(),
                "request_source": "housekeeping",
                "reason": "housekeeping_client_unavailable"
            ])
            return
        }
        guard let autoHostPorts = probeAutoForwardHostPorts(client: client) else {
            autoPortNextAllowedEpochMs = now + 5_000
            return
        }
        autoPortNextAllowedEpochMs = 0
        syncEffectivePortMappings(autoHostPorts: autoHostPorts, reason: "auto_probe")
    }

    private func schedulePortMappingsRefresh(reason: String) {
        housekeepingQueue.async { [weak self] in
            guard let self else { return }
            if let client = self.autoPortProbeClient(),
               let autoHostPorts = self.probeAutoForwardHostPorts(client: client) {
                self.autoPortNextAllowedEpochMs = 0
                self.syncEffectivePortMappings(autoHostPorts: autoHostPorts, reason: reason)
                return
            }
            self.logger.log("auto_port_probe_deferred", fields: [
                "instance": self.currentRuntimeInstanceName(),
                "request_source": "housekeeping",
                "reason": "housekeeping_client_unavailable",
                "trigger": reason
            ])
            let current = self.currentEffectivePortMappingsSnapshot()
            self.syncEffectivePortMappings(autoHostPorts: current.autoHostPorts, reason: reason)
        }
    }

    private func syncEffectivePortMappings(autoHostPorts: Set<Int>, reason: String) {
        guard let fw = forwarder else {
            return
        }

        let manualMappings: [PortMapping]
        let instanceName = currentRuntimeInstanceName()
        do {
            manualMappings = try lock.withExclusiveLock(timeoutSec: 1) {
                try store.loadPortMappings().mappings
                    .filter { $0.instance == instanceName }
            }
        } catch {
            logger.log("daemon_port_preload_failed", fields: ["error": String(describing: error)])
            return
        }

        let previous = currentEffectivePortMappingsSnapshot()
        let effective = AutoPortForwardingPlanner.merge(
            manualMappings: manualMappings,
            autoHostPorts: autoHostPorts,
            instanceName: instanceName
        )
        setEffectivePortMappingsSnapshot(effective)

        let result = fw.sync(mappings: effective.mappings)
        logAutoPortDiff(previous: previous, current: effective, statusItems: result.items ?? [], reason: reason)
    }

    private func probeAutoForwardHostPorts(client: InitChannelClient) -> Set<Int>? {
        do {
            logger.log("housekeeping_exec_started", fields: [
                "instance": currentRuntimeInstanceName(),
                "request_source": "housekeeping",
                "kind": "auto_port_probe"
            ])
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/proc/net/tcp"],
                timeoutMs: 1_500
            ))
            guard response.ok else {
                logger.log("auto_port_probe_failed", fields: [
                    "reason": response.error?.message ?? "exec_failed"
                ])
                return nil
            }
            return GuestListeningPortDetector.discoverableHostPorts(fromProcNetTCP: response.stdout ?? "")
        } catch {
            logger.log("auto_port_probe_failed", fields: ["reason": String(describing: error)])
            return nil
        }
    }

    private func logAutoPortDiff(
        previous: EffectivePortMappings,
        current: EffectivePortMappings,
        statusItems: [RuntimePortStatusItem],
        reason: String
    ) {
        let previousErrors: [Int: String]
        portMappingsSnapshotLock.lock()
        previousErrors = autoPortErrorsByHostPort
        portMappingsSnapshotLock.unlock()

        let added = current.autoHostPorts.subtracting(previous.autoHostPorts).sorted()
        for hostPort in added {
            logger.log("auto_port_detected", fields: [
                "hostPort": String(hostPort),
                "reason": reason
            ])
        }

        let removed = previous.autoHostPorts.subtracting(current.autoHostPorts).sorted()
        for hostPort in removed {
            logger.log("auto_port_removed", fields: [
                "hostPort": String(hostPort),
                "reason": reason
            ])
        }

        var nextErrors: [Int: String] = [:]
        for item in statusItems where current.autoHostPorts.contains(item.hostPort) {
            guard let error = item.error, !error.isEmpty else {
                continue
            }
            nextErrors[item.hostPort] = error
            if previousErrors[item.hostPort] != error {
                logger.log("auto_port_conflict", fields: [
                    "hostPort": String(item.hostPort),
                    "guestPort": String(item.guestPort),
                    "error": error
                ])
            }
        }
        portMappingsSnapshotLock.lock()
        autoPortErrorsByHostPort = nextErrors
        portMappingsSnapshotLock.unlock()
    }

    private func currentEffectivePortMappingsSnapshot() -> EffectivePortMappings {
        portMappingsSnapshotLock.lock()
        defer { portMappingsSnapshotLock.unlock() }
        return effectivePortMappingsSnapshot
    }

    private func setEffectivePortMappingsSnapshot(_ snapshot: EffectivePortMappings) {
        portMappingsSnapshotLock.lock()
        effectivePortMappingsSnapshot = snapshot
        portMappingsSnapshotLock.unlock()
    }

    private func configureMemoryReclaimPolicy() {
        do {
            let config = try defaultInstanceStore.loadConfig()
            let resolution = MemoryReclaimPolicyResolver.resolve(config: config.memory)
            memoryReclaimPolicy = resolution.policy
            for warning in resolution.warnings {
                logger.log("memory_reclaim_policy_warning", fields: ["warning": warning])
            }
        } catch {
            memoryReclaimPolicy = .defaultPolicy
            logger.log("memory_reclaim_policy_warning", fields: [
                "warning": "failed_to_load_config",
                "error": String(describing: error)
            ])
        }
        logger.log("memory_reclaim_policy_resolved", fields: [
            "shortIdle": memoryReclaimPolicy.shortIdle.rawValue,
            "longIdle": memoryReclaimPolicy.longIdle.rawValue,
            "hostPressure": memoryReclaimPolicy.hostPressure.rawValue,
            "cacheCleanThresholdMB": String(memoryReclaimPolicy.cacheCleanThresholdMB),
            "cooldownDurationS": String(memoryReclaimPolicy.cacheCleanupCooldownMs / 1_000),
            "hysteresisPercent": String(memoryReclaimPolicy.cacheCleanupHysteresisPercent)
        ])
    }

    private func ensureGuestMSLCommandAlias(client: InitChannelClient) {
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: [
                    "/bin/sh",
                    "-lc",
                    "mkdir -p /usr/local/bin; ln -sf /usr/local/bin/msl-init /usr/local/bin/msl; ln -sf /usr/local/bin/msl-init /usr/local/bin/code"
                ],
                timeoutMs: 2_000
            ))
            guard response.ok else {
                logger.log("guest_msl_alias_ensure_failed", fields: [
                    "error": response.error?.message ?? "exec_failed"
                ])
                return
            }
            logger.log("guest_msl_alias_ensured")
        } catch {
            logger.log("guest_msl_alias_ensure_failed", fields: ["error": String(describing: error)])
        }
    }

    private func noteGuestActivity() {
        let now = nowEpochMs()
        reclaimStateQueue.sync {
            lastGuestActivityEpochMs = now
        }
    }

    private func isBackgroundMemoryMaintenanceSuspended(instanceName: String? = nil) -> Bool {
        let now = nowEpochMs()
        let activeInstance = instanceName ?? activeInstanceName ?? currentRuntimeInstanceName()
        let activeSessionCount: Int = (try? lock.withExclusiveLock(timeoutSec: 1) {
            let state = try store.loadState()
            return state.instances?.first(where: { $0.instance == activeInstance })?.activeSessionCount ?? 0
        }) ?? 0
        let lastActivity = reclaimStateQueue.sync { lastGuestActivityEpochMs }
        return MemoryReclaimPolicyResolver.shouldSuspendBackgroundMaintenance(
            activeSessionCount: activeSessionCount,
            nowMs: now,
            lastGuestActivityEpochMs: lastActivity
        )
    }

    private func startMemoryReclaimLoop() {
        stopMemoryReclaimLoop()
        reclaimStateQueue.sync {
            lastGuestActivityEpochMs = nowEpochMs()
            lastShortIdleReclaimEpochMs = nil
            lastLongIdleReclaimEpochMs = nil
            lastHostPressureReclaimEpochMs = nil
            lastCacheCapReclaimEpochMs = nil
            cacheOverCapActive = false
        }

        let timer = DispatchSource.makeTimerSource(queue: memoryReclaimQueue)
        timer.schedule(
            deadline: .now() + .seconds(MemoryReclaimPolicyResolver.periodicPollIntervalSec),
            repeating: .seconds(MemoryReclaimPolicyResolver.periodicPollIntervalSec)
        )
        timer.setEventHandler { [weak self] in
            self?.evaluateMemoryReclaimOnTimer()
        }
        timer.resume()
        memoryReclaimTimer = timer

#if canImport(Darwin)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: memoryReclaimQueue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let level: String
            if event.contains(.critical) {
                level = "critical"
            } else if event.contains(.warning) {
                level = "warning"
            } else {
                level = "unknown"
            }
            self.handleHostMemoryPressure(level: level)
        }
        source.resume()
        hostMemoryPressureSource = source
#endif
    }

    private func stopMemoryReclaimLoop() {
        memoryReclaimTimer?.cancel()
        memoryReclaimTimer = nil
#if canImport(Darwin)
        hostMemoryPressureSource?.cancel()
        hostMemoryPressureSource = nil
#endif
    }

    private func evaluateMemoryReclaimOnTimer() {
        if isBackgroundMemoryMaintenanceSuspended() {
            return
        }
        let now = nowEpochMs()
        let snapshot = reclaimStateQueue.sync { () -> (Int64, Int64?, Int64?, Int64?, Int64?) in
            (
                lastGuestActivityEpochMs,
                lastShortIdleReclaimEpochMs,
                lastLongIdleReclaimEpochMs,
                lastHostPressureReclaimEpochMs,
                lastCacheCapReclaimEpochMs
            )
        }
        let inactivityMs = now - snapshot.0

        if evaluateCacheCapReclaim(nowMs: now, lastCacheCapReclaimEpochMs: snapshot.4) {
            return
        }

        if MemoryReclaimPolicyResolver.shouldTriggerLongIdle(
            nowMs: now,
            lastGuestActivityEpochMs: snapshot.0,
            lastLongIdleReclaimEpochMs: snapshot.2
        ) {
            runMemoryReclaim(trigger: .longIdle, strategy: memoryReclaimPolicy.longIdle, inactivityMs: inactivityMs)
            return
        }

        guard inactivityMs >= MemoryReclaimPolicyResolver.shortIdleThresholdMs else {
            return
        }
        guard let isCPUIdle = sampleGuestCPUIdle() else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.shortIdle.rawValue,
                "reason": "cpu_idle_probe_failed"
            ])
            return
        }
        guard MemoryReclaimPolicyResolver.shouldTriggerShortIdle(
            nowMs: now,
            lastGuestActivityEpochMs: snapshot.0,
            lastShortIdleReclaimEpochMs: snapshot.1,
            isGuestCPUIdle: isCPUIdle
        ) else {
            return
        }

        runMemoryReclaim(trigger: .shortIdle, strategy: memoryReclaimPolicy.shortIdle, inactivityMs: inactivityMs)
    }

    private func evaluateCacheCapReclaim(nowMs: Int64, lastCacheCapReclaimEpochMs: Int64?) -> Bool {
        let cacheThresholdMB = memoryReclaimPolicy.cacheCleanThresholdMB
        guard let meminfo = sampleGuestMemInfo(),
              let cacheUsageKB = MemoryReclaimPolicyResolver.parseCacheUsageKB(meminfo) else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.cacheCap.rawValue,
                "reason": "cache_probe_failed"
            ])
            return false
        }

        let cacheUsageMB = cacheUsageKB / 1024
        let overCap = reclaimStateQueue.sync { () -> Bool in
            let next = MemoryReclaimPolicyResolver.isCacheOverCap(
                cacheUsageMB: cacheUsageMB,
                cacheCleanThresholdMB: cacheThresholdMB,
                hysteresisPercent: memoryReclaimPolicy.cacheCleanupHysteresisPercent,
                wasOverCap: cacheOverCapActive
            )
            cacheOverCapActive = next
            return next
        }
        logger.log("memory_reclaim_cache_eval", fields: [
            "cache_usage_mb": String(cacheUsageMB),
            "cache_clean_threshold_mb": String(cacheThresholdMB),
            "over_cap": overCap ? "1" : "0"
        ])
        guard overCap else {
            return false
        }

        guard let isCPUIdle = sampleGuestCPUIdle() else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.cacheCap.rawValue,
                "reason": "cpu_idle_probe_failed"
            ])
            return false
        }

        guard MemoryReclaimPolicyResolver.shouldTriggerCacheCap(
            nowMs: nowMs,
            lastCacheCapReclaimEpochMs: lastCacheCapReclaimEpochMs,
            isOverCap: overCap,
            isGuestCPUIdle: isCPUIdle,
            cooldownMs: memoryReclaimPolicy.cacheCleanupCooldownMs
        ) else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.cacheCap.rawValue,
                "reason": "cooldown_or_busy_cpu"
            ])
            return false
        }

        runMemoryReclaim(trigger: .cacheCap, strategy: .dropCaches, inactivityMs: nil)
        return true
    }

    private func handleHostMemoryPressure(level: String) {
        if isBackgroundMemoryMaintenanceSuspended() {
            return
        }
        let now = nowEpochMs()
        let shouldTrigger = reclaimStateQueue.sync {
            MemoryReclaimPolicyResolver.shouldTriggerHostPressure(
                nowMs: now,
                lastHostPressureReclaimEpochMs: lastHostPressureReclaimEpochMs
            )
        }
        guard shouldTrigger else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.hostPressure.rawValue,
                "reason": "cooldown",
                "level": level
            ])
            return
        }
        runMemoryReclaim(trigger: .hostPressure, strategy: memoryReclaimPolicy.hostPressure, inactivityMs: nil)
    }

    private func sampleGuestCPUIdle() -> Bool? {
        guard let client = initClient else {
            return nil
        }
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/proc/loadavg"],
                timeoutMs: 1_500
            ))
            guard response.ok, let stdout = response.stdout,
                  let load1 = MemoryReclaimPolicyResolver.parseLoadAverage1(stdout) else {
                return nil
            }
            return load1 < 0.20
        } catch {
            return nil
        }
    }

    private func sampleGuestMemInfo() -> String? {
        guard let client = initClient else {
            return nil
        }
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/proc/meminfo"],
                timeoutMs: 1_500
            ))
            guard response.ok, let stdout = response.stdout else {
                return nil
            }
            return stdout
        } catch {
            return nil
        }
    }

    private func runMemoryReclaim(
        trigger: MemoryReclaimTrigger,
        strategy: MemoryReclaimStrategy,
        inactivityMs: Int64?
    ) {
        let now = nowEpochMs()
        defer {
            reclaimStateQueue.sync {
                switch trigger {
                case .shortIdle:
                    lastShortIdleReclaimEpochMs = now
                case .longIdle:
                    lastLongIdleReclaimEpochMs = now
                case .hostPressure:
                    lastHostPressureReclaimEpochMs = now
                case .cacheCap:
                    lastCacheCapReclaimEpochMs = now
                case .manual:
                    break
                }
            }
        }

        let action: String?
        switch strategy {
        case .compact:
            action = "compact"
        case .dropCaches:
            action = "drop-cache"
        case .none:
            action = nil
        }

        guard let action else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": trigger.rawValue,
                "strategy": strategy.rawValue,
                "reason": "strategy_none"
            ])
            return
        }
        guard let client = initClient else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": trigger.rawValue,
                "strategy": strategy.rawValue,
                "reason": "init_channel_unavailable"
            ])
            return
        }

        logger.log("memory_reclaim_triggered", fields: [
            "trigger": trigger.rawValue,
            "strategy": strategy.rawValue,
            "inactivity_ms": inactivityMs.map(String.init) ?? ""
        ])
        do {
            var response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/usr/local/bin/msl-init", "memory", action],
                timeoutMs: 5_000
            ))
            var exitCode = response.exitCode ?? 0

            if !(response.ok && exitCode == 0), let fallback = strategy.shellCommand {
                logger.log("memory_reclaim_retry_fallback", fields: [
                    "trigger": trigger.rawValue,
                    "strategy": strategy.rawValue,
                    "error": response.error?.message ?? "guest_msl_memory_failed",
                    "exit_code": String(exitCode)
                ])
                response = try client.send(InitChannelRequest(
                    op: "exec",
                    argv: ["/bin/sh", "-lc", fallback],
                    timeoutMs: 5_000
                ))
                exitCode = response.exitCode ?? 0
            }

            if response.ok && exitCode == 0 {
                logger.log("memory_reclaim_completed", fields: [
                    "trigger": trigger.rawValue,
                    "strategy": strategy.rawValue,
                    "exit_code": String(exitCode)
                ])
            } else {
                logger.log("memory_reclaim_failed", fields: [
                    "trigger": trigger.rawValue,
                    "strategy": strategy.rawValue,
                    "error": response.error?.message ?? "exec_failed",
                    "exit_code": String(exitCode)
                ])
            }
        } catch {
            logger.log("memory_reclaim_failed", fields: [
                "trigger": trigger.rawValue,
                "strategy": strategy.rawValue,
                "error": String(describing: error)
            ])
        }
    }

    private struct GuestMemoryReclaimStats {
        var compactCount: UInt64
        var compactLastEpochMs: Int64?
        var dropCacheCount: UInt64
        var dropCacheLastEpochMs: Int64?

        static let zero = GuestMemoryReclaimStats(
            compactCount: 0,
            compactLastEpochMs: nil,
            dropCacheCount: 0,
            dropCacheLastEpochMs: nil
        )
    }

    private func readGuestMemoryReclaimStats(client: InitChannelClient) -> GuestMemoryReclaimStats {
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/run/msl-memory-stats.env"],
                timeoutMs: 1_500
            ))
            guard response.ok, (response.exitCode ?? 1) == 0, let stdout = response.stdout else {
                return .zero
            }
            return parseGuestMemoryReclaimStats(stdout)
        } catch {
            return .zero
        }
    }

    private func parseGuestMemoryReclaimStats(_ text: String) -> GuestMemoryReclaimStats {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let sep = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<sep]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        func parseUInt64(_ key: String) -> UInt64 {
            guard let raw = values[key], let value = UInt64(raw) else {
                return 0
            }
            return value
        }

        func parseInt64Optional(_ key: String) -> Int64? {
            guard let raw = values[key], !raw.isEmpty, let value = Int64(raw), value > 0 else {
                return nil
            }
            return value
        }

        return GuestMemoryReclaimStats(
            compactCount: parseUInt64("compact_count"),
            compactLastEpochMs: parseInt64Optional("compact_last_epoch_ms"),
            dropCacheCount: parseUInt64("drop_cache_count"),
            dropCacheLastEpochMs: parseInt64Optional("drop_cache_last_epoch_ms")
        )
    }

    private func resolveIdleTimeoutMs() -> Int64 {
        if let raw = ProcessInfo.processInfo.environment["MSL_IDLE_TIMEOUT_MS"],
           let val = Int64(raw), val > 0 {
            return val
        }
        if !FileManager.default.fileExists(atPath: paths.mslHostInitBootstrapLogFile.path) {
            return 300_000  // 5 min (first provisioning)
        }
        return 120_000  // 2 min (warm VM default)
    }

    private func updateInitChannelState(_ probe: InitChannelProbeResult) {
        do {
            try lock.withExclusiveLock(timeoutSec: 1) {
                var state = try store.loadState()
                let initState = InitChannelState(
                    version: probe.version,
                    lastHeartbeatEpochMs: nowEpochMs(),
                    lastStatus: probe.status,
                    lastErrorCode: probe.errorCode,
                    lastErrorMessage: probe.errorMessage
                )
                state.initChannel = initState
                upsertInstanceState(
                    &state,
                    instanceName: currentRuntimeInstanceName(),
                    lifecycleState: state.vmState == .running ? .running : .stopped,
                    activeSessionCount: state.activeSessionCount,
                    idleTimer: state.idleTimer,
                    runtimeHostPid: state.runtimeHostPid,
                    runtimeControlSocket: state.runtimeControlSocket,
                    runtimeUser: instanceRegistry.context(for: currentRuntimeInstanceName()).runtimeUser,
                    initChannel: initState,
                    lastError: nil
                )
                try store.saveState(state)
            }
        } catch {
            logger.log("init_channel_state_update_failed", fields: ["error": String(describing: error)])
        }
    }
}

private func daemonMonotonicMs() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}

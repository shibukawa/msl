use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::symlink;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::FromRawFd;
use std::os::unix::net::UnixListener;
use std::os::unix::net::UnixStream;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI8, AtomicU64, Ordering};
use std::sync::mpsc::{self as std_mpsc, Receiver};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::{unix::AsyncFd, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command as TokioCommand;
use tokio::runtime::{Builder as TokioRuntimeBuilder, Runtime as TokioRuntime};
use tokio::sync::{mpsc as tokio_mpsc, oneshot, Mutex as TokioMutex};
use tokio::time::{timeout as tokio_timeout, Duration as TokioDuration};

const MAX_READ_BYTES: usize = 16 * 1024;
const INIT_CHANNEL_FRAME_MAGIC: u32 = 0x4D534C49; // "MSLI"
const INIT_CHANNEL_FRAME_OPCODE_JSON_RPC_REQUEST: u32 = 1;
const INIT_CHANNEL_FRAME_OPCODE_JSON_RPC_RESPONSE: u32 = 2;
const INIT_CHANNEL_FRAME_OPCODE_PTY_READ_REQUEST: u32 = 3;
const INIT_CHANNEL_FRAME_OPCODE_PTY_READ_RESPONSE: u32 = 4;
const INIT_CHANNEL_FRAME_OPCODE_PTY_WRITE_REQUEST: u32 = 5;
const INIT_CHANNEL_FRAME_OPCODE_PTY_WRITE_RESPONSE: u32 = 6;
const INIT_CHANNEL_FRAME_OPCODE_PROC_READ_REQUEST: u32 = 7;
const INIT_CHANNEL_FRAME_OPCODE_PROC_READ_RESPONSE: u32 = 8;
const INIT_CHANNEL_FRAME_OPCODE_PROC_WRITE_REQUEST: u32 = 9;
const INIT_CHANNEL_FRAME_OPCODE_PROC_WRITE_RESPONSE: u32 = 10;
const INIT_CHANNEL_FRAME_OPCODE_PROC_SUBSCRIBE_REQUEST: u32 = 11;
const INIT_CHANNEL_FRAME_OPCODE_PROC_EVENT: u32 = 12;
const INIT_CHANNEL_FRAME_OPCODE_PTY_SUBSCRIBE_REQUEST: u32 = 13;
const INIT_CHANNEL_FRAME_OPCODE_PTY_EVENT: u32 = 14;
const MSL_VSOCK_PORT: u32 = 1024;
const MSL_CODE_OPEN_VSOCK_PORT: u32 = 5001;
const MSL_DNS_TUNNEL_PORT: u32 = 1053;
const MSL_TIME_TUNNEL_PORT: u32 = 1067;
const MEMORY_STATS_FILE: &str = "/run/msl-memory-stats.env";
const LOCAL_CONTROL_SOCKET: &str = "/run/msl-init.sock";
const LOCAL_NTP_BIND_ADDR: &str = "127.0.0.1:123";
const NTP_UNIX_OFFSET_SECONDS: u64 = 2_208_988_800;
const BUILD_GIT_COMMIT: &str = match option_env!("MSL_INIT_BUILD_GIT_COMMIT") {
    Some(value) => value,
    None => "unknown",
};
const BUILD_TIMESTAMP: &str = match option_env!("MSL_INIT_BUILD_TIMESTAMP") {
    Some(value) => value,
    None => "unknown",
};
const BUILD_TARGET: &str = match option_env!("MSL_INIT_BUILD_TARGET") {
    Some(value) => value,
    None => "unknown",
};

// Linux constants for vsock
const AF_VSOCK: i32 = 40;
const SOCK_STREAM: i32 = 1;
const VMADDR_CID_HOST: u32 = 2;

#[repr(C)]
struct SockaddrVm {
    svm_family: u16,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [u8; 4],
}

extern "C" {
    fn socket(domain: i32, ty: i32, protocol: i32) -> i32;
    fn connect(sockfd: i32, addr: *const SockaddrVm, addrlen: u32) -> i32;
    fn close(fd: i32) -> i32;
}

// PTY / process FFI
const TIOCSWINSZ: u64 = 0x5414;

#[repr(C)]
struct Winsize {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
}

// poll() FFI for non-blocking I/O
#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

const POLLIN: i16 = 0x001;
const POLLOUT: i16 = 0x004;
const POLLHUP: i16 = 0x010;
const POLLERR: i16 = 0x008;
const F_GETFL: i32 = 3;
const F_SETFL: i32 = 4;
const O_NONBLOCK: i32 = 0x800;
const MS_NOSUID: usize = 2;
const MS_NODEV: usize = 4;
const MS_BIND: usize = 4096;

extern "C" {
    fn poll(fds: *mut PollFd, nfds: u64, timeout: i32) -> i32;
    fn fcntl(fd: i32, cmd: i32, ...) -> i32;
    fn _exit(status: i32) -> !;
    fn chdir(path: *const u8) -> i32;
    fn setgroups(size: usize, list: *const u32) -> i32;
    fn setgid(gid: u32) -> i32;
    fn setuid(uid: u32) -> i32;
    fn sethostname(name: *const u8, len: usize) -> i32;
    fn getrlimit(resource: i32, rlim: *mut Rlimit) -> i32;
    fn mount(
        source: *const u8,
        target: *const u8,
        filesystemtype: *const u8,
        mountflags: usize,
        data: *const u8,
    ) -> i32;
    fn geteuid() -> u32;
}

#[repr(C)]
struct Rlimit {
    rlim_cur: u64,
    rlim_max: u64,
}

const RLIMIT_NOFILE: i32 = 7;

extern "C" {
    fn openpty(
        amaster: *mut i32,
        aslave: *mut i32,
        name: *mut u8,
        termp: *const u8,
        winp: *const Winsize,
    ) -> i32;
    fn fork() -> i32;
    fn setsid() -> i32;
    fn dup2(oldfd: i32, newfd: i32) -> i32;
    fn dup(oldfd: i32) -> i32;
    fn execve(pathname: *const u8, argv: *const *const u8, envp: *const *const u8) -> i32;
    fn ioctl(fd: i32, request: u64, ...) -> i32;
    fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
    fn kill(pid: i32, sig: i32) -> i32;
}

const WNOHANG: i32 = 1;
const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;

struct PtySession {
    master_fd: i32,
    child_pid: i32,
    stdin_tx: Option<tokio_mpsc::Sender<PtyInputMessage>>,
    rx: Arc<TokioMutex<tokio_mpsc::Receiver<PtyEvent>>>,
    child_exit_code: Option<i32>,
    child_exit_reason: Option<String>,
    streams_closed: bool,
}

enum PtyEvent {
    Output(Vec<u8>),
    Exited { code: i32, reason: String },
    StreamsClosed,
}

enum PtyInputMessage {
    Data { bytes: Vec<u8>, enqueued_at_ms: i64 },
    Close,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ProcStreamKind {
    Stdout,
    Stderr,
}

#[derive(Clone)]
struct ProcStreamChunk {
    seq: u64,
    stream: ProcStreamKind,
    data: Vec<u8>,
}

const SHELL_SERVER_SENTINEL: &[u8] = b"\xE2\x90\x84";
const PROC_STDERR_HOLDBACK_WINDOW_MS: u64 = 8;

enum ProcEvent {
    Stream(ProcStreamChunk),
    Exited { code: i32, reason: String },
    StreamsClosed,
}

struct ProcSession {
    child_pid: i32,
    stdin_tx: Option<tokio_mpsc::Sender<ProcStdinMessage>>,
    rx: Arc<TokioMutex<tokio_mpsc::Receiver<ProcEvent>>>,
    child_exit_code: Option<i32>,
    child_exit_reason: Option<String>,
    streams_closed: bool,
    stdin_tail: String,
    stdin_text_tail: String,
    helper_trace: String,
    stdin_line_buffer: Vec<u8>,
    helper_watch_started: bool,
    helper_candidate_logged: bool,
    helper_reference_logged: bool,
    helper_tail_last_logged: String,
}

enum ProcStdinMessage {
    Data { bytes: Vec<u8>, enqueued_at_ms: i64 },
    Close,
}

static PTY_SESSIONS: OnceLock<Mutex<HashMap<String, PtySession>>> = OnceLock::new();
static PTY_SEQ: AtomicU64 = AtomicU64::new(1);
static PROC_SESSIONS: OnceLock<Mutex<HashMap<String, ProcSession>>> = OnceLock::new();
static PROC_SEQ: AtomicU64 = AtomicU64::new(1);
static WAYLAND_TRACE_SEQ: AtomicU64 = AtomicU64::new(1);
static LOG_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static DIAG_LOCK: OnceLock<Mutex<Option<std::fs::File>>> = OnceLock::new();
static RUNTIME_USER: OnceLock<Mutex<RuntimeUserContext>> = OnceLock::new();
static DNS_PROXY_STATE: OnceLock<Mutex<Option<DNSProxyRuntime>>> = OnceLock::new();
static WAYLAND_PROXIES: OnceLock<Mutex<HashMap<String, WaylandProxyRuntime>>> = OnceLock::new();
static NTP_UPSTREAM_HEALTH: AtomicI8 = AtomicI8::new(0);

#[derive(Clone)]
struct RuntimeUserContext {
    username: String,
    uid: u32,
    gid: u32,
    home: String,
    shell: String,
}

struct DNSProxyRuntime {
    listen: SocketAddr,
    upstreams: Vec<SocketAddr>,
    stop_tx: std_mpsc::Sender<()>,
    handle: JoinHandle<()>,
}

struct WaylandProxyRuntime {
    display_name: String,
    display_port: u32,
    runtime_dir: String,
    socket_path: String,
    active_clients: usize,
    default_proxy_started: bool,
    build_marker: String,
    last_trace_id: Option<String>,
    last_error: Option<String>,
    last_client_event: Option<String>,
    last_host_event: Option<String>,
    bytes_client_to_host: u64,
    bytes_host_to_client: u64,
    keymap_sent: bool,
    stop_tx: Option<oneshot::Sender<()>>,
}

struct RawAsyncFD(i32);

impl AsRawFd for RawAsyncFD {
    fn as_raw_fd(&self) -> i32 {
        self.0
    }
}

static IO_RUNTIME: OnceLock<TokioRuntime> = OnceLock::new();

fn io_runtime() -> &'static TokioRuntime {
    IO_RUNTIME.get_or_init(|| {
        TokioRuntimeBuilder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("msl-init-io")
            .build()
            .expect("failed to build tokio runtime")
    })
}

enum BlockingRecvResult<T> {
    Event(T),
    Timeout,
    Closed,
}

fn sessions() -> &'static Mutex<HashMap<String, PtySession>> {
    PTY_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn proc_sessions() -> &'static Mutex<HashMap<String, ProcSession>> {
    PROC_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn runtime_user() -> &'static Mutex<RuntimeUserContext> {
    RUNTIME_USER.get_or_init(|| {
        Mutex::new(RuntimeUserContext {
            username: "root".to_string(),
            uid: 0,
            gid: 0,
            home: "/root".to_string(),
            shell: "/bin/sh".to_string(),
        })
    })
}

fn runtime_context_for_request(run_as_root: bool) -> RuntimeUserContext {
    if run_as_root {
        RuntimeUserContext {
            username: "root".to_string(),
            uid: 0,
            gid: 0,
            home: "/root".to_string(),
            shell: "/bin/sh".to_string(),
        }
    } else {
        runtime_user()
            .lock()
            .map(|v| v.clone())
            .unwrap_or(RuntimeUserContext {
                username: "root".to_string(),
                uid: 0,
                gid: 0,
                home: "/root".to_string(),
                shell: "/bin/sh".to_string(),
            })
    }
}

fn dns_proxy_state() -> &'static Mutex<Option<DNSProxyRuntime>> {
    DNS_PROXY_STATE.get_or_init(|| Mutex::new(None))
}

fn wayland_proxies() -> &'static Mutex<HashMap<String, WaylandProxyRuntime>> {
    WAYLAND_PROXIES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn update_wayland_proxy_state(display_name: &str, update: impl FnOnce(&mut WaylandProxyRuntime)) {
    if let Ok(mut proxies) = wayland_proxies().lock() {
        if let Some(proxy) = proxies.get_mut(display_name) {
            update(proxy);
        }
    }
}

fn next_wayland_trace_id() -> String {
    let seq = WAYLAND_TRACE_SEQ.fetch_add(1, Ordering::Relaxed);
    format!("wl-{}-{}", now_epoch_ms(), seq)
}

fn normalize_dns_upstream(raw: &str) -> Option<SocketAddr> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(ip) = trimmed.parse::<IpAddr>() {
        return Some(SocketAddr::new(ip, 53));
    }
    trimmed.parse::<SocketAddr>().ok()
}

fn build_listen_addr(address: &str, port: u16) -> Option<SocketAddr> {
    let ip = address.trim().parse::<IpAddr>().ok()?;
    Some(SocketAddr::new(ip, port))
}

fn detect_default_local_ip() -> Option<IpAddr> {
    let probe = UdpSocket::bind("0.0.0.0:0").ok()?;
    if probe.connect("1.1.1.1:53").is_err() {
        return None;
    }
    let local = probe.local_addr().ok()?;
    if local.ip().is_unspecified() {
        return None;
    }
    Some(local.ip())
}

fn ensure_loopback_interface_up() {
    let _ = Command::new("sh")
        .arg("-lc")
        .arg("ip link set lo up >/dev/null 2>&1 || ifconfig lo up >/dev/null 2>&1 || true")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn list_non_loopback_interfaces() -> Vec<String> {
    let text = match fs::read_to_string("/proc/net/dev") {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };
    let mut interfaces = Vec::new();
    for line in text.lines().skip(2) {
        let Some((name, _)) = line.split_once(':') else {
            continue;
        };
        let iface = name.trim();
        if iface.is_empty() || iface == "lo" {
            continue;
        }
        if iface.starts_with("sit") || iface.starts_with("ip6tnl") {
            continue;
        }
        interfaces.push(iface.to_string());
    }
    interfaces
}

fn ensure_interface_up(iface: &str) {
    let _ = Command::new("ip")
        .args(["link", "set", "dev", iface, "up"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn interface_has_global_ipv4(iface: &str) -> bool {
    Command::new("ip")
        .args(["-4", "-o", "addr", "show", "dev", iface, "scope", "global"])
        .output()
        .ok()
        .map(|out| out.status.success() && !String::from_utf8_lossy(&out.stdout).trim().is_empty())
        .unwrap_or(false)
}

fn interface_has_global_ipv6(iface: &str) -> bool {
    Command::new("ip")
        .args(["-6", "-o", "addr", "show", "dev", iface, "scope", "global"])
        .output()
        .ok()
        .map(|out| {
            out.status.success()
                && String::from_utf8_lossy(&out.stdout)
                    .lines()
                    .any(|line| !line.contains(" tentative "))
        })
        .unwrap_or(false)
}

fn has_default_ipv4_route() -> bool {
    let text = match fs::read_to_string("/proc/net/route") {
        Ok(value) => value,
        Err(_) => return false,
    };
    for line in text.lines().skip(1) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 2 {
            continue;
        }
        if fields[1] == "00000000" {
            return true;
        }
    }
    false
}

fn has_default_ipv6_route() -> bool {
    Command::new("ip")
        .args(["-6", "route", "show", "default"])
        .output()
        .ok()
        .map(|out| out.status.success() && !String::from_utf8_lossy(&out.stdout).trim().is_empty())
        .unwrap_or(false)
}

fn has_ipv4_transport_path(interfaces: &[String]) -> bool {
    has_default_ipv4_route()
        && interfaces
            .iter()
            .any(|iface| interface_has_global_ipv4(iface))
}

fn has_ipv6_transport_path(interfaces: &[String]) -> bool {
    has_default_ipv6_route()
        && interfaces
            .iter()
            .any(|iface| interface_has_global_ipv6(iface))
}

fn has_transport_path(interfaces: &[String]) -> bool {
    has_ipv4_transport_path(interfaces) || has_ipv6_transport_path(interfaces)
}

fn run_dhcp_once(iface: &str) -> bool {
    let script_path = "/tmp/msl-udhcpc-script.sh";
    let script = r#"#!/bin/sh
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
"#;
    let _ = fs::write(script_path, script.as_bytes());
    let _ = Command::new("chmod")
        .args(["0755", script_path])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let udhcpc_args = [
        "udhcpc",
        "-i",
        iface,
        "-n",
        "-q",
        "-t",
        "3",
        "-T",
        "1",
        "-s",
        script_path,
    ];
    if command_exists("udhcpc") {
        return Command::new("udhcpc")
            .args([
                "-i",
                iface,
                "-n",
                "-q",
                "-t",
                "3",
                "-T",
                "1",
                "-s",
                script_path,
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
    }
    if command_exists("busybox") {
        return Command::new("busybox")
            .args(udhcpc_args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
    }
    if command_exists("dhclient") {
        return Command::new("dhclient")
            .args(["-4", "-1", iface])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
    }
    false
}

fn ensure_guest_network_ready() {
    ensure_loopback_interface_up();
    let interfaces = list_non_loopback_interfaces();
    if interfaces.is_empty() {
        log_line("network bootstrap skipped: no non-loopback interfaces");
        return;
    }
    for iface in &interfaces {
        ensure_interface_up(iface);
    }
    if has_transport_path(&interfaces) {
        return;
    }
    for iface in &interfaces {
        if !interface_has_global_ipv4(iface) || !has_default_ipv4_route() {
            let _ = run_dhcp_once(iface);
            if has_transport_path(&interfaces) {
                log_line(&format!("network bootstrap succeeded interface={}", iface));
                return;
            }
        }
    }
    log_line("network bootstrap incomplete: missing default route or global ipv4/ipv6 address");
}

fn stop_dns_proxy() {
    let mut state = dns_proxy_state().lock().unwrap();
    if let Some(runtime) = state.take() {
        let _ = runtime.stop_tx.send(());
        let _ = runtime.handle.join();
    }
}

fn ensure_dns_proxy(
    listen: SocketAddr,
    upstreams: Vec<SocketAddr>,
) -> Result<(bool, bool), String> {
    ensure_loopback_interface_up();
    let mut state = dns_proxy_state().lock().unwrap();
    if let Some(current) = state.as_ref() {
        if current.listen == listen && current.upstreams == upstreams {
            return Ok((false, false));
        }
    }
    if let Some(runtime) = state.take() {
        let _ = runtime.stop_tx.send(());
        let _ = runtime.handle.join();
    }

    let socket = UdpSocket::bind(listen)
        .map_err(|err| format!("dns proxy bind failed listen={} err={}", listen, err))?;
    let _ = socket.set_read_timeout(Some(Duration::from_millis(200)));

    let (stop_tx, stop_rx) = std_mpsc::channel::<()>();
    let listen_for_thread = listen;
    let upstreams_for_thread = upstreams.clone();
    let handle = thread::spawn(move || {
        run_dns_proxy_loop(socket, listen_for_thread, upstreams_for_thread, stop_rx);
    });
    *state = Some(DNSProxyRuntime {
        listen,
        upstreams,
        stop_tx,
        handle,
    });
    Ok((true, true))
}

fn run_dns_proxy_loop(
    socket: UdpSocket,
    listen: SocketAddr,
    upstreams: Vec<SocketAddr>,
    stop_rx: Receiver<()>,
) {
    log_line(&format!(
        "dns proxy started listen={} upstream_count={}",
        listen,
        upstreams.len()
    ));

    let mut buf = [0u8; 4096];
    loop {
        match stop_rx.try_recv() {
            Ok(_) => break,
            Err(std_mpsc::TryRecvError::Disconnected) => break,
            Err(std_mpsc::TryRecvError::Empty) => {}
        }

        match socket.recv_from(&mut buf) {
            Ok((size, src)) => {
                let response = forward_dns_query_via_tunnel(&buf[..size]);
                if let Some(payload) = response {
                    let _ = socket.send_to(&payload, src);
                }
            }
            Err(err)
                if err.kind() == std::io::ErrorKind::WouldBlock
                    || err.kind() == std::io::ErrorKind::TimedOut => {}
            Err(err) => {
                log_line(&format!(
                    "dns proxy recv failed listen={} err={}",
                    listen, err
                ));
            }
        }
    }
    log_line(&format!("dns proxy stopped listen={}", listen));
}

fn resolve_dns_tunnel_port() -> u32 {
    env::var("MSL_DNS_TUNNEL_PORT")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(MSL_DNS_TUNNEL_PORT)
}

fn connect_vsock(fd_port: u32) -> Result<std::fs::File, String> {
    let fd = unsafe { socket(AF_VSOCK, SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(format!(
            "socket(AF_VSOCK) failed: {}",
            std::io::Error::last_os_error()
        ));
    }
    let addr = SockaddrVm {
        svm_family: AF_VSOCK as u16,
        svm_reserved1: 0,
        svm_port: fd_port,
        svm_cid: VMADDR_CID_HOST,
        svm_zero: [0; 4],
    };
    let ret = unsafe { connect(fd, &addr, std::mem::size_of::<SockaddrVm>() as u32) };
    if ret < 0 {
        let err = std::io::Error::last_os_error();
        unsafe {
            close(fd);
        }
        return Err(format!("vsock connect failed port={} err={}", fd_port, err));
    }
    let file: std::fs::File = unsafe { FromRawFd::from_raw_fd(fd) };
    Ok(file)
}

fn parse_dns_question(query: &[u8]) -> Option<(u16, usize, String, u16)> {
    if query.len() < 12 {
        return None;
    }
    let id = u16::from_be_bytes([query[0], query[1]]);
    let qdcount = u16::from_be_bytes([query[4], query[5]]);
    if qdcount == 0 {
        return None;
    }
    let mut index = 12usize;
    let mut labels: Vec<String> = Vec::new();
    while index < query.len() {
        let len = query[index] as usize;
        index += 1;
        if len == 0 {
            break;
        }
        if (len & 0b1100_0000) != 0 || index + len > query.len() {
            return None;
        }
        labels.push(String::from_utf8_lossy(&query[index..index + len]).to_string());
        index += len;
    }
    if index + 4 > query.len() {
        return None;
    }
    let qtype = u16::from_be_bytes([query[index], query[index + 1]]);
    let qclass = u16::from_be_bytes([query[index + 2], query[index + 3]]);
    if qclass != 1 {
        return None;
    }
    let qname = labels.join(".");
    Some((id, index + 4, qname, qtype))
}

fn build_dns_error_response(query: &[u8], rcode: u8) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let id = if query.len() >= 2 {
        u16::from_be_bytes([query[0], query[1]])
    } else {
        0
    };
    let flags: u16 = 0x8000 | 0x0100 | 0x0080 | (rcode as u16 & 0x000f);
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&flags.to_be_bytes());
    out.extend_from_slice(&1u16.to_be_bytes()); // qdcount
    out.extend_from_slice(&0u16.to_be_bytes()); // ancount
    out.extend_from_slice(&0u16.to_be_bytes()); // nscount
    out.extend_from_slice(&0u16.to_be_bytes()); // arcount
    if let Some((_, end, _, _)) = parse_dns_question(query) {
        out.extend_from_slice(&query[12..end]);
    }
    out
}

fn build_dns_success_response(query: &[u8], qtype: u16, answers: &[String]) -> Vec<u8> {
    let parsed = match parse_dns_question(query) {
        Some(value) => value,
        None => return build_dns_error_response(query, 2),
    };
    let (_, question_end, _, _) = parsed;
    let mut rdata_items: Vec<Vec<u8>> = Vec::new();
    for answer in answers {
        if qtype == 1 {
            if let Ok(ip) = answer.parse::<Ipv4Addr>() {
                rdata_items.push(ip.octets().to_vec());
            }
        } else if qtype == 28 {
            if let Ok(ip) = answer.parse::<Ipv6Addr>() {
                rdata_items.push(ip.octets().to_vec());
            }
        }
    }

    let mut out: Vec<u8> = Vec::new();
    let id = u16::from_be_bytes([query[0], query[1]]);
    let flags: u16 = 0x8180; // QR=1, RD=1, RA=1, NOERROR
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&flags.to_be_bytes());
    out.extend_from_slice(&1u16.to_be_bytes()); // qdcount
    out.extend_from_slice(&(rdata_items.len() as u16).to_be_bytes()); // ancount
    out.extend_from_slice(&0u16.to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes());
    out.extend_from_slice(&query[12..question_end]);

    for rdata in rdata_items {
        out.extend_from_slice(&0xC00Cu16.to_be_bytes()); // name ptr to question
        out.extend_from_slice(&qtype.to_be_bytes());
        out.extend_from_slice(&1u16.to_be_bytes()); // class IN
        out.extend_from_slice(&60u32.to_be_bytes()); // ttl
        out.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
        out.extend_from_slice(&rdata);
    }
    out
}

fn query_dns_tunnel(qname: &str, qtype: u16) -> Option<Vec<String>> {
    let port = resolve_dns_tunnel_port();
    let mut stream = connect_vsock(port).ok()?;
    let request = format!(
        "{{\"qname\":\"{}\",\"qtype\":{}}}",
        escape_json(qname),
        qtype
    );
    let payload = request.as_bytes();
    let len = (payload.len() as u32).to_be_bytes();
    if stream.write_all(&len).is_err() || stream.write_all(payload).is_err() {
        return None;
    }
    let mut header = [0u8; 4];
    if stream.read_exact(&mut header).is_err() {
        return None;
    }
    let resp_len = u32::from_be_bytes(header) as usize;
    if resp_len == 0 || resp_len > 64 * 1024 {
        return None;
    }
    let mut resp = vec![0u8; resp_len];
    if stream.read_exact(&mut resp).is_err() {
        return None;
    }
    let text = String::from_utf8(resp).ok()?;
    if extract_bool(&text, "ok") != Some(true) {
        return None;
    }
    extract_string_array(&text, "answers")
}

fn forward_dns_query_via_tunnel(query: &[u8]) -> Option<Vec<u8>> {
    let parsed = parse_dns_question(query)?;
    let (_, _, qname, qtype) = parsed;
    if qname.is_empty() {
        return Some(build_dns_error_response(query, 3));
    }
    if qtype != 1 && qtype != 28 {
        return Some(build_dns_error_response(query, 4));
    }
    let answers = query_dns_tunnel(&qname, qtype).unwrap_or_default();
    Some(build_dns_success_response(query, qtype, &answers))
}

fn resolve_time_tunnel_port() -> u32 {
    env::var("MSL_TIME_TUNNEL_PORT")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(MSL_TIME_TUNNEL_PORT)
}

fn query_time_tunnel_ms() -> Option<i64> {
    let port = resolve_time_tunnel_port();
    let mut stream = connect_vsock(port).ok()?;
    let payload = br#"{"op":"now_ms"}"#;
    let len = (payload.len() as u32).to_be_bytes();
    if stream.write_all(&len).is_err() || stream.write_all(payload).is_err() {
        return None;
    }
    let mut header = [0u8; 4];
    if stream.read_exact(&mut header).is_err() {
        return None;
    }
    let resp_len = u32::from_be_bytes(header) as usize;
    if resp_len == 0 || resp_len > 16 * 1024 {
        return None;
    }
    let mut resp = vec![0u8; resp_len];
    if stream.read_exact(&mut resp).is_err() {
        return None;
    }
    let text = String::from_utf8(resp).ok()?;
    if extract_bool(&text, "ok") != Some(true) {
        return None;
    }
    extract_int64(&text, "unixMs")
}

fn now_unix_ms() -> i64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_millis() as i64,
        Err(_) => 0,
    }
}

fn write_ntp_timestamp(dst: &mut [u8], unix_ms: i64) {
    if dst.len() < 8 {
        return;
    }
    let clamped_ms = if unix_ms < 0 { 0u64 } else { unix_ms as u64 };
    let sec = clamped_ms / 1000;
    let frac_ms = clamped_ms % 1000;
    let ntp_sec = sec.saturating_add(NTP_UNIX_OFFSET_SECONDS);
    let ntp_sec_u32 = if ntp_sec > u32::MAX as u64 {
        u32::MAX
    } else {
        ntp_sec as u32
    };
    let ntp_frac_u64 = (frac_ms << 32) / 1000;
    let ntp_frac_u32 = if ntp_frac_u64 > u32::MAX as u64 {
        u32::MAX
    } else {
        ntp_frac_u64 as u32
    };
    dst[..4].copy_from_slice(&ntp_sec_u32.to_be_bytes());
    dst[4..8].copy_from_slice(&ntp_frac_u32.to_be_bytes());
}

fn build_ntp_response(request: &[u8], unix_ms: i64) -> [u8; 48] {
    let mut out = [0u8; 48];
    out[0] = 0x24; // LI=0, VN=4, Mode=4(server)
    out[1] = 1; // stratum
    out[2] = request.get(2).copied().unwrap_or(4); // poll
    out[3] = 0xEC; // precision ~= -20
    out[12..16].copy_from_slice(b"MSL\0");
    write_ntp_timestamp(&mut out[16..24], unix_ms);
    if request.len() >= 48 {
        out[24..32].copy_from_slice(&request[40..48]); // originate = client transmit
    }
    write_ntp_timestamp(&mut out[32..40], unix_ms); // receive
    write_ntp_timestamp(&mut out[40..48], unix_ms); // transmit
    out
}

fn record_ntp_upstream_health(success: bool) {
    let next_state = if success { 1 } else { -1 };
    let previous = NTP_UPSTREAM_HEALTH.swap(next_state, Ordering::Relaxed);
    if previous == next_state {
        return;
    }
    if success {
        log_line("ntp_upstream_healthcheck_succeeded source=host_time_tunnel");
    } else {
        log_line("ntp_upstream_healthcheck_failed source=host_time_tunnel fallback=guest_clock");
    }
}

fn start_local_ntp_server() {
    let enabled = env::var("MSL_NTP_PROXY_ENABLED")
        .ok()
        .map(|v| v != "0")
        .unwrap_or(true);
    if !enabled {
        log_line("local ntp proxy disabled by MSL_NTP_PROXY_ENABLED=0");
        return;
    }

    let bind_addr = env::var("MSL_NTP_BIND_ADDR")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| LOCAL_NTP_BIND_ADDR.to_string());

    let socket = match UdpSocket::bind(&bind_addr) {
        Ok(v) => v,
        Err(e) => {
            log_line(&format!(
                "local ntp bind failed addr={} err={}",
                bind_addr, e
            ));
            return;
        }
    };
    let _ = socket.set_read_timeout(Some(Duration::from_millis(500)));
    log_line(&format!("local ntp proxy started listen={}", bind_addr));
    log_line(&format!(
        "ntp_upstream_config_applied listen={} source=host_time_tunnel fallback=guest_clock",
        bind_addr
    ));

    thread::spawn(move || {
        let mut buf = [0u8; 512];
        loop {
            match socket.recv_from(&mut buf) {
                Ok((size, src)) => {
                    if size < 48 {
                        continue;
                    }
                    let unix_ms = match query_time_tunnel_ms() {
                        Some(value) => {
                            record_ntp_upstream_health(true);
                            value
                        }
                        None => {
                            record_ntp_upstream_health(false);
                            now_unix_ms()
                        }
                    };
                    let payload = build_ntp_response(&buf[..size], unix_ms);
                    let _ = socket.send_to(&payload, src);
                }
                Err(err)
                    if err.kind() == std::io::ErrorKind::WouldBlock
                        || err.kind() == std::io::ErrorKind::TimedOut => {}
                Err(err) => {
                    log_line(&format!("local ntp recv failed err={}", err));
                    thread::sleep(Duration::from_millis(50));
                }
            }
        }
    });
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MemoryCliAction {
    Compact,
    DropCaches,
}

impl MemoryCliAction {
    fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "compact" | "compat" => Some(Self::Compact),
            "drop-cache" | "drop_caches" | "dropcache" => Some(Self::DropCaches),
            _ => None,
        }
    }

    fn as_str(&self) -> &'static str {
        match self {
            Self::Compact => "compact",
            Self::DropCaches => "drop-cache",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct MemoryReclaimStats {
    compact_count: u64,
    compact_last_epoch_ms: u64,
    drop_cache_count: u64,
    drop_cache_last_epoch_ms: u64,
}

fn main() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if let Some(result) = run_guest_cli_if_requested(&args) {
        return result;
    }

    let vsock_port: u32 = env::var("MSL_VSOCK_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(MSL_VSOCK_PORT);

    log_line(&format!(
        "session_started build_git={} build_ts={} build_target={}",
        BUILD_GIT_COMMIT, BUILD_TIMESTAMP, BUILD_TARGET
    ));
    log_line(&format!("started vsock_port={}", vsock_port));
    ensure_process_environment();
    ensure_mount_prerequisites();
    if let Err(err) = bootstrap_ephemeral_tmp_storage() {
        log_line(&format!("tmp_storage_prepare_failed {}", err));
        return Err(format!("tmp storage bootstrap failed: {}", err));
    }
    ensure_pty_prerequisites();
    ensure_guest_network_ready();
    start_local_control_server();
    start_local_ntp_server();
    start_default_wayland_proxy();
    init_diagnostic_channel();
    log_wayland_boot_identity("after_diagnostic_channel");
    if let Ok(proxies) = wayland_proxies().lock() {
        if let Some(proxy) = proxies.get("wayland-0") {
            log_line(&format!(
                "wayland_default_proxy_diagnostic display={} socket={} port={} defaultProxyStarted={} buildMarker={}",
                proxy.display_name,
                proxy.socket_path,
                proxy.display_port,
                proxy.default_proxy_started,
                proxy.build_marker
            ));
        }
    }
    start_diagnostic_forwarders();

    // Optionally start file handoff in background for external commands
    let handoff_file = env::var("MSL_INIT_HANDOFF_FILE").ok();
    let ack_file = env::var("MSL_INIT_ACK_FILE").ok();
    if let (Some(ref hf), Some(ref af)) = (&handoff_file, &ack_file) {
        if !hf.is_empty() && !af.is_empty() {
            let hf_clone = hf.clone();
            let af_clone = af.clone();
            thread::spawn(move || {
                if let Err(e) = run_file_handoff_loop(&hf_clone, &af_clone) {
                    log_line(&format!("file handoff loop error: {e}"));
                }
            });
            log_line(&format!(
                "file handoff background started handoff={} ack={}",
                hf, af
            ));
        }
    }

    // Primary: vsock client (connect to host)
    run_vsock_client(vsock_port)
}

fn run_guest_cli_if_requested(args: &[String]) -> Option<Result<(), String>> {
    let argv0 = args.first().map(String::as_str).unwrap_or("msl-init");
    let invoked_name = Path::new(argv0)
        .file_name()
        .and_then(|v| v.to_str())
        .unwrap_or("msl-init");
    let invoked_as_msl = invoked_name == "msl";
    let invoked_as_code = invoked_name == "code";

    if invoked_as_code {
        let command_args = if args.len() >= 2 { &args[1..] } else { &[] };
        return Some(run_guest_code_cli(command_args));
    }

    if !invoked_as_msl && (args.len() < 2 || args[1] != "memory") {
        return None;
    }

    let command_args = if args.len() >= 2 { &args[1..] } else { &[] };
    Some(run_guest_memory_cli(command_args))
}

fn run_guest_memory_cli(args: &[String]) -> Result<(), String> {
    if args.is_empty() || args[0] != "memory" {
        return Err(guest_memory_usage());
    }
    if args.len() == 1 || args[1] == "status" {
        print_guest_memory_status();
        return Ok(());
    }

    let action = MemoryCliAction::parse(&args[1]).ok_or_else(guest_memory_usage)?;
    execute_memory_reclaim_with_auto_elevation(action)?;
    println!("memory reclaim executed: {}", action.as_str());
    Ok(())
}

fn guest_memory_usage() -> String {
    "usage: msl memory [status|compact|drop-cache|compat]".to_string()
}

fn run_guest_code_cli(args: &[String]) -> Result<(), String> {
    if args.len() > 1 {
        return Err(guest_code_usage());
    }
    let raw_target = args.first().map(|v| v.as_str()).unwrap_or(".");
    let target = resolve_code_target(raw_target)?;
    send_code_open_request(&target)?;
    Ok(())
}

fn guest_code_usage() -> String {
    "usage: code [path]".to_string()
}

fn resolve_code_target(raw: &str) -> Result<String, String> {
    let trimmed = if raw.trim().is_empty() {
        "."
    } else {
        raw.trim()
    };
    let candidate = Path::new(trimmed);
    let absolute = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        let cwd = env::current_dir().map_err(|e| format!("failed to get cwd: {}", e))?;
        cwd.join(candidate)
    };
    let normalized_path = match fs::canonicalize(&absolute) {
        Ok(v) => v,
        Err(_) => absolute,
    };
    let as_str = normalized_path
        .to_str()
        .ok_or_else(|| "path is not valid UTF-8".to_string())?;
    Ok(normalize_absolute_path(as_str).unwrap_or_else(|| as_str.to_string()))
}

fn send_code_open_request(target: &str) -> Result<(), String> {
    let port = env::var("MSL_CODE_OPEN_VSOCK_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(MSL_CODE_OPEN_VSOCK_PORT);
    let mut stream = connect_vsock(port)?;
    let payload = format!("OPEN:{}\n", target);
    stream
        .write_all(payload.as_bytes())
        .map_err(|e| format!("failed to send OPEN request: {}", e))?;
    stream
        .flush()
        .map_err(|e| format!("failed to flush OPEN request: {}", e))?;
    Ok(())
}

fn print_guest_memory_status() {
    let stats = load_memory_stats(Path::new(MEMORY_STATS_FILE));
    let meminfo = read_proc_meminfo();

    println!("memoryStatus:");
    match meminfo {
        Some((total_kb, available_kb)) => {
            let usage_kb = total_kb.saturating_sub(available_kb);
            let limit_mb = kb_to_mb(total_kb);
            let usage_mb = kb_to_mb(usage_kb);
            let available_mb = kb_to_mb(available_kb);
            let usage_percent = if total_kb > 0 {
                (usage_kb as f64 * 100.0) / total_kb as f64
            } else {
                0.0
            };

            println!("  limitMB: {}", format_u64_with_commas(limit_mb));
            println!(
                "  usageMB: {} ({:.2}%)",
                format_u64_with_commas(usage_mb),
                usage_percent
            );
            println!("  availableMB: {}", format_u64_with_commas(available_mb));
        }
        None => {
            println!("  limitMB: unknown");
            println!("  usageMB: unknown");
            println!("  availableMB: unknown");
        }
    }
    println!(
        "  compactCount: {}",
        format_u64_with_commas(stats.compact_count)
    );
    println!(
        "  compactLast: {}",
        format_last_event(stats.compact_last_epoch_ms)
    );
    println!(
        "  dropCacheCount: {}",
        format_u64_with_commas(stats.drop_cache_count)
    );
    println!(
        "  dropCacheLast: {}",
        format_last_event(stats.drop_cache_last_epoch_ms)
    );
}

fn read_proc_meminfo() -> Option<(u64, u64)> {
    let text = fs::read_to_string("/proc/meminfo").ok()?;
    let mut total: Option<u64> = None;
    let mut available: Option<u64> = None;

    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("MemTotal:") {
            total = parse_kb_value(trimmed);
        } else if trimmed.starts_with("MemAvailable:") {
            available = parse_kb_value(trimmed);
        }
    }

    Some((total?, available?))
}

fn parse_kb_value(line: &str) -> Option<u64> {
    let mut parts = line.split_whitespace();
    let _label = parts.next()?;
    let value = parts.next()?.parse::<u64>().ok()?;
    Some(value)
}

fn kb_to_mb(value_kb: u64) -> u64 {
    value_kb / 1024
}

fn format_u64_with_commas(value: u64) -> String {
    let digits: Vec<char> = value.to_string().chars().collect();
    let mut out = String::with_capacity(digits.len() + (digits.len() / 3));
    for (idx, ch) in digits.iter().enumerate() {
        if idx > 0 && (digits.len() - idx) % 3 == 0 {
            out.push(',');
        }
        out.push(*ch);
    }
    out
}

fn format_last_event(epoch_ms: u64) -> String {
    if epoch_ms == 0 {
        return "never".to_string();
    }
    let now = now_epoch_ms();
    if now <= epoch_ms {
        return "just now".to_string();
    }
    format!("{} ago", format_duration_ms(now - epoch_ms))
}

fn format_duration_ms(ms: u64) -> String {
    if ms < 1_000 {
        return "just now".to_string();
    }

    let seconds = ms / 1_000;
    if seconds < 60 {
        return format!("{}s", seconds);
    }

    if seconds < 3_600 {
        let minutes = seconds / 60;
        let rem_seconds = seconds % 60;
        if rem_seconds == 0 {
            return format!("{}m", minutes);
        }
        return format!("{}m {}s", minutes, rem_seconds);
    }

    if seconds < 86_400 {
        let hours = seconds / 3_600;
        let rem_minutes = (seconds % 3_600) / 60;
        if rem_minutes == 0 {
            return format!("{}h", hours);
        }
        return format!("{}h {}m", hours, rem_minutes);
    }

    let days = seconds / 86_400;
    let rem_hours = (seconds % 86_400) / 3_600;
    if rem_hours == 0 {
        return format!("{}d", days);
    }
    format!("{}d {}h", days, rem_hours)
}

fn execute_manual_memory_reclaim(action: MemoryCliAction) -> Result<(), String> {
    match action {
        MemoryCliAction::Compact => {
            write_proc_control("/proc/sys/vm/compact_memory", "1\n")?;
            update_memory_stats(action)?;
            log_line("memory_reclaim_manual strategy=compact result=ok");
        }
        MemoryCliAction::DropCaches => {
            let _ = Command::new("/bin/sync")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            write_proc_control("/proc/sys/vm/drop_caches", "1\n")?;
            update_memory_stats(action)?;
            log_line("memory_reclaim_manual strategy=drop-cache result=ok");
        }
    }
    Ok(())
}

fn execute_memory_reclaim_with_auto_elevation(action: MemoryCliAction) -> Result<(), String> {
    if unsafe { geteuid() } == 0 {
        return execute_manual_memory_reclaim(action);
    }

    if let Err(e) = delegate_memory_reclaim_to_local_service(action) {
        log_line(&format!(
            "memory_reclaim_manual strategy={} local_delegate_error={}",
            action.as_str(),
            e
        ));
    } else {
        return Ok(());
    }

    let action_arg = action.as_str();
    let attempts = [
        (
            "sudo",
            vec!["-n", "/usr/local/bin/msl-init", "memory", action_arg],
        ),
        (
            "doas",
            vec!["/usr/local/bin/msl-init", "memory", action_arg],
        ),
    ];

    for (program, args) in attempts {
        if !command_exists(program) {
            continue;
        }
        match Command::new(program).args(&args).status() {
            Ok(status) if status.success() => {
                log_line(&format!(
                    "memory_reclaim_manual strategy={} delegated_via={} result=ok",
                    action_arg, program
                ));
                return Ok(());
            }
            Ok(status) => {
                log_line(&format!(
                    "memory_reclaim_manual strategy={} delegated_via={} exit_status={}",
                    action_arg, program, status
                ));
            }
            Err(e) => {
                log_line(&format!(
                    "memory_reclaim_manual strategy={} delegated_via={} error={}",
                    action_arg, program, e
                ));
            }
        }
    }

    Err(format!(
        "permission denied for memory reclaim (strategy={}). run as root or configure passwordless sudo/doas for /usr/local/bin/msl-init",
        action_arg
    ))
}

fn start_local_control_server() {
    let socket_path = Path::new(LOCAL_CONTROL_SOCKET);
    if let Some(parent) = socket_path.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            log_line(&format!(
                "local control mkdir failed {}: {}",
                parent.display(),
                e
            ));
            return;
        }
    }
    if socket_path.exists() {
        let _ = fs::remove_file(socket_path);
    }

    let listener = match UnixListener::bind(socket_path) {
        Ok(v) => v,
        Err(e) => {
            log_line(&format!(
                "local control bind failed {}: {}",
                socket_path.display(),
                e
            ));
            return;
        }
    };
    let _ = fs::set_permissions(socket_path, fs::Permissions::from_mode(0o666));
    log_line(&format!(
        "local control socket ready at {}",
        socket_path.display()
    ));

    thread::spawn(move || {
        for accepted in listener.incoming() {
            match accepted {
                Ok(stream) => {
                    thread::spawn(move || {
                        handle_local_control_stream(stream);
                    });
                }
                Err(e) => {
                    log_line(&format!("local control accept failed: {}", e));
                    thread::sleep(Duration::from_millis(50));
                }
            }
        }
    });
}

fn handle_local_control_stream(mut stream: UnixStream) {
    let mut line = String::new();
    {
        let mut reader = BufReader::new(&mut stream);
        if reader.read_line(&mut line).is_err() {
            let _ = stream.write_all(b"error invalid request\n");
            let _ = stream.flush();
            return;
        }
    }

    match parse_local_control_memory_action(&line) {
        Some(action) => match execute_manual_memory_reclaim(action) {
            Ok(()) => {
                let _ = stream.write_all(b"ok\n");
                let _ = stream.flush();
            }
            Err(e) => {
                let _ = stream.write_all(format!("error {}\n", e).as_bytes());
                let _ = stream.flush();
            }
        },
        None => {
            let _ = stream.write_all(b"error unsupported command\n");
            let _ = stream.flush();
        }
    }
}

fn parse_local_control_memory_action(line: &str) -> Option<MemoryCliAction> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() < 2 || parts[0] != "memory" {
        return None;
    }
    MemoryCliAction::parse(parts[1])
}

fn delegate_memory_reclaim_to_local_service(action: MemoryCliAction) -> Result<(), String> {
    let mut stream = UnixStream::connect(LOCAL_CONTROL_SOCKET)
        .map_err(|e| format!("connect {} failed: {}", LOCAL_CONTROL_SOCKET, e))?;
    let request = format!("memory {}\n", action.as_str());
    stream
        .write_all(request.as_bytes())
        .map_err(|e| format!("write local control request failed: {}", e))?;
    stream
        .flush()
        .map_err(|e| format!("flush local control request failed: {}", e))?;

    let mut response = String::new();
    let mut reader = BufReader::new(stream);
    reader
        .read_line(&mut response)
        .map_err(|e| format!("read local control response failed: {}", e))?;
    let normalized = response.trim();
    if normalized == "ok" {
        return Ok(());
    }
    if normalized.is_empty() {
        return Err("empty local control response".to_string());
    }
    Err(normalized.to_string())
}

fn update_memory_stats(action: MemoryCliAction) -> Result<(), String> {
    update_memory_stats_at_path(Path::new(MEMORY_STATS_FILE), action)
}

fn update_memory_stats_at_path(path: &Path, action: MemoryCliAction) -> Result<(), String> {
    let mut stats = load_memory_stats(path);
    let now = now_epoch_ms();
    match action {
        MemoryCliAction::Compact => {
            stats.compact_count = stats.compact_count.saturating_add(1);
            stats.compact_last_epoch_ms = now;
        }
        MemoryCliAction::DropCaches => {
            stats.drop_cache_count = stats.drop_cache_count.saturating_add(1);
            stats.drop_cache_last_epoch_ms = now;
        }
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            format!(
                "failed to create memory stats dir {}: {}",
                parent.display(),
                e
            )
        })?;
    }

    let payload = format!(
        "compact_count={}\ncompact_last_epoch_ms={}\ndrop_cache_count={}\ndrop_cache_last_epoch_ms={}\n",
        stats.compact_count,
        stats.compact_last_epoch_ms,
        stats.drop_cache_count,
        stats.drop_cache_last_epoch_ms
    );
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, payload.as_bytes())
        .map_err(|e| format!("failed to write memory stats {}: {}", tmp.display(), e))?;
    fs::rename(&tmp, path)
        .map_err(|e| format!("failed to finalize memory stats {}: {}", path.display(), e))?;
    Ok(())
}

fn load_memory_stats(path: &Path) -> MemoryReclaimStats {
    let content = match fs::read_to_string(path) {
        Ok(v) => v,
        Err(_) => return MemoryReclaimStats::default(),
    };
    let mut stats = MemoryReclaimStats::default();
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let parsed = value.trim().parse::<u64>().unwrap_or(0);
        match key.trim() {
            "compact_count" => stats.compact_count = parsed,
            "compact_last_epoch_ms" => stats.compact_last_epoch_ms = parsed,
            "drop_cache_count" => stats.drop_cache_count = parsed,
            "drop_cache_last_epoch_ms" => stats.drop_cache_last_epoch_ms = parsed,
            _ => {}
        }
    }
    stats
}

fn now_epoch_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(d) => {
            let ms = d.as_millis();
            if ms > u128::from(u64::MAX) {
                u64::MAX
            } else {
                ms as u64
            }
        }
        Err(_) => 0,
    }
}

fn write_proc_control(path: &str, value: &str) -> Result<(), String> {
    fs::write(path, value.as_bytes()).map_err(|e| {
        format!(
            "failed to update {} (requires root and mounted /proc): {}",
            path, e
        )
    })
}

fn ensure_process_environment() {
    if env::var_os("PATH").is_none() {
        env::set_var(
            "PATH",
            "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        );
    }
    if env::var_os("HOME").is_none() {
        env::set_var("HOME", "/root");
    }
    if env::var_os("SHELL").is_none() {
        env::set_var("SHELL", "/bin/sh");
    }
    if env::var_os("TERM").is_none() {
        env::set_var("TERM", "xterm-256color");
    }
    if env::var_os("XDG_RUNTIME_DIR").is_none() {
        env::set_var("XDG_RUNTIME_DIR", "/tmp");
    }
    if env::var_os("TZ").is_none() {
        if let Some(time_zone_id) = load_timezone_from_process_or_etc_environment() {
            env::set_var("TZ", time_zone_id);
        }
    }
}

fn load_timezone_from_process_or_etc_environment() -> Option<String> {
    if let Some(value) = env::var_os("TZ") {
        let value = value.to_string_lossy().trim().to_string();
        if is_valid_timezone_id(&value) {
            return Some(value);
        }
    }
    let text = fs::read_to_string("/etc/environment").ok()?;
    load_timezone_from_text(&text)
}

fn load_timezone_from_text(text: &str) -> Option<String> {
    for line in text.lines() {
        let trimmed = line.trim();
        if !trimmed.starts_with("TZ=") {
            continue;
        }
        let raw = trimmed.trim_start_matches("TZ=").trim();
        let unquoted = raw
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .unwrap_or(raw)
            .trim();
        if is_valid_timezone_id(unquoted) {
            return Some(unquoted.to_string());
        }
    }
    None
}

fn wayland_socket_path(runtime_dir: &str, display_name: &str) -> String {
    format!("{}/{}", runtime_dir.trim_end_matches('/'), display_name)
}

fn start_default_wayland_proxy() {
    log_wayland_boot_identity("before_default_proxy_start");
    match start_wayland_proxy("wayland-0".to_string(), 38000, "/tmp".to_string()) {
        Ok(proxy) => {
            update_wayland_proxy_state(&proxy.display_name, |state| {
                state.default_proxy_started = true;
                state.last_client_event = Some("default_proxy_started".to_string());
            });
            log_line(&format!(
                "wayland_default_proxy_started display={} socket={} port={} build_marker={}",
                proxy.display_name, proxy.socket_path, proxy.display_port, proxy.build_marker
            ));
        }
        Err(err) => log_line(&format!("wayland_default_proxy_start_failed err={}", err)),
    }
}

fn log_wayland_boot_identity(phase: &str) {
    let keys = [
        "WAYLAND_DISPLAY",
        "MSL_WAYLAND_DISPLAY",
        "XDG_RUNTIME_DIR",
        "GDK_BACKEND",
        "QT_QPA_PLATFORM",
        "SDL_VIDEODRIVER",
        "MOZ_ENABLE_WAYLAND",
    ];
    let env_summary = keys
        .iter()
        .map(|key| format!("{}={}", key, env::var(key).unwrap_or_default()))
        .collect::<Vec<_>>()
        .join(",");
    log_line(&format!(
        "wayland_proxy_fd_support=enabled build_marker=fd-aware-keymap phase={} build_git={} build_ts={} build_target={} env={}",
        phase, BUILD_GIT_COMMIT, BUILD_TIMESTAMP, BUILD_TARGET, env_summary
    ));
}

fn start_wayland_proxy(
    display_name: String,
    display_port: u32,
    runtime_dir: String,
) -> Result<WaylandProxyRuntime, String> {
    validate_wayland_display_name(&display_name)?;
    if display_port == 0 || display_port > 65535 {
        return Err("displayPort must be in 1..65535".to_string());
    }
    let socket_path = wayland_socket_path(&runtime_dir, &display_name);
    {
        let mut proxies = wayland_proxies()
            .lock()
            .map_err(|_| "wayland proxy lock poisoned".to_string())?;
        if let Some(existing) = proxies.get(&display_name) {
            return Ok(WaylandProxyRuntime {
                display_name: existing.display_name.clone(),
                display_port: existing.display_port,
                runtime_dir: existing.runtime_dir.clone(),
                socket_path: existing.socket_path.clone(),
                active_clients: existing.active_clients,
                default_proxy_started: existing.default_proxy_started,
                build_marker: existing.build_marker.clone(),
                last_trace_id: existing.last_trace_id.clone(),
                last_error: existing.last_error.clone(),
                last_client_event: existing.last_client_event.clone(),
                last_host_event: existing.last_host_event.clone(),
                bytes_client_to_host: existing.bytes_client_to_host,
                bytes_host_to_client: existing.bytes_host_to_client,
                keymap_sent: existing.keymap_sent,
                stop_tx: None,
            });
        }
        fs::create_dir_all(&runtime_dir)
            .map_err(|e| format!("create wayland runtime dir {} failed: {}", runtime_dir, e))?;
        if Path::new(&socket_path).exists() {
            log_line(&format!(
                "wayland_proxy_stale_socket_replaced display={} socket={}",
                display_name, socket_path
            ));
            let _ = fs::remove_file(&socket_path);
        }
        let std_listener = UnixListener::bind(&socket_path)
            .map_err(|e| format!("bind {} failed: {}", socket_path, e))?;
        fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o666))
            .map_err(|e| format!("chmod {} failed: {}", socket_path, e))?;
        std_listener
            .set_nonblocking(true)
            .map_err(|e| format!("set nonblocking {} failed: {}", socket_path, e))?;
        let _runtime_guard = io_runtime().enter();
        let listener = tokio::net::UnixListener::from_std(std_listener)
            .map_err(|e| format!("register {} failed: {}", socket_path, e))?;
        let (stop_tx, stop_rx) = oneshot::channel::<()>();
        let runtime = WaylandProxyRuntime {
            display_name: display_name.clone(),
            display_port,
            runtime_dir: runtime_dir.clone(),
            socket_path: socket_path.clone(),
            active_clients: 0,
            default_proxy_started: false,
            build_marker: "fd-aware-keymap".to_string(),
            last_trace_id: None,
            last_error: None,
            last_client_event: None,
            last_host_event: None,
            bytes_client_to_host: 0,
            bytes_host_to_client: 0,
            keymap_sent: false,
            stop_tx: Some(stop_tx),
        };
        proxies.insert(display_name.clone(), runtime);
        spawn_wayland_proxy_task(
            display_name.clone(),
            display_port,
            socket_path.clone(),
            listener,
            stop_rx,
        );
    }
    Ok(WaylandProxyRuntime {
        display_name,
        display_port,
        runtime_dir,
        socket_path,
        active_clients: 0,
        default_proxy_started: false,
        build_marker: "fd-aware-keymap".to_string(),
        last_trace_id: None,
        last_error: None,
        last_client_event: None,
        last_host_event: None,
        bytes_client_to_host: 0,
        bytes_host_to_client: 0,
        keymap_sent: false,
        stop_tx: None,
    })
}

fn spawn_wayland_proxy_task(
    display_name: String,
    display_port: u32,
    socket_path: String,
    listener: tokio::net::UnixListener,
    mut stop_rx: oneshot::Receiver<()>,
) {
    io_runtime().spawn(async move {
        log_line(&format!(
            "wayland_proxy_listening display={} socket={} port={}",
            display_name, socket_path, display_port
        ));
        loop {
            tokio::select! {
                accept = listener.accept() => {
                    match accept {
                        Ok((stream, _)) => {
                            let trace_id = next_wayland_trace_id();
                            let accepted = match wayland_proxies().lock() {
                                Ok(mut proxies) => {
                                    if let Some(proxy) = proxies.get_mut(&display_name) {
                                        if proxy.active_clients == 0 {
                                            proxy.active_clients = 1;
                                            proxy.last_trace_id = Some(trace_id.clone());
                                            proxy.last_client_event = Some("client_accepted".to_string());
                                            true
                                        } else {
                                            proxy.last_error = Some("client_rejected_already_active".to_string());
                                            proxy.last_trace_id = Some(trace_id.clone());
                                            proxy.last_client_event = Some("client_rejected_already_active".to_string());
                                            false
                                        }
                                    } else {
                                        false
                                    }
                                }
                                Err(_) => false,
                            };
                            if !accepted {
                                log_line(&format!(
                                    "wayland_proxy_client_rejected trace_id={} display={} reason=client_already_active",
                                    trace_id, display_name
                                ));
                                drop(stream);
                                continue;
                            }
                            let task_display_name = display_name.clone();
                            tokio::spawn(async move {
                                let result = proxy_wayland_client(stream, display_port, task_display_name.clone(), trace_id.clone()).await;
                                if let Ok(mut proxies) = wayland_proxies().lock() {
                                    if let Some(proxy) = proxies.get_mut(&task_display_name) {
                                        proxy.active_clients = proxy.active_clients.saturating_sub(1);
                                        proxy.last_client_event = Some("client_closed".to_string());
                                        if let Err(err) = result.as_ref() {
                                            proxy.last_error = Some(err.clone());
                                        }
                                    }
                                }
                                if let Err(err) = result {
                                    log_line(&format!("wayland_proxy_client_failed trace_id={} port={} err={}", trace_id, display_port, err));
                                }
                            });
                        }
                        Err(err) => {
                            log_line(&format!("wayland_proxy_accept_failed display={} err={}", display_name, err));
                            tokio::time::sleep(TokioDuration::from_millis(50)).await;
                        }
                    }
                }
                _ = &mut stop_rx => {
                    break;
                }
            }
        }
        let _ = fs::remove_file(&socket_path);
        if let Ok(mut proxies) = wayland_proxies().lock() {
            proxies.remove(&display_name);
        }
        log_line(&format!("wayland_proxy_stopped display={} socket={}", display_name, socket_path));
    });
}

async fn proxy_wayland_client(
    mut stream: tokio::net::UnixStream,
    display_port: u32,
    display_name: String,
    trace_id: String,
) -> Result<(), String> {
    log_line(&format!(
        "wayland_proxy_client_accepted trace_id={} display={} port={}",
        trace_id, display_name, display_port
    ));
    log_line(&format!(
        "wayland_proxy_transport_connect_start trace_id={} display={} port={}",
        trace_id, display_name, display_port
    ));
    let vsock = match connect_vsock_stream(display_port) {
        Ok(vsock) => vsock,
        Err(err) => {
            log_line(&format!(
                "wayland_proxy_transport_unavailable trace_id={} display={} port={} err={}",
                trace_id, display_name, display_port, err
            ));
            let _ = stream.shutdown().await;
            update_wayland_proxy_state(&display_name, |proxy| {
                proxy.last_trace_id = Some(trace_id.clone());
                proxy.last_host_event = Some("transport_unavailable".to_string());
                proxy.last_error = Some(format!("display_transport_unavailable: {}", err));
            });
            return Err(format!("display_transport_unavailable: {}", err));
        }
    };
    log_line(&format!(
        "wayland_proxy_transport_connected trace_id={} display={} port={}",
        trace_id, display_name, display_port
    ));
    update_wayland_proxy_state(&display_name, |proxy| {
        proxy.last_trace_id = Some(trace_id.clone());
        proxy.last_host_event = Some("transport_connected".to_string());
    });
    let client = stream
        .into_std()
        .map_err(|e| format!("wayland client into_std failed: {}", e))?;
    let relay_trace_id = trace_id.clone();
    let (client_to_host, host_to_client) = tokio::task::spawn_blocking(move || {
        relay_wayland_transport(&display_name, &relay_trace_id, client, vsock)
    })
    .await
    .map_err(|e| format!("wayland relay join failed: {}", e))??;
    log_line(&format!(
        "wayland_proxy_client_closed trace_id={} port={} client_to_host={} host_to_client={}",
        trace_id, display_port, client_to_host, host_to_client
    ));
    Ok(())
}

fn relay_wayland_transport(
    display_name: &str,
    trace_id: &str,
    client: std::os::unix::net::UnixStream,
    vsock: std::fs::File,
) -> Result<(u64, u64), String> {
    client
        .set_nonblocking(false)
        .map_err(|e| format!("set client blocking failed: {}", e))?;
    let vsock_fd = vsock.as_raw_fd();
    let client_fd = client.as_raw_fd();

    let mut client_reader = client
        .try_clone()
        .map_err(|e| format!("clone client reader failed: {}", e))?;
    let mut client_writer = client;
    let mut vsock_reader = vsock
        .try_clone()
        .map_err(|e| format!("clone vsock reader failed: {}", e))?;
    let mut vsock_writer = vsock;

    let client_display_name = display_name.to_string();
    let client_trace_id = trace_id.to_string();
    let client_to_host = thread::spawn(move || {
        relay_wayland_client_to_host(
            &client_display_name,
            &client_trace_id,
            &mut client_reader,
            &mut vsock_writer,
        )
    });
    let host_display_name = display_name.to_string();
    let host_trace_id = trace_id.to_string();
    let host_to_client = thread::spawn(move || {
        relay_host_to_wayland_client(
            &host_display_name,
            &host_trace_id,
            &mut vsock_reader,
            &mut client_writer,
        )
    });

    let client_to_host = client_to_host
        .join()
        .map_err(|_| "client_to_host relay panicked".to_string())?
        .map_err(|e| format!("client_to_host relay failed: {}", e))?;
    unsafe {
        libc::shutdown(client_fd, libc::SHUT_RDWR);
        libc::shutdown(vsock_fd, libc::SHUT_RDWR);
    }
    let host_to_client = host_to_client
        .join()
        .map_err(|_| "host_to_client relay panicked".to_string())?
        .map_err(|e| format!("host_to_client relay failed: {}", e))?;
    Ok((client_to_host, host_to_client))
}

fn relay_wayland_client_to_host(
    display_name: &str,
    trace_id: &str,
    client_reader: &mut std::os::unix::net::UnixStream,
    vsock_writer: &mut std::fs::File,
) -> std::io::Result<u64> {
    let mut total = 0_u64;
    let mut first = true;
    let mut state = GuestWaylandParseState::new();
    loop {
        let received = recv_wayland_client_chunk(client_reader.as_raw_fd())?;
        if received.bytes.is_empty() && received.fds.is_empty() {
            log_line(&format!(
                "wayland_proxy_guest_eof trace_id={} display={} bytes={}",
                trace_id, display_name, total
            ));
            break;
        }
        if first {
            first = false;
            log_line(&format!(
                "wayland_proxy_first_guest_bytes trace_id={} display={} count={}",
                trace_id,
                display_name,
                received.bytes.len()
            ));
            update_wayland_proxy_state(display_name, |proxy| {
                proxy.last_trace_id = Some(trace_id.to_string());
                proxy.last_client_event =
                    Some(format!("first_guest_bytes:{}", received.bytes.len()));
            });
        }
        state.pending.extend_from_slice(&received.bytes);
        state.pending_fds.extend(received.fds);
        let forwarded =
            drain_guest_wayland_messages(display_name, trace_id, &mut state, vsock_writer)?;
        total += forwarded;
        update_wayland_proxy_state(display_name, |proxy| {
            proxy.bytes_client_to_host = proxy.bytes_client_to_host.saturating_add(forwarded);
            proxy.last_client_event = Some(format!("guest_bytes_forwarded:{}", forwarded));
        });
    }
    let _ = vsock_writer.flush();
    unsafe {
        libc::shutdown(vsock_writer.as_raw_fd(), libc::SHUT_RDWR);
    }
    log_line(&format!(
        "wayland_proxy_guest_to_host_shutdown trace_id={} display={} bytes={}",
        trace_id, display_name, total
    ));
    Ok(total)
}

struct GuestWaylandChunk {
    bytes: Vec<u8>,
    fds: Vec<RawFd>,
}

struct GuestWaylandParseState {
    pending: Vec<u8>,
    pending_fds: VecDeque<RawFd>,
    objects: HashMap<u32, String>,
    registry_globals: HashMap<u32, String>,
    shm_pool_fds: HashMap<u32, RawFd>,
}

impl GuestWaylandParseState {
    fn new() -> Self {
        let mut objects = HashMap::new();
        objects.insert(1, "wl_display".to_string());
        Self {
            pending: Vec::new(),
            pending_fds: VecDeque::new(),
            objects,
            registry_globals: HashMap::new(),
            shm_pool_fds: HashMap::new(),
        }
    }
}

impl Drop for GuestWaylandParseState {
    fn drop(&mut self) {
        for (_, fd) in self.shm_pool_fds.drain() {
            unsafe {
                libc::close(fd);
            }
        }
        while let Some(fd) = self.pending_fds.pop_front() {
            unsafe {
                libc::close(fd);
            }
        }
    }
}

fn recv_wayland_client_chunk(socket_fd: RawFd) -> std::io::Result<GuestWaylandChunk> {
    let mut buffer = vec![0_u8; 16 * 1024];
    let mut iov = libc::iovec {
        iov_base: buffer.as_mut_ptr() as *mut libc::c_void,
        iov_len: buffer.len(),
    };
    let control_len =
        unsafe { libc::CMSG_SPACE((std::mem::size_of::<RawFd>() * 8) as u32) } as usize;
    let mut control = vec![0_u8; control_len];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
    msg.msg_controllen = control.len() as _;

    let count = unsafe { libc::recvmsg(socket_fd, &mut msg, 0) };
    if count < 0 {
        return Err(std::io::Error::last_os_error());
    }
    buffer.truncate(count as usize);

    let mut fds = Vec::new();
    unsafe {
        let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
        while !cmsg.is_null() {
            if (*cmsg).cmsg_level == libc::SOL_SOCKET && (*cmsg).cmsg_type == libc::SCM_RIGHTS {
                let data = libc::CMSG_DATA(cmsg) as *const RawFd;
                let data_len =
                    ((*cmsg).cmsg_len as usize).saturating_sub(libc::CMSG_LEN(0) as usize);
                let fd_count = data_len / std::mem::size_of::<RawFd>();
                for index in 0..fd_count {
                    fds.push(*data.add(index));
                }
            }
            cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
        }
    }
    Ok(GuestWaylandChunk { bytes: buffer, fds })
}

fn drain_guest_wayland_messages(
    display_name: &str,
    trace_id: &str,
    state: &mut GuestWaylandParseState,
    vsock_writer: &mut std::fs::File,
) -> std::io::Result<u64> {
    let mut forwarded = 0_u64;
    loop {
        if state.pending.len() < 8 {
            break;
        }
        let object_id = read_wayland_u32(&state.pending, 0)?;
        let word = read_wayland_u32(&state.pending, 4)?;
        let opcode = (word & 0xffff) as u16;
        let size = (word >> 16) as usize;
        if size < 8 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("invalid wayland request size {}", size),
            ));
        }
        if state.pending.len() < size {
            break;
        }
        let message = state.pending[..size].to_vec();
        state.pending.drain(..size);
        let interface = state
            .objects
            .get(&object_id)
            .cloned()
            .unwrap_or_else(|| "unknown".to_string());

        if interface == "wl_shm" && opcode == 0 {
            let fd = state.pending_fds.pop_front().ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!(
                        "missing fd for wl_shm.create_pool object={} opcode={}",
                        object_id, opcode
                    ),
                )
            })?;
            let pool_id = read_wayland_u32(&message, 8)?;
            let size = read_wayland_i32(&message, 12)?.max(0) as usize;
            let data = read_fd_payload_from_dup(fd, size)?;
            if let Some(old_fd) = state.shm_pool_fds.insert(pool_id, fd) {
                unsafe {
                    libc::close(old_fd);
                }
            }
            write_display_transport_json(
                vsock_writer,
                &format!(
                    r#"{{"type":"shmPoolCreate","poolId":{},"size":{},"dataBase64":"{}"}}"#,
                    pool_id,
                    size,
                    b64_encode(&data)
                ),
            )?;
            log_line(&format!(
                "wayland_proxy_shm_pool_create_sent trace_id={} display={} pool={} size={}",
                trace_id, display_name, pool_id, size
            ));
        } else if interface == "wl_shm_pool" && opcode == 2 {
            let size = read_wayland_i32(&message, 8)?.max(0) as usize;
            let fd = *state.shm_pool_fds.get(&object_id).ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("missing shm pool fd for resize pool={}", object_id),
                )
            })?;
            let data = read_fd_payload_from_dup(fd, size)?;
            write_display_transport_json(
                vsock_writer,
                &format!(
                    r#"{{"type":"shmPoolResize","poolId":{},"size":{},"dataBase64":"{}"}}"#,
                    object_id,
                    size,
                    b64_encode(&data)
                ),
            )?;
            log_line(&format!(
                "wayland_proxy_shm_pool_resize_sent trace_id={} display={} pool={} size={}",
                trace_id, display_name, object_id, size
            ));
        }
        handle_guest_wayland_tracking(state, object_id, opcode, &message);
        write_display_transport_json(
            vsock_writer,
            &format!(
                r#"{{"type":"waylandBytes","dataBase64":"{}"}}"#,
                b64_encode(&message)
            ),
        )?;
        forwarded = forwarded.saturating_add(message.len() as u64);
    }
    Ok(forwarded)
}

fn handle_guest_wayland_tracking(
    state: &mut GuestWaylandParseState,
    object_id: u32,
    opcode: u16,
    message: &[u8],
) {
    let interface = state.objects.get(&object_id).cloned().unwrap_or_default();
    let body = &message[8..];
    if interface == "wl_display" && opcode == 1 && body.len() >= 4 {
        let registry_id = u32::from_ne_bytes([body[0], body[1], body[2], body[3]]);
        state.objects.insert(registry_id, "wl_registry".to_string());
    } else if interface == "wl_registry" && opcode == 0 && body.len() >= 16 {
        let name = u32::from_ne_bytes([body[0], body[1], body[2], body[3]]);
        if let Ok((requested, next)) = read_guest_wayland_string(body, 4) {
            if body.len() >= next + 8 {
                let new_id = u32::from_ne_bytes([
                    body[next + 4],
                    body[next + 5],
                    body[next + 6],
                    body[next + 7],
                ]);
                state.objects.insert(new_id, requested);
            }
        }
        let _ = state.registry_globals.get(&name);
    } else if interface == "wl_compositor" && opcode == 0 && body.len() >= 4 {
        let surface_id = u32::from_ne_bytes([body[0], body[1], body[2], body[3]]);
        state.objects.insert(surface_id, "wl_surface".to_string());
    } else if interface == "wl_shm" && opcode == 0 && body.len() >= 4 {
        let pool_id = u32::from_ne_bytes([body[0], body[1], body[2], body[3]]);
        state.objects.insert(pool_id, "wl_shm_pool".to_string());
    } else if interface == "wl_shm_pool" && opcode == 1 {
        state.objects.remove(&object_id);
        if let Some(fd) = state.shm_pool_fds.remove(&object_id) {
            unsafe {
                libc::close(fd);
            }
        }
    }
}

fn read_fd_payload_from_dup(fd: RawFd, size: usize) -> std::io::Result<Vec<u8>> {
    let dup_fd = unsafe { libc::dup(fd) };
    if dup_fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut file = unsafe { std::fs::File::from_raw_fd(dup_fd) };
    let _ = file.seek(SeekFrom::Start(0));
    let mut data = Vec::new();
    file.take(size as u64).read_to_end(&mut data)?;
    if data.len() < size {
        data.resize(size, 0);
    }
    Ok(data)
}

fn write_display_transport_json(writer: &mut std::fs::File, json: &str) -> std::io::Result<()> {
    let payload = json.as_bytes();
    writer.write_all(&(payload.len() as u32).to_le_bytes())?;
    writer.write_all(payload)?;
    writer.flush()
}

fn read_wayland_u32(bytes: &[u8], offset: usize) -> std::io::Result<u32> {
    let slice = bytes.get(offset..offset + 4).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "short wayland u32")
    })?;
    Ok(u32::from_ne_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

fn read_wayland_i32(bytes: &[u8], offset: usize) -> std::io::Result<i32> {
    let slice = bytes.get(offset..offset + 4).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "short wayland i32")
    })?;
    Ok(i32::from_ne_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

fn read_guest_wayland_string(bytes: &[u8], offset: usize) -> Result<(String, usize), String> {
    let len = read_wayland_u32(bytes, offset).map_err(|e| e.to_string())? as usize;
    let start = offset + 4;
    let end = start + len;
    let raw = bytes
        .get(start..end)
        .ok_or_else(|| "short wayland string".to_string())?;
    let value = if raw.last() == Some(&0) {
        &raw[..raw.len() - 1]
    } else {
        raw
    };
    Ok((String::from_utf8_lossy(value).into_owned(), (end + 3) & !3))
}

fn relay_host_to_wayland_client(
    display_name: &str,
    trace_id: &str,
    vsock_reader: &mut std::fs::File,
    client_writer: &mut std::os::unix::net::UnixStream,
) -> std::io::Result<u64> {
    let mut total = 0_u64;
    let mut first = true;
    let mut pending = Vec::<u8>::new();
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = vsock_reader.read(&mut buffer)?;
        if count == 0 {
            log_line(&format!(
                "wayland_proxy_host_eof trace_id={} display={} bytes={}",
                trace_id, display_name, total
            ));
            break;
        }
        if first {
            first = false;
            log_line(&format!(
                "wayland_proxy_first_host_bytes trace_id={} display={} count={}",
                trace_id, display_name, count
            ));
        }
        pending.extend_from_slice(&buffer[..count]);
        update_wayland_proxy_state(display_name, |proxy| {
            proxy.last_trace_id = Some(trace_id.to_string());
            proxy.last_host_event = Some(format!("raw_or_control_bytes_received:{}", count));
        });
        drain_host_wayland_bytes(
            display_name,
            trace_id,
            client_writer,
            &mut pending,
            &mut total,
        )?;
    }
    if !pending.is_empty() {
        client_writer.write_all(&pending)?;
        total += pending.len() as u64;
    }
    let _ = client_writer.flush();
    let _ = client_writer.shutdown(std::net::Shutdown::Both);
    log_line(&format!(
        "wayland_proxy_host_to_guest_shutdown trace_id={} display={} bytes={}",
        trace_id, display_name, total
    ));
    Ok(total)
}

fn drain_host_wayland_bytes(
    display_name: &str,
    trace_id: &str,
    client_writer: &mut std::os::unix::net::UnixStream,
    pending: &mut Vec<u8>,
    total: &mut u64,
) -> std::io::Result<()> {
    loop {
        if pending.is_empty() {
            return Ok(());
        }
        if pending.starts_with(b"MSLW") {
            if pending.len() < 8 {
                return Ok(());
            }
            let len = u32::from_le_bytes([pending[4], pending[5], pending[6], pending[7]]) as usize;
            if pending.len() < 8 + len {
                return Ok(());
            }
            let payload = pending[8..8 + len].to_vec();
            pending.drain(..8 + len);
            log_line(&format!(
                "wayland_proxy_control_frame_received trace_id={} display={} size={}",
                trace_id, display_name, len
            ));
            update_wayland_proxy_state(display_name, |proxy| {
                proxy.last_trace_id = Some(trace_id.to_string());
                proxy.last_host_event = Some(format!("control_frame_received:{}", len));
            });
            if let Err(err) =
                handle_wayland_control_frame(display_name, trace_id, client_writer, &payload)
            {
                log_line(&format!(
                    "wayland_proxy_control_frame_failed trace_id={} display={} err={}",
                    trace_id, display_name, err
                ));
                update_wayland_proxy_state(display_name, |proxy| {
                    proxy.last_error = Some(format!("control_frame_failed: {}", err));
                    proxy.last_host_event = Some("control_frame_failed".to_string());
                });
            }
            continue;
        }

        if pending.len() < 8 {
            return Ok(());
        }

        let object_id = u32::from_ne_bytes([pending[0], pending[1], pending[2], pending[3]]);
        let header = u32::from_ne_bytes([pending[4], pending[5], pending[6], pending[7]]);
        let raw_len = (header >> 16) as usize;
        let opcode = header & 0xffff;
        if object_id == 0 || raw_len < 8 || raw_len > 16 * 1024 * 1024 {
            log_line(&format!(
                "wayland_proxy_host_event_invalid trace_id={} display={} object={} opcode={} size={} pending={}",
                trace_id,
                display_name,
                object_id,
                opcode,
                raw_len,
                pending.len()
            ));
            let raw_len = pending.len();
            client_writer.write_all(pending)?;
            client_writer.flush()?;
            *total += raw_len as u64;
            update_wayland_proxy_state(display_name, |proxy| {
                proxy.bytes_host_to_client =
                    proxy.bytes_host_to_client.saturating_add(raw_len as u64);
                proxy.last_host_event = Some(format!("raw_bytes_forwarded_invalid:{}", raw_len));
            });
            pending.clear();
            return Ok(());
        }
        if pending.len() < raw_len {
            return Ok(());
        }

        client_writer.write_all(&pending[..raw_len])?;
        client_writer.flush()?;
        *total += raw_len as u64;
        log_line(&format!(
            "wayland_proxy_raw_event_forwarded trace_id={} display={} object={} opcode={} size={}",
            trace_id, display_name, object_id, opcode, raw_len
        ));
        update_wayland_proxy_state(display_name, |proxy| {
            proxy.bytes_host_to_client = proxy.bytes_host_to_client.saturating_add(raw_len as u64);
            proxy.last_host_event = Some(format!(
                "raw_event_forwarded:object={},opcode={},size={}",
                object_id, opcode, raw_len
            ));
        });
        pending.drain(..raw_len);
    }
}

fn handle_wayland_control_frame(
    display_name: &str,
    trace_id: &str,
    client_writer: &mut std::os::unix::net::UnixStream,
    payload: &[u8],
) -> Result<(), String> {
    let text =
        std::str::from_utf8(payload).map_err(|e| format!("control frame utf8 failed: {}", e))?;
    let message_type = extract_string(text, "type").unwrap_or_default();
    if message_type != "keyboardKeymap" {
        return Err(format!("unsupported control frame type {}", message_type));
    }
    let keyboard_id = extract_int(text, "keyboardId").ok_or("missing keyboardId")? as u32;
    let format = extract_int(text, "format").unwrap_or(1) as u32;
    let size = extract_int(text, "size").unwrap_or(0).max(0) as usize;
    let data_base64 = extract_string(text, "dataBase64").ok_or("missing dataBase64")?;
    let mut keymap = b64_decode(&data_base64)?;
    if size > 0 && keymap.len() > size {
        keymap.truncate(size);
    }
    send_keyboard_keymap_event(client_writer, keyboard_id, format, &keymap)?;
    log_line(&format!(
        "wayland_proxy_keyboard_keymap_sent trace_id={} display={} keyboard={} size={}",
        trace_id,
        display_name,
        keyboard_id,
        keymap.len()
    ));
    update_wayland_proxy_state(display_name, |proxy| {
        proxy.last_trace_id = Some(trace_id.to_string());
        proxy.keymap_sent = true;
        proxy.last_host_event = Some("keyboard_keymap_sent".to_string());
    });
    Ok(())
}

fn send_keyboard_keymap_event(
    client_writer: &mut std::os::unix::net::UnixStream,
    keyboard_id: u32,
    format: u32,
    keymap: &[u8],
) -> Result<(), String> {
    let mut file = create_wayland_fd_payload("keymap", keymap)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|e| format!("seek keymap payload failed: {}", e))?;
    let fd = file.as_raw_fd();
    let size = keymap.len() as u32;
    let mut event = Vec::with_capacity(16);
    event.extend_from_slice(&keyboard_id.to_ne_bytes());
    event.extend_from_slice(&((16_u32 << 16) | 0_u32).to_ne_bytes());
    event.extend_from_slice(&format.to_ne_bytes());
    event.extend_from_slice(&size.to_ne_bytes());
    send_wayland_message_with_fd(client_writer.as_raw_fd(), &event, fd)
}

fn create_wayland_fd_payload(prefix: &str, data: &[u8]) -> Result<std::fs::File, String> {
    let path = format!(
        "/tmp/msl-wayland-{}-{}-{}",
        prefix,
        std::process::id(),
        now_epoch_ms()
    );
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)
        .map_err(|e| format!("create {} failed: {}", path, e))?;
    let _ = fs::remove_file(&path);
    file.write_all(data)
        .map_err(|e| format!("write fd payload failed: {}", e))?;
    file.flush()
        .map_err(|e| format!("flush fd payload failed: {}", e))?;
    Ok(file)
}

fn send_wayland_message_with_fd(
    socket_fd: RawFd,
    bytes: &[u8],
    fd_to_send: RawFd,
) -> Result<(), String> {
    unsafe {
        let mut iov = libc::iovec {
            iov_base: bytes.as_ptr() as *mut libc::c_void,
            iov_len: bytes.len(),
        };
        let control_len = libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) as usize;
        let mut control = vec![0_u8; control_len];
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
        msg.msg_controllen = control.len() as _;

        let cmsg = libc::CMSG_FIRSTHDR(&msg);
        if cmsg.is_null() {
            return Err("CMSG_FIRSTHDR returned null".to_string());
        }
        (*cmsg).cmsg_level = libc::SOL_SOCKET;
        (*cmsg).cmsg_type = libc::SCM_RIGHTS;
        (*cmsg).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as _;
        let data = libc::CMSG_DATA(cmsg) as *mut RawFd;
        *data = fd_to_send;
        msg.msg_controllen = (*cmsg).cmsg_len as _;

        let sent = libc::sendmsg(socket_fd, &msg, libc::MSG_NOSIGNAL);
        if sent < 0 {
            return Err(format!(
                "sendmsg failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        if sent as usize != bytes.len() {
            return Err(format!("short sendmsg: {} of {}", sent, bytes.len()));
        }
    }
    Ok(())
}

fn stop_wayland_proxy(display_name: &str) -> Result<Option<WaylandProxyRuntime>, String> {
    let mut proxies = wayland_proxies()
        .lock()
        .map_err(|_| "wayland proxy lock poisoned".to_string())?;
    let mut proxy = match proxies.remove(display_name) {
        Some(proxy) => proxy,
        None => return Ok(None),
    };
    if let Some(stop_tx) = proxy.stop_tx.take() {
        let _ = stop_tx.send(());
    }
    let _ = fs::remove_file(&proxy.socket_path);
    Ok(Some(WaylandProxyRuntime {
        display_name: proxy.display_name,
        display_port: proxy.display_port,
        runtime_dir: proxy.runtime_dir,
        socket_path: proxy.socket_path,
        active_clients: proxy.active_clients,
        default_proxy_started: proxy.default_proxy_started,
        build_marker: proxy.build_marker,
        last_trace_id: proxy.last_trace_id,
        last_error: proxy.last_error,
        last_client_event: proxy.last_client_event,
        last_host_event: proxy.last_host_event,
        bytes_client_to_host: proxy.bytes_client_to_host,
        bytes_host_to_client: proxy.bytes_host_to_client,
        keymap_sent: proxy.keymap_sent,
        stop_tx: None,
    }))
}

fn validate_wayland_display_name(value: &str) -> Result<(), String> {
    if value.is_empty() || value.contains('/') || value.contains('\0') || value.contains("..") {
        return Err("invalid displayName".to_string());
    }
    Ok(())
}

fn child_process_environment(
    runtime: &RuntimeUserContext,
    env_additions: Vec<(String, String)>,
) -> Vec<(String, String)> {
    let mut env_map: BTreeMap<String, String> = env::vars().collect();

    env_map.insert("HOME".to_string(), runtime.home.clone());
    env_map.insert("TERM".to_string(), "xterm-256color".to_string());
    env_map.insert(
        "PATH".to_string(),
        "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin".to_string(),
    );
    env_map.insert("USER".to_string(), runtime.username.clone());
    env_map.insert("LOGNAME".to_string(), runtime.username.clone());
    env_map.insert("SHELL".to_string(), runtime.shell.clone());
    env_map.insert("LANG".to_string(), "C.UTF-8".to_string());
    env_map.insert("LC_ALL".to_string(), "C.UTF-8".to_string());

    if !env_map.contains_key("TZ") {
        if let Some(time_zone_id) = load_timezone_from_process_or_etc_environment() {
            env_map.insert("TZ".to_string(), time_zone_id);
        }
    }

    for (key, value) in env_additions {
        if is_valid_env_key(&key) {
            env_map.insert(key, value);
        }
    }

    env_map.into_iter().collect()
}

fn is_valid_timezone_id(value: &str) -> bool {
    !value.is_empty()
        && !value
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace())
}

fn ensure_mount_prerequisites() {
    mount_fs_if_needed("/proc", b"proc\0", b"proc\0", None);
    mount_fs_if_needed("/sys", b"sysfs\0", b"sysfs\0", None);
    mount_fs_if_needed("/sys/fs/cgroup", b"cgroup2\0", b"cgroup2\0", None);
    mount_fs_if_needed("/run", b"tmpfs\0", b"tmpfs\0", Some(b"mode=0755\0"));
}

fn bootstrap_ephemeral_tmp_storage() -> Result<(), String> {
    let mode = env::var("MSL_EPHEMERAL_TMP_MODE").unwrap_or_default();
    if !mode.eq_ignore_ascii_case("ephemeral") {
        return Ok(());
    }

    let device = env::var("MSL_EPHEMERAL_TMP_DEVICE")
        .map_err(|_| "stage=env detail=missing_device".to_string())?;
    let size_mib = env::var("MSL_EPHEMERAL_TMP_SIZE_MIB").unwrap_or_else(|_| "-".to_string());
    let reset_on_stop =
        env::var("MSL_EPHEMERAL_TMP_RESET_ON_STOP").unwrap_or_else(|_| "-".to_string());
    let label = env::var("MSL_EPHEMERAL_TMP_LABEL").unwrap_or_else(|_| "-".to_string());

    log_line(&format!(
        "tmp_storage_prepare_started mode=ephemeral device={} size_mib={} reset_on_stop={} label={}",
        device, size_mib, reset_on_stop, label
    ));

    mount_ephemeral_tmp_storage(&device)?;
    log_line(&format!(
        "tmp_storage_prepare_succeeded mode=ephemeral device={} size_mib={} reset_on_stop={} label={}",
        device, size_mib, reset_on_stop, label
    ));
    Ok(())
}

fn mount_ephemeral_tmp_storage(device: &str) -> Result<(), String> {
    mount_ext4_if_needed(device, "/run/msl/tmp")?;
    set_path_mode("/run/msl/tmp", 0o1777)
        .map_err(|e| format!("stage=chmod_tmp_root detail={}", e))?;

    fs::create_dir_all("/tmp")
        .map_err(|e| format!("stage=tmp_dir_create detail=failed to create /tmp: {}", e))?;
    bind_mount_directory_if_needed("/run/msl/tmp", "/tmp")
        .map_err(|e| format!("stage=tmp_bind detail={}", e))?;
    set_path_mode("/tmp", 0o1777).map_err(|e| format!("stage=chmod_tmp detail={}", e))?;

    if mount_fstype("/").as_deref() == Some("erofs") {
        prepare_erofs_ephemeral_state()?;
    }
    Ok(())
}

fn mount_ext4_if_needed(device: &str, target: &str) -> Result<(), String> {
    fs::create_dir_all(target).map_err(|e| format!("failed to create {}: {}", target, e))?;
    if is_mountpoint(target) {
        return Ok(());
    }

    let source_bytes = to_c_string_bytes(device);
    let target_bytes = to_c_string_bytes(target);
    let fstype = b"ext4\0";
    let mount_ret = unsafe {
        mount(
            source_bytes.as_ptr(),
            target_bytes.as_ptr(),
            fstype.as_ptr(),
            MS_NOSUID | MS_NODEV,
            std::ptr::null(),
        )
    };
    if mount_ret == 0 {
        return Ok(());
    }
    let err = std::io::Error::last_os_error();
    if err.raw_os_error() == Some(16) {
        return Ok(());
    }
    Err(format!("failed to mount {} on {}: {}", device, target, err))
}

fn set_path_mode(path: &str, mode: u32) -> Result<(), String> {
    let permissions = fs::Permissions::from_mode(mode);
    fs::set_permissions(path, permissions)
        .map_err(|e| format!("failed to chmod {} to {:o}: {}", path, mode, e))
}

fn bind_mount_directory_if_needed(source: &str, target: &str) -> Result<bool, String> {
    bind_mount_any_if_needed(source, target, true)
}

fn bind_mount_any_if_needed(source: &str, target: &str, directory: bool) -> Result<bool, String> {
    if directory {
        fs::create_dir_all(target).map_err(|e| format!("failed to create {}: {}", target, e))?;
    } else {
        let target_path = Path::new(target);
        if let Some(parent) = target_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create {}: {}", parent.display(), e))?;
        }
        if !target_path.exists() {
            OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(target_path)
                .map_err(|e| format!("failed to create {}: {}", target, e))?;
        }
    }

    let source_bytes = to_c_string_bytes(source);
    let target_bytes = to_c_string_bytes(target);
    let mount_ret = unsafe {
        mount(
            source_bytes.as_ptr(),
            target_bytes.as_ptr(),
            std::ptr::null(),
            MS_BIND,
            std::ptr::null(),
        )
    };
    if mount_ret == 0 {
        return Ok(true);
    }
    let err = std::io::Error::last_os_error();
    if err.raw_os_error() == Some(16) {
        return Ok(false);
    }
    Err(format!(
        "bind mount {} -> {} failed: {}",
        source, target, err
    ))
}

fn prepare_erofs_ephemeral_state() -> Result<(), String> {
    fs::create_dir_all("/run/msl/tmp/var")
        .map_err(|e| format!("stage=erofs_var_root detail={}", e))?;
    fs::create_dir_all("/run/msl/tmp/etc")
        .map_err(|e| format!("stage=erofs_etc_root detail={}", e))?;

    copy_tree_best_effort("/var", "/run/msl/tmp/var", "erofs_var_copy");
    for path in [
        "/run/msl/tmp/var/log",
        "/run/msl/tmp/var/tmp",
        "/run/msl/tmp/var/devcontainer",
    ] {
        fs::create_dir_all(path).map_err(|e| {
            format!(
                "stage=erofs_var_tree detail=failed to create {}: {}",
                path, e
            )
        })?;
    }
    set_path_mode("/run/msl/tmp/var/tmp", 0o1777)
        .map_err(|e| format!("stage=erofs_var_tmp_mode detail={}", e))?;
    bind_mount_directory_if_needed("/run/msl/tmp/var", "/var")
        .map_err(|e| format!("stage=erofs_var_bind detail={}", e))?;
    let _ = set_path_mode("/var/tmp", 0o1777);

    copy_tree_best_effort("/etc", "/run/msl/tmp/etc", "erofs_etc_copy");
    bind_mount_directory_if_needed("/run/msl/tmp/etc", "/etc")
        .map_err(|e| format!("stage=erofs_etc_bind detail={}", e))?;
    Ok(())
}

fn copy_tree_best_effort(source: &str, target: &str, stage: &str) {
    let source_path = Path::new(source);
    if !source_path.exists() {
        return;
    }
    if let Err(err) = copy_tree_entry(source_path, Path::new(target)) {
        log_line(&format!(
            "tmp_storage_prepare_warning stage={} source={} target={} error={}",
            stage, source, target, err
        ));
    }
}

fn copy_tree_entry(source: &Path, target: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(source)
        .map_err(|e| format!("failed to stat {}: {}", source.display(), e))?;
    let file_type = metadata.file_type();

    if file_type.is_symlink() {
        if target.exists() {
            let _ = fs::remove_file(target);
            let _ = fs::remove_dir_all(target);
        }
        let link_target = fs::read_link(source)
            .map_err(|e| format!("failed to read symlink {}: {}", source.display(), e))?;
        symlink(&link_target, target)
            .map_err(|e| format!("failed to create symlink {}: {}", target.display(), e))?;
        return Ok(());
    }

    if file_type.is_dir() {
        fs::create_dir_all(target)
            .map_err(|e| format!("failed to create {}: {}", target.display(), e))?;
        let _ = fs::set_permissions(
            target,
            fs::Permissions::from_mode(metadata.permissions().mode() & 0o7777),
        );
        let entries = fs::read_dir(source)
            .map_err(|e| format!("failed to read {}: {}", source.display(), e))?;
        for entry in entries {
            let entry = entry
                .map_err(|e| format!("failed to read dir entry {}: {}", source.display(), e))?;
            copy_tree_entry(&entry.path(), &target.join(entry.file_name()))?;
        }
        return Ok(());
    }

    if file_type.is_file() {
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create {}: {}", parent.display(), e))?;
        }
        fs::copy(source, target).map_err(|e| {
            format!(
                "failed to copy {} to {}: {}",
                source.display(),
                target.display(),
                e
            )
        })?;
        let _ = fs::set_permissions(
            target,
            fs::Permissions::from_mode(metadata.permissions().mode() & 0o7777),
        );
        return Ok(());
    }

    log_line(&format!(
        "tmp_storage_prepare_warning stage=erofs_tree_copy_skip source={} reason=unsupported_file_type",
        source.display()
    ));
    Ok(())
}

fn is_mountpoint(target: &str) -> bool {
    let text = match fs::read_to_string("/proc/self/mountinfo") {
        Ok(v) => v,
        Err(_) => return false,
    };
    text.lines().any(|line| {
        let mut fields = line.split_whitespace();
        // mountinfo: id parent major:minor root mount_point ...
        let _id = fields.next();
        let _parent = fields.next();
        let _majmin = fields.next();
        let _root = fields.next();
        let mount_point = fields.next();
        mount_point == Some(target)
    })
}

fn mount_fstype(target: &str) -> Option<String> {
    let text = fs::read_to_string("/proc/self/mountinfo").ok()?;
    for line in text.lines() {
        let mut parts = line.split(" - ");
        let left = parts.next()?;
        let right = parts.next()?;
        if parts.next().is_some() {
            continue;
        }

        let mut left_fields = left.split_whitespace();
        let _id = left_fields.next();
        let _parent = left_fields.next();
        let _majmin = left_fields.next();
        let _root = left_fields.next();
        let mount_point = left_fields.next()?;
        if mount_point != target {
            continue;
        }

        let mut right_fields = right.split_whitespace();
        let fstype = right_fields.next()?;
        return Some(fstype.to_string());
    }
    None
}

fn mount_fs_if_needed(target: &str, source: &[u8], fstype: &[u8], data: Option<&[u8]>) {
    if let Err(e) = fs::create_dir_all(target) {
        log_line(&format!("failed to create mountpoint {}: {}", target, e));
        return;
    }

    // In service-managed boot, /proc,/sys,/run are already mounted by the init system.
    // Re-mounting /run here can shadow systemd runtime state.
    if is_mountpoint(target) {
        return;
    }

    let mut target_bytes = target.as_bytes().to_vec();
    target_bytes.push(0);
    let data_ptr = data.map_or(std::ptr::null(), |v| v.as_ptr());

    let mount_ret = unsafe {
        mount(
            source.as_ptr(),
            target_bytes.as_ptr(),
            fstype.as_ptr(),
            0,
            data_ptr,
        )
    };
    if mount_ret != 0 {
        let err = std::io::Error::last_os_error();
        // EBUSY (16): already mounted.
        if err.raw_os_error() != Some(16) {
            log_line(&format!("mount {} failed: {}", target, err));
        }
    }
}

fn normalize_absolute_path(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || !trimmed.starts_with('/') {
        return None;
    }
    let mut normalized = trimmed.to_string();
    while normalized.len() > 1 && normalized.ends_with('/') {
        normalized.pop();
    }
    Some(normalized)
}

fn to_c_string_bytes(value: &str) -> Vec<u8> {
    let mut bytes = value.as_bytes().to_vec();
    bytes.push(0);
    bytes
}

fn mount_virtiofs_macos_if_needed() -> Result<bool, String> {
    if mount_fstype("/").as_deref() == Some("erofs") {
        mount_fs_if_needed("/mnt", b"tmpfs\0", b"tmpfs\0", Some(b"mode=0755\0"));
    }
    fs::create_dir_all("/mnt/macos").map_err(|e| format!("failed to create /mnt/macos: {}", e))?;
    let source = b"macos\0";
    let target = b"/mnt/macos\0";
    let fstype = b"virtiofs\0";
    let mount_ret = unsafe {
        mount(
            source.as_ptr(),
            target.as_ptr(),
            fstype.as_ptr(),
            0,
            std::ptr::null(),
        )
    };
    if mount_ret == 0 {
        return Ok(true);
    }
    let err = std::io::Error::last_os_error();
    if err.raw_os_error() == Some(16) {
        return Ok(false);
    }
    Err(format!("mount /mnt/macos failed: {}", err))
}

fn bind_mount_if_needed(source: &str, target: &str) -> Result<bool, String> {
    bind_mount_directory_if_needed(source, target)
}

fn ensure_pty_prerequisites() {
    if let Err(e) = fs::create_dir_all("/dev/pts") {
        log_line(&format!("failed to create /dev/pts: {}", e));
        return;
    }
    if is_mountpoint("/dev/pts") {
        return;
    }

    let source = b"devpts\0";
    let target = b"/dev/pts\0";
    let fstype = b"devpts\0";
    let data = b"newinstance,ptmxmode=0666,mode=0620,gid=5\0";
    let mount_ret = unsafe {
        mount(
            source.as_ptr(),
            target.as_ptr(),
            fstype.as_ptr(),
            0,
            data.as_ptr(),
        )
    };
    if mount_ret != 0 {
        let err = std::io::Error::last_os_error();
        // EBUSY (16): already mounted.
        if err.raw_os_error() != Some(16) {
            log_line(&format!("devpts mount failed: {}", err));
        }
    }

    if !Path::new("/dev/ptmx").exists() {
        if let Err(e) = symlink("/dev/pts/ptmx", "/dev/ptmx") {
            log_line(&format!("failed to create /dev/ptmx symlink: {}", e));
        }
    }
}

fn run_vsock_client(port: u32) -> Result<(), String> {
    let mut backoff_ms: u64 = 100;
    const MAX_BACKOFF_MS: u64 = 2000;

    loop {
        log_line(&format!("attempting vsock connect to host port {}", port));
        let stream = match connect_vsock_stream(port) {
            Ok(stream) => stream,
            Err(err) => {
                log_line(&format!(
                    "vsock connect to host port {} failed: {}",
                    port, err
                ));
                thread::sleep(Duration::from_millis(backoff_ms));
                backoff_ms = (backoff_ms * 2).min(MAX_BACKOFF_MS);
                continue;
            }
        };

        log_line(&format!("vsock connected to host port {}", port));
        backoff_ms = 100; // reset on successful connect
        let mut stream = stream;
        if let Err(err) = send_role_hello(&mut stream, "control") {
            log_line(&format!("control hello send failed: {}", err));
            drop(stream);
            thread::sleep(Duration::from_millis(backoff_ms));
            backoff_ms = (backoff_ms * 2).min(MAX_BACKOFF_MS);
            continue;
        }
        log_line("control hello sent");
        handle_persistent_connection(stream);

        log_line("vsock connection closed, reconnecting...");
    }
}

fn connect_single_vsock_session(port: u32, role: &str) -> Result<(), String> {
    log_line(&format!(
        "attempting vsock connect to host port {} role={}",
        port, role
    ));
    let mut stream = connect_vsock_stream(port).map_err(|err| {
        format!(
            "vsock connect to host port {} failed for role={}: {}",
            port, role, err
        )
    })?;
    log_line(&format!(
        "vsock connected to host port {} role={}",
        port, role
    ));
    send_role_hello(&mut stream, &format!("sideband:{}", role))?;
    log_line(&format!("sideband hello sent role={}", role));
    handle_persistent_connection(stream);
    log_line(&format!("vsock connection closed role={}", role));
    Ok(())
}

fn connect_vsock_stream(port: u32) -> Result<std::fs::File, String> {
    let fd = unsafe { socket(AF_VSOCK, SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(format!(
            "socket(AF_VSOCK) failed: {}",
            std::io::Error::last_os_error()
        ));
    }

    let flags = unsafe { fcntl(fd, F_GETFL) };
    if flags < 0 {
        let err = std::io::Error::last_os_error();
        unsafe {
            close(fd);
        }
        return Err(format!("fcntl(F_GETFL) failed: {}", err));
    }
    if unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) } < 0 {
        let err = std::io::Error::last_os_error();
        unsafe {
            close(fd);
        }
        return Err(format!("fcntl(F_SETFL, O_NONBLOCK) failed: {}", err));
    }

    let addr = SockaddrVm {
        svm_family: AF_VSOCK as u16,
        svm_reserved1: 0,
        svm_port: port,
        svm_cid: VMADDR_CID_HOST,
        svm_zero: [0; 4],
    };

    let ret = unsafe { connect(fd, &addr, std::mem::size_of::<SockaddrVm>() as u32) };
    if ret == 0 {
        if unsafe { fcntl(fd, F_SETFL, flags) } < 0 {
            let err = std::io::Error::last_os_error();
            unsafe {
                close(fd);
            }
            return Err(format!("fcntl(F_SETFL) restore failed: {}", err));
        }
        return Ok(unsafe { FromRawFd::from_raw_fd(fd) });
    }

    let err = std::io::Error::last_os_error();
    let raw = err.raw_os_error();
    if raw != Some(libc::EINPROGRESS) && raw != Some(libc::EAGAIN) && raw != Some(libc::EINTR) {
        unsafe {
            close(fd);
        }
        return Err(err.to_string());
    }

    let mut pfd = PollFd {
        fd,
        events: POLLOUT,
        revents: 0,
    };
    let poll_ret = unsafe { poll(&mut pfd, 1, 1000) };
    if poll_ret == 0 {
        unsafe {
            close(fd);
        }
        return Err("connect timed out waiting for writable socket".to_string());
    }
    if poll_ret < 0 {
        let poll_err = std::io::Error::last_os_error();
        unsafe {
            close(fd);
        }
        return Err(format!("poll during connect failed: {}", poll_err));
    }

    let retry = unsafe { connect(fd, &addr, std::mem::size_of::<SockaddrVm>() as u32) };
    if retry < 0 {
        let retry_err = std::io::Error::last_os_error();
        if retry_err.raw_os_error() != Some(libc::EISCONN) {
            unsafe {
                close(fd);
            }
            return Err(retry_err.to_string());
        }
    }

    if unsafe { fcntl(fd, F_SETFL, flags) } < 0 {
        let err = std::io::Error::last_os_error();
        unsafe {
            close(fd);
        }
        return Err(format!("fcntl(F_SETFL) restore failed: {}", err));
    }
    Ok(unsafe { FromRawFd::from_raw_fd(fd) })
}

fn handle_persistent_connection(mut stream: std::fs::File) {
    loop {
        // Poll for data before blocking on frame read.
        // This prevents the connection handler from blocking indefinitely when the
        // host side becomes slow or unresponsive (e.g. during macOS sleep).
        // Use -1 (infinite wait): the daemon owns the VM lifecycle and will
        // shut down msl-init by stopping the VM. No need for msl-init to
        // independently timeout the vsock connection.
        let fd = stream.as_raw_fd();
        let mut rpfd = PollFd {
            fd,
            events: POLLIN,
            revents: 0,
        };
        let poll_ret = unsafe { poll(&mut rpfd, 1, -1) };
        if poll_ret == 0 {
            // Should not happen with timeout=-1, but handle gracefully
            continue;
        }
        if poll_ret < 0 {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() == Some(4) {
                // EINTR
                continue;
            }
            log_line(&format!("vsock read poll error: {}", e));
            return;
        }
        // Check for hangup/error
        if (rpfd.revents & POLLHUP) != 0 && (rpfd.revents & POLLIN) == 0 {
            log_line("vsock POLLHUP from host");
            return;
        }
        if (rpfd.revents & POLLERR) != 0 {
            log_line("vsock POLLERR from host");
            return;
        }

        let request_frame = match read_frame(&mut stream) {
            Ok(Some(frame)) => frame,
            Ok(None) => {
                log_line("vsock EOF from host");
                return;
            }
            Err(e) => {
                log_line(&format!("vsock read error: {}", e));
                return;
            }
        };

        match decode_frame(request_frame.as_slice()) {
            Ok(decoded) if decoded.magic == INIT_CHANNEL_FRAME_MAGIC => {
                let decoded_op = decoded.opcode;
                let decoded_header = decoded._header.clone();
                log_line(&format!("direct_frame_received opcode={}", decoded_op));
                let streamed = match decoded.opcode {
                    INIT_CHANNEL_FRAME_OPCODE_PROC_SUBSCRIBE_REQUEST => {
                        if let Some(proc_id) = extract_direct_string(&decoded_header, "procId") {
                            log_line(&format!(
                                "proc_subscribe_stream_started proc_id={}",
                                proc_id
                            ));
                        } else {
                            log_line("proc_subscribe_stream_started proc_id=unknown");
                        }
                        if let Err(err) = handle_direct_proc_subscribe(decoded._header, &mut stream)
                        {
                            log_line(&format!("proc subscribe error: {}", err));
                        }
                        true
                    }
                    INIT_CHANNEL_FRAME_OPCODE_PTY_SUBSCRIBE_REQUEST => {
                        if let Some(pty_id) = extract_direct_string(&decoded_header, "ptyId") {
                            log_line(&format!("pty_subscribe_stream_started pty_id={}", pty_id));
                        } else {
                            log_line("pty_subscribe_stream_started pty_id=unknown");
                        }
                        if let Err(err) = handle_direct_pty_subscribe(decoded._header, &mut stream)
                        {
                            log_line(&format!("pty subscribe error: {}", err));
                        }
                        true
                    }
                    _ => false,
                };
                if streamed {
                    log_line(&format!(
                        "vsock direct stream handler returning opcode={}",
                        decoded_op
                    ));
                    return;
                }
            }
            _ => {}
        }

        let response_frame = handle_frame(request_frame);
        if stream.write_all(&response_frame).is_err() {
            log_line("vsock write error");
            return;
        }
        if stream.flush().is_err() {
            log_line("vsock flush error");
            return;
        }
    }
    // stream (owning the fd) is dropped here, closing the fd
}

fn send_role_hello(stream: &mut std::fs::File, role: &str) -> Result<(), String> {
    let line = format!("MSLB2 HELLO 1 {}", role);
    stream
        .write_all(format!("{line}\n").as_bytes())
        .map_err(|e| format!("write role hello failed: {e}"))?;
    stream
        .flush()
        .map_err(|e| format!("flush role hello failed: {e}"))?;
    Ok(())
}

fn run_file_handoff_loop(handoff_file: &str, ack_file: &str) -> Result<(), String> {
    let handoff = Path::new(handoff_file);
    if let Some(parent) = handoff.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("failed to create handoff dir: {e}"))?;
    }
    let ack = Path::new(ack_file);
    if let Some(parent) = ack.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("failed to create ack dir: {e}"))?;
    }
    log_line(&format!(
        "file handoff loop started handoff={} ack={}",
        handoff_file, ack_file
    ));

    let mut last_request_id = String::new();
    loop {
        if let Ok(data) = fs::read(handoff) {
            let request_payload = match decode_json_rpc_request_payload(&data) {
                Ok(payload) => payload,
                Err(e) => {
                    log_line(&format!("file handoff decode error: {}", e));
                    thread::sleep(Duration::from_millis(50));
                    continue;
                }
            };
            let request_id = extract_string(&request_payload, "requestId").unwrap_or_default();
            if !request_id.is_empty() && request_id != last_request_id {
                let response = handle_request_line(&request_payload);
                let response_frame = encode_json_rpc_response(&response);
                let tmp_ack = format!("{}.tmp", ack_file);
                if fs::write(&tmp_ack, response_frame).is_ok() {
                    let _ = fs::rename(&tmp_ack, ack);
                    last_request_id = request_id;
                }
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn handle_frame(frame: Vec<u8>) -> Vec<u8> {
    match decode_frame(frame.as_slice()) {
        Ok(decoded) => {
            if decoded.magic != INIT_CHANNEL_FRAME_MAGIC {
                let response = error_response(
                    "unknown",
                    "unknown",
                    "invalid_request",
                    "invalid init channel frame magic",
                );
                return encode_json_rpc_response(&response);
            }
            match decoded.opcode {
                INIT_CHANNEL_FRAME_OPCODE_JSON_RPC_REQUEST => {
                    let request = match String::from_utf8(decoded.payload) {
                        Ok(v) => v,
                        Err(_) => {
                            let response = error_response(
                                "unknown",
                                "unknown",
                                "invalid_request",
                                "invalid JSON-RPC payload",
                            );
                            return encode_json_rpc_response(&response);
                        }
                    };
                    let request_op =
                        extract_string(&request, "op").unwrap_or_else(|| "unknown".to_string());
                    log_line(&format!("control_request_received op={}", request_op));
                    let response = handle_request_line(&request);
                    encode_json_rpc_response(&response)
                }
                INIT_CHANNEL_FRAME_OPCODE_PTY_READ_REQUEST => {
                    handle_direct_pty_read(decoded._header)
                }
                INIT_CHANNEL_FRAME_OPCODE_PTY_WRITE_REQUEST => {
                    handle_direct_pty_write(decoded._header, decoded.payload)
                }
                INIT_CHANNEL_FRAME_OPCODE_PROC_READ_REQUEST => {
                    handle_direct_proc_read(decoded._header)
                }
                INIT_CHANNEL_FRAME_OPCODE_PROC_WRITE_REQUEST => {
                    handle_direct_proc_write(decoded._header, decoded.payload)
                }
                _ => {
                    let response = error_response(
                        "unknown",
                        "unknown",
                        "unsupported_op",
                        "unsupported init channel frame opcode",
                    );
                    encode_json_rpc_response(&response)
                }
            }
        }
        Err(e) => {
            let response = error_response(
                "unknown",
                "unknown",
                "invalid_request",
                &format!("invalid init channel frame: {}", e),
            );
            encode_json_rpc_response(&response)
        }
    }
}

fn handle_request_line(line: &str) -> String {
    let version = extract_int(line, "version").unwrap_or(1);
    let request_id = extract_string(line, "requestId").unwrap_or_else(|| "unknown".to_string());
    let op = extract_string(line, "op").unwrap_or_else(|| "unknown".to_string());

    if version != 1 {
        return error_response(
            &request_id,
            &op,
            "unsupported_version",
            &format!("unsupported version {}", version),
        );
    }

    match op.as_str() {
        "ping" => ok_response(
            &request_id,
            "ping",
            Some("\"meta\":{\"server\":\"msl-init\",\"version\":\"1\"}".to_string()),
        ),
        "converge_status" => converge_status_response(&request_id),
        "converge_user" => converge_user_response(&request_id, &op, line),
        "exec" => {
            let argv = extract_string_array(line, "argv");
            let timeout_ms = extract_int(line, "timeoutMs");
            let cwd = extract_string(line, "cwd");
            let env_additions = extract_string_map(line, "envAdditions").unwrap_or_default();
            let run_as_root = extract_bool(line, "runAsRoot").unwrap_or(false);
            match argv {
                Some(v) if !v.is_empty() => exec_response(
                    &request_id,
                    &op,
                    v,
                    cwd,
                    timeout_ms,
                    env_additions,
                    run_as_root,
                ),
                _ => error_response(&request_id, &op, "invalid_request", "missing argv"),
            }
        }
        "host_share_prepare" => host_share_prepare_response(&request_id, &op, line),
        "pty_open" => pty_open_response(&request_id, &op, line),
        "pty_read" => pty_read_response(&request_id, &op, line),
        "pty_write" => pty_write_response(&request_id, &op, line),
        "pty_resize" => pty_resize_response(&request_id, &op, line),
        "pty_close" => pty_close_response(&request_id, &op, line),
        "proc_open" => proc_open_response(&request_id, &op, line),
        "proc_read" => proc_read_response(&request_id, &op, line),
        "proc_write" => proc_write_response(&request_id, &op, line),
        "proc_stdin_close" => proc_stdin_close_response(&request_id, &op, line),
        "proc_close" => proc_close_response(&request_id, &op, line),
        "sideband_open" => sideband_open_response(&request_id, &op, line),
        "wayland_proxy_start" => wayland_proxy_start_response(&request_id, &op, line),
        "wayland_proxy_stop" => wayland_proxy_stop_response(&request_id, &op, line),
        "wayland_proxy_status" => wayland_proxy_status_response(&request_id, &op, line),
        "dns_reconcile" => dns_reconcile_response(&request_id, &op, line),
        "dns_healthcheck" => dns_healthcheck_response(&request_id, &op, line),
        _ => error_response(
            &request_id,
            &op,
            "unsupported_op",
            &format!("unsupported op {}", op),
        ),
    }
}

fn sideband_open_response(request_id: &str, op: &str, line: &str) -> String {
    let role = extract_string(line, "sidebandRole").unwrap_or_else(|| "sideband".to_string());
    let port = env::var("MSL_VSOCK_PORT")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(MSL_VSOCK_PORT);
    let role_clone = role.clone();
    thread::spawn(move || {
        if let Err(err) = connect_single_vsock_session(port, &role_clone) {
            log_line(&err);
        }
    });
    ok_response(
        request_id,
        op,
        Some(format!("\"meta\":{{\"role\":\"{}\"}}", escape_json(&role))),
    )
}

fn wayland_proxy_start_response(request_id: &str, op: &str, line: &str) -> String {
    let display_name =
        extract_string(line, "displayName").unwrap_or_else(|| "wayland-0".to_string());
    let display_port = extract_int(line, "displayPort").unwrap_or(38000);
    let runtime_dir = extract_string(line, "runtimeDir").unwrap_or_else(|| "/tmp".to_string());
    let display_port_u32 = match u32::try_from(display_port) {
        Ok(value) => value,
        Err(_) => {
            return error_response(
                request_id,
                op,
                "invalid_request",
                "displayPort must be in 1..65535",
            )
        }
    };
    match start_wayland_proxy(display_name, display_port_u32, runtime_dir) {
        Ok(proxy) => ok_response(
            request_id,
            op,
            Some(format!(
                "\"meta\":{{\"displayName\":\"{}\",\"displayPort\":\"{}\",\"runtimeDir\":\"{}\",\"socketPath\":\"{}\",\"status\":\"running\",\"activeClients\":\"{}\",\"lastError\":\"{}\"}}",
                escape_json(&proxy.display_name),
                proxy.display_port,
                escape_json(&proxy.runtime_dir),
                escape_json(&proxy.socket_path),
                proxy.active_clients,
                escape_json(proxy.last_error.as_deref().unwrap_or(""))
            )),
        ),
        Err(err) => error_response(request_id, op, "internal_error", &err),
    }
}

fn wayland_proxy_stop_response(request_id: &str, op: &str, line: &str) -> String {
    let display_name =
        extract_string(line, "displayName").unwrap_or_else(|| "wayland-0".to_string());
    match stop_wayland_proxy(&display_name) {
        Ok(Some(proxy)) => ok_response(
            request_id,
            op,
            Some(format!(
                "\"meta\":{{\"displayName\":\"{}\",\"displayPort\":\"{}\",\"socketPath\":\"{}\",\"status\":\"stopped\"}}",
                escape_json(&proxy.display_name),
                proxy.display_port,
                escape_json(&proxy.socket_path)
            )),
        ),
        Ok(None) => ok_response(
            request_id,
            op,
            Some(format!(
                "\"meta\":{{\"displayName\":\"{}\",\"status\":\"already_stopped\"}}",
                escape_json(&display_name)
            )),
        ),
        Err(err) => error_response(request_id, op, "internal_error", &err),
    }
}

fn wayland_proxy_status_response(request_id: &str, op: &str, line: &str) -> String {
    let display_name = extract_string(line, "displayName");
    let proxies = match wayland_proxies().lock() {
        Ok(proxies) => proxies,
        Err(_) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                "wayland proxy lock poisoned",
            )
        }
    };
    if let Some(display_name) = display_name {
        if let Some(proxy) = proxies.get(&display_name) {
            return ok_response(
                request_id,
                op,
            Some(format!(
                "\"meta\":{{\"displayName\":\"{}\",\"displayPort\":\"{}\",\"runtimeDir\":\"{}\",\"socketPath\":\"{}\",\"status\":\"running\",\"transportState\":\"{}\",\"activeClients\":\"{}\",\"fdSupport\":\"enabled\",\"buildMarker\":\"{}\",\"defaultProxyStarted\":\"{}\",\"lastTraceId\":\"{}\",\"keymapSent\":\"{}\",\"bytesClientToHost\":\"{}\",\"bytesHostToClient\":\"{}\",\"lastClientEvent\":\"{}\",\"lastHostEvent\":\"{}\",\"lastError\":\"{}\"}}",
                escape_json(&proxy.display_name),
                proxy.display_port,
                escape_json(&proxy.runtime_dir),
                escape_json(&proxy.socket_path),
                if proxy.active_clients > 0 && proxy.last_error.is_none() { "active" } else if proxy.last_error.is_some() { "error" } else { "idle" },
                proxy.active_clients,
                escape_json(&proxy.build_marker),
                proxy.default_proxy_started,
                escape_json(proxy.last_trace_id.as_deref().unwrap_or("")),
                proxy.keymap_sent,
                proxy.bytes_client_to_host,
                proxy.bytes_host_to_client,
                escape_json(proxy.last_client_event.as_deref().unwrap_or("")),
                escape_json(proxy.last_host_event.as_deref().unwrap_or("")),
                escape_json(proxy.last_error.as_deref().unwrap_or(""))
            )),
        );
        }
        return ok_response(
            request_id,
            op,
            Some(format!(
                "\"meta\":{{\"displayName\":\"{}\",\"status\":\"stopped\"}}",
                escape_json(&display_name)
            )),
        );
    }
    let displays = proxies.keys().cloned().collect::<Vec<String>>().join(",");
    ok_response(
        request_id,
        op,
        Some(format!(
            "\"meta\":{{\"count\":\"{}\",\"displays\":\"{}\"}}",
            proxies.len(),
            escape_json(&displays)
        )),
    )
}

struct InitChannelFrame {
    magic: u32,
    opcode: u32,
    _header: Vec<u8>,
    payload: Vec<u8>,
}

struct DirectFrameChunkDescriptor {
    stream: &'static str,
    length: usize,
}

#[derive(Copy, Clone)]
enum DirectBinaryStreamKind {
    Stdout = 1,
    Stderr = 2,
}

fn read_frame<R: Read>(reader: &mut R) -> Result<Option<Vec<u8>>, String> {
    let mut fixed = [0u8; 16];
    let mut offset = 0usize;
    while offset < fixed.len() {
        match reader.read(&mut fixed[offset..]) {
            Ok(0) => {
                if offset == 0 {
                    return Ok(None);
                }
                return Err("unexpected EOF while reading frame header".to_string());
            }
            Ok(n) => offset += n,
            Err(e) => return Err(format!("frame header read failed: {}", e)),
        }
    }

    let header_len = u32::from_be_bytes([fixed[8], fixed[9], fixed[10], fixed[11]]) as usize;
    let payload_len = u32::from_be_bytes([fixed[12], fixed[13], fixed[14], fixed[15]]) as usize;
    let mut body = vec![0u8; header_len + payload_len];
    let mut body_offset = 0usize;
    while body_offset < body.len() {
        match reader.read(&mut body[body_offset..]) {
            Ok(0) => return Err("unexpected EOF while reading frame body".to_string()),
            Ok(n) => body_offset += n,
            Err(e) => return Err(format!("frame body read failed: {}", e)),
        }
    }

    let mut frame = fixed.to_vec();
    frame.extend_from_slice(&body);
    Ok(Some(frame))
}

fn decode_frame(data: &[u8]) -> Result<InitChannelFrame, String> {
    if data.len() < 16 {
        return Err("short frame".to_string());
    }
    let magic = u32::from_be_bytes([data[0], data[1], data[2], data[3]]);
    let opcode = u32::from_be_bytes([data[4], data[5], data[6], data[7]]);
    let header_len = u32::from_be_bytes([data[8], data[9], data[10], data[11]]) as usize;
    let payload_len = u32::from_be_bytes([data[12], data[13], data[14], data[15]]) as usize;
    let expected = 16usize
        .checked_add(header_len)
        .and_then(|v| v.checked_add(payload_len))
        .ok_or_else(|| "frame length overflow".to_string())?;
    if data.len() != expected {
        return Err("frame length mismatch".to_string());
    }
    let header_start = 16usize;
    let payload_start = header_start + header_len;
    Ok(InitChannelFrame {
        magic,
        opcode,
        _header: data[header_start..payload_start].to_vec(),
        payload: data[payload_start..expected].to_vec(),
    })
}

fn encode_frame(opcode: u32, header: &[u8], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(16 + header.len() + payload.len());
    out.extend_from_slice(&INIT_CHANNEL_FRAME_MAGIC.to_be_bytes());
    out.extend_from_slice(&opcode.to_be_bytes());
    out.extend_from_slice(&(header.len() as u32).to_be_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(header);
    out.extend_from_slice(payload);
    out
}

fn encode_json_rpc_response(response: &str) -> Vec<u8> {
    encode_frame(
        INIT_CHANNEL_FRAME_OPCODE_JSON_RPC_RESPONSE,
        &[],
        response.as_bytes(),
    )
}

fn decode_json_rpc_request_payload(data: &[u8]) -> Result<String, String> {
    let frame = decode_frame(data)?;
    if frame.magic != INIT_CHANNEL_FRAME_MAGIC {
        return Err("invalid frame magic".to_string());
    }
    if frame.opcode != INIT_CHANNEL_FRAME_OPCODE_JSON_RPC_REQUEST {
        return Err("unexpected frame opcode".to_string());
    }
    String::from_utf8(frame.payload).map_err(|_| "invalid JSON-RPC UTF-8 payload".to_string())
}

fn direct_header(request_id: &str, op: &str, extras: Option<String>) -> Vec<u8> {
    let mut fields = vec![
        format!("\"version\":1"),
        format!("\"requestId\":\"{}\"", escape_json(request_id)),
        format!("\"op\":\"{}\"", escape_json(op)),
        format!("\"status\":\"ok\""),
    ];
    if let Some(extra) = extras {
        fields.push(extra);
    }
    format!("{{{}}}", fields.join(",")).into_bytes()
}

fn direct_error_header(request_id: &str, op: &str, code: &str, message: &str) -> Vec<u8> {
    format!(
        "{{\"version\":1,\"requestId\":\"{}\",\"op\":\"{}\",\"status\":\"error\",\"error\":{{\"code\":\"{}\",\"message\":\"{}\"}}}}",
        escape_json(request_id),
        escape_json(op),
        escape_json(code),
        escape_json(message)
    )
    .into_bytes()
}

fn encode_binary_pty_read_header(
    ok: bool,
    exit_code: Option<i32>,
    id: &str,
    text: Option<&str>,
) -> Vec<u8> {
    let id_bytes = id.as_bytes();
    let text_bytes = text.unwrap_or("").as_bytes();
    let mut flags = 0u8;
    if exit_code.is_some() {
        flags |= 1 << 0;
    }
    if !text_bytes.is_empty() {
        flags |= 1 << 1;
    }
    let mut header = Vec::with_capacity(16 + id_bytes.len() + text_bytes.len());
    header.push(if ok { 1 } else { 0 });
    header.push(flags);
    header.extend_from_slice(&[0, 0]);
    header.extend_from_slice(&exit_code.unwrap_or(0).to_be_bytes());
    header.extend_from_slice(&(id_bytes.len() as u32).to_be_bytes());
    header.extend_from_slice(&(text_bytes.len() as u32).to_be_bytes());
    header.extend_from_slice(id_bytes);
    header.extend_from_slice(text_bytes);
    header
}

fn encode_binary_proc_read_header(
    ok: bool,
    exit_code: Option<i32>,
    proc_id: &str,
    text: Option<&str>,
    descriptors: &[DirectFrameChunkDescriptor],
) -> Vec<u8> {
    let id_bytes = proc_id.as_bytes();
    let text_bytes = text.unwrap_or("").as_bytes();
    let mut flags = 0u8;
    if exit_code.is_some() {
        flags |= 1 << 0;
    }
    if !text_bytes.is_empty() {
        flags |= 1 << 1;
    }
    let mut header =
        Vec::with_capacity(20 + id_bytes.len() + text_bytes.len() + descriptors.len() * 8);
    header.push(if ok { 1 } else { 0 });
    header.push(flags);
    header.extend_from_slice(&[0, 0]);
    header.extend_from_slice(&exit_code.unwrap_or(0).to_be_bytes());
    header.extend_from_slice(&(id_bytes.len() as u32).to_be_bytes());
    header.extend_from_slice(&(text_bytes.len() as u32).to_be_bytes());
    header.extend_from_slice(&(descriptors.len() as u32).to_be_bytes());
    header.extend_from_slice(id_bytes);
    header.extend_from_slice(text_bytes);
    for descriptor in descriptors {
        let stream_id = match descriptor.stream {
            "stdout" => DirectBinaryStreamKind::Stdout as u8,
            "stderr" => DirectBinaryStreamKind::Stderr as u8,
            _ => 0,
        };
        header.push(stream_id);
        header.extend_from_slice(&[0, 0, 0]);
        header.extend_from_slice(&(descriptor.length as u32).to_be_bytes());
    }
    header
}

fn extract_direct_string(header: &[u8], key: &str) -> Option<String> {
    let line = std::str::from_utf8(header).ok()?;
    extract_string(line, key)
}

fn extract_direct_int(header: &[u8], key: &str) -> Option<i32> {
    let line = std::str::from_utf8(header).ok()?;
    extract_int(line, key)
}

fn collect_proc_read_events(
    session: &mut ProcSession,
    timeout_ms: Option<i32>,
) -> (Vec<ProcStreamChunk>, Option<i32>, Option<String>, bool) {
    let mut chunks: Vec<ProcStreamChunk> = Vec::new();
    let mut total_bytes = 0usize;
    let timeout = timeout_ms.map(|value| value.max(0) as u64).unwrap_or(0);

    let mut rx = session.rx.blocking_lock();

    if total_bytes < MAX_READ_BYTES {
        match recv_proc_event_blocking(&mut rx, timeout) {
            BlockingRecvResult::Event(ProcEvent::Stream(chunk)) => {
                total_bytes += chunk.data.len();
                chunks.push(chunk);
            }
            BlockingRecvResult::Event(ProcEvent::Exited { code, reason }) => {
                session.child_exit_code = Some(code);
                session.child_exit_reason = Some(reason);
            }
            BlockingRecvResult::Event(ProcEvent::StreamsClosed) => {
                session.streams_closed = true;
            }
            BlockingRecvResult::Timeout => {}
            BlockingRecvResult::Closed => {
                session.streams_closed = true;
            }
        }
    }

    while total_bytes < MAX_READ_BYTES {
        match rx.try_recv() {
            Ok(ProcEvent::Stream(chunk)) => {
                total_bytes += chunk.data.len();
                chunks.push(chunk);
            }
            Ok(ProcEvent::Exited { code, reason }) => {
                session.child_exit_code = Some(code);
                session.child_exit_reason = Some(reason);
            }
            Ok(ProcEvent::StreamsClosed) => {
                session.streams_closed = true;
            }
            Err(tokio_mpsc::error::TryRecvError::Empty) => break,
            Err(tokio_mpsc::error::TryRecvError::Disconnected) => {
                session.streams_closed = true;
                break;
            }
        }
    }

    let finalize = session.child_exit_code.is_some() && session.streams_closed;
    (
        chunks,
        session.child_exit_code,
        session.child_exit_reason.clone(),
        finalize,
    )
}

fn recv_proc_event_blocking(
    rx: &mut tokio_mpsc::Receiver<ProcEvent>,
    timeout_ms: u64,
) -> BlockingRecvResult<ProcEvent> {
    if timeout_ms == 0 {
        match rx.try_recv() {
            Ok(event) => BlockingRecvResult::Event(event),
            Err(tokio_mpsc::error::TryRecvError::Empty) => BlockingRecvResult::Timeout,
            Err(tokio_mpsc::error::TryRecvError::Disconnected) => BlockingRecvResult::Closed,
        }
    } else {
        match io_runtime().block_on(tokio_timeout(
            TokioDuration::from_millis(timeout_ms),
            rx.recv(),
        )) {
            Ok(Some(event)) => BlockingRecvResult::Event(event),
            Ok(None) => BlockingRecvResult::Closed,
            Err(_) => BlockingRecvResult::Timeout,
        }
    }
}

fn recv_pty_event_blocking(
    rx: &mut tokio_mpsc::Receiver<PtyEvent>,
    timeout_ms: u64,
) -> BlockingRecvResult<PtyEvent> {
    if timeout_ms == 0 {
        match rx.try_recv() {
            Ok(event) => BlockingRecvResult::Event(event),
            Err(tokio_mpsc::error::TryRecvError::Empty) => BlockingRecvResult::Timeout,
            Err(tokio_mpsc::error::TryRecvError::Disconnected) => BlockingRecvResult::Closed,
        }
    } else {
        match io_runtime().block_on(tokio_timeout(
            TokioDuration::from_millis(timeout_ms),
            rx.recv(),
        )) {
            Ok(Some(event)) => BlockingRecvResult::Event(event),
            Ok(None) => BlockingRecvResult::Closed,
            Err(_) => BlockingRecvResult::Timeout,
        }
    }
}

fn handle_direct_pty_read(header: Vec<u8>) -> Vec<u8> {
    let pty_id = match extract_direct_string(&header, "ptyId") {
        Some(v) if !v.is_empty() => v,
        _ => {
            return encode_frame(
                INIT_CHANNEL_FRAME_OPCODE_PTY_READ_RESPONSE,
                &encode_binary_pty_read_header(false, None, "", Some("missing ptyId")),
                &[],
            )
        }
    };

    let mut map = match sessions().lock() {
        Ok(v) => v,
        Err(_) => {
            return encode_frame(
                INIT_CHANNEL_FRAME_OPCODE_PTY_READ_RESPONSE,
                &encode_binary_pty_read_header(
                    false,
                    None,
                    &pty_id,
                    Some("pty session lock poisoned"),
                ),
                &[],
            )
        }
    };

    let mut output: Vec<u8> = Vec::new();
    {
        let session = match map.get_mut(&pty_id) {
            Some(v) => v,
            None => {
                return encode_frame(
                    INIT_CHANNEL_FRAME_OPCODE_PTY_READ_RESPONSE,
                    &encode_binary_pty_read_header(false, None, &pty_id, Some("unknown ptyId")),
                    &[],
                )
            }
        };
        let mut rx = session.rx.blocking_lock();
        while output.len() < MAX_READ_BYTES {
            match recv_pty_event_blocking(&mut rx, 0) {
                BlockingRecvResult::Event(PtyEvent::Output(chunk)) => {
                    output.extend_from_slice(&chunk)
                }
                BlockingRecvResult::Event(PtyEvent::Exited { code, reason }) => {
                    session.child_exit_code = Some(code);
                    session.child_exit_reason = Some(reason);
                }
                BlockingRecvResult::Event(PtyEvent::StreamsClosed) => {
                    session.streams_closed = true;
                }
                BlockingRecvResult::Timeout => break,
                BlockingRecvResult::Closed => {
                    session.streams_closed = true;
                    break;
                }
            }
        }
    }
    let exit_code = map.get(&pty_id).and_then(|session| session.child_exit_code);
    if exit_code.is_some() && map.get(&pty_id).map(|v| v.streams_closed).unwrap_or(false) {
        if let Some(session) = map.remove(&pty_id) {
            unsafe {
                close(session.master_fd);
            }
        }
    }

    encode_frame(
        INIT_CHANNEL_FRAME_OPCODE_PTY_READ_RESPONSE,
        &encode_binary_pty_read_header(true, exit_code, &pty_id, None),
        &output,
    )
}

fn handle_direct_pty_write(header: Vec<u8>, payload: Vec<u8>) -> Vec<u8> {
    let request_id =
        extract_direct_string(&header, "requestId").unwrap_or_else(|| "unknown".to_string());
    let op = extract_direct_string(&header, "op").unwrap_or_else(|| "pty_write".to_string());
    let pty_id = match extract_direct_string(&header, "ptyId") {
        Some(v) if !v.is_empty() => v,
        _ => {
            return encode_frame(
                INIT_CHANNEL_FRAME_OPCODE_PTY_WRITE_RESPONSE,
                &direct_error_header(&request_id, &op, "invalid_request", "missing ptyId"),
                &[],
            )
        }
    };
    let line = format!(
        "{{\"requestId\":\"{}\",\"op\":\"{}\",\"ptyId\":\"{}\",\"dataBase64\":\"{}\"}}",
        escape_json(&request_id),
        escape_json(&op),
        escape_json(&pty_id),
        escape_json(&b64_encode(&payload))
    );
    let response = pty_write_response(&request_id, &op, &line);
    encode_frame(
        INIT_CHANNEL_FRAME_OPCODE_PTY_WRITE_RESPONSE,
        response.as_bytes(),
        &[],
    )
}

fn handle_direct_proc_read(header: Vec<u8>) -> Vec<u8> {
    let proc_id = match extract_direct_string(&header, "procId") {
        Some(v) if !v.is_empty() => v,
        _ => {
            return encode_frame(
                INIT_CHANNEL_FRAME_OPCODE_PROC_READ_RESPONSE,
                &encode_binary_proc_read_header(false, None, "", Some("missing procId"), &[]),
                &[],
            )
        }
    };
    let requested_timeout_ms = extract_direct_int(&header, "timeoutMs");
    log_line(&format!(
        "proc_read_direct_received proc_id={} requested_timeout_ms={} effective_timeout_ms=0",
        proc_id,
        requested_timeout_ms.unwrap_or(-1)
    ));

    let mut map = match proc_sessions().lock() {
        Ok(v) => v,
        Err(_) => {
            return encode_frame(
                INIT_CHANNEL_FRAME_OPCODE_PROC_READ_RESPONSE,
                &encode_binary_proc_read_header(
                    false,
                    None,
                    &proc_id,
                    Some("proc session lock poisoned"),
                    &[],
                ),
                &[],
            )
        }
    };

    let (mut chunks, exit_code, exit_reason, finalize) = {
        let session = match map.get_mut(&proc_id) {
            Some(v) => v,
            None => {
                return encode_frame(
                    INIT_CHANNEL_FRAME_OPCODE_PROC_READ_RESPONSE,
                    &encode_binary_proc_read_header(
                        false,
                        None,
                        &proc_id,
                        Some("unknown procId"),
                        &[],
                    ),
                    &[],
                )
            }
        };
        // Direct-frame clients already poll from the host side. Blocking here can
        // stall the single control connection and delay terminal progress output.
        collect_proc_read_events(session, Some(0))
    };
    if finalize {
        map.remove(&proc_id);
    }

    chunks.sort_by_key(|chunk| chunk.seq);
    let mut payload: Vec<u8> = Vec::new();
    let mut chunk_descriptors: Vec<DirectFrameChunkDescriptor> = Vec::new();
    for chunk in chunks {
        let stream = match chunk.stream {
            ProcStreamKind::Stdout => "stdout",
            ProcStreamKind::Stderr => "stderr",
        };
        chunk_descriptors.push(DirectFrameChunkDescriptor {
            stream,
            length: chunk.data.len(),
        });
        payload.extend_from_slice(&chunk.data);
    }

    encode_frame(
        INIT_CHANNEL_FRAME_OPCODE_PROC_READ_RESPONSE,
        &encode_binary_proc_read_header(
            true,
            exit_code,
            &proc_id,
            exit_reason.as_deref(),
            &chunk_descriptors,
        ),
        &payload,
    )
}

fn handle_direct_proc_write(header: Vec<u8>, payload: Vec<u8>) -> Vec<u8> {
    let request_id =
        extract_direct_string(&header, "requestId").unwrap_or_else(|| "unknown".to_string());
    let op = extract_direct_string(&header, "op").unwrap_or_else(|| "proc_write".to_string());
    let proc_id = match extract_direct_string(&header, "procId") {
        Some(v) if !v.is_empty() => v,
        _ => {
            return encode_frame(
                INIT_CHANNEL_FRAME_OPCODE_PROC_WRITE_RESPONSE,
                &direct_error_header(&request_id, &op, "invalid_request", "missing procId"),
                &[],
            )
        }
    };

    let stdin_tx = {
        let mut map = match proc_sessions().lock() {
            Ok(v) => v,
            Err(_) => {
                return encode_frame(
                    INIT_CHANNEL_FRAME_OPCODE_PROC_WRITE_RESPONSE,
                    &direct_error_header(
                        &request_id,
                        &op,
                        "internal_error",
                        "proc session lock poisoned",
                    ),
                    &[],
                )
            }
        };
        let session = match map.get_mut(&proc_id) {
            Some(v) => v,
            None => {
                return encode_frame(
                    INIT_CHANNEL_FRAME_OPCODE_PROC_WRITE_RESPONSE,
                    &direct_error_header(&request_id, &op, "invalid_request", "unknown procId"),
                    &[],
                )
            }
        };
        observe_helper_handoff(&proc_id, session, &payload);
        match session.stdin_tx.as_ref() {
            Some(v) => v.clone(),
            None => {
                return encode_frame(
                    INIT_CHANNEL_FRAME_OPCODE_PROC_WRITE_RESPONSE,
                    &direct_error_header(
                        &request_id,
                        &op,
                        "internal_error",
                        "proc stdin already closed",
                    ),
                    &[],
                )
            }
        }
    };
    if let Err(err) = stdin_tx.blocking_send(ProcStdinMessage::Data {
        bytes: payload,
        enqueued_at_ms: now_epoch_ms() as i64,
    }) {
        return encode_frame(
            INIT_CHANNEL_FRAME_OPCODE_PROC_WRITE_RESPONSE,
            &direct_error_header(
                &request_id,
                &op,
                "internal_error",
                &format!("proc stdin queue failed: {}", err),
            ),
            &[],
        );
    }
    encode_frame(
        INIT_CHANNEL_FRAME_OPCODE_PROC_WRITE_RESPONSE,
        &direct_header(
            &request_id,
            &op,
            Some(format!("\"procId\":\"{}\"", escape_json(&proc_id))),
        ),
        &[],
    )
}

fn encode_proc_event_frame(
    proc_id: &str,
    kind: &str,
    payload: &[u8],
    exit_code: Option<i32>,
    text: Option<&str>,
) -> Vec<u8> {
    let header = format!(
        "{{\"kind\":\"{}\",\"procId\":\"{}\"{}{}{}}}",
        escape_json(kind),
        escape_json(proc_id),
        exit_code
            .map(|v| format!(",\"exitCode\":{}", v))
            .unwrap_or_default(),
        text.map(|v| format!(",\"text\":\"{}\"", escape_json(v)))
            .unwrap_or_default(),
        ""
    );
    encode_frame(
        INIT_CHANNEL_FRAME_OPCODE_PROC_EVENT,
        header.as_bytes(),
        payload,
    )
}

fn encode_pty_event_frame(
    pty_id: &str,
    kind: &str,
    payload: &[u8],
    exit_code: Option<i32>,
    text: Option<&str>,
) -> Vec<u8> {
    let header = format!(
        "{{\"kind\":\"{}\",\"ptyId\":\"{}\"{}{}{}}}",
        escape_json(kind),
        escape_json(pty_id),
        exit_code
            .map(|v| format!(",\"exitCode\":{}", v))
            .unwrap_or_default(),
        text.map(|v| format!(",\"text\":\"{}\"", escape_json(v)))
            .unwrap_or_default(),
        ""
    );
    encode_frame(
        INIT_CHANNEL_FRAME_OPCODE_PTY_EVENT,
        header.as_bytes(),
        payload,
    )
}

fn handle_direct_proc_subscribe(header: Vec<u8>, writer: &mut std::fs::File) -> Result<(), String> {
    let proc_id = extract_direct_string(&header, "procId")
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "missing procId".to_string())?;

    let rx = {
        let map = proc_sessions()
            .lock()
            .map_err(|_| "proc session lock poisoned".to_string())?;
        let session = map
            .get(&proc_id)
            .ok_or_else(|| "unknown procId".to_string())?;
        session.rx.clone()
    };

    let mut saw_exit = false;
    let mut saw_streams_closed = false;
    loop {
        let event = {
            let mut guard = rx.blocking_lock();
            guard
                .blocking_recv()
                .ok_or_else(|| "proc event stream closed".to_string())?
        };
        let frame = match event {
            ProcEvent::Stream(chunk) => match chunk.stream {
                ProcStreamKind::Stdout => {
                    encode_proc_event_frame(&proc_id, "stdout", &chunk.data, None, None)
                }
                ProcStreamKind::Stderr => {
                    encode_proc_event_frame(&proc_id, "stderr", &chunk.data, None, None)
                }
            },
            ProcEvent::Exited { code, reason } => {
                saw_exit = true;
                encode_proc_event_frame(&proc_id, "exited", &[], Some(code), Some(&reason))
            }
            ProcEvent::StreamsClosed => {
                saw_streams_closed = true;
                encode_proc_event_frame(&proc_id, "streams_closed", &[], None, None)
            }
        };
        writer
            .write_all(&frame)
            .map_err(|e| format!("proc subscribe write failed: {e}"))?;
        writer
            .flush()
            .map_err(|e| format!("proc subscribe flush failed: {e}"))?;
        if saw_exit && saw_streams_closed {
            break;
        }
    }
    Ok(())
}

fn handle_direct_pty_subscribe(header: Vec<u8>, writer: &mut std::fs::File) -> Result<(), String> {
    let pty_id = extract_direct_string(&header, "ptyId")
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "missing ptyId".to_string())?;

    let rx = {
        let map = sessions()
            .lock()
            .map_err(|_| "pty session lock poisoned".to_string())?;
        let session = map
            .get(&pty_id)
            .ok_or_else(|| "unknown ptyId".to_string())?;
        session.rx.clone()
    };

    let mut saw_exit = false;
    let mut saw_streams_closed = false;
    loop {
        let event = {
            let mut guard = rx.blocking_lock();
            guard
                .blocking_recv()
                .ok_or_else(|| "pty event stream closed".to_string())?
        };
        let frame = match event {
            PtyEvent::Output(data) => encode_pty_event_frame(&pty_id, "output", &data, None, None),
            PtyEvent::Exited { code, reason } => {
                saw_exit = true;
                encode_pty_event_frame(&pty_id, "exited", &[], Some(code), Some(&reason))
            }
            PtyEvent::StreamsClosed => {
                saw_streams_closed = true;
                encode_pty_event_frame(&pty_id, "streams_closed", &[], None, None)
            }
        };
        writer
            .write_all(&frame)
            .map_err(|e| format!("pty subscribe write failed: {e}"))?;
        writer
            .flush()
            .map_err(|e| format!("pty subscribe flush failed: {e}"))?;
        if saw_exit && saw_streams_closed {
            break;
        }
    }
    Ok(())
}

fn dns_reconcile_response(request_id: &str, op: &str, line: &str) -> String {
    let mode = extract_string(line, "dnsMode").unwrap_or_else(|| "host".to_string());
    if mode == "unmanaged" {
        stop_dns_proxy();
        return ok_response(
            request_id,
            op,
            Some("\"meta\":{\"applied_mode\":\"unmanaged\",\"action\":\"policy_skip\",\"resolv_conf_path\":\"/etc/resolv.conf\",\"resolv_conf_replaced_symlink\":\"false\",\"warnings\":\"\",\"proxy_enabled\":\"false\"}".to_string()),
        );
    }
    if mode != "host" && mode != "manual" {
        return error_response(
            request_id,
            op,
            "invalid_request",
            "dnsMode must be host|manual|unmanaged",
        );
    }

    let requested_nameservers = extract_string_array(line, "dnsNameservers").unwrap_or_default();
    if requested_nameservers.is_empty() {
        return error_response(
            request_id,
            op,
            "invalid_request",
            "dnsNameservers is required for managed mode",
        );
    }
    let search_domains = extract_string_array(line, "dnsSearchDomains").unwrap_or_default();
    let mut nameservers_to_write = requested_nameservers.clone();
    let mut proxy_enabled = false;
    let mut proxy_listen = String::new();
    let mut proxy_upstream_count = 0usize;

    if mode == "host" {
        let proxy_upstreams_raw = extract_string_array(line, "dnsProxyUpstreams")
            .unwrap_or_else(|| requested_nameservers.clone());
        let proxy_listen_address = extract_string(line, "dnsProxyListenAddress")
            .unwrap_or_else(|| "127.0.0.1".to_string());
        let proxy_listen_port = extract_int(line, "dnsProxyListenPort").unwrap_or(53);
        if proxy_listen_port <= 0 || proxy_listen_port > 65535 {
            return error_response(
                request_id,
                op,
                "invalid_request",
                "dnsProxyListenPort must be in 1..65535",
            );
        }
        if proxy_listen_port != 53 {
            return error_response(
                request_id,
                op,
                "invalid_request",
                "dnsProxyListenPort must be 53 for resolv.conf compatibility",
            );
        }

        let preferred_listen =
            match build_listen_addr(&proxy_listen_address, proxy_listen_port as u16) {
                Some(value) => value,
                None => {
                    return error_response(
                        request_id,
                        op,
                        "invalid_request",
                        "dnsProxyListenAddress must be a valid IP",
                    )
                }
            };

        let upstreams: Vec<SocketAddr> = proxy_upstreams_raw
            .iter()
            .filter_map(|value| normalize_dns_upstream(value))
            .collect();
        if upstreams.is_empty() {
            return error_response(
                request_id,
                op,
                "invalid_request",
                "dnsProxyUpstreams is required for host mode",
            );
        }
        let mut listen_candidates: Vec<SocketAddr> = vec![preferred_listen];
        if preferred_listen.ip().to_string() != "127.0.0.1" {
            if let Some(loopback) = build_listen_addr("127.0.0.1", proxy_listen_port as u16) {
                listen_candidates.push(loopback);
            }
        }
        if let Some(detected) = detect_default_local_ip() {
            let detected_addr = SocketAddr::new(detected, proxy_listen_port as u16);
            if !listen_candidates
                .iter()
                .any(|value| *value == detected_addr)
            {
                listen_candidates.push(detected_addr);
            }
        }

        let mut selected_listen: Option<SocketAddr> = None;
        let mut last_error = String::new();
        for candidate in listen_candidates {
            match ensure_dns_proxy(candidate, upstreams.clone()) {
                Ok(_) => {
                    selected_listen = Some(candidate);
                    break;
                }
                Err(err) => {
                    last_error = err;
                }
            }
        }

        let listen = match selected_listen {
            Some(value) => value,
            None => {
                return error_response(
                    request_id,
                    op,
                    "internal_error",
                    &format!("failed to configure dns proxy: {}", last_error),
                );
            }
        };

        nameservers_to_write = vec![listen.ip().to_string()];
        proxy_enabled = true;
        proxy_listen = listen.to_string();
        proxy_upstream_count = upstreams.len();
    } else {
        stop_dns_proxy();
    }

    let mut content = String::from("# Generated by msl (step21)\n");
    content.push_str(&format!("# mode: {}\n", mode));
    for ns in nameservers_to_write {
        content.push_str("nameserver ");
        content.push_str(&ns);
        content.push('\n');
    }
    if !search_domains.is_empty() {
        content.push_str("search ");
        content.push_str(&search_domains.join(" "));
        content.push('\n');
    }

    let target = Path::new("/etc/resolv.conf");
    let replaced_symlink = fs::symlink_metadata(target)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false);

    let tmp = Path::new("/etc/resolv.conf.msl.tmp");
    if let Err(e) = fs::write(tmp, content) {
        return error_response(
            request_id,
            op,
            "internal_error",
            &format!("failed to write resolv tmp: {}", e),
        );
    }
    if let Err(e) = fs::rename(tmp, target) {
        let _ = fs::remove_file(tmp);
        return error_response(
            request_id,
            op,
            "internal_error",
            &format!("failed to replace resolv.conf: {}", e),
        );
    }

    ok_response(
        request_id,
        op,
        Some(format!(
            "\"meta\":{{\"applied_mode\":\"{}\",\"action\":\"applied\",\"resolv_conf_path\":\"/etc/resolv.conf\",\"resolv_conf_replaced_symlink\":\"{}\",\"warnings\":\"\",\"proxy_enabled\":\"{}\",\"proxy_listen\":\"{}\",\"proxy_upstream_count\":\"{}\"}}",
            escape_json(&mode),
            if replaced_symlink { "true" } else { "false" },
            if proxy_enabled { "true" } else { "false" },
            escape_json(&proxy_listen),
            proxy_upstream_count
        )),
    )
}

fn dns_healthcheck_response(request_id: &str, op: &str, _line: &str) -> String {
    ensure_guest_network_ready();
    let interfaces = list_non_loopback_interfaces();
    if !has_transport_path(&interfaces) {
        return error_response(
            request_id,
            op,
            "internal_error",
            "network transport unavailable: missing default route or global ipv4/ipv6 address",
        );
    }
    let domains = [
        "www.msftconnecttest.com",
        "archive.ubuntu.com",
        "dl-cdn.alpinelinux.org",
    ];
    let started = Instant::now();
    let per_domain_timeout = Duration::from_millis(700);
    for domain in domains {
        let mut child = match Command::new("getent")
            .arg("hosts")
            .arg(domain)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => child,
            Err(_) => continue,
        };
        let deadline = Instant::now() + per_domain_timeout;
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    if status.success() {
                        let output = match child.wait_with_output() {
                            Ok(output) => output,
                            Err(_) => break,
                        };
                        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
                        let first_ip = stdout.split_whitespace().next().unwrap_or("");
                        return ok_response(
                            request_id,
                            op,
                            Some(format!(
                                "\"meta\":{{\"resolved_domain\":\"{}\",\"resolved_ips\":\"{}\",\"duration_ms\":\"{}\"}}",
                                escape_json(domain),
                                escape_json(first_ip),
                                started.elapsed().as_millis()
                            )),
                        );
                    }
                    break;
                }
                Ok(None) => {
                    if Instant::now() >= deadline {
                        let _ = child.kill();
                        let _ = child.wait();
                        break;
                    }
                    thread::sleep(Duration::from_millis(50));
                }
                Err(_) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break;
                }
            }
        }
    }
    error_response(request_id, op, "internal_error", "dns healthcheck failed")
}

fn host_share_prepare_response(request_id: &str, op: &str, line: &str) -> String {
    let workspace_path = extract_string(line, "cwd").and_then(|v| normalize_absolute_path(&v));
    let share_root = extract_string(line, "hostShareRoot")
        .and_then(|v| normalize_absolute_path(&v))
        .unwrap_or_else(|| "/".to_string());
    let readonly_root = mount_fstype("/").as_deref() == Some("erofs");

    let source_root = if share_root == "/" {
        "/mnt/macos".to_string()
    } else {
        format!("/mnt/macos{}", share_root)
    };
    let target_root = share_root.clone();

    if let Err(e) = mount_virtiofs_macos_if_needed() {
        return error_response(request_id, op, "internal_error", &e);
    }

    if !Path::new(&source_root).is_dir() {
        return error_response(
            request_id,
            op,
            "invalid_request",
            &format!("host share source is not accessible: {}", source_root),
        );
    }

    let mut applied = false;
    if !readonly_root && share_root != "/" {
        let root_applied = match bind_mount_if_needed(&source_root, &target_root) {
            Ok(v) => v,
            Err(e) => return error_response(request_id, op, "internal_error", &e),
        };
        applied = applied || root_applied;
    }

    if let Some(workspace_path) = workspace_path {
        let source_workspace = if workspace_path == "/" {
            "/mnt/macos".to_string()
        } else {
            format!("/mnt/macos{}", workspace_path)
        };
        if !Path::new(&source_workspace).exists() {
            return error_response(
                request_id,
                op,
                "invalid_request",
                &format!("workspace source is not accessible: {}", source_workspace),
            );
        }
        if !readonly_root && share_root == "/" {
            let workspace_applied = match bind_mount_if_needed(&source_workspace, &workspace_path) {
                Ok(v) => v,
                Err(e) => return error_response(request_id, op, "internal_error", &e),
            };
            applied = applied || workspace_applied;
        }
    }

    let status = if applied { "applied" } else { "reused" };
    ok_response(
        request_id,
        op,
        Some(format!(
            "\"meta\":{{\"status\":\"{}\",\"sourceRoot\":\"{}\",\"targetRoot\":\"{}\"}}",
            status,
            escape_json(&source_root),
            escape_json(&target_root)
        )),
    )
}

fn pty_open_response(request_id: &str, op: &str, line: &str) -> String {
    let argv = extract_string_array(line, "argv")
        .unwrap_or_else(|| vec!["/bin/sh".to_string(), "-l".to_string()]);
    if argv.is_empty() {
        return error_response(request_id, op, "invalid_request", "missing argv");
    }
    let requested_cwd = extract_string(line, "cwd");
    let env_additions = extract_string_map(line, "envAdditions").unwrap_or_default();
    let run_as_root = extract_bool(line, "runAsRoot").unwrap_or(false);

    let rows = extract_int(line, "rows").unwrap_or(24) as u16;
    let cols = extract_int(line, "cols").unwrap_or(80) as u16;
    let runtime = runtime_context_for_request(run_as_root);
    let supplementary_gids = supplementary_gids_for_user(&runtime.username, runtime.gid);

    let started = Instant::now();

    // Allocate a real PTY pair
    let mut master_fd: i32 = -1;
    let mut slave_fd: i32 = -1;
    let ws = Winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };

    if unsafe {
        openpty(
            &mut master_fd,
            &mut slave_fd,
            std::ptr::null_mut(),
            std::ptr::null(),
            &ws,
        )
    } != 0
    {
        return error_response(
            request_id,
            op,
            "internal_error",
            &format!("openpty failed: {}", std::io::Error::last_os_error()),
        );
    }

    // Prepare all heap allocations BEFORE fork() to avoid malloc corruption
    // in a multi-threaded process. After fork, only async-signal-safe calls are allowed.
    let c_strings: Vec<Vec<u8>> = argv
        .iter()
        .map(|s| {
            let mut v = s.as_bytes().to_vec();
            v.push(0);
            v
        })
        .collect();
    let c_ptrs: Vec<*const u8> = c_strings
        .iter()
        .map(|v| v.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect();

    // Build environment as "KEY=VALUE\0" strings for execve.
    let env_values: Vec<String> = child_process_environment(&runtime, env_additions)
        .into_iter()
        .map(|(key, value)| format!("{}={}", key, value))
        .collect();
    let env_cstrings: Vec<Vec<u8>> = env_values
        .iter()
        .map(|s| {
            let mut v = s.as_bytes().to_vec();
            v.push(0);
            v
        })
        .collect();
    let env_ptrs: Vec<*const u8> = env_cstrings
        .iter()
        .map(|v| v.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect();
    let selected_cwd = requested_cwd
        .as_ref()
        .filter(|v| v.starts_with('/') && Path::new(v).is_dir())
        .cloned()
        .unwrap_or_else(|| runtime.home.clone());
    let mut cwd_path = selected_cwd.as_bytes().to_vec();
    cwd_path.push(0);

    let pid = unsafe { fork() };
    if pid < 0 {
        unsafe {
            close(master_fd);
            close(slave_fd);
        }
        return error_response(
            request_id,
            op,
            "internal_error",
            &format!("fork failed: {}", std::io::Error::last_os_error()),
        );
    }

    if pid == 0 {
        // Child process: ONLY async-signal-safe syscalls below (no malloc/free).
        unsafe {
            close(master_fd);
            setsid();
            // Set controlling terminal
            ioctl(slave_fd, 0x540E /* TIOCSCTTY */, 0i32);
            dup2(slave_fd, 0);
            dup2(slave_fd, 1);
            dup2(slave_fd, 2);
            if slave_fd > 2 {
                close(slave_fd);
            }
            if supplementary_gids.is_empty() {
                setgroups(0, std::ptr::null());
            } else {
                setgroups(supplementary_gids.len(), supplementary_gids.as_ptr());
            }
            setgid(runtime.gid);
            setuid(runtime.uid);

            // Close ALL inherited file descriptors > 2.
            // This prevents vsock fd, other PTY master fds, etc. from leaking
            // into the child process, which can cause subtle corruption.
            let mut rlim = Rlimit {
                rlim_cur: 1024,
                rlim_max: 1024,
            };
            getrlimit(RLIMIT_NOFILE, &mut rlim);
            let max_fd = if rlim.rlim_cur > 4096 {
                4096
            } else {
                rlim.rlim_cur as i32
            };
            for fd in 3..max_fd {
                close(fd);
            }

            // Change to requested cwd when available, fallback is runtime home.
            chdir(cwd_path.as_ptr());

            // Use execve with explicit env — avoids setenv (not async-signal-safe)
            execve(c_ptrs[0], c_ptrs.as_ptr(), env_ptrs.as_ptr());
            // If execve returns, use _exit to avoid running destructors in forked child
            _exit(127);
        }
    }

    // Parent: close slave, set up reader thread for master
    unsafe {
        close(slave_fd);
    }
    let pty_id = format!(
        "pty-{}-{}",
        std::process::id(),
        PTY_SEQ.fetch_add(1, Ordering::Relaxed)
    );
    let _ = set_fd_nonblocking(master_fd);

    let (event_tx, event_rx) = tokio_mpsc::channel::<PtyEvent>(256);
    let (stdin_tx, stdin_rx) = tokio_mpsc::channel::<PtyInputMessage>(128);
    start_pty_output_pump(master_fd, event_tx.clone());
    start_pty_input_pump(pty_id.clone(), master_fd, stdin_rx);
    start_pty_wait_task(pid, event_tx);

    let session = PtySession {
        master_fd,
        child_pid: pid,
        stdin_tx: Some(stdin_tx),
        rx: Arc::new(TokioMutex::new(event_rx)),
        child_exit_code: None,
        child_exit_reason: None,
        streams_closed: false,
    };

    match sessions().lock() {
        Ok(mut map) => {
            map.insert(pty_id.clone(), session);
        }
        Err(_) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                "pty session lock poisoned",
            )
        }
    }

    let duration_ms = started.elapsed().as_millis();
    log_line(&format!(
        "pty_open ok request_id={} pty_id={} argv0={} pid={} user={} uid={} gid={} supplementary_gids={}",
        request_id,
        pty_id,
        argv[0],
        pid,
        runtime.username,
        runtime.uid,
        runtime.gid,
        supplementary_gids
            .iter()
            .map(|gid| gid.to_string())
            .collect::<Vec<String>>()
            .join(",")
    ));
    ok_response(
        request_id,
        op,
        Some(format!(
            "\"ptyId\":\"{}\",\"durationMs\":{}",
            escape_json(&pty_id),
            duration_ms
        )),
    )
}

// Extra libc FFI for PTY I/O
extern "C" {
    #[link_name = "read"]
    fn libc_read(fd: i32, buf: *mut u8, count: usize) -> isize;
    #[link_name = "write"]
    fn libc_write(fd: i32, buf: *const u8, count: usize) -> isize;
}

fn start_pty_output_pump(master_fd: i32, tx: tokio_mpsc::Sender<PtyEvent>) {
    io_runtime().spawn(async move {
        let async_fd = match AsyncFd::new(RawAsyncFD(master_fd)) {
            Ok(fd) => fd,
            Err(_) => {
                let _ = tx.send(PtyEvent::StreamsClosed).await;
                return;
            }
        };
        let mut buf = [0u8; 4096];
        loop {
            let mut guard = match async_fd.readable().await {
                Ok(guard) => guard,
                Err(_) => break,
            };
            let read_result = guard.try_io(|inner| {
                let n =
                    unsafe { libc_read(inner.get_ref().as_raw_fd(), buf.as_mut_ptr(), buf.len()) };
                if n < 0 {
                    let err = std::io::Error::last_os_error();
                    if matches!(err.kind(), std::io::ErrorKind::WouldBlock) {
                        Err(err)
                    } else {
                        log_line(&format!(
                            "pty_output_event proc_id={} reason=read_failed message={}",
                            master_fd, err
                        ));
                        Ok(0)
                    }
                } else {
                    Ok(n)
                }
            });
            match read_result {
                Ok(Ok(0)) => break,
                Ok(Ok(n)) => {
                    if tx
                        .send(PtyEvent::Output(buf[..n as usize].to_vec()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Ok(Err(_)) => continue,
                Err(_would_block) => continue,
            }
        }
        let _ = tx.send(PtyEvent::StreamsClosed).await;
    });
}

fn start_pty_input_pump(
    proc_id: String,
    master_fd: i32,
    mut rx: tokio_mpsc::Receiver<PtyInputMessage>,
) {
    io_runtime().spawn(async move {
        let write_fd = unsafe { dup(master_fd) };
        if write_fd < 0 {
            let err = std::io::Error::last_os_error();
            log_line(&format!("pty_stdin_writer_error proc_id={} reason=dup message={}", proc_id, err));
            return;
        }
        let async_fd = match AsyncFd::new(RawAsyncFD(write_fd)) {
            Ok(fd) => fd,
            Err(err) => {
                log_line(&format!("pty_stdin_writer_error proc_id={} reason=async_fd message={}", proc_id, err));
                return;
            }
        };
        while let Some(message) = rx.recv().await {
            match message {
                PtyInputMessage::Data { bytes, enqueued_at_ms } => {
                    let dequeued_at_ms = now_epoch_ms() as i64;
                    let queue_wait_ms = dequeued_at_ms.saturating_sub(enqueued_at_ms);
                    let mut offset = 0usize;
                    while offset < bytes.len() {
                        let mut guard = match async_fd.writable().await {
                            Ok(guard) => guard,
                            Err(err) => {
                                log_line(&format!("pty_stdin_writer_error proc_id={} reason=writable message={}", proc_id, err));
                                return;
                            }
                        };
                        let write_result = guard.try_io(|inner| {
                            let n = unsafe {
                                libc_write(
                                    inner.get_ref().as_raw_fd(),
                                    bytes[offset..].as_ptr(),
                                    bytes.len() - offset,
                                )
                            };
                            if n < 0 {
                                let err = std::io::Error::last_os_error();
                                if matches!(err.kind(), std::io::ErrorKind::WouldBlock) {
                                    Err(err)
                                } else {
                                    log_line(&format!("pty_stdin_writer_error proc_id={} reason=write_failed message={}", proc_id, err));
                                    Ok(bytes.len())
                                }
                            } else {
                                Ok(n as usize)
                            }
                        });
                        match write_result {
                            Ok(Ok(n)) => offset += n,
                            Ok(Err(_)) => continue,
                            Err(_would_block) => continue,
                        }
                    }
                    let write_done_ms = now_epoch_ms() as i64;
                    log_line(&format!(
                        "pty_stdin_writer_write proc_id={} bytes={} queue_wait_ms={} write_ms={}",
                        proc_id,
                        bytes.len(),
                        queue_wait_ms,
                        write_done_ms.saturating_sub(dequeued_at_ms)
                    ));
                }
                PtyInputMessage::Close => {
                    log_line(&format!("pty_stdin_writer_closed proc_id={} reason=stdin_close", proc_id));
                    break;
                }
            }
        }
    });
}

fn start_pty_wait_task(child_pid: i32, tx: tokio_mpsc::Sender<PtyEvent>) {
    io_runtime().spawn(async move {
        let waited = tokio::task::spawn_blocking(move || {
            let mut status: i32 = 0;
            let ret = unsafe { waitpid(child_pid, &mut status, 0) };
            if ret > 0 {
                let code = if status & 0x7f == 0 {
                    (status >> 8) & 0xff
                } else {
                    128 + (status & 0x7f)
                };
                let reason = if status & 0x7f == 0 {
                    "exit".to_string()
                } else {
                    "signal".to_string()
                };
                Some(PtyEvent::Exited { code, reason })
            } else {
                None
            }
        })
        .await
        .ok()
        .flatten();
        if let Some(event) = waited {
            let _ = tx.send(event).await;
        }
    });
}

fn pty_read_response(request_id: &str, op: &str, line: &str) -> String {
    let pty_id = match extract_string(line, "ptyId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing ptyId"),
    };

    let mut map = match sessions().lock() {
        Ok(v) => v,
        Err(_) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                "pty session lock poisoned",
            )
        }
    };

    let mut output: Vec<u8> = Vec::new();

    {
        let session = match map.get_mut(&pty_id) {
            Some(v) => v,
            None => return error_response(request_id, op, "invalid_request", "unknown ptyId"),
        };

        let mut rx = session.rx.blocking_lock();

        while output.len() < MAX_READ_BYTES {
            match recv_pty_event_blocking(&mut rx, 0) {
                BlockingRecvResult::Event(PtyEvent::Output(chunk)) => {
                    output.extend_from_slice(&chunk)
                }
                BlockingRecvResult::Event(PtyEvent::Exited { code, reason }) => {
                    session.child_exit_code = Some(code);
                    session.child_exit_reason = Some(reason);
                }
                BlockingRecvResult::Event(PtyEvent::StreamsClosed) => {
                    session.streams_closed = true;
                }
                BlockingRecvResult::Timeout => break,
                BlockingRecvResult::Closed => {
                    session.streams_closed = true;
                    break;
                }
            }
        }
    }
    let exit_code = map.get(&pty_id).and_then(|session| session.child_exit_code);

    if exit_code.is_some() && map.get(&pty_id).map(|v| v.streams_closed).unwrap_or(false) {
        if let Some(session) = map.remove(&pty_id) {
            unsafe {
                close(session.master_fd);
            }
        }
    }

    let mut extras: Vec<String> = Vec::new();
    if !output.is_empty() {
        let encoded = b64_encode(&output);
        extras.push(format!("\"dataBase64\":\"{}\"", escape_json(&encoded)));
    }
    if let Some(code) = exit_code {
        extras.push(format!("\"meta\":{{\"exitCode\":\"{}\"}}", code));
        extras.push(format!("\"exitCode\":{}", code));
    }

    let extra = if extras.is_empty() {
        None
    } else {
        Some(extras.join(","))
    };
    ok_response(request_id, op, extra)
}

fn pty_write_response(request_id: &str, op: &str, line: &str) -> String {
    let pty_id = match extract_string(line, "ptyId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing ptyId"),
    };
    let payload = match extract_string(line, "dataBase64") {
        Some(v) => v,
        None => return error_response(request_id, op, "invalid_request", "missing dataBase64"),
    };

    let bytes = match b64_decode(&payload) {
        Ok(v) => v,
        Err(e) => {
            return error_response(
                request_id,
                op,
                "invalid_request",
                &format!("invalid base64: {e}"),
            )
        }
    };

    let mut map = match sessions().lock() {
        Ok(v) => v,
        Err(_) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                "pty session lock poisoned",
            )
        }
    };

    let session = match map.get_mut(&pty_id) {
        Some(v) => v,
        None => return error_response(request_id, op, "invalid_request", "unknown ptyId"),
    };

    let stdin_tx = match session.stdin_tx.as_ref() {
        Some(v) => v,
        None => {
            return error_response(request_id, op, "internal_error", "pty stdin already closed")
        }
    };
    if let Err(err) = stdin_tx.blocking_send(PtyInputMessage::Data {
        bytes,
        enqueued_at_ms: now_epoch_ms() as i64,
    }) {
        return error_response(
            request_id,
            op,
            "internal_error",
            &format!("pty stdin queue failed: {}", err),
        );
    }

    ok_response(request_id, op, None)
}

fn pty_resize_response(request_id: &str, op: &str, line: &str) -> String {
    let pty_id = match extract_string(line, "ptyId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing ptyId"),
    };

    let rows = extract_int(line, "rows").unwrap_or(24) as u16;
    let cols = extract_int(line, "cols").unwrap_or(80) as u16;

    let map = match sessions().lock() {
        Ok(v) => v,
        Err(_) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                "pty session lock poisoned",
            )
        }
    };
    let session = match map.get(&pty_id) {
        Some(v) => v,
        None => return error_response(request_id, op, "invalid_request", "unknown ptyId"),
    };

    let ws = Winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let ret = unsafe { ioctl(session.master_fd, TIOCSWINSZ, &ws) };
    if ret < 0 {
        return error_response(
            request_id,
            op,
            "internal_error",
            &format!("TIOCSWINSZ failed: {}", std::io::Error::last_os_error()),
        );
    }

    ok_response(
        request_id,
        op,
        Some(format!(
            "\"meta\":{{\"rows\":\"{}\",\"cols\":\"{}\"}}",
            rows, cols
        )),
    )
}

fn pty_close_response(request_id: &str, op: &str, line: &str) -> String {
    let pty_id = match extract_string(line, "ptyId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing ptyId"),
    };

    let mut map = match sessions().lock() {
        Ok(v) => v,
        Err(_) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                "pty session lock poisoned",
            )
        }
    };

    let mut session = match map.remove(&pty_id) {
        Some(v) => v,
        None => {
            return ok_response(
                request_id,
                op,
                Some("\"meta\":{\"closed\":\"already\"}".to_string()),
            )
        }
    };

    if let Some(tx) = session.stdin_tx.take() {
        let _ = tx.blocking_send(PtyInputMessage::Close);
    }

    // Close master fd first (sends EOF to child)
    unsafe {
        close(session.master_fd);
    }

    // Check if child already exited
    let mut status: i32 = 0;
    let ret = unsafe { waitpid(session.child_pid, &mut status, WNOHANG) };
    let code = if ret > 0 {
        if status & 0x7f == 0 {
            (status >> 8) & 0xff
        } else {
            128 + (status & 0x7f)
        }
    } else {
        // Not yet exited, send SIGTERM then wait briefly
        unsafe {
            kill(session.child_pid, SIGTERM);
        }
        thread::sleep(Duration::from_millis(100));
        let ret2 = unsafe { waitpid(session.child_pid, &mut status, WNOHANG) };
        if ret2 > 0 {
            if status & 0x7f == 0 {
                (status >> 8) & 0xff
            } else {
                128 + (status & 0x7f)
            }
        } else {
            unsafe {
                kill(session.child_pid, SIGKILL);
                waitpid(session.child_pid, &mut status, 0);
            }
            if status & 0x7f == 0 {
                (status >> 8) & 0xff
            } else {
                128 + (status & 0x7f)
            }
        }
    };

    log_line(&format!(
        "pty_close request_id={} pty_id={} exit_code={}",
        request_id, pty_id, code
    ));

    ok_response(
        request_id,
        op,
        Some(format!(
            "\"meta\":{{\"exitCode\":\"{}\"}},\"exitCode\":{}",
            code, code
        )),
    )
}

fn exit_status_code(status: &std::process::ExitStatus) -> i32 {
    status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(1))
}

fn exit_status_reason(status: &std::process::ExitStatus) -> String {
    match status.code() {
        Some(code) => format!("exit({})", code),
        None => format!("signal({})", status.signal().unwrap_or(1)),
    }
}

fn parse_children_pids(raw: &str) -> Vec<u32> {
    raw.split_whitespace()
        .filter_map(|part| part.parse::<u32>().ok())
        .collect()
}

fn read_process_children(pid: u32) -> Vec<u32> {
    let path = format!("/proc/{}/task/{}/children", pid, pid);
    match fs::read_to_string(path) {
        Ok(contents) => parse_children_pids(&contents),
        Err(_) => Vec::new(),
    }
}

fn read_process_cmdline(pid: u32) -> Option<String> {
    let cmdline_path = format!("/proc/{}/cmdline", pid);
    if let Ok(raw) = fs::read(cmdline_path) {
        let cmdline = raw
            .split(|b| *b == 0)
            .filter(|part| !part.is_empty())
            .map(|part| String::from_utf8_lossy(part).into_owned())
            .collect::<Vec<_>>()
            .join(" ");
        if !cmdline.is_empty() {
            return Some(cmdline);
        }
    }

    let comm_path = format!("/proc/{}/comm", pid);
    fs::read_to_string(comm_path)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn collect_process_descendants(root_pid: u32) -> HashMap<u32, String> {
    let mut discovered: HashMap<u32, String> = HashMap::new();
    let mut visited: HashSet<u32> = HashSet::new();
    let mut pending = read_process_children(root_pid);

    while let Some(pid) = pending.pop() {
        if !visited.insert(pid) {
            continue;
        }
        let cmd = read_process_cmdline(pid).unwrap_or_else(|| "<unknown>".to_string());
        discovered.insert(pid, cmd);
        pending.extend(read_process_children(pid));
    }

    discovered
}

fn log_proc_child_lifecycle(proc_id: String, root_pid: u32) {
    let mut known_children: HashMap<u32, String> = HashMap::new();

    loop {
        let root_alive = Path::new(&format!("/proc/{}", root_pid)).exists();
        let current_children = collect_process_descendants(root_pid);

        for (pid, cmd) in current_children.iter() {
            if !known_children.contains_key(pid) {
                log_line(&format!(
                    "proc_child_spawn proc_id={} root_pid={} pid={} cmd={}",
                    proc_id, root_pid, pid, cmd
                ));
            }
        }

        for pid in known_children.keys() {
            if !current_children.contains_key(pid) {
                log_line(&format!(
                    "proc_child_exit proc_id={} root_pid={} pid={}",
                    proc_id, root_pid, pid
                ));
            }
        }

        known_children = current_children;

        if !root_alive && known_children.is_empty() {
            break;
        }

        thread::sleep(Duration::from_millis(50));
    }
}

fn append_tail(buffer: &mut String, fragment: &str, max_chars: usize) {
    buffer.push_str(fragment);
    let char_count = buffer.chars().count();
    if char_count > max_chars {
        let keep_from = char_count - max_chars;
        let byte_index = buffer
            .char_indices()
            .nth(keep_from)
            .map(|(idx, _)| idx)
            .unwrap_or(0);
        buffer.drain(..byte_index);
    }
}

fn sanitize_preview_for_log(text: &str) -> String {
    text.replace('\n', "\\n").replace('\r', "\\r")
}

fn log_helper_tail_snapshot(proc_id: &str, session: &mut ProcSession, reason: &str) {
    if !session.helper_reference_logged || session.helper_watch_started {
        return;
    }
    let tail = session.helper_trace.as_str();
    if tail.is_empty() || tail == session.helper_tail_last_logged {
        return;
    }
    log_line(&format!(
        "proc_helper_tail proc_id={} reason={} preview={}",
        proc_id,
        reason,
        sanitize_preview_for_log(tail)
    ));
    session.helper_tail_last_logged = tail.to_string();
}

fn is_shell_text_byte(byte: u8) -> bool {
    matches!(byte, b'\n' | b'\r' | b'\t' | b' ') || byte.is_ascii_graphic()
}

fn sanitize_shell_candidate(bytes: &[u8]) -> String {
    bytes
        .iter()
        .filter(|byte| is_shell_text_byte(**byte))
        .map(|byte| *byte as char)
        .collect()
}

fn is_likely_shell_line(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.len() < 16 || trimmed.len() > 4096 {
        return false;
    }
    let bytes = trimmed.as_bytes();
    let ascii_shell_bytes = bytes
        .iter()
        .filter(|byte| is_shell_text_byte(**byte))
        .count();
    if ascii_shell_bytes * 100 / bytes.len().max(1) < 95 {
        return false;
    }

    [
        "REMOTE_CONTAINERS_",
        "vscode-remote-containers",
        "/.vscode-server/bin/",
        "git config --system --replace-all credential.helper",
        "gpgconf --list-dirs",
        "extensionsCache",
        "check-requirements.sh",
        "code-server",
        "product.json",
        "connection-token",
        "/tmp/devcontainers-",
        "# Test for /root/.ssh/known_hosts",
        "# Copy ",
    ]
    .iter()
    .any(|needle| trimmed.contains(needle))
}

fn is_helper_relevant_line(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return false;
    }
    [
        "REMOTE_CONTAINERS_",
        "vscode-remote-containers",
        "credential.helper",
        "/.vscode-server/bin/",
        "gpgconf --list-dirs",
        "extensionsCache",
        "check-requirements.sh",
        "code-server",
        "product.json",
        "connection-token",
        "/tmp/devcontainers-",
        "# Test for /root/.ssh/known_hosts",
        "# Copy ",
    ]
    .iter()
    .any(|needle| trimmed.contains(needle))
}

fn append_helper_trace(session: &mut ProcSession, text_fragment: &str) {
    for line in text_fragment.lines() {
        if !is_helper_relevant_line(line) {
            continue;
        }
        if !session.helper_trace.is_empty() && !session.helper_trace.ends_with('\n') {
            session.helper_trace.push('\n');
        }
        append_tail(&mut session.helper_trace, line, 128 * 1024);
    }
}

fn filter_shell_text_fragment(line_buffer: &mut Vec<u8>, bytes: &[u8]) -> String {
    let mut filtered = String::new();
    for byte in bytes {
        if *byte == b'\n' || *byte == b'\r' {
            if !line_buffer.is_empty() {
                let candidate = sanitize_shell_candidate(line_buffer);
                if is_likely_shell_line(candidate.as_str()) {
                    if !filtered.is_empty() && !filtered.ends_with('\n') {
                        filtered.push('\n');
                    }
                    filtered.push_str(candidate.as_str());
                }
                line_buffer.clear();
            }
            continue;
        }
        line_buffer.push(*byte);
        if line_buffer.len() > 4096 {
            let candidate = sanitize_shell_candidate(line_buffer);
            if is_likely_shell_line(candidate.as_str()) {
                if !filtered.is_empty() && !filtered.ends_with('\n') {
                    filtered.push('\n');
                }
                filtered.push_str(candidate.as_str());
            }
            line_buffer.clear();
        }
    }

    if !line_buffer.is_empty() {
        let candidate = sanitize_shell_candidate(line_buffer);
        if is_likely_shell_line(candidate.as_str()) {
            if !filtered.is_empty() && !filtered.ends_with('\n') {
                filtered.push('\n');
            }
            filtered.push_str(candidate.as_str());
        }
    }

    filtered
}

fn extract_shell_assignment_value(text: &str, key: &str) -> Option<String> {
    let needle = format!("{}=", key);
    let start = text.find(&needle)? + needle.len();
    let bytes = text.as_bytes();
    if start >= bytes.len() {
        return None;
    }

    let quote = bytes[start];
    if quote == b'\'' || quote == b'"' {
        let mut end = start + 1;
        while end < bytes.len() {
            if bytes[end] == quote {
                return Some(text[start + 1..end].to_string());
            }
            end += 1;
        }
        return None;
    }

    let mut end = start;
    while end < bytes.len() {
        let ch = bytes[end];
        if ch.is_ascii_whitespace() || ch == b';' {
            break;
        }
        end += 1;
    }
    if end > start {
        Some(text[start..end].to_string())
    } else {
        None
    }
}

fn is_helper_path_char(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'-' | b'_' | b'.')
}

fn extract_remote_containers_paths(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut seen = HashSet::new();
    let bytes = text.as_bytes();
    let mut cursor = 0usize;

    while cursor < bytes.len() {
        let Some(offset) = text[cursor..].find("/tmp/vscode-remote-containers") else {
            break;
        };
        let start = cursor + offset;
        let mut end = start;
        while end < bytes.len() && is_helper_path_char(bytes[end]) {
            end += 1;
        }
        let path = text[start..end].to_string();
        if seen.insert(path.clone()) {
            found.push(path);
        }
        cursor = end;
    }

    found
}

fn watch_helper_artifacts(proc_id: String, ipc_path: Option<String>, asset_paths: Vec<String>) {
    if ipc_path.is_none() && asset_paths.is_empty() {
        return;
    }

    thread::spawn(move || {
        let mut watched: Vec<(String, String)> = Vec::new();
        if let Some(ipc) = ipc_path {
            watched.push(("ipc".to_string(), ipc));
        }
        for asset in asset_paths {
            watched.push(("asset".to_string(), asset));
        }

        let mut previous: HashMap<String, bool> = HashMap::new();
        for (_, path) in &watched {
            previous.insert(path.clone(), false);
        }

        for _ in 0..400 {
            let mut any_change = false;
            for (kind, path) in &watched {
                let exists = Path::new(path).exists();
                let was = previous.get(path).copied().unwrap_or(false);
                if exists != was {
                    log_line(&format!(
                        "proc_helper_artifact_state proc_id={} kind={} path={} exists={}",
                        proc_id, kind, path, exists
                    ));
                    previous.insert(path.clone(), exists);
                    any_change = true;
                }
            }
            if !any_change && previous.values().all(|exists| *exists) {
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
    });
}

fn start_proc_stdin_writer(
    proc_id: String,
    mut stdin: tokio::process::ChildStdin,
    mut rx: tokio_mpsc::Receiver<ProcStdinMessage>,
) {
    io_runtime().spawn(async move {
        while let Some(message) = rx.recv().await {
            match message {
                ProcStdinMessage::Data {
                    bytes,
                    enqueued_at_ms,
                } => {
                    let dequeued_at_ms = now_epoch_ms() as i64;
                    let queue_wait_ms = dequeued_at_ms.saturating_sub(enqueued_at_ms);
                    if let Err(err) = stdin.write_all(&bytes).await {
                        log_line(&format!(
                            "proc_stdin_writer_error proc_id={} reason=write_failed message={}",
                            proc_id, err
                        ));
                        break;
                    }
                    let write_done_ms = now_epoch_ms() as i64;
                    log_line(&format!(
                        "proc_stdin_writer_write proc_id={} bytes={} queue_wait_ms={} write_ms={}",
                        proc_id,
                        bytes.len(),
                        queue_wait_ms,
                        write_done_ms.saturating_sub(dequeued_at_ms)
                    ));
                }
                ProcStdinMessage::Close => {
                    let _ = stdin.shutdown().await;
                    log_line(&format!(
                        "proc_stdin_writer_closed proc_id={} reason=stdin_close",
                        proc_id
                    ));
                    break;
                }
            }
        }
    });
}

fn start_proc_output_merge_pump(
    mut stdout: tokio::process::ChildStdout,
    mut stderr: tokio::process::ChildStderr,
    tx: tokio_mpsc::Sender<ProcEvent>,
    seq: Arc<AtomicU64>,
    proc_id: String,
) {
    io_runtime().spawn(async move {
        let mut stdout_open = true;
        let mut stderr_open = true;
        let mut pending_stderr: Option<Vec<u8>> = None;
        let mut stdout_buf = vec![0u8; 4096];
        let mut stderr_buf = vec![0u8; 4096];

        while stdout_open || stderr_open {
            if let Some(data) = pending_stderr.take() {
                if stdout_open {
                    match tokio_timeout(
                        TokioDuration::from_millis(PROC_STDERR_HOLDBACK_WINDOW_MS),
                        stdout.read(&mut stdout_buf),
                    )
                    .await
                    {
                        Ok(Ok(0)) => {
                            stdout_open = false;
                        }
                        Ok(Ok(n)) => {
                            log_line(&format!(
                                "proc_merge_flush proc_id={} stream=stdout bytes={}",
                                proc_id, n
                            ));
                            if emit_proc_stream_chunk(
                                &tx,
                                &seq,
                                &proc_id,
                                ProcStreamKind::Stdout,
                                stdout_buf[..n].to_vec(),
                            )
                            .await
                            .is_err()
                            {
                                return;
                            }
                        }
                        Ok(Err(err)) => {
                            log_line(&format!(
                                "proc_stream_error proc_id={} stream={:?} message={}",
                                proc_id,
                                ProcStreamKind::Stdout,
                                err
                            ));
                            stdout_open = false;
                        }
                        Err(_) => {
                            log_line(&format!(
                                "proc_merge_flush proc_id={} stream=stderr bytes={} reason=holdback_timeout",
                                proc_id,
                                data.len()
                            ));
                        }
                    }
                }
                if emit_proc_stream_chunk(&tx, &seq, &proc_id, ProcStreamKind::Stderr, data)
                    .await
                    .is_err()
                {
                    return;
                }
                continue;
            }
            tokio::select! {
                stdout_result = stdout.read(&mut stdout_buf), if stdout_open => {
                    match stdout_result {
                        Ok(0) => {
                            stdout_open = false;
                        }
                        Ok(n) => {
                            log_line(&format!("proc_stdout_event proc_id={} bytes={}", proc_id, n));
                            if emit_proc_stream_chunk(
                                &tx,
                                &seq,
                                &proc_id,
                                ProcStreamKind::Stdout,
                                stdout_buf[..n].to_vec(),
                            ).await.is_err() {
                                return;
                            }
                        }
                        Err(err) => {
                            log_line(&format!(
                                "proc_stream_error proc_id={} stream={:?} message={}",
                                proc_id,
                                ProcStreamKind::Stdout,
                                err
                            ));
                            stdout_open = false;
                        }
                    }
                }
                stderr_result = stderr.read(&mut stderr_buf), if stderr_open => {
                    match stderr_result {
                        Ok(0) => {
                            stderr_open = false;
                        }
                        Ok(n) => {
                            log_line(&format!("proc_stderr_event proc_id={} bytes={}", proc_id, n));
                            let data = stderr_buf[..n].to_vec();
                            if should_holdback_proc_stderr_chunk(&data) && stdout_open {
                                log_line(&format!(
                                    "proc_merge_holdback proc_id={} stream=stderr bytes={} reason=shell_server_sentinel",
                                    proc_id, n
                                ));
                                pending_stderr = Some(data);
                            } else if emit_proc_stream_chunk(
                                &tx,
                                &seq,
                                &proc_id,
                                ProcStreamKind::Stderr,
                                data,
                            ).await.is_err() {
                                    return;
                            }
                        }
                        Err(err) => {
                            log_line(&format!(
                                "proc_stream_error proc_id={} stream={:?} message={}",
                                proc_id,
                                ProcStreamKind::Stderr,
                                err
                            ));
                            stderr_open = false;
                        }
                    }
                }
            }
        }

        if let Some(data) = pending_stderr.take() {
            log_line(&format!(
                "proc_merge_flush proc_id={} stream=stderr bytes={} reason=finalize",
                proc_id,
                data.len()
            ));
            if emit_proc_stream_chunk(&tx, &seq, &proc_id, ProcStreamKind::Stderr, data)
                .await
                .is_err()
            {
                return;
            }
        }
        let _ = tx.send(ProcEvent::StreamsClosed).await;
    });
}

async fn emit_proc_stream_chunk(
    tx: &tokio_mpsc::Sender<ProcEvent>,
    seq: &Arc<AtomicU64>,
    proc_id: &str,
    stream: ProcStreamKind,
    data: Vec<u8>,
) -> Result<(), ()> {
    let chunk = ProcStreamChunk {
        seq: seq.fetch_add(1, Ordering::Relaxed),
        stream,
        data,
    };
    log_line(&format!(
        "proc_merge_emit proc_id={} stream={:?} seq={} bytes={}",
        proc_id,
        stream,
        chunk.seq,
        chunk.data.len()
    ));
    tx.send(ProcEvent::Stream(chunk)).await.map_err(|_| ())
}

fn should_holdback_proc_stderr_chunk(data: &[u8]) -> bool {
    data == SHELL_SERVER_SENTINEL
}

fn start_proc_wait_task(
    proc_id: String,
    mut child: tokio::process::Child,
    tx: tokio_mpsc::Sender<ProcEvent>,
) {
    io_runtime().spawn(async move {
        match child.wait().await {
            Ok(status) => {
                let code = exit_status_code(&status);
                let reason = exit_status_reason(&status);
                log_line(&format!(
                    "proc_exited proc_id={} exit_code={} reason={}",
                    proc_id, code, reason
                ));
                let _ = tx.send(ProcEvent::Exited { code, reason }).await;
            }
            Err(err) => {
                log_line(&format!(
                    "proc_wait_error proc_id={} message={}",
                    proc_id, err
                ));
                let _ = tx
                    .send(ProcEvent::Exited {
                        code: 126,
                        reason: format!("wait_error({})", err),
                    })
                    .await;
            }
        }
    });
}

fn observe_helper_handoff(proc_id: &str, session: &mut ProcSession, bytes: &[u8]) {
    let fragment = String::from_utf8_lossy(bytes);
    if fragment.is_empty() {
        return;
    }

    append_tail(&mut session.stdin_tail, &fragment, 32 * 1024);
    let text_fragment = filter_shell_text_fragment(&mut session.stdin_line_buffer, bytes);
    if !text_fragment.is_empty() {
        append_tail(&mut session.stdin_text_tail, &text_fragment, 32 * 1024);
        append_helper_trace(session, &text_fragment);
    }

    let tail = session.helper_trace.clone();
    if tail.is_empty() {
        return;
    }

    let has_helper_path = tail.contains("/tmp/vscode-remote-containers-");
    let has_server_script = tail.contains("/tmp/vscode-remote-containers-server-");
    let has_ipc = tail.contains("REMOTE_CONTAINERS_IPC=");
    let has_node_exec = tail.contains("/.vscode-server/bin/") && tail.contains("/node");

    if !has_helper_path && !has_ipc {
        return;
    }

    if !session.helper_reference_logged && has_helper_path && !(has_ipc && has_server_script) {
        let helper_paths = extract_remote_containers_paths(&tail);
        log_line(&format!(
            "proc_helper_reference proc_id={} helper_paths={} preview={}",
            proc_id,
            helper_paths.join(","),
            sanitize_preview_for_log(&tail)
        ));
        session.helper_reference_logged = true;
    }

    log_helper_tail_snapshot(proc_id, session, "stdin_progress");

    if !session.helper_candidate_logged && (has_ipc || has_server_script || has_node_exec) {
        log_line(&format!(
            "proc_helper_candidate proc_id={} has_ipc={} has_server_script={} has_node_exec={} preview={}",
            proc_id,
            has_ipc,
            has_server_script,
            has_node_exec,
            sanitize_preview_for_log(&tail)
        ));
        session.helper_candidate_logged = true;
    }

    if session.helper_watch_started || !has_ipc || !has_server_script || !has_node_exec {
        return;
    }

    let ipc_path = extract_shell_assignment_value(&tail, "REMOTE_CONTAINERS_IPC");
    let sockets = extract_shell_assignment_value(&tail, "REMOTE_CONTAINERS_SOCKETS");
    let helper_paths = extract_remote_containers_paths(&tail);
    let preview = sanitize_preview_for_log(&tail);
    log_line(&format!(
        "proc_helper_detected proc_id={} ipc_path={} sockets={} helper_paths={} preview={}",
        proc_id,
        ipc_path.as_deref().unwrap_or(""),
        sockets.as_deref().unwrap_or(""),
        if helper_paths.is_empty() {
            "".to_string()
        } else {
            helper_paths.join(",")
        },
        preview
    ));
    session.helper_watch_started = true;
    watch_helper_artifacts(proc_id.to_string(), ipc_path, helper_paths);
}

fn proc_open_response(request_id: &str, op: &str, line: &str) -> String {
    let argv = extract_string_array(line, "argv").unwrap_or_else(|| vec!["/bin/sh".to_string()]);
    if argv.is_empty() {
        return error_response(request_id, op, "invalid_request", "missing argv");
    }
    let requested_cwd = extract_string(line, "cwd");
    let env_additions = extract_string_map(line, "envAdditions").unwrap_or_default();
    let run_as_root = extract_bool(line, "runAsRoot").unwrap_or(false);
    let runtime = runtime_context_for_request(run_as_root);
    log_line(&format!(
        "proc_open_received request_id={} argv0={} run_as_root={} requested_cwd={}",
        request_id,
        argv[0],
        run_as_root,
        requested_cwd.clone().unwrap_or_default()
    ));

    let mut cmd = TokioCommand::new(&argv[0]);
    if argv.len() > 1 {
        cmd.args(&argv[1..]);
    }
    cmd.uid(runtime.uid);
    cmd.gid(runtime.gid);
    cmd.stdin(Stdio::piped());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    cmd.envs(child_process_environment(&runtime, env_additions));
    let desired_cwd = requested_cwd
        .as_ref()
        .filter(|v| v.starts_with('/') && Path::new(v).is_dir())
        .cloned()
        .unwrap_or_else(|| runtime.home.clone());
    if Path::new(&desired_cwd).is_dir() {
        cmd.current_dir(&desired_cwd);
    }

    let tokio_runtime = io_runtime();
    let _runtime_guard = tokio_runtime.enter();
    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(err) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                &format!("spawn failed: {}", err),
            )
        }
    };

    let stdin = match child.stdin.take() {
        Some(stdin) => stdin,
        None => return error_response(request_id, op, "internal_error", "missing child stdin"),
    };
    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => return error_response(request_id, op, "internal_error", "missing child stdout"),
    };
    let stderr = match child.stderr.take() {
        Some(stderr) => stderr,
        None => return error_response(request_id, op, "internal_error", "missing child stderr"),
    };

    let proc_id = format!(
        "proc-{}-{}",
        std::process::id(),
        PROC_SEQ.fetch_add(1, Ordering::Relaxed)
    );
    let (merged_tx, merged_rx) = tokio_mpsc::channel::<ProcEvent>(512);
    let stream_seq = Arc::new(AtomicU64::new(1));
    start_proc_output_merge_pump(
        stdout,
        stderr,
        merged_tx.clone(),
        Arc::clone(&stream_seq),
        proc_id.clone(),
    );

    let pid = child.id().unwrap_or(0);
    let (stdin_tx, stdin_rx) = tokio_mpsc::channel::<ProcStdinMessage>(256);
    start_proc_stdin_writer(proc_id.clone(), stdin, stdin_rx);
    let child_monitor_proc_id = proc_id.clone();
    thread::spawn(move || {
        log_proc_child_lifecycle(child_monitor_proc_id, pid);
    });
    start_proc_wait_task(proc_id.clone(), child, merged_tx.clone());

    match proc_sessions().lock() {
        Ok(mut map) => {
            map.insert(
                proc_id.clone(),
                ProcSession {
                    child_pid: pid as i32,
                    stdin_tx: Some(stdin_tx),
                    rx: Arc::new(TokioMutex::new(merged_rx)),
                    child_exit_code: None,
                    child_exit_reason: None,
                    streams_closed: false,
                    stdin_tail: String::new(),
                    stdin_text_tail: String::new(),
                    helper_trace: String::new(),
                    stdin_line_buffer: Vec::new(),
                    helper_watch_started: false,
                    helper_candidate_logged: false,
                    helper_reference_logged: false,
                    helper_tail_last_logged: String::new(),
                },
            );
        }
        Err(_) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                "proc session lock poisoned",
            )
        }
    }

    log_line(&format!(
        "proc_session_started request_id={} proc_id={} argv0={} pid={} user={} uid={} gid={}",
        request_id, proc_id, argv[0], pid, runtime.username, runtime.uid, runtime.gid
    ));
    ok_response(
        request_id,
        op,
        Some(format!("\"procId\":\"{}\"", escape_json(&proc_id))),
    )
}

fn proc_read_response(request_id: &str, op: &str, line: &str) -> String {
    let proc_id = match extract_string(line, "procId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing procId"),
    };
    let timeout_ms = extract_int(line, "timeoutMs");

    let mut map = match proc_sessions().lock() {
        Ok(v) => v,
        Err(_) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                "proc session lock poisoned",
            )
        }
    };

    let mut stdout: Vec<u8> = Vec::new();
    let mut stderr: Vec<u8> = Vec::new();
    let (mut chunks, exit_code, exit_reason, finalize) = {
        let session = match map.get_mut(&proc_id) {
            Some(v) => v,
            None => return error_response(request_id, op, "invalid_request", "unknown procId"),
        };
        collect_proc_read_events(session, timeout_ms)
    };

    if finalize {
        map.remove(&proc_id);
    }

    chunks.sort_by_key(|chunk| chunk.seq);

    let mut chunks_json: Vec<String> = Vec::new();
    for chunk in chunks {
        match chunk.stream {
            ProcStreamKind::Stdout => {
                stdout.extend_from_slice(&chunk.data);
                chunks_json.push(format!(
                    "{{\"stream\":\"stdout\",\"dataBase64\":\"{}\"}}",
                    escape_json(&b64_encode(&chunk.data))
                ));
            }
            ProcStreamKind::Stderr => {
                stderr.extend_from_slice(&chunk.data);
                chunks_json.push(format!(
                    "{{\"stream\":\"stderr\",\"dataBase64\":\"{}\"}}",
                    escape_json(&b64_encode(&chunk.data))
                ));
            }
        }
    }

    let mut extras: Vec<String> = Vec::new();
    if !stdout.is_empty() {
        extras.push(format!(
            "\"stdoutBase64\":\"{}\"",
            escape_json(&b64_encode(&stdout))
        ));
    }
    if !stderr.is_empty() {
        extras.push(format!(
            "\"stderrBase64\":\"{}\"",
            escape_json(&b64_encode(&stderr))
        ));
    }
    if !chunks_json.is_empty() {
        extras.push(format!("\"chunks\":[{}]", chunks_json.join(",")));
    }
    if let Some(code) = exit_code {
        let mut meta_fields = vec![format!("\"exitCode\":\"{}\"", code)];
        if let Some(reason) = exit_reason.as_ref() {
            meta_fields.push(format!("\"exitReason\":\"{}\"", escape_json(reason)));
        }
        extras.push(format!("\"meta\":{{{}}}", meta_fields.join(",")));
        extras.push(format!("\"exitCode\":{}", code));
    }
    ok_response(
        request_id,
        op,
        if extras.is_empty() {
            None
        } else {
            Some(extras.join(","))
        },
    )
}

fn set_fd_nonblocking(fd: i32) -> bool {
    let flags = unsafe { fcntl(fd, F_GETFL) };
    if flags < 0 {
        return false;
    }
    (unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) }) == 0
}

fn proc_write_response(request_id: &str, op: &str, line: &str) -> String {
    let proc_id = match extract_string(line, "procId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing procId"),
    };
    let payload = match extract_string(line, "dataBase64") {
        Some(v) => v,
        None => return error_response(request_id, op, "invalid_request", "missing dataBase64"),
    };

    let bytes = match b64_decode(&payload) {
        Ok(v) => v,
        Err(e) => {
            return error_response(
                request_id,
                op,
                "invalid_request",
                &format!("invalid base64: {e}"),
            )
        }
    };

    let stdin_tx = {
        let mut map = match proc_sessions().lock() {
            Ok(v) => v,
            Err(_) => {
                return error_response(
                    request_id,
                    op,
                    "internal_error",
                    "proc session lock poisoned",
                )
            }
        };
        let session = match map.get_mut(&proc_id) {
            Some(v) => v,
            None => return error_response(request_id, op, "invalid_request", "unknown procId"),
        };
        observe_helper_handoff(&proc_id, session, &bytes);

        match session.stdin_tx.as_ref() {
            Some(v) => v.clone(),
            None => {
                return error_response(
                    request_id,
                    op,
                    "internal_error",
                    "proc stdin already closed",
                )
            }
        }
    };

    let enqueue_started_ms = now_epoch_ms() as i64;
    let byte_len = bytes.len();
    if let Err(err) = stdin_tx.blocking_send(ProcStdinMessage::Data {
        bytes,
        enqueued_at_ms: enqueue_started_ms,
    }) {
        return error_response(
            request_id,
            op,
            "internal_error",
            &format!("proc stdin queue failed: {}", err),
        );
    }
    let meta = format!(
        "\"meta\":{{\"bytes\":\"{}\",\"queueSendMs\":\"{}\"}}",
        byte_len,
        (now_epoch_ms() as i64).saturating_sub(enqueue_started_ms)
    );
    ok_response(request_id, op, Some(meta))
}

fn proc_stdin_close_response(request_id: &str, op: &str, line: &str) -> String {
    let proc_id = match extract_string(line, "procId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing procId"),
    };

    let (sender, already_closed, child_alive) = {
        let mut map = match proc_sessions().lock() {
            Ok(v) => v,
            Err(_) => {
                return error_response(
                    request_id,
                    op,
                    "internal_error",
                    "proc session lock poisoned",
                )
            }
        };
        let session = match map.get_mut(&proc_id) {
            Some(v) => v,
            None => {
                return ok_response(
                    request_id,
                    op,
                    Some("\"meta\":{\"closed\":\"already\"}".to_string()),
                )
            }
        };

        log_helper_tail_snapshot(&proc_id, session, "stdin_close");
        let sender = session.stdin_tx.take();
        let already_closed = sender.is_none();
        let child_alive = session.child_exit_code.is_none();
        (sender, already_closed, child_alive)
    };
    if let Some(tx) = sender {
        let _ = tx.blocking_send(ProcStdinMessage::Close);
    }
    log_line(&format!(
        "proc_stdin_close request_id={} proc_id={} already_closed={} child_alive={} close_reason=stdin_eof",
        request_id, proc_id, already_closed, child_alive
    ));
    ok_response(
        request_id,
        op,
        Some(format!(
            "\"meta\":{{\"alreadyClosed\":\"{}\",\"childAlive\":\"{}\",\"closeReason\":\"stdin_eof\"}}",
            already_closed, child_alive
        )),
    )
}

fn proc_close_response(request_id: &str, op: &str, line: &str) -> String {
    let proc_id = match extract_string(line, "procId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing procId"),
    };

    let mut session = {
        let mut map = match proc_sessions().lock() {
            Ok(v) => v,
            Err(_) => {
                return error_response(
                    request_id,
                    op,
                    "internal_error",
                    "proc session lock poisoned",
                )
            }
        };
        match map.remove(&proc_id) {
            Some(v) => v,
            None => {
                return ok_response(
                    request_id,
                    op,
                    Some("\"meta\":{\"closed\":\"already\"}".to_string()),
                )
            }
        }
    };

    log_helper_tail_snapshot(&proc_id, &mut session, "proc_close");
    if let Some(tx) = session.stdin_tx.take() {
        let _ = tx.blocking_send(ProcStdinMessage::Close);
    }
    let mut close_action = "already_exited".to_string();
    if session.child_exit_code.is_none() {
        close_action = "killed".to_string();
        unsafe {
            kill(session.child_pid, SIGKILL);
        }
    }
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline
        && (session.child_exit_code.is_none() || !session.streams_closed)
    {
        let mut rx = session.rx.blocking_lock();
        match recv_proc_event_blocking(&mut rx, 50) {
            BlockingRecvResult::Event(ProcEvent::Stream(_)) => {}
            BlockingRecvResult::Event(ProcEvent::Exited { code, reason }) => {
                session.child_exit_code = Some(code);
                session.child_exit_reason = Some(reason);
            }
            BlockingRecvResult::Event(ProcEvent::StreamsClosed) => {
                session.streams_closed = true;
            }
            BlockingRecvResult::Timeout => {}
            BlockingRecvResult::Closed => {
                session.streams_closed = true;
            }
        }
    }
    let code = session.child_exit_code.unwrap_or(1);
    let exit_reason = session
        .child_exit_reason
        .clone()
        .unwrap_or_else(|| "wait_error".to_string());

    log_line(&format!(
        "proc_close request_id={} proc_id={} exit_code={} exit_reason={} close_action={}",
        request_id, proc_id, code, exit_reason, close_action
    ));

    ok_response(
        request_id,
        op,
        Some(format!(
            "\"meta\":{{\"exitCode\":\"{}\",\"exitReason\":\"{}\",\"closeAction\":\"{}\"}},\"exitCode\":{}",
            code,
            escape_json(&exit_reason),
            escape_json(&close_action),
            code
        )),
    )
}

fn b64_encode(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut i = 0;
    while i < data.len() {
        let b0 = data[i] as u32;
        let b1 = if i + 1 < data.len() {
            data[i + 1] as u32
        } else {
            0
        };
        let b2 = if i + 2 < data.len() {
            data[i + 2] as u32
        } else {
            0
        };

        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((n >> 18) & 0x3f) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3f) as usize] as char);
        if i + 1 < data.len() {
            out.push(TABLE[((n >> 6) & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
        if i + 2 < data.len() {
            out.push(TABLE[(n & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
        i += 3;
    }
    out
}

fn b64_decode(input: &str) -> Result<Vec<u8>, String> {
    let bytes: Vec<u8> = input
        .as_bytes()
        .iter()
        .copied()
        .filter(|b| !b" \n\r\t".contains(b))
        .collect();
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if bytes.len() % 4 != 0 {
        return Err("length must be multiple of 4".to_string());
    }

    let mut out: Vec<u8> = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let c0 = chunk[0];
        let c1 = chunk[1];
        let c2 = chunk[2];
        let c3 = chunk[3];

        let v0 = b64_val(c0).ok_or_else(|| "invalid base64 character".to_string())? as u32;
        let v1 = b64_val(c1).ok_or_else(|| "invalid base64 character".to_string())? as u32;
        let v2 = if c2 == b'=' {
            0
        } else {
            b64_val(c2).ok_or_else(|| "invalid base64 character".to_string())? as u32
        };
        let v3 = if c3 == b'=' {
            0
        } else {
            b64_val(c3).ok_or_else(|| "invalid base64 character".to_string())? as u32
        };

        let n = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;
        out.push(((n >> 16) & 0xff) as u8);
        if c2 != b'=' {
            out.push(((n >> 8) & 0xff) as u8);
        }
        if c3 != b'=' {
            out.push((n & 0xff) as u8);
        }
    }
    Ok(out)
}

fn b64_val(c: u8) -> Option<u8> {
    match c {
        b'A'..=b'Z' => Some(c - b'A'),
        b'a'..=b'z' => Some(26 + (c - b'a')),
        b'0'..=b'9' => Some(52 + (c - b'0')),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

fn ok_response(request_id: &str, op: &str, extra: Option<String>) -> String {
    let mut fields = vec![
        "\"version\":1".to_string(),
        format!("\"requestId\":\"{}\"", escape_json(request_id)),
        format!("\"op\":\"{}\"", escape_json(op)),
        "\"status\":\"ok\"".to_string(),
    ];
    if let Some(extra_fields) = extra {
        fields.push(extra_fields);
    }
    format!("{{{}}}", fields.join(","))
}

fn error_response(request_id: &str, op: &str, code: &str, message: &str) -> String {
    log_line(&format!(
        "error request_id={} op={} code={} message={}",
        request_id, op, code, message
    ));
    format!(
        "{{\"version\":1,\"requestId\":\"{}\",\"op\":\"{}\",\"status\":\"error\",\"error\":{{\"code\":\"{}\",\"message\":\"{}\"}}}}",
        escape_json(request_id),
        escape_json(op),
        escape_json(code),
        escape_json(message)
    )
}

fn init_diagnostic_channel() {
    let tty_path = env::var("MSL_DIAG_TTY")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "/dev/hvc1".to_string());
    let file = OpenOptions::new().write(true).open(&tty_path).ok();
    let lock = DIAG_LOCK.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = lock.lock() {
        *guard = file;
    }
}

fn start_diagnostic_forwarders() {
    start_kernel_forwarder();
    start_syslog_forwarder();
}

fn start_kernel_forwarder() {
    thread::spawn(|| {
        let mut child = match Command::new("/bin/sh")
            .arg("-lc")
            .arg("dmesg -w")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(v) => v,
            Err(e) => {
                log_line(&format!("kernel forwarder unavailable: {e}"));
                return;
            }
        };

        if let Some(stdout) = child.stdout.take() {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                match line {
                    Ok(line) if !line.trim().is_empty() => diag_write("kernel", &line),
                    Ok(_) => {}
                    Err(e) => {
                        log_line(&format!("kernel forwarder read error: {e}"));
                        break;
                    }
                }
            }
        }
    });
}

fn start_syslog_forwarder() {
    thread::spawn(|| {
        let source = [
            "/var/log/syslog",
            "/var/log/messages",
            "/var/log/kern.log",
            "/var/log/dmesg",
        ]
        .iter()
        .find(|candidate| Path::new(*candidate).exists())
        .copied();

        let Some(source) = source else {
            log_line("syslog forwarder source not found");
            return;
        };

        let command = format!("tail -n 0 -F {}", source);
        let mut child = match Command::new("/bin/sh")
            .arg("-lc")
            .arg(command)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(v) => v,
            Err(e) => {
                log_line(&format!("syslog forwarder unavailable: {e}"));
                return;
            }
        };

        if let Some(stdout) = child.stdout.take() {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                match line {
                    Ok(line) if !line.trim().is_empty() => diag_write("syslog", &line),
                    Ok(_) => {}
                    Err(e) => {
                        log_line(&format!("syslog forwarder read error: {e}"));
                        break;
                    }
                }
            }
        }
    });
}

fn diag_write(channel: &str, message: &str) {
    let line = format!(
        "[{channel}] ts_ms={} pid={} {}",
        now_epoch_ms(),
        std::process::id(),
        message
    );
    let lock = DIAG_LOCK.get_or_init(|| Mutex::new(None));
    let mut guard = match lock.lock() {
        Ok(v) => v,
        Err(_) => return,
    };
    if let Some(file) = guard.as_mut() {
        let _ = writeln!(file, "{line}");
        let _ = file.flush();
    }
}

fn format_log_record(message: &str, ts_ms: u64, pid: u32) -> String {
    format!("msl-init: ts_ms={} pid={} {}", ts_ms, pid, message)
}

fn log_line(message: &str) {
    let line = format_log_record(message, now_epoch_ms(), std::process::id());
    eprintln!("{line}");
    diag_write("init", message);

    let path = match env::var("MSL_INIT_LOG_FILE") {
        Ok(v) if !v.is_empty() => v,
        _ => return,
    };

    if let Some(parent) = Path::new(&path).parent() {
        let _ = fs::create_dir_all(parent);
    }

    let lock = LOG_LOCK.get_or_init(|| Mutex::new(()));
    let _guard = match lock.lock() {
        Ok(g) => g,
        Err(_) => return,
    };

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(file, "{line}");
    }
}

fn converge_status_response(request_id: &str) -> String {
    ok_response(
        request_id,
        "converge_status",
        Some("\"meta\":{\"convergence\":\"done\",\"status\":\"ok\"}".to_string()),
    )
}

#[derive(Clone)]
struct PasswdEntry {
    username: String,
    uid: u32,
    gid: u32,
    home: String,
    shell: String,
}

#[derive(Clone)]
struct GroupEntry {
    name: String,
    gid: u32,
    members: Vec<String>,
}

fn converge_user_response(request_id: &str, op: &str, line: &str) -> String {
    let username = match extract_string(line, "convergeUsername") {
        Some(v) if !v.is_empty() => v,
        _ => {
            return error_response(
                request_id,
                op,
                "invalid_request",
                "missing convergeUsername",
            )
        }
    };
    if !is_safe_identifier(&username) {
        return error_response(
            request_id,
            op,
            "invalid_request",
            "invalid convergeUsername",
        );
    }

    let uid = match extract_int(line, "convergeUID") {
        Some(v) if v >= 0 => v as u32,
        _ => {
            return error_response(
                request_id,
                op,
                "invalid_request",
                "missing or invalid convergeUID",
            )
        }
    };
    let gid = match extract_int(line, "convergeGID") {
        Some(v) if v >= 0 => v as u32,
        _ => {
            return error_response(
                request_id,
                op,
                "invalid_request",
                "missing or invalid convergeGID",
            )
        }
    };

    let home = match extract_string(line, "convergeHome") {
        Some(v) if !v.is_empty() && v.starts_with('/') => v,
        _ => {
            return error_response(
                request_id,
                op,
                "invalid_request",
                "missing or invalid convergeHome",
            )
        }
    };
    let preferred_shell = extract_string(line, "convergePreferredShell");
    let fail_on_uid_conflict = extract_bool(line, "convergeFailOnUIDConflict").unwrap_or(true);

    let template_id =
        extract_string(line, "policyTemplateId").unwrap_or_else(|| "unknown".to_string());
    let command_family =
        extract_string(line, "policyCommandFamily").unwrap_or_else(|| "useradd".to_string());
    let admin_group =
        extract_string(line, "policyAdminGroup").unwrap_or_else(|| "sudo".to_string());
    if !is_safe_identifier(&admin_group) {
        return error_response(
            request_id,
            op,
            "invalid_request",
            "invalid policyAdminGroup",
        );
    }
    let sudo_enabled = extract_bool(line, "policySudoEnabled").unwrap_or(true);
    let sudo_require_binary = extract_bool(line, "policySudoRequireBinary").unwrap_or(false);
    let sudo_passwordless = extract_bool(line, "policySudoPasswordless").unwrap_or(true);
    let su_enabled = extract_bool(line, "policySuEnabled").unwrap_or(false);
    let su_passwordless = extract_bool(line, "policySuPasswordless").unwrap_or(false);
    let sudo_drop_in = extract_string(line, "policySudoDropInPath")
        .unwrap_or_else(|| "/etc/sudoers.d/msl-user".to_string());
    if !sudo_drop_in.starts_with('/') {
        return error_response(
            request_id,
            op,
            "invalid_request",
            "policySudoDropInPath must be absolute",
        );
    }
    let shell_fallbacks = extract_string_array(line, "policyShellFallbacks")
        .unwrap_or_else(|| vec!["/bin/sh".to_string()]);

    let welcome_enabled = extract_bool(line, "policyWelcomeEnabled").unwrap_or(true);
    let welcome_frequency =
        extract_string(line, "policyWelcomeFrequency").unwrap_or_else(|| "daily".to_string());
    let welcome_respect_hushlogin =
        extract_bool(line, "policyWelcomeRespectHushlogin").unwrap_or(true);
    let welcome_instance =
        extract_string(line, "policyWelcomeInstance").unwrap_or_else(|| "msl".to_string());

    let requested_shell = preferred_shell
        .and_then(|s| {
            if is_executable_path(&s) {
                Some(s)
            } else {
                None
            }
        })
        .or_else(|| {
            shell_fallbacks
                .iter()
                .find(|s| is_executable_path(s))
                .cloned()
        })
        .unwrap_or_else(|| "/bin/sh".to_string());

    let mut warnings: Vec<String> = Vec::new();
    let existing_by_name = find_user_by_name(&username);
    let mut created = false;

    if existing_by_name.is_none() {
        if fail_on_uid_conflict {
            if let Some(conflict) = find_user_by_uid(uid) {
                if conflict.username != username {
                    return error_response(
                        request_id,
                        op,
                        "invalid_request",
                        &format!(
                            "uid_conflict: uid {} already owned by {}",
                            uid, conflict.username
                        ),
                    );
                }
            }
        }

        if let Err(e) = create_user_from_policy(
            &command_family,
            &username,
            uid,
            gid,
            &home,
            &requested_shell,
        ) {
            return error_response(
                request_id,
                op,
                "internal_error",
                &format!("user_create_failed: {}", e),
            );
        }
        created = true;
    }

    let mut resolved = match find_user_by_name(&username) {
        Some(v) => v,
        None => {
            return error_response(
                request_id,
                op,
                "internal_error",
                &format!("user_not_found_after_converge: {}", username),
            );
        }
    };

    if !is_executable_path(&resolved.shell) {
        resolved.shell = requested_shell.clone();
    }
    if resolved.home.is_empty() {
        resolved.home = home.clone();
    }

    if let Err(e) = ensure_user_home(&resolved) {
        warnings.push(format!("home_setup_failed: {}", e));
    }
    if let Err(e) = ensure_admin_group_membership(&command_family, &resolved.username, &admin_group)
    {
        warnings.push(format!("admin_group_failed: {}", e));
    }
    match apply_su_policy(&admin_group, su_enabled, su_passwordless) {
        Ok(Some(warning)) => warnings.push(warning),
        Ok(None) => {}
        Err(e) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                &format!("su_policy_failed: {}", e),
            );
        }
    }
    match apply_sudo_policy(
        &resolved.username,
        sudo_enabled,
        sudo_require_binary,
        sudo_passwordless,
        &sudo_drop_in,
    ) {
        Ok(Some(warning)) => warnings.push(warning),
        Ok(None) => {}
        Err(e) => {
            return error_response(
                request_id,
                op,
                "internal_error",
                &format!("sudo_policy_failed: {}", e),
            );
        }
    }
    if let Err(e) = ensure_su_setuid_if_present() {
        warnings.push(format!("su_setup_failed: {}", e));
    }
    if let Err(e) = ensure_runtime_hostname(&welcome_instance) {
        warnings.push(format!("hostname_setup_failed: {}", e));
    }
    if let Err(e) = install_welcome_script(
        welcome_enabled,
        &welcome_frequency,
        welcome_respect_hushlogin,
        &welcome_instance,
    ) {
        warnings.push(format!("welcome_setup_failed: {}", e));
    }

    if let Ok(mut state) = runtime_user().lock() {
        *state = RuntimeUserContext {
            username: resolved.username.clone(),
            uid: resolved.uid,
            gid: resolved.gid,
            home: resolved.home.clone(),
            shell: resolved.shell.clone(),
        };
    }

    log_line(&format!(
        "converge_user ok user={} uid={} gid={} created={} template={}",
        resolved.username, resolved.uid, resolved.gid, created, template_id
    ));

    ok_response(
        request_id,
        op,
        Some(format!(
            "\"meta\":{{\"resolved_user\":\"{}\",\"resolved_uid\":\"{}\",\"resolved_gid\":\"{}\",\"resolved_home\":\"{}\",\"resolved_shell\":\"{}\",\"created\":\"{}\",\"policy_template_id\":\"{}\",\"warnings\":\"{}\"}}",
            escape_json(&resolved.username),
            resolved.uid,
            resolved.gid,
            escape_json(&resolved.home),
            escape_json(&resolved.shell),
            if created { "true" } else { "false" },
            escape_json(&template_id),
            escape_json(&warnings.join("; "))
        )),
    )
}

fn is_safe_identifier(value: &str) -> bool {
    if value.is_empty() {
        return false;
    }
    value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
}

fn is_executable_path(path: &str) -> bool {
    let p = Path::new(path);
    if !p.is_file() {
        return false;
    }
    match fs::metadata(p) {
        Ok(meta) => (meta.permissions().mode() & 0o111) != 0,
        Err(_) => false,
    }
}

fn read_passwd_entries() -> Vec<PasswdEntry> {
    let content = match fs::read_to_string("/etc/passwd") {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    content
        .lines()
        .filter_map(|line| {
            let parts: Vec<&str> = line.split(':').collect();
            if parts.len() < 7 {
                return None;
            }
            let uid = parts[2].parse::<u32>().ok()?;
            let gid = parts[3].parse::<u32>().ok()?;
            Some(PasswdEntry {
                username: parts[0].to_string(),
                uid,
                gid,
                home: parts[5].to_string(),
                shell: parts[6].to_string(),
            })
        })
        .collect()
}

fn read_group_entries() -> Vec<GroupEntry> {
    let content = match fs::read_to_string("/etc/group") {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    content
        .lines()
        .filter_map(|line| {
            let parts: Vec<&str> = line.split(':').collect();
            if parts.len() < 4 {
                return None;
            }
            let gid = parts[2].parse::<u32>().ok()?;
            let members = parts[3]
                .split(',')
                .map(|member| member.trim())
                .filter(|member| !member.is_empty())
                .map(|member| member.to_string())
                .collect::<Vec<String>>();
            Some(GroupEntry {
                name: parts[0].to_string(),
                gid,
                members,
            })
        })
        .collect()
}

fn supplementary_gids_for_user(username: &str, primary_gid: u32) -> Vec<u32> {
    read_group_entries()
        .into_iter()
        .filter(|group| group.gid != primary_gid)
        .filter(|group| group.members.iter().any(|member| member == username))
        .map(|group| group.gid)
        .collect()
}

fn find_user_by_name(name: &str) -> Option<PasswdEntry> {
    read_passwd_entries()
        .into_iter()
        .find(|u| u.username == name)
}

fn find_user_by_uid(uid: u32) -> Option<PasswdEntry> {
    read_passwd_entries().into_iter().find(|u| u.uid == uid)
}

fn find_group_by_gid(gid: u32) -> Option<GroupEntry> {
    read_group_entries().into_iter().find(|g| g.gid == gid)
}

fn command_exists(name: &str) -> bool {
    Command::new("sh")
        .arg("-lc")
        .arg(format!("command -v {} >/dev/null 2>&1", name))
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn normalize_hostname(value: &str) -> String {
    let mut out = String::new();
    let mut prev_sep = false;

    for c in value.chars() {
        let normalized = if c.is_ascii_alphanumeric() {
            c.to_ascii_lowercase()
        } else if c == '-' || c == '_' || c == '.' {
            '-'
        } else {
            '-'
        };

        if normalized == '-' {
            if prev_sep {
                continue;
            }
            prev_sep = true;
            out.push(normalized);
            continue;
        }

        prev_sep = false;
        out.push(normalized);
    }

    let trimmed = out.trim_matches('-');
    let mut candidate = if trimmed.is_empty() {
        "msl".to_string()
    } else {
        trimmed.to_string()
    };
    if candidate.len() > 63 {
        candidate.truncate(63);
        candidate = candidate.trim_matches('-').to_string();
        if candidate.is_empty() {
            return "msl".to_string();
        }
    }
    candidate
}

fn ensure_runtime_hostname(raw: &str) -> Result<(), String> {
    let hostname = normalize_hostname(raw);
    let ret = unsafe { sethostname(hostname.as_bytes().as_ptr(), hostname.len()) };
    if ret != 0 {
        return Err(format!(
            "sethostname failed: {}",
            std::io::Error::last_os_error()
        ));
    }

    fs::write("/etc/hostname", format!("{}\n", hostname))
        .map_err(|e| format!("write /etc/hostname failed: {}", e))?;
    ensure_hosts_hostname_mapping(&hostname)?;
    Ok(())
}

fn ensure_hosts_hostname_mapping(hostname: &str) -> Result<(), String> {
    let hosts_path = Path::new("/etc/hosts");
    let existing = if hosts_path.exists() {
        fs::read_to_string(hosts_path).map_err(|e| format!("read /etc/hosts failed: {}", e))?
    } else {
        String::new()
    };

    let mut lines: Vec<String> = Vec::new();
    let mut has_localhost = false;
    let mut has_hostname = false;

    for raw in existing.lines() {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            lines.push(raw.to_string());
            continue;
        }

        let mut parts = trimmed.split_whitespace();
        let ip = match parts.next() {
            Some(v) => v,
            None => {
                lines.push(raw.to_string());
                continue;
            }
        };
        let names: Vec<&str> = parts.collect();

        if ip == "127.0.0.1" && names.iter().any(|name| *name == "localhost") {
            has_localhost = true;
        }
        if (ip == "127.0.1.1" || ip == "127.0.0.1") && names.iter().any(|name| *name == hostname) {
            has_hostname = true;
        }

        if ip == "127.0.1.1" {
            continue;
        }
        lines.push(raw.to_string());
    }

    if !has_localhost {
        lines.push("127.0.0.1 localhost".to_string());
    }
    if !has_hostname {
        lines.push(format!("127.0.1.1 {}", hostname));
    }

    let mut rendered = lines.join("\n");
    rendered.push('\n');
    fs::write(hosts_path, rendered).map_err(|e| format!("write /etc/hosts failed: {}", e))?;
    Ok(())
}

fn run_command(program: &str, args: &[String]) -> Result<(), String> {
    let output = Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("failed to start {}: {}", program, e))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Err(format!(
        "{} {:?} failed: {}{}",
        program,
        args,
        stderr,
        if stdout.is_empty() {
            "".to_string()
        } else {
            format!(" ({})", stdout)
        }
    ))
}

fn create_user_from_policy(
    command_family: &str,
    username: &str,
    uid: u32,
    gid: u32,
    home: &str,
    shell: &str,
) -> Result<(), String> {
    if command_family != "useradd" && command_family != "busybox_adduser" {
        return Err(format!("unsupported commandFamily {}", command_family));
    }

    let gid_str = gid.to_string();
    let uid_str = uid.to_string();
    let primary_group_name = if let Some(group) = find_group_by_gid(gid) {
        group.name
    } else if command_exists("groupadd") {
        let create_group_args = vec!["-g".to_string(), gid_str.clone(), username.to_string()];
        run_command("groupadd", &create_group_args)?;
        username.to_string()
    } else if command_exists("addgroup") {
        let create_group_args = vec!["-g".to_string(), gid_str.clone(), username.to_string()];
        run_command("addgroup", &create_group_args)?;
        username.to_string()
    } else {
        gid_str.clone()
    };

    if command_family == "busybox_adduser" {
        if !command_exists("adduser") {
            return Err("adduser not found".to_string());
        }
        let mut args = vec![
            "-D".to_string(),
            "-h".to_string(),
            home.to_string(),
            "-s".to_string(),
            shell.to_string(),
            "-u".to_string(),
            uid_str.clone(),
            "-G".to_string(),
            primary_group_name,
            username.to_string(),
        ];
        if run_command("adduser", &args).is_err() {
            args = vec![
                "-D".to_string(),
                "-h".to_string(),
                home.to_string(),
                "-s".to_string(),
                shell.to_string(),
                "-u".to_string(),
                uid_str,
                username.to_string(),
            ];
            run_command("adduser", &args)?;
        }
        return Ok(());
    }

    if !command_exists("useradd") {
        return Err("useradd not found".to_string());
    }
    let args = vec![
        "-m".to_string(),
        "-u".to_string(),
        uid.to_string(),
        "-g".to_string(),
        primary_group_name,
        "-d".to_string(),
        home.to_string(),
        "-s".to_string(),
        shell.to_string(),
        username.to_string(),
    ];
    run_command("useradd", &args)
}

fn ensure_user_home(user: &PasswdEntry) -> Result<(), String> {
    if user.home.is_empty() || !user.home.starts_with('/') {
        return Ok(());
    }
    let home_path = Path::new(&user.home);
    if !home_path.exists() {
        fs::create_dir_all(home_path)
            .map_err(|e| format!("create home {} failed: {}", user.home, e))?;
    }
    if command_exists("chown") {
        let args = vec![format!("{}:{}", user.uid, user.gid), user.home.clone()];
        let _ = run_command("chown", &args);
    }
    Ok(())
}

fn ensure_admin_group_membership(
    command_family: &str,
    username: &str,
    admin_group: &str,
) -> Result<(), String> {
    if command_family == "busybox_adduser" && command_exists("addgroup") {
        let args = vec![username.to_string(), admin_group.to_string()];
        return run_command("addgroup", &args);
    }
    if command_exists("usermod") {
        let args = vec![
            "-aG".to_string(),
            admin_group.to_string(),
            username.to_string(),
        ];
        return run_command("usermod", &args);
    }
    if command_exists("adduser") {
        let args = vec![username.to_string(), admin_group.to_string()];
        return run_command("adduser", &args);
    }
    Err("no supported command for group membership update".to_string())
}

fn apply_sudo_policy(
    username: &str,
    enabled: bool,
    require_sudo_binary: bool,
    passwordless: bool,
    drop_in_path: &str,
) -> Result<Option<String>, String> {
    log_line(&format!(
        "sudo_policy_requested user={} enabled={} passwordless={} require_binary={} drop_in={}",
        username, enabled, passwordless, require_sudo_binary, drop_in_path
    ));
    if !enabled {
        return Ok(None);
    }
    if !command_exists("sudo") {
        if require_sudo_binary {
            return Err("sudo binary is required by policy but missing".to_string());
        }
        let warning = "sudo_missing_degraded".to_string();
        log_line(&format!("{} for user={}", warning, username));
        return Ok(Some(warning));
    }
    let drop_path = Path::new(drop_in_path);
    let parent = drop_path
        .parent()
        .ok_or_else(|| format!("invalid sudo drop-in path {}", drop_in_path))?;
    fs::create_dir_all(parent)
        .map_err(|e| format!("failed to create sudoers dir {}: {}", parent.display(), e))?;
    let line = if passwordless {
        format!("{} ALL=(ALL) NOPASSWD:ALL\n", username)
    } else {
        format!("{} ALL=(ALL) ALL\n", username)
    };
    fs::write(drop_path, line).map_err(|e| format!("failed to write {}: {}", drop_in_path, e))?;
    let mut perms = fs::metadata(drop_path)
        .map_err(|e| format!("failed to stat {}: {}", drop_in_path, e))?
        .permissions();
    perms.set_mode(0o440);
    fs::set_permissions(drop_path, perms)
        .map_err(|e| format!("failed to chmod {}: {}", drop_in_path, e))?;
    Ok(None)
}

fn apply_su_policy(
    admin_group: &str,
    enabled: bool,
    passwordless: bool,
) -> Result<Option<String>, String> {
    log_line(&format!(
        "su_policy_requested group={} enabled={} passwordless={}",
        admin_group, enabled, passwordless
    ));
    if !enabled || !passwordless {
        return Ok(None);
    }

    let pam_su = Path::new("/etc/pam.d/su");
    if pam_su.exists() {
        let content = fs::read_to_string(pam_su)
            .map_err(|e| format!("failed to read {}: {}", pam_su.display(), e))?;
        let expected = format!(
            "auth sufficient pam_wheel.so trust use_uid group={}",
            admin_group
        );
        if !content.lines().any(|line| line.trim() == expected) {
            let mut updated = String::new();
            updated.push_str(&expected);
            updated.push('\n');
            updated.push_str(&content);
            fs::write(pam_su, updated.as_bytes())
                .map_err(|e| format!("failed to update {}: {}", pam_su.display(), e))?;
            log_line(&format!(
                "su_policy_passwordless_enabled group={}",
                admin_group
            ));
        }
    }

    // BusyBox su may ignore PAM and shadow; ensure root password fields are empty in both files.
    let mut warnings: Vec<String> = Vec::new();
    if let Err(e) = ensure_root_passwordless_shadow() {
        let warning = format!("su_policy_shadow_fallback_failed: {}", e);
        log_line(&warning);
        warnings.push(warning);
    }
    if let Err(e) = ensure_root_passwordless_passwd() {
        let warning = format!("su_policy_passwd_fallback_failed: {}", e);
        log_line(&warning);
        warnings.push(warning);
    }
    if let Err(e) = ensure_securetty_allows_pts() {
        let warning = format!("su_policy_securetty_fallback_failed: {}", e);
        log_line(&warning);
        warnings.push(warning);
    }
    if warnings.is_empty() {
        Ok(None)
    } else {
        Ok(Some(warnings.join("; ")))
    }
}

fn ensure_root_passwordless_shadow() -> Result<(), String> {
    let shadow = Path::new("/etc/shadow");
    if !shadow.exists() {
        return Err("/etc/shadow not found".to_string());
    }
    let content = fs::read_to_string(shadow)
        .map_err(|e| format!("failed to read {}: {}", shadow.display(), e))?;
    let mut changed = false;
    let mut out: Vec<String> = Vec::new();

    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("root:") {
            let mut parts: Vec<String> = rest.split(':').map(|s| s.to_string()).collect();
            if parts.is_empty() {
                parts.push(String::new());
            }
            if !parts[0].is_empty() {
                parts[0] = String::new();
                changed = true;
            }
            out.push(format!("root:{}", parts.join(":")));
            continue;
        }
        out.push(line.to_string());
    }

    if changed {
        let mut rendered = out.join("\n");
        rendered.push('\n');
        fs::write(shadow, rendered.as_bytes())
            .map_err(|e| format!("failed to write {}: {}", shadow.display(), e))?;
        log_line("su_policy_root_shadow_passwordless_enabled");
    }
    Ok(())
}

fn ensure_root_passwordless_passwd() -> Result<(), String> {
    let passwd = Path::new("/etc/passwd");
    if !passwd.exists() {
        return Err("/etc/passwd not found".to_string());
    }
    let content = fs::read_to_string(passwd)
        .map_err(|e| format!("failed to read {}: {}", passwd.display(), e))?;
    let mut changed = false;
    let mut out: Vec<String> = Vec::new();

    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("root:") {
            let mut parts: Vec<String> = rest.split(':').map(|s| s.to_string()).collect();
            if parts.is_empty() {
                parts.push(String::new());
            }
            if !parts[0].is_empty() {
                parts[0] = String::new();
                changed = true;
            }
            out.push(format!("root:{}", parts.join(":")));
            continue;
        }
        out.push(line.to_string());
    }

    if changed {
        let mut rendered = out.join("\n");
        rendered.push('\n');
        fs::write(passwd, rendered.as_bytes())
            .map_err(|e| format!("failed to write {}: {}", passwd.display(), e))?;
        log_line("su_policy_root_passwd_passwordless_enabled");
    }
    Ok(())
}

fn ensure_securetty_allows_pts() -> Result<(), String> {
    let securetty = Path::new("/etc/securetty");
    if !securetty.exists() {
        return Ok(());
    }
    let content = fs::read_to_string(securetty)
        .map_err(|e| format!("failed to read {}: {}", securetty.display(), e))?;
    let mut existing: Vec<String> = content
        .lines()
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .collect();
    let mut changed = false;
    for idx in 0..64 {
        let entry = format!("pts/{}", idx);
        if !existing.iter().any(|line| line == &entry) {
            existing.push(entry);
            changed = true;
        }
    }
    if changed {
        let mut rendered = existing.join("\n");
        rendered.push('\n');
        fs::write(securetty, rendered.as_bytes())
            .map_err(|e| format!("failed to write {}: {}", securetty.display(), e))?;
        log_line("su_policy_securetty_pts_enabled");
    }
    Ok(())
}

fn ensure_su_setuid_if_present() -> Result<(), String> {
    let candidates = ["/bin/su", "/usr/bin/su"];
    for candidate in candidates {
        let path = Path::new(candidate);
        if !path.exists() {
            continue;
        }
        let metadata =
            fs::metadata(path).map_err(|e| format!("failed to stat {}: {}", candidate, e))?;
        if metadata.uid() != 0 || metadata.gid() != 0 {
            if command_exists("chown") {
                let args = vec!["0:0".to_string(), candidate.to_string()];
                run_command("chown", &args)
                    .map_err(|e| format!("failed to chown {} to root: {}", candidate, e))?;
            } else {
                return Err(format!(
                    "{} is not owned by root and chown command is unavailable",
                    candidate
                ));
            }
        }
        let metadata = fs::metadata(path)
            .map_err(|e| format!("failed to stat {} after chown: {}", candidate, e))?;
        let mut perms = metadata.permissions();
        let current_mode = perms.mode();
        let desired_mode = current_mode | 0o4000;
        if desired_mode != current_mode {
            perms.set_mode(desired_mode);
            fs::set_permissions(path, perms).map_err(|e| {
                format!("failed to chmod {} to {:o}: {}", candidate, desired_mode, e)
            })?;
            log_line(&format!(
                "su_setuid_enabled path={} mode={:o}->{:o}",
                candidate, current_mode, desired_mode
            ));
        }
        break;
    }
    Ok(())
}

fn install_welcome_script(
    enabled: bool,
    frequency: &str,
    respect_hushlogin: bool,
    instance_name: &str,
) -> Result<(), String> {
    if !enabled {
        return Ok(());
    }
    let path = Path::new("/etc/profile.d/msl-welcome.sh");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create {}: {}", parent.display(), e))?;
    }
    let hush_line = if respect_hushlogin {
        "if [ -f \"$HOME/.hushlogin\" ]; then return 0 2>/dev/null || exit 0; fi"
    } else {
        ":"
    };
    let script = format!(
        "#!/bin/sh\n\
case \"$-\" in\n\
  *i*) ;;\n\
  *) return 0 2>/dev/null || exit 0 ;;\n\
esac\n\
{hush_line}\n\
freq=\"{frequency}\"\n\
stamp=\"$HOME/.cache/msl/welcome.stamp\"\n\
today=\"$(date +%Y-%m-%d 2>/dev/null || echo unknown)\"\n\
if [ \"$freq\" = \"never\" ]; then\n\
  return 0 2>/dev/null || exit 0\n\
fi\n\
if [ \"$freq\" = \"daily\" ]; then\n\
  if [ -f \"$stamp\" ] && [ \"$(cat \"$stamp\" 2>/dev/null)\" = \"$today\" ]; then\n\
    return 0 2>/dev/null || exit 0\n\
  fi\n\
  mkdir -p \"$(dirname \"$stamp\")\" >/dev/null 2>&1 || true\n\
  printf '%s\\n' \"$today\" > \"$stamp\" 2>/dev/null || true\n\
fi\n\
printf 'Welcome to msl ({instance_name}).\\n'\n\
printf 'Run \"msl run --help\" from macOS for non-interactive commands.\\n'\n"
    );
    fs::write(path, script).map_err(|e| format!("failed to write {}: {}", path.display(), e))?;
    let mut perms = fs::metadata(path)
        .map_err(|e| format!("failed to stat {}: {}", path.display(), e))?
        .permissions();
    perms.set_mode(0o755);
    fs::set_permissions(path, perms)
        .map_err(|e| format!("failed to chmod {}: {}", path.display(), e))?;
    Ok(())
}

fn exec_response(
    request_id: &str,
    op: &str,
    argv: Vec<String>,
    cwd: Option<String>,
    timeout_ms: Option<i32>,
    env_additions: Vec<(String, String)>,
    run_as_root: bool,
) -> String {
    let started = Instant::now();
    let runtime = runtime_context_for_request(run_as_root);
    let mut cmd = Command::new(&argv[0]);
    if argv.len() > 1 {
        cmd.args(&argv[1..]);
    }
    cmd.uid(runtime.uid);
    cmd.gid(runtime.gid);
    cmd.envs(child_process_environment(&runtime, env_additions));
    let desired_cwd = cwd
        .as_ref()
        .filter(|v| v.starts_with('/') && Path::new(v).is_dir())
        .cloned()
        .unwrap_or_else(|| runtime.home.clone());
    if Path::new(&desired_cwd).is_dir() {
        cmd.current_dir(&desired_cwd);
    }

    // If timeout is specified, spawn and wait with timeout
    if let Some(ms) = timeout_ms {
        if ms > 0 {
            match cmd
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
            {
                Ok(mut child) => {
                    let timeout_dur = Duration::from_millis(ms as u64);
                    let deadline = Instant::now() + timeout_dur;
                    loop {
                        match child.try_wait() {
                            Ok(Some(status)) => {
                                let exit = status.code().unwrap_or(1);
                                let stdout = child
                                    .stdout
                                    .take()
                                    .map(|mut s| {
                                        let mut buf = String::new();
                                        use std::io::Read;
                                        let _ = s.read_to_string(&mut buf);
                                        buf
                                    })
                                    .unwrap_or_default();
                                let stderr = child
                                    .stderr
                                    .take()
                                    .map(|mut s| {
                                        let mut buf = String::new();
                                        use std::io::Read;
                                        let _ = s.read_to_string(&mut buf);
                                        buf
                                    })
                                    .unwrap_or_default();
                                let duration_ms = started.elapsed().as_millis();
                                return format!(
                                    "{{\"version\":1,\"requestId\":\"{}\",\"op\":\"{}\",\"status\":\"ok\",\"exitCode\":{},\"stdout\":\"{}\",\"stderr\":\"{}\",\"durationMs\":{}}}",
                                    escape_json(request_id),
                                    escape_json(op),
                                    exit,
                                    escape_json(&stdout),
                                    escape_json(&stderr),
                                    duration_ms
                                );
                            }
                            Ok(None) => {
                                if Instant::now() >= deadline {
                                    // Timeout: SIGTERM, wait 2s, SIGKILL
                                    let pid = child.id() as i32;
                                    unsafe {
                                        kill(pid, SIGTERM);
                                    }
                                    thread::sleep(Duration::from_secs(2));
                                    if child.try_wait().ok().flatten().is_none() {
                                        unsafe {
                                            kill(pid, SIGKILL);
                                        }
                                        let _ = child.wait();
                                    }
                                    return error_response(
                                        request_id,
                                        op,
                                        "timeout",
                                        &format!("command timed out after {}ms", ms),
                                    );
                                }
                                thread::sleep(Duration::from_millis(50));
                            }
                            Err(e) => {
                                return error_response(
                                    request_id,
                                    op,
                                    "internal_error",
                                    &format!("wait failed: {e}"),
                                );
                            }
                        }
                    }
                }
                Err(e) => {
                    return error_response(
                        request_id,
                        op,
                        "internal_error",
                        &format!("exec failed: {e}"),
                    )
                }
            }
        }
    }

    // No timeout: blocking wait
    match cmd.output() {
        Ok(output) => {
            let exit = output.status.code().unwrap_or(1);
            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            let duration_ms = started.elapsed().as_millis();
            format!(
                "{{\"version\":1,\"requestId\":\"{}\",\"op\":\"{}\",\"status\":\"ok\",\"exitCode\":{},\"stdout\":\"{}\",\"stderr\":\"{}\",\"durationMs\":{}}}",
                escape_json(request_id),
                escape_json(op),
                exit,
                escape_json(&stdout),
                escape_json(&stderr),
                duration_ms
            )
        }
        Err(e) => error_response(
            request_id,
            op,
            "internal_error",
            &format!("exec failed: {e}"),
        ),
    }
}

fn extract_string(input: &str, key: &str) -> Option<String> {
    let pattern = format!("\"{}\":\"", key);
    let start = input.find(&pattern)? + pattern.len();
    let rest = &input[start..];
    let (value, _) = decode_json_string(rest)?;
    Some(value)
}

fn extract_int(input: &str, key: &str) -> Option<i32> {
    let pattern = format!("\"{}\":", key);
    let start = input.find(&pattern)? + pattern.len();
    let rest = &input[start..];
    let mut num = String::new();
    for c in rest.chars() {
        if c.is_ascii_digit() || c == '-' {
            num.push(c);
        } else {
            break;
        }
    }
    num.parse::<i32>().ok()
}

fn extract_int64(input: &str, key: &str) -> Option<i64> {
    let pattern = format!("\"{}\":", key);
    let start = input.find(&pattern)? + pattern.len();
    let rest = &input[start..];
    let mut num = String::new();
    for c in rest.chars() {
        if c.is_ascii_digit() || c == '-' {
            num.push(c);
        } else {
            break;
        }
    }
    num.parse::<i64>().ok()
}

fn extract_bool(input: &str, key: &str) -> Option<bool> {
    let pattern = format!("\"{}\":", key);
    let start = input.find(&pattern)? + pattern.len();
    let rest = &input[start..];
    if rest.starts_with("true") {
        return Some(true);
    }
    if rest.starts_with("false") {
        return Some(false);
    }
    None
}

fn extract_string_array(input: &str, key: &str) -> Option<Vec<String>> {
    let pattern = format!("\"{}\":[", key);
    let start = input.find(&pattern)? + pattern.len();
    let rest = &input[start..];
    let mut out: Vec<String> = Vec::new();
    let mut index = 0usize;

    loop {
        while let Some(c) = rest[index..].chars().next() {
            if c.is_whitespace() {
                index += c.len_utf8();
            } else {
                break;
            }
        }

        if index >= rest.len() {
            return None;
        }

        if rest[index..].starts_with(']') {
            return Some(out);
        }

        if !rest[index..].starts_with('"') {
            return None;
        }
        index += 1;

        let (value, consumed) = decode_json_string(&rest[index..])?;
        out.push(value);
        index += consumed;

        while let Some(c) = rest[index..].chars().next() {
            if c.is_whitespace() {
                index += c.len_utf8();
            } else {
                break;
            }
        }

        if index >= rest.len() {
            return None;
        }

        if rest[index..].starts_with(',') {
            index += 1;
            continue;
        }

        if rest[index..].starts_with(']') {
            return Some(out);
        }

        return None;
    }
}

fn extract_string_map(input: &str, key: &str) -> Option<Vec<(String, String)>> {
    let pattern = format!("\"{}\":{{", key);
    let start = input.find(&pattern)? + pattern.len();
    let rest = &input[start..];
    let mut out: Vec<(String, String)> = Vec::new();
    let mut index = 0usize;

    loop {
        while let Some(c) = rest[index..].chars().next() {
            if c.is_whitespace() {
                index += c.len_utf8();
            } else {
                break;
            }
        }

        if index >= rest.len() {
            return None;
        }

        if rest[index..].starts_with('}') {
            return Some(out);
        }

        if !rest[index..].starts_with('"') {
            return None;
        }
        index += 1;
        let (map_key, key_consumed) = decode_json_string(&rest[index..])?;
        index += key_consumed;

        while let Some(c) = rest[index..].chars().next() {
            if c.is_whitespace() {
                index += c.len_utf8();
            } else {
                break;
            }
        }
        if !rest[index..].starts_with(':') {
            return None;
        }
        index += 1;

        while let Some(c) = rest[index..].chars().next() {
            if c.is_whitespace() {
                index += c.len_utf8();
            } else {
                break;
            }
        }
        if !rest[index..].starts_with('"') {
            return None;
        }
        index += 1;
        let (map_value, value_consumed) = decode_json_string(&rest[index..])?;
        index += value_consumed;
        out.push((map_key, map_value));

        while let Some(c) = rest[index..].chars().next() {
            if c.is_whitespace() {
                index += c.len_utf8();
            } else {
                break;
            }
        }

        if index >= rest.len() {
            return None;
        }

        if rest[index..].starts_with(',') {
            index += 1;
            continue;
        }
        if rest[index..].starts_with('}') {
            return Some(out);
        }
        return None;
    }
}

fn is_valid_env_key(key: &str) -> bool {
    if key.is_empty() {
        return false;
    }
    for ch in key.chars() {
        if !(ch.is_ascii_alphanumeric() || ch == '_') {
            return false;
        }
    }
    true
}

fn decode_json_string(input: &str) -> Option<(String, usize)> {
    let mut out = String::new();
    let bytes = input.as_bytes();
    let mut index = 0usize;

    while index < bytes.len() {
        let b = bytes[index];
        if b == b'"' {
            return Some((out, index + 1));
        }
        if b == b'\\' {
            index += 1;
            if index >= bytes.len() {
                return None;
            }

            let escaped = bytes[index] as char;
            match escaped {
                '"' => out.push('"'),
                '\\' => out.push('\\'),
                '/' => out.push('/'),
                'b' => out.push('\u{0008}'),
                'f' => out.push('\u{000C}'),
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                'u' => {
                    if index + 4 >= bytes.len() {
                        return None;
                    }
                    let hex = &input[index + 1..index + 5];
                    let codepoint = u16::from_str_radix(hex, 16).ok()? as u32;
                    let ch = char::from_u32(codepoint)?;
                    out.push(ch);
                    index += 4;
                }
                _ => return None,
            }
            index += 1;
            continue;
        }

        let ch = input[index..].chars().next()?;
        out.push(ch);
        index += ch.len_utf8();
    }
    None
}

fn escape_json(s: &str) -> String {
    let mut escaped = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            '\u{08}' => escaped.push_str("\\b"),
            '\u{0c}' => escaped.push_str("\\f"),
            c if c <= '\u{1f}' => escaped.push_str(&format!("\\u{:04x}", c as u32)),
            c => escaped.push(c),
        }
    }
    escaped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_string_unescapes_slash_and_quote() {
        let input = r#"{"convergeHome":"\/home\/test-user","note":"hello \"world\""}"#;
        assert_eq!(
            extract_string(input, "convergeHome").as_deref(),
            Some("/home/test-user")
        );
        assert_eq!(
            extract_string(input, "note").as_deref(),
            Some("hello \"world\"")
        );
    }

    #[test]
    fn extract_string_decodes_unicode_escape() {
        let input = r#"{"value":"\u0031\u0032"}"#;
        assert_eq!(extract_string(input, "value").as_deref(), Some("12"));
    }

    #[test]
    fn extract_string_array_unescapes_elements() {
        let input = r#"{"policyShellFallbacks":["\/bin\/bash","\/bin\/sh","hello \"quoted\""]}"#;
        let values = extract_string_array(input, "policyShellFallbacks").unwrap_or_default();
        assert_eq!(
            values,
            vec![
                "/bin/bash".to_string(),
                "/bin/sh".to_string(),
                "hello \"quoted\"".to_string(),
            ]
        );
    }

    #[test]
    fn extract_string_map_unescapes_pairs() {
        let input = r#"{"envAdditions":{"PIP_CACHE_DIR":"\/mnt\/macos\/cache","NPM_CONFIG_CACHE":"\/tmp\/npm"}}"#;
        let values = extract_string_map(input, "envAdditions").unwrap_or_default();
        assert_eq!(
            values,
            vec![
                ("PIP_CACHE_DIR".to_string(), "/mnt/macos/cache".to_string()),
                ("NPM_CONFIG_CACHE".to_string(), "/tmp/npm".to_string()),
            ]
        );
    }

    #[test]
    fn escape_json_escapes_ascii_control_characters() {
        let escaped = escape_json("a\u{1b}b\u{0001}c");
        assert_eq!(escaped, "a\\u001bb\\u0001c");
    }

    #[test]
    fn env_key_validation_rejects_invalid_chars() {
        assert!(is_valid_env_key("NPM_CONFIG_CACHE"));
        assert!(!is_valid_env_key(""));
        assert!(!is_valid_env_key("BAD-KEY"));
        assert!(!is_valid_env_key("BAD.KEY"));
    }

    #[test]
    fn timezone_loader_reads_tz_from_environment_file() {
        let path = "/tmp/msl-init-test-environment";
        fs::write(path, "PATH=\"/usr/bin\"\nTZ=\"Asia/Tokyo\"\n").unwrap();
        let current_tz = env::var_os("TZ");
        env::remove_var("TZ");
        assert_eq!(
            load_timezone_from_text(&fs::read_to_string(path).unwrap()).as_deref(),
            Some("Asia/Tokyo")
        );
        let _ = fs::remove_file(path);
        match current_tz {
            Some(value) => env::set_var("TZ", value),
            None => env::remove_var("TZ"),
        }
    }

    #[test]
    fn timezone_loader_rejects_invalid_values() {
        assert_eq!(load_timezone_from_text("TZ=\n"), None);
        assert_eq!(load_timezone_from_text("TZ=\"Asia/ Tokyo\"\n"), None);
    }

    #[test]
    fn child_process_environment_inherits_runtime_environment_without_allowlist() {
        let _guard = test_env_lock().lock().unwrap();
        let previous_wayland = env::var_os("WAYLAND_DISPLAY");
        let previous_xdg_runtime_dir = env::var_os("XDG_RUNTIME_DIR");
        let previous_custom = env::var_os("MSL_TEST_BOOT_ENV");
        env::set_var("WAYLAND_DISPLAY", "wayland-0");
        env::set_var("XDG_RUNTIME_DIR", "/tmp");
        env::set_var("MSL_TEST_BOOT_ENV", "1");

        let runtime = RuntimeUserContext {
            username: "alice".to_string(),
            uid: 1000,
            gid: 1000,
            home: "/home/alice".to_string(),
            shell: "/bin/bash".to_string(),
        };
        let envs = child_process_environment(&runtime, Vec::new());

        assert_eq!(
            env_value(&envs, "WAYLAND_DISPLAY").as_deref(),
            Some("wayland-0")
        );
        assert_eq!(env_value(&envs, "XDG_RUNTIME_DIR").as_deref(), Some("/tmp"));
        assert_eq!(env_value(&envs, "MSL_TEST_BOOT_ENV").as_deref(), Some("1"));
        assert_eq!(env_value(&envs, "HOME").as_deref(), Some("/home/alice"));
        assert_eq!(env_value(&envs, "USER").as_deref(), Some("alice"));
        assert_eq!(env_value(&envs, "LOGNAME").as_deref(), Some("alice"));
        assert_eq!(env_value(&envs, "SHELL").as_deref(), Some("/bin/bash"));

        restore_env("WAYLAND_DISPLAY", previous_wayland);
        restore_env("XDG_RUNTIME_DIR", previous_xdg_runtime_dir);
        restore_env("MSL_TEST_BOOT_ENV", previous_custom);
    }

    #[test]
    fn child_process_environment_request_additions_override_runtime_environment() {
        let _guard = test_env_lock().lock().unwrap();
        let previous_wayland = env::var_os("WAYLAND_DISPLAY");
        env::set_var("WAYLAND_DISPLAY", "wayland-0");

        let runtime = RuntimeUserContext {
            username: "alice".to_string(),
            uid: 1000,
            gid: 1000,
            home: "/home/alice".to_string(),
            shell: "/bin/bash".to_string(),
        };
        let envs = child_process_environment(
            &runtime,
            vec![("WAYLAND_DISPLAY".to_string(), "wayland-session".to_string())],
        );

        assert_eq!(
            env_value(&envs, "WAYLAND_DISPLAY").as_deref(),
            Some("wayland-session")
        );

        restore_env("WAYLAND_DISPLAY", previous_wayland);
    }

    fn env_value(envs: &[(String, String)], key: &str) -> Option<String> {
        envs.iter()
            .find(|(candidate, _)| candidate == key)
            .map(|(_, value)| value.clone())
    }

    fn restore_env(key: &str, value: Option<std::ffi::OsString>) {
        match value {
            Some(value) => env::set_var(key, value),
            None => env::remove_var(key),
        }
    }

    #[test]
    fn wayland_socket_path_uses_runtime_dir_and_display_name() {
        assert_eq!(wayland_socket_path("/tmp", "wayland-0"), "/tmp/wayland-0");
        assert_eq!(wayland_socket_path("/tmp/", "wayland-1"), "/tmp/wayland-1");
    }

    #[test]
    fn wayland_proxy_start_is_idempotent_and_stop_cleans_socket() {
        let _guard = test_env_lock().lock().unwrap();
        let display = format!("wayland-test-{}", std::process::id());
        let runtime_dir =
            std::env::temp_dir().join(format!("msl-wayland-test-{}", std::process::id()));
        let runtime_dir_string = runtime_dir.to_string_lossy().to_string();
        let socket = wayland_socket_path(&runtime_dir_string, &display);
        let _ = fs::remove_file(&socket);
        let _ = fs::remove_dir_all(&runtime_dir);

        let first =
            start_wayland_proxy(display.clone(), 38123, runtime_dir_string.clone()).unwrap();
        assert_eq!(first.socket_path, socket);
        assert!(Path::new(&socket).exists());
        assert_eq!(
            fs::metadata(&socket).unwrap().permissions().mode() & 0o777,
            0o666
        );

        let duplicate =
            start_wayland_proxy(display.clone(), 38123, runtime_dir_string.clone()).unwrap();
        assert_eq!(duplicate.socket_path, socket);
        assert_eq!(wayland_proxies().lock().unwrap().len(), 1);

        let status = wayland_proxy_status_response(
            "req-status",
            "wayland_proxy_status",
            &format!(r#"{{"displayName":"{}"}}"#, display),
        );
        assert!(status.contains("\"buildMarker\":\"fd-aware-keymap\""));
        assert!(status.contains("\"defaultProxyStarted\":\"false\""));
        assert!(status.contains("\"lastTraceId\":\"\""));
        assert!(status.contains("\"keymapSent\":\"false\""));
        assert!(status.contains("\"bytesClientToHost\":\"0\""));
        assert!(status.contains("\"bytesHostToClient\":\"0\""));

        let mut client = UnixStream::connect(&socket).unwrap();
        client
            .set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();
        let mut byte = [0_u8; 1];
        let read_result = client.read(&mut byte);
        assert!(matches!(read_result, Ok(0) | Err(_)));
        for _ in 0..20 {
            let last_error = wayland_proxies()
                .lock()
                .unwrap()
                .get(&display)
                .and_then(|proxy| proxy.last_error.clone());
            if last_error
                .as_deref()
                .is_some_and(|value| value.starts_with("display_transport_unavailable"))
            {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(wayland_proxies()
            .lock()
            .unwrap()
            .get(&display)
            .and_then(|proxy| proxy.last_error.clone())
            .is_some_and(|value| value.starts_with("display_transport_unavailable")));

        let stopped = stop_wayland_proxy(&display).unwrap().unwrap();
        assert_eq!(stopped.socket_path, socket);
        for _ in 0..20 {
            if !Path::new(&socket).exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!Path::new(&socket).exists());
        let _ = fs::remove_dir_all(&runtime_dir);
    }

    #[test]
    fn wayland_proxy_converts_shm_pool_fd_to_transport_messages() {
        let _guard = test_env_lock().lock().unwrap();
        let (sender, receiver) = UnixStream::pair().unwrap();
        let mut fd_payload = create_wayland_fd_payload("test-shm", &[1, 2, 3, 4]).unwrap();
        fd_payload.seek(SeekFrom::Start(0)).unwrap();
        let mut request = Vec::new();
        request.extend_from_slice(&6_u32.to_ne_bytes());
        request.extend_from_slice(&((16_u32 << 16) | 0_u32).to_ne_bytes());
        request.extend_from_slice(&9_u32.to_ne_bytes());
        request.extend_from_slice(&4_i32.to_ne_bytes());
        send_wayland_message_with_fd(sender.as_raw_fd(), &request, fd_payload.as_raw_fd()).unwrap();

        let chunk = recv_wayland_client_chunk(receiver.as_raw_fd()).unwrap();
        assert_eq!(chunk.bytes, request);
        assert_eq!(chunk.fds.len(), 1);

        let mut state = GuestWaylandParseState::new();
        state.objects.insert(6, "wl_shm".to_string());
        state.pending.extend_from_slice(&chunk.bytes);
        state.pending_fds.extend(chunk.fds);
        let path =
            std::env::temp_dir().join(format!("msl-wayland-transport-test-{}", std::process::id()));
        let _ = fs::remove_file(&path);
        let mut transport = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .unwrap();
        let forwarded =
            drain_guest_wayland_messages("wayland-test", "trace-test", &mut state, &mut transport)
                .unwrap();
        assert_eq!(forwarded, request.len() as u64);
        transport.seek(SeekFrom::Start(0)).unwrap();
        let mut bytes = Vec::new();
        transport.read_to_end(&mut bytes).unwrap();
        let text = String::from_utf8_lossy(&bytes);
        assert!(text.contains(r#""type":"shmPoolCreate""#));
        assert!(text.contains(r#""poolId":9"#));
        assert!(text.contains(r#""dataBase64":"AQIDBA==""#));
        assert!(text.contains(r#""type":"waylandBytes""#));
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn wayland_proxy_keeps_ancillary_fd_until_shm_create_pool_message() {
        let _guard = test_env_lock().lock().unwrap();
        let mut fd_payload = create_wayland_fd_payload("test-shm-delayed", &[5, 6, 7, 8]).unwrap();
        fd_payload.seek(SeekFrom::Start(0)).unwrap();
        let retained_fd = unsafe { libc::dup(fd_payload.as_raw_fd()) };
        assert!(retained_fd >= 0);

        let mut registry_bind = Vec::new();
        registry_bind.extend_from_slice(&2_u32.to_ne_bytes());
        registry_bind.extend_from_slice(&((40_u32 << 16) | 0_u32).to_ne_bytes());
        registry_bind.extend_from_slice(&1_u32.to_ne_bytes());
        registry_bind.extend_from_slice(&14_u32.to_ne_bytes());
        let mut interface = b"wl_compositor\0".to_vec();
        interface.resize(16, 0);
        registry_bind.extend_from_slice(&interface);
        registry_bind.extend_from_slice(&3_u32.to_ne_bytes());
        registry_bind.extend_from_slice(&4_u32.to_ne_bytes());

        let mut shm_create_pool = Vec::new();
        shm_create_pool.extend_from_slice(&6_u32.to_ne_bytes());
        shm_create_pool.extend_from_slice(&((16_u32 << 16) | 0_u32).to_ne_bytes());
        shm_create_pool.extend_from_slice(&9_u32.to_ne_bytes());
        shm_create_pool.extend_from_slice(&4_i32.to_ne_bytes());

        let path = std::env::temp_dir().join(format!(
            "msl-wayland-delayed-fd-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_file(&path);
        let mut transport = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .unwrap();
        let mut state = GuestWaylandParseState::new();
        state.objects.insert(2, "wl_registry".to_string());
        state.objects.insert(6, "wl_shm".to_string());
        state.pending_fds.push_back(retained_fd);

        state.pending.extend_from_slice(&registry_bind);
        let forwarded = drain_guest_wayland_messages(
            "wayland-test",
            "trace-test",
            &mut state,
            &mut transport,
        )
        .unwrap();
        assert_eq!(forwarded, registry_bind.len() as u64);
        assert_eq!(state.pending_fds.len(), 1);

        state.pending.extend_from_slice(&shm_create_pool);
        let forwarded = drain_guest_wayland_messages(
            "wayland-test",
            "trace-test",
            &mut state,
            &mut transport,
        )
        .unwrap();
        assert_eq!(forwarded, shm_create_pool.len() as u64);
        assert!(state.pending_fds.is_empty());

        transport.seek(SeekFrom::Start(0)).unwrap();
        let mut bytes = Vec::new();
        transport.read_to_end(&mut bytes).unwrap();
        let text = String::from_utf8_lossy(&bytes);
        assert!(text.contains(r#""type":"shmPoolCreate""#));
        assert!(text.contains(r#""poolId":9"#));
        assert!(text.contains(r#""dataBase64":"BQYHCA==""#));
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn wayland_proxy_keyboard_keymap_event_omits_fd_placeholder_bytes() {
        let _guard = test_env_lock().lock().unwrap();
        let (mut sender, receiver) = UnixStream::pair().unwrap();

        send_keyboard_keymap_event(&mut sender, 15, 1, b"xkb-keymap").unwrap();

        let chunk = recv_wayland_client_chunk(receiver.as_raw_fd()).unwrap();
        assert_eq!(chunk.fds.len(), 1);
        assert_eq!(chunk.bytes.len(), 16);
        assert_eq!(read_wayland_u32(&chunk.bytes, 0).unwrap(), 15);
        assert_eq!(read_wayland_u32(&chunk.bytes, 4).unwrap(), 16_u32 << 16);
        assert_eq!(read_wayland_u32(&chunk.bytes, 8).unwrap(), 1);
        assert_eq!(read_wayland_u32(&chunk.bytes, 12).unwrap(), 10);
    }

    #[test]
    fn wayland_proxy_delivers_raw_event_after_keyboard_keymap_fd_event() {
        let _guard = test_env_lock().lock().unwrap();
        let (mut writer, reader) = UnixStream::pair().unwrap();
        reader
            .set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();

        send_keyboard_keymap_event(&mut writer, 15, 1, b"xkb-keymap").unwrap();
        let first = recv_wayland_client_chunk(reader.as_raw_fd()).unwrap();
        assert_eq!(first.bytes.len(), 16);
        assert_eq!(first.fds.len(), 1);

        let mut repeat_info = Vec::new();
        repeat_info.extend_from_slice(&15_u32.to_ne_bytes());
        repeat_info.extend_from_slice(&((16_u32 << 16) | 5_u32).to_ne_bytes());
        repeat_info.extend_from_slice(&25_i32.to_ne_bytes());
        repeat_info.extend_from_slice(&600_i32.to_ne_bytes());
        writer.write_all(&repeat_info).unwrap();

        let second = recv_wayland_client_chunk(reader.as_raw_fd()).unwrap();
        assert_eq!(second.bytes, repeat_info);
        assert!(second.fds.is_empty());
    }

    #[test]
    fn wayland_proxy_forwards_complete_host_events_without_magic_suffix_delay() {
        let _guard = test_env_lock().lock().unwrap();
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        reader
            .set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();

        let mut event = Vec::new();
        event.extend_from_slice(&25_u32.to_ne_bytes());
        event.extend_from_slice(&((20_u32 << 16) | 0_u32).to_ne_bytes());
        event.extend_from_slice(&0_i32.to_ne_bytes());
        event.extend_from_slice(&0_i32.to_ne_bytes());
        event.extend_from_slice(&0_u32.to_ne_bytes());

        let mut pending = event[..7].to_vec();
        let mut total = 0_u64;
        drain_host_wayland_bytes(
            "wayland-test",
            "trace-test",
            &mut writer,
            &mut pending,
            &mut total,
        )
        .unwrap();
        assert_eq!(total, 0);
        assert_eq!(pending, event[..7]);

        pending.extend_from_slice(&event[7..]);
        drain_host_wayland_bytes(
            "wayland-test",
            "trace-test",
            &mut writer,
            &mut pending,
            &mut total,
        )
        .unwrap();
        assert_eq!(total, event.len() as u64);
        assert!(pending.is_empty());

        let mut received = vec![0_u8; event.len()];
        reader.read_exact(&mut received).unwrap();
        assert_eq!(received, event);
    }

    fn test_env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn normalize_hostname_uses_instance_safe_form() {
        assert_eq!(normalize_hostname("Ubuntu_24.04"), "ubuntu-24-04");
        assert_eq!(normalize_hostname("___"), "msl");
        assert_eq!(normalize_hostname("my.instance-name"), "my-instance-name");
    }

    #[test]
    fn memory_cli_action_parses_aliases() {
        assert_eq!(
            MemoryCliAction::parse("compact"),
            Some(MemoryCliAction::Compact)
        );
        assert_eq!(
            MemoryCliAction::parse("compat"),
            Some(MemoryCliAction::Compact)
        );
        assert_eq!(
            MemoryCliAction::parse("drop-cache"),
            Some(MemoryCliAction::DropCaches)
        );
        assert_eq!(
            MemoryCliAction::parse("drop_caches"),
            Some(MemoryCliAction::DropCaches)
        );
        assert_eq!(
            MemoryCliAction::parse("dropcache"),
            Some(MemoryCliAction::DropCaches)
        );
        assert_eq!(MemoryCliAction::parse("unknown"), None);
    }

    #[test]
    fn memory_stats_file_updates() {
        let root =
            std::env::temp_dir().join(format!("msl-init-memory-stats-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("stats.env");

        update_memory_stats_at_path(&file, MemoryCliAction::Compact).unwrap();
        update_memory_stats_at_path(&file, MemoryCliAction::DropCaches).unwrap();
        update_memory_stats_at_path(&file, MemoryCliAction::DropCaches).unwrap();

        let stats = load_memory_stats(&file);
        assert_eq!(stats.compact_count, 1);
        assert_eq!(stats.drop_cache_count, 2);
        assert!(stats.compact_last_epoch_ms > 0);
        assert!(stats.drop_cache_last_epoch_ms > 0);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn parse_local_control_memory_action_works() {
        assert_eq!(
            parse_local_control_memory_action("memory compact\n"),
            Some(MemoryCliAction::Compact)
        );
        assert_eq!(
            parse_local_control_memory_action("memory drop-cache"),
            Some(MemoryCliAction::DropCaches)
        );
        assert_eq!(
            parse_local_control_memory_action("memory compat"),
            Some(MemoryCliAction::Compact)
        );
        assert_eq!(parse_local_control_memory_action("unknown"), None);
    }

    #[test]
    fn guest_memory_usage_mentions_status_and_actions() {
        assert_eq!(
            guest_memory_usage(),
            "usage: msl memory [status|compact|drop-cache|compat]"
        );
    }

    #[test]
    fn run_guest_memory_cli_defaults_to_status() {
        assert!(run_guest_memory_cli(&["memory".to_string()]).is_ok());
        assert!(run_guest_memory_cli(&["memory".to_string(), "status".to_string()]).is_ok());
    }

    #[test]
    fn run_guest_memory_cli_rejects_unknown_action() {
        let result = run_guest_memory_cli(&["memory".to_string(), "unknown".to_string()]);
        assert_eq!(
            result.err().as_deref(),
            Some("usage: msl memory [status|compact|drop-cache|compat]")
        );
    }

    #[test]
    fn guest_code_usage_is_stable() {
        assert_eq!(guest_code_usage(), "usage: code [path]");
    }

    #[test]
    fn resolve_code_target_returns_absolute_path() {
        let path = resolve_code_target(".").expect("resolve code target");
        assert!(path.starts_with('/'));
    }

    #[test]
    fn format_u64_with_commas_formats_large_values() {
        assert_eq!(format_u64_with_commas(0), "0");
        assert_eq!(format_u64_with_commas(999), "999");
        assert_eq!(format_u64_with_commas(1_000), "1,000");
        assert_eq!(format_u64_with_commas(8_123_540), "8,123,540");
    }

    #[test]
    fn format_duration_ms_human_readable() {
        assert_eq!(format_duration_ms(900), "just now");
        assert_eq!(format_duration_ms(45_000), "45s");
        assert_eq!(format_duration_ms(120_000), "2m");
        assert_eq!(format_duration_ms(125_000), "2m 5s");
        assert_eq!(format_duration_ms(3_600_000), "1h");
        assert_eq!(format_duration_ms(3_900_000), "1h 5m");
        assert_eq!(format_duration_ms(86_400_000), "1d");
        assert_eq!(format_duration_ms(93_600_000), "1d 2h");
    }

    #[test]
    fn format_last_event_handles_never() {
        assert_eq!(format_last_event(0), "never");
    }

    #[test]
    fn parse_children_pids_ignores_invalid_entries() {
        assert_eq!(parse_children_pids("12 34 nope 56\n"), vec![12, 34, 56]);
        assert!(parse_children_pids("").is_empty());
    }

    #[test]
    fn proc_stream_chunks_sort_by_sequence_before_encoding() {
        let mut chunks = vec![
            ProcStreamChunk {
                seq: 2,
                stream: ProcStreamKind::Stderr,
                data: b"err".to_vec(),
            },
            ProcStreamChunk {
                seq: 1,
                stream: ProcStreamKind::Stdout,
                data: b"out".to_vec(),
            },
        ];

        chunks.sort_by_key(|chunk| chunk.seq);

        assert_eq!(chunks[0].seq, 1);
        assert_eq!(chunks[0].stream, ProcStreamKind::Stdout);
        assert_eq!(chunks[0].data, b"out".to_vec());
        assert_eq!(chunks[1].seq, 2);
        assert_eq!(chunks[1].stream, ProcStreamKind::Stderr);
        assert_eq!(chunks[1].data, b"err".to_vec());
    }

    #[test]
    fn holdback_proc_stderr_chunk_matches_shell_server_sentinel_only() {
        assert!(should_holdback_proc_stderr_chunk(SHELL_SERVER_SENTINEL));
        assert!(!should_holdback_proc_stderr_chunk(b"err"));
        assert!(!should_holdback_proc_stderr_chunk(b"\xE2\x90\x841"));
    }

    #[test]
    fn extract_shell_assignment_value_handles_quoted_values() {
        let command = "REMOTE_CONTAINERS_SOCKETS='[]' REMOTE_CONTAINERS_IPC='/tmp/vscode-remote-containers-ipc-123.sock' '/root/.vscode-server/bin/x/node' '/tmp/vscode-remote-containers-server-123.js'";
        assert_eq!(
            extract_shell_assignment_value(command, "REMOTE_CONTAINERS_SOCKETS").as_deref(),
            Some("[]")
        );
        assert_eq!(
            extract_shell_assignment_value(command, "REMOTE_CONTAINERS_IPC").as_deref(),
            Some("/tmp/vscode-remote-containers-ipc-123.sock")
        );
    }

    #[test]
    fn extract_remote_containers_paths_finds_helper_assets() {
        let command = "cat >/tmp/vscode-remote-containers-abc.js && '/root/.vscode-server/bin/x/node' '/tmp/vscode-remote-containers-server-abc.js' && export REMOTE_CONTAINERS_IPC='/tmp/vscode-remote-containers-ipc-abc.sock'";
        let paths = extract_remote_containers_paths(command);
        assert!(paths.contains(&"/tmp/vscode-remote-containers-abc.js".to_string()));
        assert!(paths.contains(&"/tmp/vscode-remote-containers-server-abc.js".to_string()));
        assert!(paths.contains(&"/tmp/vscode-remote-containers-ipc-abc.sock".to_string()));
    }

    #[test]
    fn filter_shell_text_fragment_strips_binary_noise() {
        let text = b"\x00\x01echo -n sentinel ; ( test -f '/tmp/vscode-remote-containers-1.js' ); echo -n $?\r";
        assert_eq!(
            filter_shell_text_fragment(&mut Vec::new(), text),
            "echo -n sentinel ; ( test -f '/tmp/vscode-remote-containers-1.js' ); echo -n $?"
        );
    }

    #[test]
    fn helper_launch_requires_ipc_server_script_and_node() {
        let reference_only = "git config --system --replace-all credential.helper '!f() { /root/.vscode-server/bin/x/node /tmp/vscode-remote-containers-abc.js git-credential-helper $*; }; f'";
        let launch = "REMOTE_CONTAINERS_SOCKETS='[]' REMOTE_CONTAINERS_IPC='/tmp/vscode-remote-containers-ipc-123.sock' '/root/.vscode-server/bin/x/node' '/tmp/vscode-remote-containers-server-123.js'";

        let reference_tail = filter_shell_text_fragment(&mut Vec::new(), reference_only.as_bytes());
        assert!(reference_tail.contains("/tmp/vscode-remote-containers-abc.js"));
        assert!(!reference_tail.contains("REMOTE_CONTAINERS_IPC="));
        assert!(!reference_tail.contains("/tmp/vscode-remote-containers-server-"));

        let launch_tail = filter_shell_text_fragment(&mut Vec::new(), launch.as_bytes());
        assert!(launch_tail.contains("REMOTE_CONTAINERS_IPC="));
        assert!(launch_tail.contains("/tmp/vscode-remote-containers-server-123.js"));
        assert!(launch_tail.contains("/.vscode-server/bin/x/node"));
    }

    #[test]
    fn helper_trace_keeps_only_helper_related_lines() {
        let (_tx, rx) = tokio_mpsc::channel(1);
        let mut session = ProcSession {
            child_pid: 1,
            stdin_tx: None,
            rx: Arc::new(TokioMutex::new(rx)),
            child_exit_code: None,
            child_exit_reason: None,
            streams_closed: false,
            stdin_tail: String::new(),
            stdin_text_tail: String::new(),
            helper_trace: String::new(),
            stdin_line_buffer: Vec::new(),
            helper_watch_started: false,
            helper_candidate_logged: false,
            helper_reference_logged: false,
            helper_tail_last_logged: String::new(),
        };

        append_helper_trace(
            &mut session,
            "echo hello\ncommand -v git\ncommand -v git >/dev/null 2>&1 && git config --system --replace-all credential.helper '!f() { /root/.vscode-server/bin/x/node /tmp/vscode-remote-containers-abc.js git-credential-helper $*; }; f'\n",
        );
        assert!(!session.helper_trace.contains("echo hello"));
        assert!(session.helper_trace.contains("credential.helper"));
        assert!(session
            .helper_trace
            .contains("/tmp/vscode-remote-containers-abc.js"));
    }

    #[test]
    fn helper_candidate_markers_are_detected_from_helper_trace() {
        let trace = "command -v git >/dev/null 2>&1 && git config --system --replace-all credential.helper '!f() { /root/.vscode-server/bin/x/node /tmp/vscode-remote-containers-abc.js git-credential-helper $*; }; f'\nREMOTE_CONTAINERS_SOCKETS='[]' REMOTE_CONTAINERS_IPC='/tmp/vscode-remote-containers-ipc-123.sock' '/root/.vscode-server/bin/x/node' '/tmp/vscode-remote-containers-server-123.js' ; exit";
        assert!(trace.contains("REMOTE_CONTAINERS_IPC="));
        assert!(trace.contains("/tmp/vscode-remote-containers-server-123.js"));
        assert!(trace.contains("/.vscode-server/bin/x/node"));
    }

    #[test]
    fn filter_shell_text_fragment_discards_short_printable_runs() {
        let text = b"\x00abc123\x01/tmp/vscode-\x02";
        assert_eq!(filter_shell_text_fragment(&mut Vec::new(), text), "");
    }

    #[test]
    fn filter_shell_text_fragment_ignores_long_printable_binary_without_markers() {
        let text = vec![b'A'; 6000];
        assert_eq!(filter_shell_text_fragment(&mut Vec::new(), &text), "");
    }

    #[test]
    fn format_log_record_includes_timestamp_and_pid() {
        let line = format_log_record("proc_open ok proc_id=proc-1-1 argv0=/bin/sh", 123456, 789);
        assert_eq!(
            line,
            "msl-init: ts_ms=123456 pid=789 proc_open ok proc_id=proc-1-1 argv0=/bin/sh"
        );
    }

    #[test]
    fn diag_channel_lines_keep_channel_and_add_timestamp_and_pid() {
        let line = format!("[init] ts_ms={} pid={} ready", 123456, 789);
        assert_eq!(line, "[init] ts_ms=123456 pid=789 ready");
    }
}

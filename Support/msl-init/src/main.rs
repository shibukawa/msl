use std::collections::HashMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::fs::symlink;
use std::os::unix::io::FromRawFd;
use std::os::unix::net::UnixListener;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicI8, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_READ_BYTES: usize = 16 * 1024;
const MSL_VSOCK_PORT: u32 = 1024;
const MSL_DNS_TUNNEL_PORT: u32 = 1053;
const MSL_TIME_TUNNEL_PORT: u32 = 1067;
const MEMORY_STATS_FILE: &str = "/run/msl-memory-stats.env";
const LOCAL_CONTROL_SOCKET: &str = "/run/msl-init.sock";
const LOCAL_NTP_BIND_ADDR: &str = "127.0.0.1:123";
const NTP_UNIX_OFFSET_SECONDS: u64 = 2_208_988_800;

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

const POLLOUT: i16 = 0x004;
const POLLIN: i16 = 0x001;
const POLLHUP: i16 = 0x010;
const POLLERR: i16 = 0x008;
const MS_BIND: usize = 4096;

extern "C" {
    fn poll(fds: *mut PollFd, nfds: u64, timeout: i32) -> i32;
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
    rx: Receiver<Vec<u8>>,
}

static PTY_SESSIONS: OnceLock<Mutex<HashMap<String, PtySession>>> = OnceLock::new();
static PTY_SEQ: AtomicU64 = AtomicU64::new(1);
static LOG_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static DIAG_LOCK: OnceLock<Mutex<Option<std::fs::File>>> = OnceLock::new();
static RUNTIME_USER: OnceLock<Mutex<RuntimeUserContext>> = OnceLock::new();
static DNS_PROXY_STATE: OnceLock<Mutex<Option<DNSProxyRuntime>>> = OnceLock::new();
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
    stop_tx: mpsc::Sender<()>,
    handle: JoinHandle<()>,
}

fn sessions() -> &'static Mutex<HashMap<String, PtySession>> {
    PTY_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
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

fn dns_proxy_state() -> &'static Mutex<Option<DNSProxyRuntime>> {
    DNS_PROXY_STATE.get_or_init(|| Mutex::new(None))
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

fn has_ipv4_transport_path(interfaces: &[String]) -> bool {
    has_default_ipv4_route()
        && interfaces
            .iter()
            .any(|iface| interface_has_global_ipv4(iface))
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
            .args(["-i", iface, "-n", "-q", "-t", "3", "-T", "1", "-s", script_path])
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
    if has_ipv4_transport_path(&interfaces) {
        return;
    }
    for iface in &interfaces {
        if !interface_has_global_ipv4(iface) || !has_default_ipv4_route() {
            let _ = run_dhcp_once(iface);
            if has_ipv4_transport_path(&interfaces) {
                log_line(&format!("network bootstrap succeeded interface={}", iface));
                return;
            }
        }
    }
    log_line("network bootstrap incomplete: missing default route or ipv4 address");
}

fn stop_dns_proxy() {
    let mut state = dns_proxy_state().lock().unwrap();
    if let Some(runtime) = state.take() {
        let _ = runtime.stop_tx.send(());
        let _ = runtime.handle.join();
    }
}

fn ensure_dns_proxy(listen: SocketAddr, upstreams: Vec<SocketAddr>) -> Result<(bool, bool), String> {
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

    let (stop_tx, stop_rx) = mpsc::channel::<()>();
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
            Err(TryRecvError::Disconnected) => break,
            Err(TryRecvError::Empty) => {}
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
                log_line(&format!("dns proxy recv failed listen={} err={}", listen, err));
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
        return Err(format!("socket(AF_VSOCK) failed: {}", std::io::Error::last_os_error()));
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
        unsafe { close(fd); }
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
            log_line(&format!("local ntp bind failed addr={} err={}", bind_addr, e));
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

    log_line(&format!("started vsock_port={}", vsock_port));
    ensure_process_environment();
    ensure_mount_prerequisites();
    ensure_pty_prerequisites();
    ensure_guest_network_ready();
    start_local_control_server();
    start_local_ntp_server();
    init_diagnostic_channel();
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
            log_line(&format!("file handoff background started handoff={} ack={}", hf, af));
        }
    }

    // Primary: vsock client (connect to host)
    run_vsock_client(vsock_port)
}

fn run_guest_cli_if_requested(args: &[String]) -> Option<Result<(), String>> {
    let argv0 = args.first().map(String::as_str).unwrap_or("msl-init");
    let invoked_as_msl = Path::new(argv0)
        .file_name()
        .and_then(|v| v.to_str())
        .map(|v| v == "msl")
        .unwrap_or(false);

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
    println!("  compactCount: {}", format_u64_with_commas(stats.compact_count));
    println!("  compactLast: {}", format_last_event(stats.compact_last_epoch_ms));
    println!("  dropCacheCount: {}", format_u64_with_commas(stats.drop_cache_count));
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
        ("sudo", vec!["-n", "/usr/local/bin/msl-init", "memory", action_arg]),
        ("doas", vec!["/usr/local/bin/msl-init", "memory", action_arg]),
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
            log_line(&format!("local control mkdir failed {}: {}", parent.display(), e));
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
    log_line(&format!("local control socket ready at {}", socket_path.display()));

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
    let mut stream = UnixStream::connect(LOCAL_CONTROL_SOCKET).map_err(|e| {
        format!(
            "connect {} failed: {}",
            LOCAL_CONTROL_SOCKET,
            e
        )
    })?;
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
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create memory stats dir {}: {}", parent.display(), e))?;
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
        env::set_var("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
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
}

fn ensure_mount_prerequisites() {
    mount_fs_if_needed("/proc", b"proc\0", b"proc\0", None);
    mount_fs_if_needed("/sys", b"sysfs\0", b"sysfs\0", None);
    mount_fs_if_needed("/run", b"tmpfs\0", b"tmpfs\0", Some(b"mode=0755\0"));
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
    fs::create_dir_all("/mnt/macos")
        .map_err(|e| format!("failed to create /mnt/macos: {}", e))?;
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
    fs::create_dir_all(target)
        .map_err(|e| format!("failed to create {}: {}", target, e))?;

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
    Err(format!("bind mount {} -> {} failed: {}", source, target, err))
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
        let fd = unsafe { socket(AF_VSOCK, SOCK_STREAM, 0) };
        if fd < 0 {
            log_line(&format!(
                "socket(AF_VSOCK) failed: {}",
                std::io::Error::last_os_error()
            ));
            thread::sleep(Duration::from_millis(backoff_ms));
            backoff_ms = (backoff_ms * 2).min(MAX_BACKOFF_MS);
            continue;
        }

        let addr = SockaddrVm {
            svm_family: AF_VSOCK as u16,
            svm_reserved1: 0,
            svm_port: port,
            svm_cid: VMADDR_CID_HOST,
            svm_zero: [0; 4],
        };

        let ret = unsafe { connect(fd, &addr, std::mem::size_of::<SockaddrVm>() as u32) };
        if ret < 0 {
            let err = std::io::Error::last_os_error();
            log_line(&format!("vsock connect to host port {} failed: {}", port, err));
            unsafe { close(fd); }
            thread::sleep(Duration::from_millis(backoff_ms));
            backoff_ms = (backoff_ms * 2).min(MAX_BACKOFF_MS);
            continue;
        }

        log_line(&format!("vsock connected to host port {}", port));
        backoff_ms = 100; // reset on successful connect

        handle_persistent_connection(fd);

        log_line("vsock connection closed, reconnecting...");
        // fd is closed by handle_persistent_connection (via File drop)
    }
}

fn handle_persistent_connection(fd: i32) {
    // SAFETY: fd is a valid file descriptor from connect()
    let stream: std::fs::File = unsafe { FromRawFd::from_raw_fd(fd) };
    let reader_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    };

    let mut reader = BufReader::new(reader_stream);
    let mut writer = stream;

    loop {
        // Poll for data before blocking on read_line.
        // This prevents the connection handler from blocking indefinitely when the
        // host side becomes slow or unresponsive (e.g. during macOS sleep).
        // Use -1 (infinite wait): the daemon owns the VM lifecycle and will
        // shut down msl-init by stopping the VM. No need for msl-init to
        // independently timeout the vsock connection.
        let mut rpfd = PollFd { fd, events: POLLIN, revents: 0 };
        let poll_ret = unsafe { poll(&mut rpfd, 1, -1) };
        if poll_ret == 0 {
            // Should not happen with timeout=-1, but handle gracefully
            continue;
        }
        if poll_ret < 0 {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() == Some(4) { // EINTR
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

        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => {
                log_line("vsock EOF from host");
                return;
            }
            Err(e) => {
                log_line(&format!("vsock read error: {}", e));
                return;
            }
            Ok(_) => {}
        }

        let response = handle_request_line(&line);
        let mut out = response.into_bytes();
        out.push(b'\n');
        if writer.write_all(&out).is_err() {
            log_line("vsock write error");
            return;
        }
        if writer.flush().is_err() {
            log_line("vsock flush error");
            return;
        }
    }
    // writer (owning the fd) is dropped here, closing the fd
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
        if let Ok(line) = fs::read_to_string(handoff) {
            let request_id = extract_string(&line, "requestId").unwrap_or_default();
            if !request_id.is_empty() && request_id != last_request_id {
                let response = handle_request_line(&line);
                let tmp_ack = format!("{}.tmp", ack_file);
                if fs::write(&tmp_ack, response).is_ok() {
                    let _ = fs::rename(&tmp_ack, ack);
                    last_request_id = request_id;
                }
            }
        }
        thread::sleep(Duration::from_millis(50));
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
        "init_refresh" => init_refresh_response(&request_id, &op, line),
        "pty_open" => pty_open_response(&request_id, &op, line),
        "pty_read" => pty_read_response(&request_id, &op, line),
        "pty_write" => pty_write_response(&request_id, &op, line),
        "pty_resize" => pty_resize_response(&request_id, &op, line),
        "pty_close" => pty_close_response(&request_id, &op, line),
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
        return error_response(request_id, op, "invalid_request", "dnsMode must be host|manual|unmanaged");
    }

    let requested_nameservers = extract_string_array(line, "dnsNameservers").unwrap_or_default();
    if requested_nameservers.is_empty() {
        return error_response(request_id, op, "invalid_request", "dnsNameservers is required for managed mode");
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
            return error_response(request_id, op, "invalid_request", "dnsProxyListenPort must be in 1..65535");
        }
        if proxy_listen_port != 53 {
            return error_response(request_id, op, "invalid_request", "dnsProxyListenPort must be 53 for resolv.conf compatibility");
        }

        let preferred_listen = match build_listen_addr(&proxy_listen_address, proxy_listen_port as u16) {
            Some(value) => value,
            None => return error_response(request_id, op, "invalid_request", "dnsProxyListenAddress must be a valid IP"),
        };

        let upstreams: Vec<SocketAddr> = proxy_upstreams_raw
            .iter()
            .filter_map(|value| normalize_dns_upstream(value))
            .collect();
        if upstreams.is_empty() {
            return error_response(request_id, op, "invalid_request", "dnsProxyUpstreams is required for host mode");
        }
        let mut listen_candidates: Vec<SocketAddr> = vec![preferred_listen];
        if preferred_listen.ip().to_string() != "127.0.0.1" {
            if let Some(loopback) = build_listen_addr("127.0.0.1", proxy_listen_port as u16) {
                listen_candidates.push(loopback);
            }
        }
        if let Some(detected) = detect_default_local_ip() {
            let detected_addr = SocketAddr::new(detected, proxy_listen_port as u16);
            if !listen_candidates.iter().any(|value| *value == detected_addr) {
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
        return error_response(request_id, op, "internal_error", &format!("failed to write resolv tmp: {}", e));
    }
    if let Err(e) = fs::rename(tmp, target) {
        let _ = fs::remove_file(tmp);
        return error_response(request_id, op, "internal_error", &format!("failed to replace resolv.conf: {}", e));
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
    if !has_ipv4_transport_path(&interfaces) {
        return error_response(
            request_id,
            op,
            "internal_error",
            "network transport unavailable: missing default route or ipv4 address",
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
    let workspace_path = extract_string(line, "cwd")
        .and_then(|v| normalize_absolute_path(&v));
    let share_root = extract_string(line, "hostShareRoot")
        .and_then(|v| normalize_absolute_path(&v))
        .unwrap_or_else(|| "/".to_string());

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
    if share_root != "/" {
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
        if share_root == "/" {
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

fn init_refresh_response(request_id: &str, op: &str, line: &str) -> String {
    let source_path = match extract_string(line, "initSourcePath")
        .and_then(|value| normalize_absolute_path(&value))
    {
        Some(path) => path,
        None => return error_response(request_id, op, "invalid_request", "initSourcePath is required"),
    };
    let dry_run = extract_bool(line, "initDryRun").unwrap_or(false);
    let source = Path::new(&source_path);
    if !source.is_file() {
        return error_response(request_id, op, "invalid_request", "initSourcePath is not a readable file");
    }

    let destination = Path::new("/usr/local/bin/msl-init");
    let same_binary = if destination.exists() {
        match (fs::read(source), fs::read(destination)) {
            (Ok(src), Ok(dst)) => src == dst,
            _ => false,
        }
    } else {
        false
    };

    if same_binary {
        return ok_response(
            request_id,
            op,
            Some("\"meta\":{\"status\":\"skipped\"}".to_string()),
        );
    }

    if dry_run {
        return ok_response(
            request_id,
            op,
            Some("\"meta\":{\"status\":\"would_update\"}".to_string()),
        );
    }

    if let Err(err) = fs::create_dir_all("/usr/local/bin") {
        return error_response(request_id, op, "internal_error", &format!("create_dir_all failed: {}", err));
    }

    let tmp_path = format!("/usr/local/bin/.msl-init.tmp.{}", std::process::id());
    if let Err(err) = fs::copy(source, &tmp_path) {
        return error_response(request_id, op, "internal_error", &format!("copy failed: {}", err));
    }
    if let Err(err) = fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o755)) {
        let _ = fs::remove_file(&tmp_path);
        return error_response(request_id, op, "internal_error", &format!("chmod failed: {}", err));
    }
    if let Err(err) = fs::rename(&tmp_path, destination) {
        let _ = fs::remove_file(&tmp_path);
        return error_response(request_id, op, "internal_error", &format!("rename failed: {}", err));
    }

    let msl_link = Path::new("/usr/local/bin/msl");
    let _ = fs::remove_file(msl_link);
    if let Err(err) = symlink("msl-init", msl_link) {
        return error_response(request_id, op, "internal_error", &format!("symlink failed: {}", err));
    }

    ok_response(
        request_id,
        op,
        Some("\"meta\":{\"status\":\"updated\"}".to_string()),
    )
}

fn pty_open_response(request_id: &str, op: &str, line: &str) -> String {
    let argv = extract_string_array(line, "argv").unwrap_or_else(|| vec!["/bin/sh".to_string(), "-l".to_string()]);
    if argv.is_empty() {
        return error_response(request_id, op, "invalid_request", "missing argv");
    }
    let requested_cwd = extract_string(line, "cwd");
    let env_additions = extract_string_map(line, "envAdditions").unwrap_or_default();

    let rows = extract_int(line, "rows").unwrap_or(24) as u16;
    let cols = extract_int(line, "cols").unwrap_or(80) as u16;
    let runtime = runtime_user()
        .lock()
        .map(|v| v.clone())
        .unwrap_or(RuntimeUserContext {
            username: "root".to_string(),
            uid: 0,
            gid: 0,
            home: "/root".to_string(),
            shell: "/bin/sh".to_string(),
        });
    let supplementary_gids = supplementary_gids_for_user(&runtime.username, runtime.gid);

    let started = Instant::now();

    // Allocate a real PTY pair
    let mut master_fd: i32 = -1;
    let mut slave_fd: i32 = -1;
    let ws = Winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };

    if unsafe { openpty(&mut master_fd, &mut slave_fd, std::ptr::null_mut(), std::ptr::null(), &ws) } != 0 {
        return error_response(request_id, op, "internal_error", &format!("openpty failed: {}", std::io::Error::last_os_error()));
    }

    // Prepare all heap allocations BEFORE fork() to avoid malloc corruption
    // in a multi-threaded process. After fork, only async-signal-safe calls are allowed.
    let c_strings: Vec<Vec<u8>> = argv.iter().map(|s| {
        let mut v = s.as_bytes().to_vec();
        v.push(0);
        v
    }).collect();
    let c_ptrs: Vec<*const u8> = c_strings.iter().map(|v| v.as_ptr())
        .chain(std::iter::once(std::ptr::null())).collect();

    // Build environment as "KEY=VALUE\0" strings for execve
    let mut env_values = vec![
        format!("HOME={}", runtime.home),
        "TERM=xterm-256color".to_string(),
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin".to_string(),
        format!("USER={}", runtime.username),
        format!("LOGNAME={}", runtime.username),
        format!("SHELL={}", runtime.shell),
        "LANG=C.UTF-8".to_string(),
        "LC_ALL=C.UTF-8".to_string(),
    ];
    for (key, value) in env_additions {
        if is_valid_env_key(&key) {
            env_values.push(format!("{}={}", key, value));
        }
    }
    let env_cstrings: Vec<Vec<u8>> = env_values.iter().map(|s| {
        let mut v = s.as_bytes().to_vec();
        v.push(0);
        v
    }).collect();
    let env_ptrs: Vec<*const u8> = env_cstrings.iter().map(|v| v.as_ptr())
        .chain(std::iter::once(std::ptr::null())).collect();
    let selected_cwd = requested_cwd
        .as_ref()
        .filter(|v| v.starts_with('/') && Path::new(v).is_dir())
        .cloned()
        .unwrap_or_else(|| runtime.home.clone());
    let mut cwd_path = selected_cwd.as_bytes().to_vec();
    cwd_path.push(0);

    let pid = unsafe { fork() };
    if pid < 0 {
        unsafe { close(master_fd); close(slave_fd); }
        return error_response(request_id, op, "internal_error", &format!("fork failed: {}", std::io::Error::last_os_error()));
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
            if slave_fd > 2 { close(slave_fd); }
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
            let mut rlim = Rlimit { rlim_cur: 1024, rlim_max: 1024 };
            getrlimit(RLIMIT_NOFILE, &mut rlim);
            let max_fd = if rlim.rlim_cur > 4096 { 4096 } else { rlim.rlim_cur as i32 };
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
    unsafe { close(slave_fd); }

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let reader_fd = master_fd;
    thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            let n = unsafe { libc_read(reader_fd, buf.as_mut_ptr(), buf.len()) };
            if n <= 0 { break; }
            if tx.send(buf[..n as usize].to_vec()).is_err() { break; }
        }
    });

    let pty_id = format!("pty-{}-{}", std::process::id(), PTY_SEQ.fetch_add(1, Ordering::Relaxed));
    let session = PtySession { master_fd, child_pid: pid, rx };

    match sessions().lock() {
        Ok(mut map) => {
            map.insert(pty_id.clone(), session);
        }
        Err(_) => return error_response(request_id, op, "internal_error", "pty session lock poisoned"),
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

fn pty_read_response(request_id: &str, op: &str, line: &str) -> String {
    let pty_id = match extract_string(line, "ptyId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing ptyId"),
    };

    let mut map = match sessions().lock() {
        Ok(v) => v,
        Err(_) => return error_response(request_id, op, "internal_error", "pty session lock poisoned"),
    };

    let mut output: Vec<u8> = Vec::new();
    let mut exit_code: Option<i32> = None;

    {
        let session = match map.get_mut(&pty_id) {
            Some(v) => v,
            None => return error_response(request_id, op, "invalid_request", "unknown ptyId"),
        };

        while output.len() < MAX_READ_BYTES {
            match session.rx.try_recv() {
                Ok(chunk) => output.extend_from_slice(&chunk),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break,
            }
        }

        // Check child status via waitpid(WNOHANG)
        let mut status: i32 = 0;
        let ret = unsafe { waitpid(session.child_pid, &mut status, WNOHANG) };
        if ret > 0 {
            if status & 0x7f == 0 {
                // Exited normally
                exit_code = Some((status >> 8) & 0xff);
            } else {
                // Killed by signal
                exit_code = Some(128 + (status & 0x7f));
            }
        }
    }

    if exit_code.is_some() {
        if let Some(session) = map.remove(&pty_id) {
            unsafe { close(session.master_fd); }
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
        Err(e) => return error_response(request_id, op, "invalid_request", &format!("invalid base64: {e}")),
    };

    let mut map = match sessions().lock() {
        Ok(v) => v,
        Err(_) => return error_response(request_id, op, "internal_error", "pty session lock poisoned"),
    };

    let session = match map.get_mut(&pty_id) {
        Some(v) => v,
        None => return error_response(request_id, op, "invalid_request", "unknown ptyId"),
    };

    let mut offset = 0;
    while offset < bytes.len() {
        // Use poll(POLLOUT) to avoid blocking indefinitely on full PTY buffer
        let mut pfd = PollFd { fd: session.master_fd, events: POLLOUT, revents: 0 };
        let pret = unsafe { poll(&mut pfd, 1, 5000) }; // 5s timeout
        if pret == 0 {
            return error_response(request_id, op, "timeout", "pty write timed out (PTY buffer full?)");
        }
        if pret < 0 {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() == Some(4) { // EINTR
                continue;
            }
            return error_response(request_id, op, "internal_error", &format!("pty write poll failed: {}", e));
        }
        let n = unsafe { libc_write(session.master_fd, bytes[offset..].as_ptr(), bytes.len() - offset) };
        if n < 0 {
            return error_response(request_id, op, "internal_error", &format!("pty write failed: {}", std::io::Error::last_os_error()));
        }
        offset += n as usize;
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
        Err(_) => return error_response(request_id, op, "internal_error", "pty session lock poisoned"),
    };
    let session = match map.get(&pty_id) {
        Some(v) => v,
        None => return error_response(request_id, op, "invalid_request", "unknown ptyId"),
    };

    let ws = Winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    let ret = unsafe { ioctl(session.master_fd, TIOCSWINSZ, &ws) };
    if ret < 0 {
        return error_response(request_id, op, "internal_error", &format!("TIOCSWINSZ failed: {}", std::io::Error::last_os_error()));
    }

    ok_response(request_id, op, Some(format!("\"meta\":{{\"rows\":{},\"cols\":{}}}", rows, cols)))
}

fn pty_close_response(request_id: &str, op: &str, line: &str) -> String {
    let pty_id = match extract_string(line, "ptyId") {
        Some(v) if !v.is_empty() => v,
        _ => return error_response(request_id, op, "invalid_request", "missing ptyId"),
    };

    let mut map = match sessions().lock() {
        Ok(v) => v,
        Err(_) => return error_response(request_id, op, "internal_error", "pty session lock poisoned"),
    };

    let session = match map.remove(&pty_id) {
        Some(v) => v,
        None => return ok_response(request_id, op, Some("\"meta\":{\"closed\":\"already\"}".to_string())),
    };

    // Close master fd first (sends EOF to child)
    unsafe { close(session.master_fd); }

    // Check if child already exited
    let mut status: i32 = 0;
    let ret = unsafe { waitpid(session.child_pid, &mut status, WNOHANG) };
    let code = if ret > 0 {
        if status & 0x7f == 0 { (status >> 8) & 0xff } else { 128 + (status & 0x7f) }
    } else {
        // Not yet exited, send SIGTERM then wait briefly
        unsafe { kill(session.child_pid, SIGTERM); }
        thread::sleep(Duration::from_millis(100));
        let ret2 = unsafe { waitpid(session.child_pid, &mut status, WNOHANG) };
        if ret2 > 0 {
            if status & 0x7f == 0 { (status >> 8) & 0xff } else { 128 + (status & 0x7f) }
        } else {
            unsafe { kill(session.child_pid, SIGKILL); waitpid(session.child_pid, &mut status, 0); }
            if status & 0x7f == 0 { (status >> 8) & 0xff } else { 128 + (status & 0x7f) }
        }
    };

    log_line(&format!(
        "pty_close request_id={} pty_id={} exit_code={}",
        request_id, pty_id, code
    ));

    ok_response(
        request_id,
        op,
        Some(format!("\"meta\":{{\"exitCode\":\"{}\"}},\"exitCode\":{}", code, code)),
    )
}

fn b64_encode(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut i = 0;
    while i < data.len() {
        let b0 = data[i] as u32;
        let b1 = if i + 1 < data.len() { data[i + 1] as u32 } else { 0 };
        let b2 = if i + 2 < data.len() { data[i + 2] as u32 } else { 0 };

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
    let line = format!("[{channel}] {message}");
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

fn log_line(message: &str) {
    let line = format!("msl-init: {message}");
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
    let cloud_init_result = Path::new("/run/cloud-init/result.json");
    let cloud_init_status = if cloud_init_result.exists() {
        match fs::read_to_string(cloud_init_result) {
            Ok(content) => {
                // Parse the status from the JSON. The file typically contains:
                // {"v1": {"datasource": "...", "errors": [], ...}}
                // If the file exists and is parsable, cloud-init has completed.
                if content.contains("\"errors\": []") || content.contains("\"errors\":[]") {
                    "done"
                } else if content.contains("\"errors\"") {
                    "error"
                } else {
                    "done"
                }
            }
            Err(_) => "running",
        }
    } else if Path::new("/run/cloud-init").exists() {
        "running"
    } else {
        "not_started"
    };

    ok_response(
        request_id,
        "converge_status",
        Some(format!(
            "\"meta\":{{\"cloud_init\":\"{}\",\"status\":\"ok\"}}",
            cloud_init_status
        )),
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
        _ => return error_response(request_id, op, "invalid_request", "missing convergeUsername"),
    };
    if !is_safe_identifier(&username) {
        return error_response(request_id, op, "invalid_request", "invalid convergeUsername");
    }

    let uid = match extract_int(line, "convergeUID") {
        Some(v) if v >= 0 => v as u32,
        _ => return error_response(request_id, op, "invalid_request", "missing or invalid convergeUID"),
    };
    let gid = match extract_int(line, "convergeGID") {
        Some(v) if v >= 0 => v as u32,
        _ => return error_response(request_id, op, "invalid_request", "missing or invalid convergeGID"),
    };

    let home = match extract_string(line, "convergeHome") {
        Some(v) if !v.is_empty() && v.starts_with('/') => v,
        _ => return error_response(request_id, op, "invalid_request", "missing or invalid convergeHome"),
    };
    let preferred_shell = extract_string(line, "convergePreferredShell");
    let fail_on_uid_conflict = extract_bool(line, "convergeFailOnUIDConflict").unwrap_or(true);

    let template_id = extract_string(line, "policyTemplateId").unwrap_or_else(|| "unknown".to_string());
    let command_family = extract_string(line, "policyCommandFamily").unwrap_or_else(|| "useradd".to_string());
    let admin_group = extract_string(line, "policyAdminGroup").unwrap_or_else(|| "sudo".to_string());
    if !is_safe_identifier(&admin_group) {
        return error_response(request_id, op, "invalid_request", "invalid policyAdminGroup");
    }
    let sudo_enabled = extract_bool(line, "policySudoEnabled").unwrap_or(true);
    let sudo_require_binary = extract_bool(line, "policySudoRequireBinary").unwrap_or(false);
    let sudo_passwordless = extract_bool(line, "policySudoPasswordless").unwrap_or(true);
    let su_enabled = extract_bool(line, "policySuEnabled").unwrap_or(false);
    let su_passwordless = extract_bool(line, "policySuPasswordless").unwrap_or(false);
    let sudo_drop_in = extract_string(line, "policySudoDropInPath")
        .unwrap_or_else(|| "/etc/sudoers.d/msl-user".to_string());
    if !sudo_drop_in.starts_with('/') {
        return error_response(request_id, op, "invalid_request", "policySudoDropInPath must be absolute");
    }
    let shell_fallbacks = extract_string_array(line, "policyShellFallbacks")
        .unwrap_or_else(|| vec!["/bin/sh".to_string()]);

    let welcome_enabled = extract_bool(line, "policyWelcomeEnabled").unwrap_or(true);
    let welcome_frequency = extract_string(line, "policyWelcomeFrequency").unwrap_or_else(|| "daily".to_string());
    let welcome_respect_hushlogin = extract_bool(line, "policyWelcomeRespectHushlogin").unwrap_or(true);
    let welcome_instance = extract_string(line, "policyWelcomeInstance").unwrap_or_else(|| "msl".to_string());

    let requested_shell = preferred_shell
        .and_then(|s| if is_executable_path(&s) { Some(s) } else { None })
        .or_else(|| shell_fallbacks.iter().find(|s| is_executable_path(s)).cloned())
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
                        &format!("uid_conflict: uid {} already owned by {}", uid, conflict.username),
                    );
                }
            }
        }

        if let Err(e) = create_user_from_policy(&command_family, &username, uid, gid, &home, &requested_shell) {
            return error_response(request_id, op, "internal_error", &format!("user_create_failed: {}", e));
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
    if let Err(e) = ensure_admin_group_membership(&command_family, &resolved.username, &admin_group) {
        warnings.push(format!("admin_group_failed: {}", e));
    }
    match apply_su_policy(
        &admin_group,
        su_enabled,
        su_passwordless
    ) {
    Ok(Some(warning)) => warnings.push(warning),
    Ok(None) => {}
    Err(e) => {
        return error_response(request_id, op, "internal_error", &format!("su_policy_failed: {}", e));
    }
    }
    match apply_sudo_policy(
        &resolved.username,
        sudo_enabled,
        sudo_require_binary,
        sudo_passwordless,
        &sudo_drop_in
    ) {
    Ok(Some(warning)) => warnings.push(warning),
    Ok(None) => {}
    Err(e) => {
        return error_response(request_id, op, "internal_error", &format!("sudo_policy_failed: {}", e));
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
        &welcome_instance
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
    value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
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
    read_passwd_entries().into_iter().find(|u| u.username == name)
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
        return Err(format!("sethostname failed: {}", std::io::Error::last_os_error()));
    }

    fs::write("/etc/hostname", format!("{}\n", hostname))
        .map_err(|e| format!("write /etc/hostname failed: {}", e))?;
    ensure_hosts_hostname_mapping(&hostname)?;
    Ok(())
}

fn ensure_hosts_hostname_mapping(hostname: &str) -> Result<(), String> {
    let hosts_path = Path::new("/etc/hosts");
    let existing = if hosts_path.exists() {
        fs::read_to_string(hosts_path)
            .map_err(|e| format!("read /etc/hosts failed: {}", e))?
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
    fs::write(hosts_path, rendered)
        .map_err(|e| format!("write /etc/hosts failed: {}", e))?;
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
        if stdout.is_empty() { "".to_string() } else { format!(" ({})", stdout) }
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
        let args = vec![
            format!("{}:{}", user.uid, user.gid),
            user.home.clone(),
        ];
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
        let args = vec!["-aG".to_string(), admin_group.to_string(), username.to_string()];
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
    fs::write(drop_path, line)
        .map_err(|e| format!("failed to write {}: {}", drop_in_path, e))?;
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
            log_line(&format!("su_policy_passwordless_enabled group={}", admin_group));
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
        let metadata = fs::metadata(path)
            .map_err(|e| format!("failed to stat {}: {}", candidate, e))?;
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
            fs::set_permissions(path, perms)
                .map_err(|e| format!("failed to chmod {} to {:o}: {}", candidate, desired_mode, e))?;
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
    let runtime = if run_as_root {
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
    };
    let mut cmd = Command::new(&argv[0]);
    if argv.len() > 1 {
        cmd.args(&argv[1..]);
    }
    cmd.uid(runtime.uid);
    cmd.gid(runtime.gid);
    cmd.env("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    cmd.env("HOME", &runtime.home);
    cmd.env("TERM", "xterm-256color");
    cmd.env("USER", &runtime.username);
    cmd.env("LOGNAME", &runtime.username);
    cmd.env("SHELL", &runtime.shell);
    for (key, value) in env_additions {
        if is_valid_env_key(&key) {
            cmd.env(key, value);
        }
    }
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
            match cmd.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).spawn() {
                Ok(mut child) => {
                    let timeout_dur = Duration::from_millis(ms as u64);
                    let deadline = Instant::now() + timeout_dur;
                    loop {
                        match child.try_wait() {
                            Ok(Some(status)) => {
                                let exit = status.code().unwrap_or(1);
                                let stdout = child.stdout.take().map(|mut s| {
                                    let mut buf = String::new();
                                    use std::io::Read;
                                    let _ = s.read_to_string(&mut buf);
                                    buf
                                }).unwrap_or_default();
                                let stderr = child.stderr.take().map(|mut s| {
                                    let mut buf = String::new();
                                    use std::io::Read;
                                    let _ = s.read_to_string(&mut buf);
                                    buf
                                }).unwrap_or_default();
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
                                    unsafe { kill(pid, SIGTERM); }
                                    thread::sleep(Duration::from_secs(2));
                                    if child.try_wait().ok().flatten().is_none() {
                                        unsafe { kill(pid, SIGKILL); }
                                        let _ = child.wait();
                                    }
                                    return error_response(request_id, op, "timeout", &format!("command timed out after {}ms", ms));
                                }
                                thread::sleep(Duration::from_millis(50));
                            }
                            Err(e) => {
                                return error_response(request_id, op, "internal_error", &format!("wait failed: {e}"));
                            }
                        }
                    }
                }
                Err(e) => return error_response(request_id, op, "internal_error", &format!("exec failed: {e}")),
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
        Err(e) => error_response(request_id, op, "internal_error", &format!("exec failed: {e}")),
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
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_string_unescapes_slash_and_quote() {
        let input = r#"{"convergeHome":"\/home\/test-user","note":"hello \"world\""}"#;
        assert_eq!(extract_string(input, "convergeHome").as_deref(), Some("/home/test-user"));
        assert_eq!(extract_string(input, "note").as_deref(), Some("hello \"world\""));
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
    fn env_key_validation_rejects_invalid_chars() {
        assert!(is_valid_env_key("NPM_CONFIG_CACHE"));
        assert!(!is_valid_env_key(""));
        assert!(!is_valid_env_key("BAD-KEY"));
        assert!(!is_valid_env_key("BAD.KEY"));
    }

    #[test]
    fn normalize_hostname_uses_instance_safe_form() {
        assert_eq!(normalize_hostname("Ubuntu_24.04"), "ubuntu-24-04");
        assert_eq!(normalize_hostname("___"), "msl");
        assert_eq!(normalize_hostname("my.instance-name"), "my-instance-name");
    }

    #[test]
    fn memory_cli_action_parses_aliases() {
        assert_eq!(MemoryCliAction::parse("compact"), Some(MemoryCliAction::Compact));
        assert_eq!(MemoryCliAction::parse("compat"), Some(MemoryCliAction::Compact));
        assert_eq!(MemoryCliAction::parse("drop-cache"), Some(MemoryCliAction::DropCaches));
        assert_eq!(MemoryCliAction::parse("drop_caches"), Some(MemoryCliAction::DropCaches));
        assert_eq!(MemoryCliAction::parse("dropcache"), Some(MemoryCliAction::DropCaches));
        assert_eq!(MemoryCliAction::parse("unknown"), None);
    }

    #[test]
    fn memory_stats_file_updates() {
        let root = std::env::temp_dir().join(format!("msl-init-memory-stats-{}", std::process::id()));
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
}

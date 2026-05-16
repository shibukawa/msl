use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::FromRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

const AF_VSOCK: i32 = 40;
const SOCK_STREAM: i32 = 1;
const VMADDR_CID_HOST: u32 = 2;
const MSL_VSOCK_PORT: u32 = 1024;
const CONNECT_TIMEOUT_SECS: u64 = 30;
const HELLO_VERSION: &str = "1";
const MAGIC: &str = "MSLB2";
const METADATA_VERSION: u32 = 1;
const REQUIRED_FLAG: u8 = 0x01;
const MIN_PAYLOAD_BYTES: usize = 4096;
const MAX_METADATA_RECORDS: u32 = 256;
const MAX_METADATA_ENTRY_BYTES: u32 = 64 * 1024;
const RUNTIME_INIT_DIR: &str = "/run/msl-init";
const RUNTIME_INIT_BINARY: &str = "/run/msl-init/msl-init";

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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TargetKind {
    Bootloader = 1,
    Environment = 2,
    ExecEnv = 3,
}

impl TryFrom<u8> for TargetKind {
    type Error = String;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Bootloader),
            2 => Ok(Self::Environment),
            3 => Ok(Self::ExecEnv),
            _ => Err(format!("unknown metadata target_kind: {}", value)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct MetadataRecord {
    target_kind: TargetKind,
    flags: u8,
    entry: String,
}

impl MetadataRecord {
    fn is_required(&self) -> bool {
        (self.flags & REQUIRED_FLAG) != 0
    }
}

fn main() -> Result<(), String> {
    let argv0 = env::args()
        .next()
        .unwrap_or_else(|| "/sbin/msl-init-bootloader".to_string());
    let self_path = PathBuf::from(argv0);
    let init_mode = determine_init_mode(&self_path);
    let exec_target = determine_exec_target(&self_path);
    let port = env::var("MSL_VSOCK_PORT")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(MSL_VSOCK_PORT);

    let mut stream = connect_vsock_with_timeout(port, Duration::from_secs(CONNECT_TIMEOUT_SECS))?;
    send_line(
        &mut stream,
        &format!("{MAGIC} HELLO {HELLO_VERSION} {init_mode}"),
    )?;

    let records = read_metadata_block(&mut stream)?;
    let exec_env_assignments = apply_metadata_records(&records)?;

    let mut payload = Vec::new();
    stream
        .read_to_end(&mut payload)
        .map_err(|e| format!("read payload failed: {e}"))?;

    validate_payload(&payload)?;
    install_payload(&payload)?;

    // The bootloader transport is only for metadata/payload transfer.
    // Close it before exec so the runtime init starts with a clean vsock state.
    drop(stream);

    let mut command = Command::new(&exec_target);
    command.env_clear();
    command.envs(build_exec_environment(exec_env_assignments)?);
    let error = command.exec();
    Err(format!("exec {} failed: {}", exec_target, error))
}

fn determine_init_mode(self_path: &Path) -> &'static str {
    if self_path.starts_with("/sbin/") {
        "direct-init"
    } else {
        "service-managed-init"
    }
}

fn determine_exec_target(self_path: &Path) -> &'static str {
    let _ = self_path;
    RUNTIME_INIT_BINARY
}

fn connect_vsock_with_timeout(port: u32, timeout: Duration) -> Result<std::fs::File, String> {
    let deadline = Instant::now() + timeout;
    let mut backoff_ms: u64 = 100;
    loop {
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
            svm_port: port,
            svm_cid: VMADDR_CID_HOST,
            svm_zero: [0; 4],
        };
        let ret = unsafe { connect(fd, &addr, std::mem::size_of::<SockaddrVm>() as u32) };
        if ret == 0 {
            return Ok(unsafe { std::fs::File::from_raw_fd(fd) });
        }

        let err = std::io::Error::last_os_error();
        unsafe {
            close(fd);
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "vsock connect to host port {} failed: {}",
                port, err
            ));
        }
        thread::sleep(Duration::from_millis(backoff_ms));
        backoff_ms = (backoff_ms * 2).min(2_000);
    }
}

fn send_line(stream: &mut std::fs::File, line: &str) -> Result<(), String> {
    stream
        .write_all(format!("{line}\n").as_bytes())
        .map_err(|e| format!("write line failed: {e}"))?;
    stream.flush().map_err(|e| format!("flush failed: {e}"))?;
    Ok(())
}

fn read_metadata_block<R: Read>(reader: &mut R) -> Result<Vec<MetadataRecord>, String> {
    let version = read_u32_le(reader)?;
    if version != METADATA_VERSION {
        return Err(format!("unsupported metadata version: {}", version));
    }
    let record_count = read_u32_le(reader)?;
    if record_count > MAX_METADATA_RECORDS {
        return Err(format!("metadata record count too large: {}", record_count));
    }
    let mut records = Vec::with_capacity(record_count as usize);
    for _ in 0..record_count {
        let target_kind = TargetKind::try_from(read_u8(reader)?)?;
        let flags = read_u8(reader)?;
        if flags & !REQUIRED_FLAG != 0 {
            return Err(format!("unsupported metadata flags: {}", flags));
        }
        let reserved = read_u16_le(reader)?;
        if reserved != 0 {
            return Err(format!(
                "metadata reserved field must be zero, got {}",
                reserved
            ));
        }
        let entry_len = read_u32_le(reader)?;
        if entry_len > MAX_METADATA_ENTRY_BYTES {
            return Err(format!("metadata entry too large: {}", entry_len));
        }
        let entry = read_utf8(reader, entry_len as usize)?;
        records.push(MetadataRecord {
            target_kind,
            flags,
            entry,
        });
    }
    Ok(records)
}

fn apply_metadata_records(records: &[MetadataRecord]) -> Result<Vec<String>, String> {
    let mut environment_assignments: Vec<String> = Vec::new();
    let mut exec_env_assignments: Vec<String> = Vec::new();

    for record in records {
        match record.target_kind {
            TargetKind::Bootloader => {
                if let Err(err) = apply_bootloader_record(record) {
                    if record.is_required() {
                        return Err(err);
                    }
                    eprintln!("warning: ignored optional bootloader metadata: {err}");
                }
            }
            TargetKind::Environment => match parse_env_assignment(&record.entry) {
                Ok((key, value)) => {
                    env::set_var(&key, &value);
                    environment_assignments.push(format!("{}={}", key, value));
                }
                Err(err) => {
                    eprintln!("warning: ignored environment metadata: {err}");
                }
            },
            TargetKind::ExecEnv => match parse_env_assignment(&record.entry) {
                Ok((key, value)) => {
                    exec_env_assignments.push(format!("{}={}", key, value));
                }
                Err(err) => {
                    eprintln!("warning: ignored exec_env metadata: {err}");
                }
            },
        }
    }

    if let Err(err) = persist_environment_assignments(&environment_assignments) {
        eprintln!("warning: failed to persist environment metadata: {err}");
    }

    Ok(exec_env_assignments)
}

fn apply_bootloader_record(record: &MetadataRecord) -> Result<(), String> {
    let (key, value) = parse_assignment(&record.entry)?;
    match key.as_str() {
        "clock.epoch_ms" => {
            let epoch_ms = value
                .parse::<u64>()
                .map_err(|e| format!("invalid clock.epoch_ms value: {e}"))?;
            if let Err(err) = apply_host_clock(epoch_ms) {
                eprintln!("warning: failed to apply host clock: {err}");
            }
            Ok(())
        }
        _ => Err(format!("unknown bootloader metadata key: {}", key)),
    }
}

fn apply_host_clock(epoch_ms: u64) -> Result<(), String> {
    let tv_sec = epoch_ms / 1000;
    let tv_nsec = (epoch_ms % 1000) * 1_000_000;
    let ts = libc::timespec {
        tv_sec: tv_sec
            .try_into()
            .map_err(|_| format!("epoch_ms seconds out of range: {}", tv_sec))?,
        tv_nsec: tv_nsec
            .try_into()
            .map_err(|_| format!("epoch_ms nanoseconds out of range: {}", tv_nsec))?,
    };
    let rc = unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &ts) };
    if rc == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error().to_string())
    }
}

fn persist_environment_assignments(assignments: &[String]) -> Result<(), String> {
    if assignments.is_empty() {
        return Ok(());
    }
    let path = Path::new("/etc/environment");
    let current = fs::read_to_string(path).unwrap_or_default();
    let content = patch_environment_text(&current, assignments)?;
    fs::write(path, content).map_err(|e| format!("write {} failed: {e}", path.display()))
}

fn patch_environment_text(current: &str, assignments: &[String]) -> Result<String, String> {
    let mut desired = BTreeMap::<String, String>::new();
    for assignment in assignments {
        let (key, value) = parse_env_assignment(assignment)?;
        desired.insert(key, value);
    }

    let mut out: Vec<String> = Vec::new();
    let mut remaining = desired.clone();
    for line in current.lines() {
        if let Some((key, _)) = parse_env_assignment_line(line) {
            if let Some(value) = remaining.remove(&key) {
                out.push(render_env_assignment(&key, &value));
            } else {
                out.push(line.to_string());
            }
        } else {
            out.push(line.to_string());
        }
    }
    for (key, value) in remaining {
        out.push(render_env_assignment(&key, &value));
    }
    let mut content = out.join("\n");
    content.push('\n');
    Ok(content)
}

fn render_env_assignment(key: &str, value: &str) -> String {
    format!("{}=\"{}\"", key, escape_env_value(value))
}

fn escape_env_value(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn build_exec_environment(
    exec_env_assignments: Vec<String>,
) -> Result<Vec<(OsString, OsString)>, String> {
    let mut map = BTreeMap::<OsString, OsString>::new();
    for (key, value) in env::vars_os() {
        map.insert(key, value);
    }
    for assignment in exec_env_assignments {
        let (key, value) = parse_env_assignment(&assignment)?;
        map.insert(OsString::from(key), OsString::from(value));
    }
    Ok(map.into_iter().collect())
}

fn parse_assignment(entry: &str) -> Result<(String, String), String> {
    let (key, value) = entry
        .split_once('=')
        .ok_or_else(|| format!("assignment missing '=': {}", entry))?;
    if key.trim().is_empty() {
        return Err(format!("assignment key is empty: {}", entry));
    }
    Ok((key.to_string(), value.to_string()))
}

fn parse_env_assignment(entry: &str) -> Result<(String, String), String> {
    let (key, value) = parse_assignment(entry)?;
    if !is_valid_env_key(&key) {
        return Err(format!("invalid environment key: {}", key));
    }
    Ok((key, value))
}

fn parse_env_assignment_line(line: &str) -> Option<(String, String)> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let (key, raw) = trimmed.split_once('=')?;
    if !is_valid_env_key(key) {
        return None;
    }
    let value = raw
        .trim()
        .strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .unwrap_or(raw.trim())
        .replace("\\\"", "\"")
        .replace("\\\\", "\\");
    Some((key.to_string(), value))
}

fn is_valid_env_key(key: &str) -> bool {
    let mut chars = key.chars();
    match chars.next() {
        Some(ch) if ch == '_' || ch.is_ascii_alphabetic() => {}
        _ => return false,
    }
    chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn read_u8<R: Read>(reader: &mut R) -> Result<u8, String> {
    let mut buf = [0_u8; 1];
    reader
        .read_exact(&mut buf)
        .map_err(|e| format!("read u8 failed: {e}"))?;
    Ok(buf[0])
}

fn read_u16_le<R: Read>(reader: &mut R) -> Result<u16, String> {
    let mut buf = [0_u8; 2];
    reader
        .read_exact(&mut buf)
        .map_err(|e| format!("read u16 failed: {e}"))?;
    Ok(u16::from_le_bytes(buf))
}

fn read_u32_le<R: Read>(reader: &mut R) -> Result<u32, String> {
    let mut buf = [0_u8; 4];
    reader
        .read_exact(&mut buf)
        .map_err(|e| format!("read u32 failed: {e}"))?;
    Ok(u32::from_le_bytes(buf))
}

fn read_utf8<R: Read>(reader: &mut R, len: usize) -> Result<String, String> {
    let mut buf = vec![0_u8; len];
    reader
        .read_exact(&mut buf)
        .map_err(|e| format!("read metadata entry failed: {e}"))?;
    String::from_utf8(buf).map_err(|e| format!("metadata entry is not UTF-8: {e}"))
}

fn validate_payload(payload: &[u8]) -> Result<(), String> {
    if payload.len() < MIN_PAYLOAD_BYTES {
        return Err(format!("payload too small: {} bytes", payload.len()));
    }
    Ok(())
}

fn install_payload(payload: &[u8]) -> Result<(), String> {
    ensure_runtime_init_dir()?;
    install_payload_at(payload, Path::new(RUNTIME_INIT_BINARY))
}

fn install_payload_at(payload: &[u8], target: &Path) -> Result<(), String> {
    let parent = target
        .parent()
        .ok_or_else(|| format!("target has no parent: {}", target.display()))?;
    fs::create_dir_all(parent)
        .map_err(|e| format!("create parent {} failed: {e}", parent.display()))?;
    let temp = temp_path_for(target);
    {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temp)
            .map_err(|e| format!("open temp {} failed: {e}", temp.display()))?;
        file.write_all(payload)
            .map_err(|e| format!("write temp {} failed: {e}", temp.display()))?;
        file.flush()
            .map_err(|e| format!("flush temp {} failed: {e}", temp.display()))?;
        file.sync_all()
            .map_err(|e| format!("fsync temp {} failed: {e}", temp.display()))?;
    }
    fs::set_permissions(&temp, fs::Permissions::from_mode(0o755))
        .map_err(|e| format!("chmod temp {} failed: {e}", temp.display()))?;
    fs::rename(&temp, target).map_err(|e| {
        format!(
            "rename {} -> {} failed: {e}",
            temp.display(),
            target.display()
        )
    })?;
    Ok(())
}

fn ensure_runtime_init_dir() -> Result<(), String> {
    let run_path = Path::new("/run");
    if !run_path.exists() {
        fs::create_dir_all(run_path).map_err(|e| format!("create /run failed: {e}"))?;
    }
    if let Err(err) = mount_tmpfs_if_needed(run_path) {
        eprintln!("warning: failed to ensure /run tmpfs: {err}");
    }
    fs::create_dir_all(RUNTIME_INIT_DIR)
        .map_err(|e| format!("create {} failed: {e}", RUNTIME_INIT_DIR))?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn mount_tmpfs_if_needed(target: &Path) -> Result<(), String> {
    match fs::read_to_string("/proc/self/mountinfo") {
        Ok(mountinfo) => {
            if mountinfo.lines().any(|line| {
                let mut fields = line.split_whitespace();
                let _mount_id = fields.next();
                let _parent_id = fields.next();
                let _major_minor = fields.next();
                let _root = fields.next();
                let mount_point = fields.next();
                mount_point == Some("/run")
            }) {
                return Ok(());
            }
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            // Early in direct-init boot, /proc may not be mounted yet. In that
            // case, optimistically attempt the tmpfs mount for /run.
        }
        Err(err) => {
            return Err(format!("read /proc/self/mountinfo failed: {err}"));
        }
    }

    let source = b"tmpfs\0";
    let fstype = b"tmpfs\0";
    let options = b"mode=0755\0";
    let target_cstr = std::ffi::CString::new(target.as_os_str().as_encoded_bytes().to_vec())
        .map_err(|e| format!("invalid /run path for mount: {e}"))?;
    let rc = unsafe {
        libc::mount(
            source.as_ptr() as *const libc::c_char,
            target_cstr.as_ptr(),
            fstype.as_ptr() as *const libc::c_char,
            0,
            options.as_ptr() as *const libc::c_void,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EBUSY) {
            Ok(())
        } else {
            Err(err.to_string())
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn mount_tmpfs_if_needed(_target: &Path) -> Result<(), String> {
    Ok(())
}

fn temp_path_for(target: &Path) -> PathBuf {
    let pid = std::process::id();
    let file_name = target
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("msl-init");
    target.with_file_name(format!(".{file_name}.tmp.{pid}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn validate_payload_rejects_small_input() {
        assert!(validate_payload(&[]).is_err());
        assert!(validate_payload(&vec![0_u8; 1024]).is_err());
        assert!(validate_payload(&vec![0_u8; 4096]).is_ok());
    }

    #[test]
    fn determine_paths_from_invocation_path() {
        assert_eq!(
            determine_init_mode(Path::new("/sbin/msl-init-bootloader")),
            "direct-init"
        );
        assert_eq!(
            determine_exec_target(Path::new("/sbin/msl-init-bootloader")),
            RUNTIME_INIT_BINARY
        );
        assert_eq!(
            determine_init_mode(Path::new("/usr/local/bin/msl-init-bootloader")),
            "service-managed-init"
        );
        assert_eq!(
            determine_exec_target(Path::new("/usr/local/bin/msl-init-bootloader")),
            RUNTIME_INIT_BINARY
        );
    }

    #[test]
    fn read_metadata_block_parses_multiple_records() {
        let bytes = metadata_bytes(&[
            (1_u8, REQUIRED_FLAG, "clock.epoch_ms=1775800000123"),
            (3_u8, 0_u8, "TZ=Asia/Tokyo"),
            (3_u8, 0_u8, "DISPLAY=/tmp/.X11-unix/X0"),
        ]);
        let records = read_metadata_block(&mut Cursor::new(bytes)).unwrap();
        assert_eq!(records.len(), 3);
        assert_eq!(records[0].target_kind, TargetKind::Bootloader);
        assert!(records[0].is_required());
        assert_eq!(records[1].target_kind, TargetKind::ExecEnv);
        assert_eq!(records[2].target_kind, TargetKind::ExecEnv);
    }

    #[test]
    fn read_metadata_block_rejects_truncated_record() {
        let mut bytes = metadata_bytes(&[(3_u8, 0_u8, "TZ=Asia/Tokyo")]);
        bytes.pop();
        assert!(read_metadata_block(&mut Cursor::new(bytes)).is_err());
    }

    #[test]
    fn read_metadata_block_rejects_invalid_utf8() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&METADATA_VERSION.to_le_bytes());
        bytes.extend_from_slice(&1_u32.to_le_bytes());
        bytes.push(TargetKind::Environment as u8);
        bytes.push(0);
        bytes.extend_from_slice(&0_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u32.to_le_bytes());
        bytes.push(0xFF);
        assert!(read_metadata_block(&mut Cursor::new(bytes)).is_err());
    }

    #[test]
    fn apply_bootloader_record_rejects_unknown_required_key() {
        let record = MetadataRecord {
            target_kind: TargetKind::Bootloader,
            flags: REQUIRED_FLAG,
            entry: "unknown.key=value".to_string(),
        };
        assert!(apply_bootloader_record(&record).is_err());
    }

    #[test]
    fn patch_environment_text_replaces_or_adds_assignments() {
        let updated = patch_environment_text(
            "PATH=\"/usr/bin\"\nTZ=\"UTC\"\n",
            &[
                "TZ=Asia/Tokyo".to_string(),
                "DISPLAY=/tmp/.X11-unix/X0".to_string(),
            ],
        )
        .unwrap();
        assert!(updated.contains("PATH=\"/usr/bin\""));
        assert!(updated.contains("TZ=\"Asia/Tokyo\""));
        assert!(updated.contains("DISPLAY=\"/tmp/.X11-unix/X0\""));
        assert!(!updated.contains("TZ=\"UTC\""));
    }

    #[test]
    fn build_exec_environment_includes_exec_env_without_persisting() {
        env::set_var("PATH", "/usr/bin");
        let envs =
            build_exec_environment(vec!["TZ=Asia/Tokyo".to_string(), "DISPLAY=:0".to_string()])
                .unwrap();
        assert!(envs
            .iter()
            .any(|(k, v)| k == &OsString::from("TZ") && v == &OsString::from("Asia/Tokyo")));
        assert!(envs
            .iter()
            .any(|(k, v)| k == &OsString::from("DISPLAY") && v == &OsString::from(":0")));
    }

    #[test]
    fn install_payload_uses_runtime_path() {
        let temp_dir =
            std::env::temp_dir().join(format!("msl-init-bootloader-test-{}", std::process::id()));
        let target = temp_dir.join("msl-init");
        let payload = vec![0_u8; MIN_PAYLOAD_BYTES];
        fs::create_dir_all(&temp_dir).unwrap();
        install_payload_at(&payload, &target).unwrap();
        assert_eq!(fs::read(&target).unwrap(), payload);
        fs::remove_dir_all(&temp_dir).unwrap();
    }

    #[test]
    fn parse_env_assignment_rejects_invalid_key() {
        assert!(parse_env_assignment("BAD.KEY=value").is_err());
        assert!(parse_env_assignment("=value").is_err());
    }

    fn metadata_bytes(records: &[(u8, u8, &str)]) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&METADATA_VERSION.to_le_bytes());
        bytes.extend_from_slice(&(records.len() as u32).to_le_bytes());
        for (target_kind, flags, entry) in records {
            bytes.push(*target_kind);
            bytes.push(*flags);
            bytes.extend_from_slice(&0_u16.to_le_bytes());
            bytes.extend_from_slice(&(entry.len() as u32).to_le_bytes());
            bytes.extend_from_slice(entry.as_bytes());
        }
        bytes
    }
}

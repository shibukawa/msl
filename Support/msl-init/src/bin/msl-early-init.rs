use std::ffi::{c_char, CString};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::process::Command;

const MS_RDONLY: usize = 1;
const MS_NOSUID: usize = 2;
const MS_NODEV: usize = 4;

extern "C" {
    fn mount(
        source: *const c_char,
        target: *const c_char,
        filesystemtype: *const c_char,
        mountflags: usize,
        data: *const c_char,
    ) -> i32;
    fn chroot(path: *const c_char) -> i32;
    fn chdir(path: *const c_char) -> i32;
}

fn main() -> Result<(), String> {
    run().map_err(|error| {
        log_console(&format!("msl-early-init: failed: {error}"));
        error
    })
}

fn run() -> Result<(), String> {
    log_console("msl-early-init: starting overlay root setup");
    mount_overlay_root()?;
    log_console("msl-early-init: switching to overlay root");
    chroot_into("/sysroot")?;
    log_console("msl-early-init: exec /sbin/msl-init-bootloader");
    let err = Command::new("/sbin/msl-init-bootloader")
        .arg("msl-init-bootloader")
        .exec();
    Err(format!("exec /sbin/msl-init-bootloader failed: {err}"))
}

fn mount_overlay_root() -> Result<(), String> {
    require_dirs(&[
        "/run",
        "/run/msl",
        "/run/msl/base",
        "/run/msl/state",
        "/sysroot",
    ])?;

    log_console("msl-early-init: mount base /dev/vda");
    mount_fs("/dev/vda", "/run/msl/base", "erofs", MS_RDONLY, None)
        .map_err(|e| format!("stage=mount_base detail={e}"))?;
    log_console("msl-early-init: mount state /dev/vdb");
    mount_fs(
        "/dev/vdb",
        "/run/msl/state",
        "btrfs",
        MS_NOSUID | MS_NODEV,
        Some("compress=zstd"),
    )
    .map_err(|e| format!("stage=mount_state detail={e}"))?;
    log_console("msl-early-init: prepare overlay upper/work");
    create_dirs(&["/run/msl/state/upper", "/run/msl/state/work"])?;
    log_console("msl-early-init: mount overlay /sysroot");
    mount_fs(
        "overlay",
        "/sysroot",
        "overlay",
        0,
        Some("lowerdir=/run/msl/base,upperdir=/run/msl/state/upper,workdir=/run/msl/state/work"),
    )
    .map_err(|e| format!("stage=mount_overlay detail={e}"))?;
    create_dirs(&[
        "/sysroot/dev",
        "/sysroot/run/msl/tmp",
        "/sysroot/run/msl/state-root",
    ])
    .map_err(|e| format!("stage=prepare_merged_tmp_mountpoint detail={e}"))?;
    log_console("msl-early-init: mount devtmpfs /sysroot/dev");
    mount_fs("devtmpfs", "/sysroot/dev", "devtmpfs", MS_NOSUID, None)
        .map_err(|e| format!("stage=mount_devtmpfs detail={e}"))?;
    log_console("msl-early-init: expose state root /sysroot/run/msl/state-root");
    mount_fs(
        "/dev/vdb",
        "/sysroot/run/msl/state-root",
        "btrfs",
        MS_NOSUID | MS_NODEV,
        Some("compress=zstd"),
    )
    .map_err(|e| format!("stage=mount_state_root detail={e}"))?;

    Ok(())
}

fn log_console(message: &str) {
    let line = format!("{message}\n");
    if let Ok(mut console) = OpenOptions::new().write(true).open("/dev/console") {
        let _ = console.write_all(line.as_bytes());
        return;
    }
    eprint!("{line}");
}

fn create_dirs(paths: &[&str]) -> Result<(), String> {
    for path in paths {
        fs::create_dir_all(path).map_err(|e| format!("failed to create {path}: {e}"))?;
    }
    Ok(())
}

fn require_dirs(paths: &[&str]) -> Result<(), String> {
    for path in paths {
        let metadata =
            fs::metadata(path).map_err(|e| format!("required directory {path} is missing: {e}"))?;
        if !metadata.is_dir() {
            return Err(format!("required path {path} is not a directory"));
        }
    }
    Ok(())
}

fn mount_fs(
    source: &str,
    target: &str,
    fstype: &str,
    flags: usize,
    data: Option<&str>,
) -> Result<(), String> {
    let source = CString::new(source).map_err(|e| format!("invalid mount source: {e}"))?;
    let target = CString::new(target).map_err(|e| format!("invalid mount target: {e}"))?;
    let fstype = CString::new(fstype).map_err(|e| format!("invalid mount fstype: {e}"))?;
    let data = match data {
        Some(value) => Some(CString::new(value).map_err(|e| format!("invalid mount data: {e}"))?),
        None => None,
    };
    let fstype_ptr = if fstype.as_bytes().is_empty() {
        std::ptr::null()
    } else {
        fstype.as_ptr()
    };
    let data_ptr = data
        .as_ref()
        .map_or(std::ptr::null(), |value| value.as_ptr());
    let ret = unsafe {
        mount(
            source.as_ptr(),
            target.as_ptr(),
            fstype_ptr,
            flags,
            data_ptr,
        )
    };
    if ret == 0 {
        return Ok(());
    }
    Err(std::io::Error::last_os_error().to_string())
}

fn chroot_into(new_root: &str) -> Result<(), String> {
    let root = CString::new(new_root).map_err(|e| format!("invalid chroot path: {e}"))?;
    let slash = CString::new("/").unwrap();
    let ret = unsafe { chroot(root.as_ptr()) };
    if ret != 0 {
        return Err(format!(
            "chroot {new_root} failed: {}",
            std::io::Error::last_os_error()
        ));
    }
    let ret = unsafe { chdir(slash.as_ptr()) };
    if ret != 0 {
        return Err(format!(
            "chdir / failed: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

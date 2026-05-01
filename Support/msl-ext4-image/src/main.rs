use ext4_lwext4::{Ext4Fs, FileBlockDevice, OpenFlags};
use std::collections::HashMap;
use std::fs as hostfs;
use std::io::{ErrorKind, Read};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

struct Options {
    rootfs: PathBuf,
    output: PathBuf,
    metadata_from_tar: PathBuf,
}

struct CopyContext {
    rootfs: PathBuf,
    // (dev, inode) -> first created guest path
    hardlinks: HashMap<(u64, u64), String>,
    metadata: HashMap<String, TarEntryMetadata>,
}

#[derive(Clone)]
struct TarEntryMetadata {
    mode: u32,
    uid: u32,
    gid: u32,
}

fn debug_enabled() -> bool {
    std::env::var("MSL_EXT4_HELPER_DEBUG")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn debug_log(message: &str) {
    if debug_enabled() {
        eprintln!("[msl-ext4-image] {message}");
    }
}

fn usage() -> &'static str {
    "usage: msl-ext4-image --rootfs <dir> --output <disk.raw> --metadata-from-tar <archive.tar.*>"
}

fn parse_args() -> Result<Options, String> {
    let mut args = std::env::args().skip(1);
    let mut rootfs: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut metadata_from_tar: Option<PathBuf> = None;

    while let Some(token) = args.next() {
        match token.as_str() {
            "--rootfs" => {
                let value = args.next().ok_or_else(|| "missing value for --rootfs".to_string())?;
                rootfs = Some(PathBuf::from(value));
            }
            "--output" => {
                let value = args.next().ok_or_else(|| "missing value for --output".to_string())?;
                output = Some(PathBuf::from(value));
            }
            "--metadata-from-tar" => {
                let value = args.next().ok_or_else(|| "missing value for --metadata-from-tar".to_string())?;
                metadata_from_tar = Some(PathBuf::from(value));
            }
            "--help" | "-h" => {
                return Err(usage().to_string());
            }
            _ => {
                return Err(format!("unknown option: {token}\n{usage}", usage = usage()));
            }
        }
    }

    let rootfs = rootfs.ok_or_else(|| format!("missing --rootfs\n{}", usage()))?;
    let output = output.ok_or_else(|| format!("missing --output\n{}", usage()))?;
    let metadata_from_tar = metadata_from_tar
        .ok_or_else(|| format!("missing --metadata-from-tar\n{}", usage()))?;
    Ok(Options {
        rootfs,
        output,
        metadata_from_tar,
    })
}

fn to_guest_path(root: &Path, source: &Path) -> Result<String, String> {
    let rel = source
        .strip_prefix(root)
        .map_err(|_| format!("path is outside rootfs: {}", source.display()))?;
    if rel.as_os_str().is_empty() {
        return Ok("/".to_string());
    }

    let mut guest = String::from("/");
    let mut first = true;
    for comp in rel.components() {
        let seg = comp
            .as_os_str()
            .to_str()
            .ok_or_else(|| format!("non-UTF8 path is unsupported: {}", source.display()))?;
        if !first {
            guest.push('/');
        }
        guest.push_str(seg);
        first = false;
    }
    Ok(guest)
}

fn normalize_tar_path(raw: &str) -> String {
    let mut path = raw.trim().to_string();
    while path.starts_with("./") {
        path = path[2..].to_string();
    }
    while path.len() > 1 && path.ends_with('/') {
        path.pop();
    }
    if path.is_empty() || path == "." {
        "/".to_string()
    } else if path.starts_with('/') {
        path
    } else {
        format!("/{}", path)
    }
}

fn parse_mode_token(token: &str) -> Option<u32> {
    let mut chars: Vec<char> = token.chars().collect();
    if chars.len() < 10 {
        return None;
    }
    chars.truncate(10);
    let mut mode = 0u32;
    let triples = [(1, 0o400, 0o200, 0o100), (4, 0o040, 0o020, 0o010), (7, 0o004, 0o002, 0o001)];
    for (idx, rbit, wbit, xbit) in triples {
        let r = chars.get(idx)?;
        let w = chars.get(idx + 1)?;
        let x = chars.get(idx + 2)?;
        if *r == 'r' {
            mode |= rbit;
        }
        if *w == 'w' {
            mode |= wbit;
        }
        match *x {
            'x' => mode |= xbit,
            's' => {
                mode |= xbit;
                if idx == 1 {
                    mode |= 0o4000;
                } else if idx == 4 {
                    mode |= 0o2000;
                }
            }
            'S' => {
                if idx == 1 {
                    mode |= 0o4000;
                } else if idx == 4 {
                    mode |= 0o2000;
                }
            }
            't' => {
                mode |= xbit;
                if idx == 7 {
                    mode |= 0o1000;
                }
            }
            'T' => {
                if idx == 7 {
                    mode |= 0o1000;
                }
            }
            _ => {}
        }
    }
    Some(mode)
}

fn parse_tar_metadata_line(line: &str) -> Option<(String, TarEntryMetadata)> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() < 9 {
        return None;
    }
    let mode = parse_mode_token(parts[0])?;
    let uid = parts[2].parse::<u32>().ok()?;
    let gid = parts[3].parse::<u32>().ok()?;
    let path = normalize_tar_path(parts[8]);
    Some((path, TarEntryMetadata { mode, uid, gid }))
}

fn load_metadata_from_tar(archive: &Path) -> Result<HashMap<String, TarEntryMetadata>, String> {
    let tar = if Path::new("/usr/bin/tar").is_file() {
        "/usr/bin/tar".to_string()
    } else {
        "tar".to_string()
    };
    let output = std::process::Command::new(tar)
        .arg("--numeric-owner")
        .arg("-tvf")
        .arg(archive)
        .output()
        .map_err(|e| format!("failed to list tar metadata for {}: {}", archive.display(), e))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(format!(
            "tar metadata listing failed for {}: {}",
            archive.display(),
            stderr
        ));
    }
    let mut map = HashMap::new();
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if let Some((path, meta)) = parse_tar_metadata_line(line) {
            map.insert(path, meta);
        }
    }
    Ok(map)
}

fn apply_mode_and_owner(
    fs: &Ext4Fs,
    guest_path: &str,
    meta: &hostfs::Metadata,
    tar_metadata: &HashMap<String, TarEntryMetadata>,
) -> Result<(), String> {
    let mut mode = meta.mode() & 0o7777;
    let uid = meta.uid();
    let gid = meta.gid();
    let (uid, gid) = if let Some(record) = tar_metadata.get(guest_path) {
        mode = record.mode;
        (record.uid, record.gid)
    } else {
        (uid, gid)
    };
    fs.set_permissions(guest_path, mode)
        .map_err(|e| format!("chmod failed for {guest_path}: {e}"))?;
    fs.set_owner(guest_path, uid, gid)
        .map_err(|e| format!("chown failed for {guest_path}: {e}"))?;
    Ok(())
}

fn copy_directory(fs: &Ext4Fs, ctx: &mut CopyContext, source_dir: &Path) -> Result<(), String> {
    let guest_dir = to_guest_path(&ctx.rootfs, source_dir)?;
    debug_log(&format!("copy dir {} -> {}", source_dir.display(), guest_dir));
    let meta = hostfs::symlink_metadata(source_dir)
        .map_err(|e| format!("stat failed for {}: {e}", source_dir.display()))?;

    if guest_dir != "/" && !fs.exists(&guest_dir) {
        fs.mkdir(&guest_dir, meta.mode() & 0o7777)
            .map_err(|e| format!("mkdir failed for {guest_dir}: {e}"))?;
    }
    if guest_dir != "/" {
        apply_mode_and_owner(fs, &guest_dir, &meta, &ctx.metadata)?;
    }

    let mut children: Vec<PathBuf> = Vec::new();
    let iter = match hostfs::read_dir(source_dir) {
        Ok(iter) => iter,
        Err(err) if err.kind() == ErrorKind::PermissionDenied => {
            eprintln!(
                "warning: skipping unreadable directory {}: {}",
                source_dir.display(),
                err
            );
            return Ok(());
        }
        Err(err) => {
            return Err(format!("read_dir failed for {}: {err}", source_dir.display()));
        }
    };
    for entry in iter {
        let entry = entry.map_err(|e| format!("read_dir entry failed: {e}"))?;
        children.push(entry.path());
    }
    children.sort();

    for child in children {
        copy_entry(fs, ctx, &child)?;
    }

    Ok(())
}

fn copy_regular_file(
    fs: &Ext4Fs,
    ctx: &mut CopyContext,
    source: &Path,
    meta: &hostfs::Metadata,
    guest_path: &str,
) -> Result<(), String> {
    debug_log(&format!("copy file {} -> {}", source.display(), guest_path));
    let link_key = (meta.dev(), meta.ino());
    if meta.nlink() > 1 {
        if let Some(existing) = ctx.hardlinks.get(&link_key) {
            fs.link(existing, guest_path)
                .map_err(|e| format!("hardlink failed {} -> {}: {e}", existing, guest_path))?;
            return Ok(());
        }
    }

    let mut src_file = open_source_file_for_copy(source, meta)?;
    let mut dst_file = fs
        .open(
            guest_path,
            OpenFlags::CREATE | OpenFlags::WRITE | OpenFlags::TRUNCATE,
        )
        .map_err(|e| format!("open destination failed for {guest_path}: {e}"))?;

    let mut buf = vec![0u8; 1024 * 1024];
    loop {
        let read = src_file
            .read(&mut buf)
            .map_err(|e| format!("read source failed for {}: {e}", source.display()))?;
        if read == 0 {
            break;
        }
        dst_file
            .write_all(&buf[..read])
            .map_err(|e| format!("write destination failed for {guest_path}: {e}"))?;
    }
    dst_file
        .sync()
        .map_err(|e| format!("sync destination failed for {guest_path}: {e}"))?;
    drop(dst_file);

    apply_mode_and_owner(fs, guest_path, meta, &ctx.metadata)?;

    if meta.nlink() > 1 {
        ctx.hardlinks.insert(link_key, guest_path.to_string());
    }

    Ok(())
}

fn open_source_file_for_copy(source: &Path, meta: &hostfs::Metadata) -> Result<hostfs::File, String> {
    match hostfs::File::open(source) {
        Ok(file) => Ok(file),
        Err(err) if err.kind() == ErrorKind::PermissionDenied => {
            let original_mode = meta.mode() & 0o7777;
            let relaxed_mode = original_mode | 0o400;
            if relaxed_mode == original_mode {
                return Err(format!("open source failed for {}: {err}", source.display()));
            }

            debug_log(&format!(
                "temporarily adding owner-read to {} (mode {:o} -> {:o})",
                source.display(),
                original_mode,
                relaxed_mode
            ));
            hostfs::set_permissions(source, hostfs::Permissions::from_mode(relaxed_mode))
                .map_err(|chmod_err| {
                    format!(
                        "open source failed for {}: {err}; chmod fallback failed: {chmod_err}",
                        source.display()
                    )
                })?;

            let reopen_result = hostfs::File::open(source).map_err(|reopen_err| {
                format!(
                    "open source failed for {} after chmod fallback: {reopen_err}",
                    source.display()
                )
            });
            let restore_result = hostfs::set_permissions(source, hostfs::Permissions::from_mode(original_mode));
            if let Err(restore_err) = restore_result {
                return Err(format!(
                    "restoring original mode failed for {}: {restore_err}",
                    source.display()
                ));
            }
            reopen_result
        }
        Err(err) => Err(format!("open source failed for {}: {err}", source.display())),
    }
}

fn copy_symlink(fs: &Ext4Fs, ctx: &CopyContext, source: &Path, guest_path: &str) -> Result<(), String> {
    debug_log(&format!("copy symlink {} -> {}", source.display(), guest_path));
    let target = hostfs::read_link(source)
        .map_err(|e| format!("readlink failed for {}: {e}", source.display()))?;
    let target_str = target
        .to_str()
        .ok_or_else(|| format!("non-UTF8 symlink target at {}", source.display()))?;

    if fs.exists(guest_path) {
        fs.remove(guest_path)
            .map_err(|e| format!("remove existing path failed for {guest_path}: {e}"))?;
    }

    fs.symlink(target_str, guest_path)
        .map_err(|e| format!("symlink create failed for {} -> {}: {e}", guest_path, target_str))?;

    // symlink ownership/permissions are platform- and backend-dependent; skip explicit mutation.
    let _ = ctx;
    Ok(())
}

fn copy_entry(fs: &Ext4Fs, ctx: &mut CopyContext, source: &Path) -> Result<(), String> {
    let meta = hostfs::symlink_metadata(source)
        .map_err(|e| format!("stat failed for {}: {e}", source.display()))?;
    let guest_path = to_guest_path(&ctx.rootfs, source)?;

    if meta.file_type().is_dir() {
        return copy_directory(fs, ctx, source);
    }
    if meta.file_type().is_symlink() {
        return copy_symlink(fs, ctx, source, &guest_path);
    }
    if meta.file_type().is_file() {
        return copy_regular_file(fs, ctx, source, &meta, &guest_path);
    }

    eprintln!(
        "warning: skipping unsupported special file {} (mode {:o})",
        source.display(),
        meta.mode()
    );
    Ok(())
}

fn run(options: Options) -> Result<(), String> {
    if !options.rootfs.is_dir() {
        return Err(format!("rootfs is not a directory: {}", options.rootfs.display()));
    }
    if !options.output.is_file() {
        return Err(format!(
            "output image does not exist (run mkfs helper first): {}",
            options.output.display()
        ));
    }

    debug_log("reopening and mounting filesystem");
    let device = FileBlockDevice::open(&options.output)
        .map_err(|e| format!("failed to reopen output image {}: {e}", options.output.display()))?;
    let fs = Ext4Fs::mount(device, false).map_err(|e| format!("mount failed: {e}"))?;

    let mut ctx = CopyContext {
        rootfs: options.rootfs,
        hardlinks: HashMap::new(),
        metadata: load_metadata_from_tar(&options.metadata_from_tar)?,
    };

    let rootfs = ctx.rootfs.clone();
    debug_log("copying rootfs");
    copy_directory(&fs, &mut ctx, &rootfs)?;

    debug_log("syncing filesystem");
    fs.sync().map_err(|e| format!("sync failed: {e}"))?;
    debug_log("completed");
    Ok(())
}

fn main() {
    let options = match parse_args() {
        Ok(v) => v,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(2);
        }
    };

    if let Err(err) = run(options) {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_path(name: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        std::env::temp_dir().join(format!("msl-ext4-image-{name}-{nanos}"))
    }

    #[test]
    fn open_source_file_for_copy_temporarily_relaxes_owner_read() {
        let path = temp_path("owner-read");
        let mut file = fs::File::create(&path).expect("create");
        writeln!(file, "hello").expect("write");
        drop(file);

        fs::set_permissions(&path, fs::Permissions::from_mode(0o111)).expect("chmod 111");
        let meta = fs::symlink_metadata(&path).expect("metadata");

        let mut reopened = open_source_file_for_copy(&path, &meta).expect("reopen");
        let mut content = String::new();
        reopened.read_to_string(&mut content).expect("read");
        assert!(content.contains("hello"));

        let restored = fs::symlink_metadata(&path).expect("metadata restored");
        assert_eq!(restored.mode() & 0o7777, 0o111);

        fs::remove_file(&path).expect("cleanup");
    }

    #[test]
    fn tar_metadata_parser_preserves_setuid_owner_and_mode() {
        let line = "---s--x--x  0 0      0      204576 Jul  1  2025 ./usr/bin/sudo";
        let (path, meta) = parse_tar_metadata_line(line).expect("parse tar metadata");

        assert_eq!(path, "/usr/bin/sudo");
        assert_eq!(meta.uid, 0);
        assert_eq!(meta.gid, 0);
        assert_eq!(meta.mode, 0o4111);
    }
}

use ext4_mkfs::{mkfs, FsType, IoBlockDevice, MkfsConfig};
use std::fs::OpenOptions;
use std::path::PathBuf;

struct Options {
    output: PathBuf,
    size_bytes: u64,
}

fn usage() -> &'static str {
    "usage: msl-ext4-mkfs --output <disk.raw> [--size-gb <n> | --size-mb <n>]"
}

fn parse_args() -> Result<Options, String> {
    let mut args = std::env::args().skip(1);
    let mut output: Option<PathBuf> = None;
    let mut size_gb: u64 = 8;
    let mut size_mb: Option<u64> = None;

    while let Some(token) = args.next() {
        match token.as_str() {
            "--output" => {
                let value = args.next().ok_or_else(|| "missing value for --output".to_string())?;
                output = Some(PathBuf::from(value));
            }
            "--size-gb" => {
                let value = args.next().ok_or_else(|| "missing value for --size-gb".to_string())?;
                if size_mb.is_some() {
                    return Err("use either --size-gb or --size-mb, not both".to_string());
                }
                size_gb = value
                    .parse::<u64>()
                    .map_err(|_| "--size-gb must be a positive integer".to_string())?;
                if size_gb == 0 {
                    return Err("--size-gb must be >= 1".to_string());
                }
            }
            "--size-mb" => {
                let value = args.next().ok_or_else(|| "missing value for --size-mb".to_string())?;
                size_mb = Some(
                    value
                        .parse::<u64>()
                        .map_err(|_| "--size-mb must be a positive integer".to_string())?,
                );
                if size_mb == Some(0) {
                    return Err("--size-mb must be >= 1".to_string());
                }
            }
            "--help" | "-h" => {
                return Err(usage().to_string());
            }
            _ => {
                return Err(format!("unknown option: {token}\n{usage}", usage = usage()));
            }
        }
    }

    let output = output.ok_or_else(|| format!("missing --output\n{}", usage()))?;
    let size_bytes = if let Some(mb) = size_mb {
        mb.checked_mul(1024)
            .and_then(|v| v.checked_mul(1024))
            .ok_or_else(|| "disk size overflow".to_string())?
    } else {
        size_gb
            .checked_mul(1024)
            .and_then(|v| v.checked_mul(1024))
            .and_then(|v| v.checked_mul(1024))
            .ok_or_else(|| "disk size overflow".to_string())?
    };

    Ok(Options { output, size_bytes })
}

fn run(options: Options) -> Result<(), String> {
    let parent = options
        .output
        .parent()
        .ok_or_else(|| format!("invalid output path: {}", options.output.display()))?;
    std::fs::create_dir_all(parent)
        .map_err(|e| format!("failed to create output directory {}: {e}", parent.display()))?;

    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(&options.output)
        .map_err(|e| format!("failed to create output image {}: {e}", options.output.display()))?;
    file.set_len(options.size_bytes)
        .map_err(|e| format!("failed to allocate output image {}: {e}", options.output.display()))?;

    let device = IoBlockDevice::new(file, 512, options.size_bytes);
    let config = MkfsConfig::new()
        .fs_type(FsType::Ext4)
        .block_size(4096)
        .inode_size(256)
        .journal(true)
        .label("msl-rootfs");
    mkfs(device, config).map_err(|e| format!("mkfs failed: {e}"))?;
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

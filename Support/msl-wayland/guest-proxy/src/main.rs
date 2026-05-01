use std::env;
use std::path::Path;
use std::process::{Command, Stdio};
use tokio::io;
use tokio::net::UnixListener;
use tokio::task::JoinSet;

#[tokio::main]
async fn main() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let mut display_name = env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".to_string());
    let mut display_port = env::var("MSL_DISPLAY_VSOCK_PORT").unwrap_or_else(|_| "38000".to_string());
    let mut command: Vec<String> = Vec::new();

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--display" => {
                display_name = args.next().ok_or("missing value for --display")?;
            }
            "--port" => {
                display_port = args.next().ok_or("missing value for --port")?;
            }
            "--" => {
                command.extend(args);
                break;
            }
            other => {
                command.push(other.to_string());
                command.extend(args);
                break;
            }
        }
    }

    let runtime_dir = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    let socket_path = format!("{}/{}", runtime_dir, display_name);
    if Path::new(&socket_path).exists() {
        let _ = std::fs::remove_file(&socket_path);
    }
    let listener = UnixListener::bind(&socket_path).map_err(|e| format!("bind {} failed: {}", socket_path, e))?;
    eprintln!(
        "msl-wayland-proxy listening socket={} display_port={}",
        socket_path, display_port
    );

    let mut child = if command.is_empty() {
        None
    } else {
        let mut cmd = Command::new(&command[0]);
        cmd.args(&command[1..]);
        cmd.env("WAYLAND_DISPLAY", &display_name);
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::inherit());
        cmd.stderr(Stdio::inherit());
        Some(cmd.spawn().map_err(|e| format!("spawn {} failed: {}", command[0], e))?)
    };

    let mut tasks = JoinSet::new();
    loop {
        tokio::select! {
            accept = listener.accept() => {
                let (stream, _) = accept.map_err(|e| format!("accept failed: {}", e))?;
                let port = display_port.clone();
                tasks.spawn(async move {
                    if let Err(err) = proxy_client(stream, &port).await {
                        eprintln!("proxy client failed: {}", err);
                    }
                });
            }
            _ = tokio::signal::ctrl_c() => {
                break;
            }
            else => {
                if let Some(child) = child.as_mut() {
                    if let Ok(Some(_status)) = child.try_wait() {
                        break;
                    }
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        }
    }

    tasks.abort_all();
    if let Some(child) = child.as_mut() {
        let _ = child.kill();
    }
    let _ = std::fs::remove_file(&socket_path);
    Ok(())
}

async fn proxy_client(
    mut stream: tokio::net::UnixStream,
    display_port: &str,
) -> Result<(), String> {
    eprintln!("accepted wayland client for display port {}", display_port);
    let mut sink = io::sink();
    io::copy(&mut stream, &mut sink)
        .await
        .map_err(|e| format!("stream drain failed: {}", e))?;
    Ok(())
}

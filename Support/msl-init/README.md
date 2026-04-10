# msl-init (Rust scaffold)

Minimal guest-side init/control server scaffold for Step3 init-first work.
The crate now builds two guest binaries:
- `msl-init-bootloader`: minimal vsock bootstrap loader
- `msl-init`: main guest init/control server

## Build

```bash
cd Support/msl-init
cargo build --release --target aarch64-unknown-linux-musl
```

If target is missing:

```bash
rustup target add aarch64-unknown-linux-musl
```

Output:
- `target/aarch64-unknown-linux-musl/release/msl-init`
- `target/aarch64-unknown-linux-musl/release/msl-init-bootloader`

## Run locally (host-side simulation)

```bash
MSL_INIT_HANDOFF_FILE=/tmp/msl-init-handoff.json \
MSL_INIT_ACK_FILE=/tmp/msl-init-ack.json \
./target/release/msl-init
```

The server accepts JSON requests via file handoff for:
- `ping`
- `converge_status`
- `exec`
- `pty_open`
- `pty_read`
- `pty_write`
- `pty_resize`
- `pty_close`
- `proc_open`
- `proc_read`
- `proc_write`
- `proc_close`

Environment variables:
- `MSL_INIT_HANDOFF_FILE` (default: `/mnt/macos/home/.msl/init-channel-handoff.json`)
- `MSL_INIT_ACK_FILE` (default: `/mnt/macos/home/.msl/init-channel-ack.json`)

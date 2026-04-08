# docker-socket-proxy

UNIX domain socket logging proxy for comparing Docker-compatible traffic.

## Usage

```sh
go run . \
  -listen /tmp/docker-proxy.sock \
  -upstream "$HOME/.docker/run/docker.sock" \
  -log-file /tmp/docker-proxy.jsonl
```

Then point the client at the proxy:

```sh
DOCKER_HOST=unix:///tmp/docker-proxy.sock docker inspect alpine
```

## Logged events

- `proxy_listen_started`
- `proxy_client_accepted`
- `proxy_stream_summary`
- `proxy_connection_closed`
- `proxy_stream_error`

Each `proxy_stream_summary` record contains:

- `direction`: `request` or `response`
- `total_bytes`
- `captured_bytes`
- `truncated`
- `first_line`
- `preview_encoding`: `utf8` or `base64`
- `preview`

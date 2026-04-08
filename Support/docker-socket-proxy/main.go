package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

type config struct {
	listenPath      string
	upstreamPath    string
	logFilePath     string
	maxPreviewBytes int
}

type jsonLogger struct {
	mu sync.Mutex
	w  io.Writer
}

type captureBuffer struct {
	mu       sync.Mutex
	limit    int
	total    int64
	truncated bool
	data     []byte
}

type streamSummary struct {
	Direction       string `json:"direction"`
	TotalBytes      int64  `json:"total_bytes"`
	CapturedBytes   int    `json:"captured_bytes"`
	Truncated       bool   `json:"truncated"`
	FirstLine       string `json:"first_line,omitempty"`
	PreviewEncoding string `json:"preview_encoding"`
	Preview         string `json:"preview"`
}

func main() {
	cfg := parseFlags()
	if err := run(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "docker-socket-proxy: %v\n", err)
		os.Exit(1)
	}
}

func parseFlags() config {
	cfg := config{}
	flag.StringVar(&cfg.listenPath, "listen", "", "UNIX socket path to listen on")
	flag.StringVar(&cfg.upstreamPath, "upstream", "", "UNIX socket path to forward to")
	flag.StringVar(&cfg.logFilePath, "log-file", "", "Optional JSONL log file path (default: stderr)")
	flag.IntVar(&cfg.maxPreviewBytes, "max-preview-bytes", 16*1024, "Max preview bytes captured per direction")
	flag.Parse()

	if cfg.listenPath == "" || cfg.upstreamPath == "" {
		fmt.Fprintln(os.Stderr, "usage: docker-socket-proxy -listen /tmp/proxy.sock -upstream /path/to/docker.sock [-log-file proxy.jsonl]")
		os.Exit(2)
	}
	if cfg.maxPreviewBytes <= 0 {
		fmt.Fprintln(os.Stderr, "-max-preview-bytes must be > 0")
		os.Exit(2)
	}
	return cfg
}

func run(cfg config) error {
	logWriter := io.Writer(os.Stderr)
	var file *os.File
	var err error
	if cfg.logFilePath != "" {
		file, err = os.OpenFile(cfg.logFilePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return fmt.Errorf("open log file: %w", err)
		}
		defer file.Close()
		logWriter = file
	}
	logger := &jsonLogger{w: logWriter}

	if err := os.RemoveAll(cfg.listenPath); err != nil {
		return fmt.Errorf("remove stale listen socket: %w", err)
	}

	listener, err := net.Listen("unix", cfg.listenPath)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.listenPath, err)
	}
	defer func() {
		_ = listener.Close()
		_ = os.Remove(cfg.listenPath)
	}()
	_ = os.Chmod(cfg.listenPath, 0o600)

	logger.log("proxy_listen_started", map[string]any{
		"listen":            cfg.listenPath,
		"upstream":          cfg.upstreamPath,
		"max_preview_bytes": cfg.maxPreviewBytes,
	})

	stopCh := make(chan os.Signal, 1)
	signal.Notify(stopCh, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(stopCh)
	go func() {
		<-stopCh
		logger.log("proxy_shutdown_requested", map[string]any{
			"listen": cfg.listenPath,
		})
		_ = listener.Close()
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			if isClosedListener(err) {
				logger.log("proxy_listen_stopped", map[string]any{
					"listen": cfg.listenPath,
				})
				return nil
			}
			logger.log("proxy_accept_failed", map[string]any{
				"listen": cfg.listenPath,
				"error":  err.Error(),
			})
			continue
		}

		id := randomID()
		logger.log("proxy_client_accepted", map[string]any{
			"connection_id": id,
			"listen":        cfg.listenPath,
			"upstream":      cfg.upstreamPath,
		})
		go handleConnection(id, conn, cfg, logger)
	}
}

func handleConnection(id string, client net.Conn, cfg config, logger *jsonLogger) {
	defer client.Close()

	upstream, err := net.Dial("unix", cfg.upstreamPath)
	if err != nil {
		logger.log("proxy_upstream_connect_failed", map[string]any{
			"connection_id": id,
			"upstream":      cfg.upstreamPath,
			"error":         err.Error(),
		})
		return
	}
	defer upstream.Close()

	requestCapture := &captureBuffer{limit: cfg.maxPreviewBytes}
	responseCapture := &captureBuffer{limit: cfg.maxPreviewBytes}

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		err := proxyStream(upstream, client, requestCapture)
		if err != nil {
			logger.log("proxy_stream_error", map[string]any{
				"connection_id": id,
				"direction":     "request",
				"error":         err.Error(),
			})
		}
	}()

	go func() {
		defer wg.Done()
		err := proxyStream(client, upstream, responseCapture)
		if err != nil {
			logger.log("proxy_stream_error", map[string]any{
				"connection_id": id,
				"direction":     "response",
				"error":         err.Error(),
			})
		}
	}()

	wg.Wait()

	for _, summary := range []streamSummary{
		requestCapture.summary("request"),
		responseCapture.summary("response"),
	} {
		logger.log("proxy_stream_summary", map[string]any{
			"connection_id":     id,
			"direction":         summary.Direction,
			"total_bytes":       summary.TotalBytes,
			"captured_bytes":    summary.CapturedBytes,
			"truncated":         summary.Truncated,
			"first_line":        summary.FirstLine,
			"preview_encoding":  summary.PreviewEncoding,
			"preview":           summary.Preview,
		})
	}

	logger.log("proxy_connection_closed", map[string]any{
		"connection_id": id,
	})
}

func proxyStream(dst net.Conn, src net.Conn, capture *captureBuffer) error {
	_, err := io.CopyBuffer(io.MultiWriter(dst, capture), src, make([]byte, 32*1024))
	if closeWriter, ok := dst.(interface{ CloseWrite() error }); ok {
		_ = closeWriter.CloseWrite()
	}
	if err != nil && !isExpectedClose(err) {
		return err
	}
	return nil
}

func (c *captureBuffer) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.total += int64(len(p))
	if len(c.data) < c.limit {
		remaining := c.limit - len(c.data)
		if remaining > len(p) {
			remaining = len(p)
		}
		c.data = append(c.data, p[:remaining]...)
	}
	if int(c.total) > len(c.data) {
		c.truncated = true
	}
	return len(p), nil
}

func (c *captureBuffer) summary(direction string) streamSummary {
	c.mu.Lock()
	defer c.mu.Unlock()

	preview := append([]byte(nil), c.data...)
	firstLine := extractFirstLine(preview)
	if looksLikeText(preview) {
		return streamSummary{
			Direction:       direction,
			TotalBytes:      c.total,
			CapturedBytes:   len(preview),
			Truncated:       c.truncated,
			FirstLine:       firstLine,
			PreviewEncoding: "utf8",
			Preview:         string(preview),
		}
	}
	return streamSummary{
		Direction:       direction,
		TotalBytes:      c.total,
		CapturedBytes:   len(preview),
		Truncated:       c.truncated,
		FirstLine:       firstLine,
		PreviewEncoding: "base64",
		Preview:         base64.StdEncoding.EncodeToString(preview),
	}
}

func extractFirstLine(data []byte) string {
	if len(data) == 0 {
		return ""
	}
	line := data
	if idx := bytes.Index(line, []byte("\r\n")); idx >= 0 {
		line = line[:idx]
	} else if idx := bytes.IndexByte(line, '\n'); idx >= 0 {
		line = line[:idx]
	}
	if !looksLikeText(line) {
		return ""
	}
	return string(line)
}

func looksLikeText(data []byte) bool {
	if len(data) == 0 {
		return true
	}
	if !utf8Safe(data) {
		return false
	}
	for _, b := range data {
		switch {
		case b == '\n', b == '\r', b == '\t':
		case b >= 0x20 && b < 0x7f:
		default:
			return false
		}
	}
	return true
}

func utf8Safe(data []byte) bool {
	return bytes.Equal(bytes.ToValidUTF8(data, []byte{}), data)
}

func isClosedListener(err error) bool {
	if err == nil {
		return false
	}
	return err == net.ErrClosed || err.Error() == "accept unix: use of closed network connection"
}

func isExpectedClose(err error) bool {
	if err == nil {
		return false
	}
	return err == io.EOF ||
		err == net.ErrClosed ||
		err.Error() == "read unix @->@: use of closed network connection" ||
		err.Error() == "write unix @->@: broken pipe"
}

func randomID() string {
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return fmt.Sprintf("conn-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf[:])
}

func (l *jsonLogger) log(event string, fields map[string]any) {
	record := map[string]any{
		"ts":    time.Now().UnixMilli(),
		"event": event,
	}
	for key, value := range fields {
		record[key] = value
	}
	data, err := json.Marshal(record)
	if err != nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = l.w.Write(append(data, '\n'))
}

package main

import (
	"encoding/base64"
	"testing"
)

func TestExtractFirstLine(t *testing.T) {
	line := extractFirstLine([]byte("GET /_ping HTTP/1.1\r\nHost: docker\r\n\r\n"))
	if line != "GET /_ping HTTP/1.1" {
		t.Fatalf("unexpected first line: %q", line)
	}
}

func TestCaptureSummaryUsesUTF8PreviewForText(t *testing.T) {
	buf := &captureBuffer{limit: 64}
	_, _ = buf.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))

	summary := buf.summary("response")
	if summary.PreviewEncoding != "utf8" {
		t.Fatalf("expected utf8 preview, got %q", summary.PreviewEncoding)
	}
	if summary.FirstLine != "HTTP/1.1 200 OK" {
		t.Fatalf("unexpected first line: %q", summary.FirstLine)
	}
}

func TestCaptureSummaryFallsBackToBase64ForBinary(t *testing.T) {
	buf := &captureBuffer{limit: 64}
	payload := []byte{0x00, 0x01, 0x02, 0xff}
	_, _ = buf.Write(payload)

	summary := buf.summary("response")
	if summary.PreviewEncoding != "base64" {
		t.Fatalf("expected base64 preview, got %q", summary.PreviewEncoding)
	}
	if summary.Preview != base64.StdEncoding.EncodeToString(payload) {
		t.Fatalf("unexpected preview: %q", summary.Preview)
	}
}

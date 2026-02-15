package httpmux

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

func TestAddRemovePadding_RoundTrip(t *testing.T) {
	data := []byte("hello world, this is test data")
	obfs := &ObfsConfig{
		Enabled:    true,
		MinPadding: 4,
		MaxPadding: 32,
	}

	padded := addPadding(data, obfs)

	// Padded should be larger
	if len(padded) <= len(data) {
		t.Fatalf("padded length (%d) should be > original (%d)", len(padded), len(data))
	}

	// Must have at least 2B header + data + minPadding
	minExpected := 2 + len(data) + obfs.MinPadding
	if len(padded) < minExpected {
		t.Fatalf("padded length (%d) should be >= %d", len(padded), minExpected)
	}

	// Round trip
	result := removePadding(padded)
	if result == nil {
		t.Fatal("removePadding returned nil")
	}
	if !bytes.Equal(result, data) {
		t.Fatalf("round trip failed: got %q, want %q", result, data)
	}
}

func TestRemovePadding_TooShort(t *testing.T) {
	result := removePadding([]byte{0})
	if result != nil {
		t.Fatal("should return nil for data < 2 bytes")
	}
}

func TestRemovePadding_InvalidLength(t *testing.T) {
	// Header says 100 bytes but only 5 available
	data := make([]byte, 7) // 2 header + 5 payload
	binary.BigEndian.PutUint16(data[:2], 100)
	result := removePadding(data)
	if result != nil {
		t.Fatal("should return nil for invalid length header")
	}
}

func TestSendTarget_RoundTrip(t *testing.T) {
	var buf bytes.Buffer
	target := "tcp://127.0.0.1:8080"

	err := sendTarget(&buf, target)
	if err != nil {
		t.Fatalf("sendTarget failed: %v", err)
	}

	// Read it back
	hdr := make([]byte, 2)
	if _, err := io.ReadFull(&buf, hdr); err != nil {
		t.Fatalf("reading header: %v", err)
	}
	tLen := binary.BigEndian.Uint16(hdr)
	tBuf := make([]byte, tLen)
	if _, err := io.ReadFull(&buf, tBuf); err != nil {
		t.Fatalf("reading target: %v", err)
	}

	if string(tBuf) != target {
		t.Fatalf("got %q, want %q", string(tBuf), target)
	}
}

func TestSplitMap_Valid(t *testing.T) {
	tests := []struct {
		input  string
		bind   string
		target string
	}{
		{"1080->127.0.0.1:8080", "0.0.0.0:1080", "127.0.0.1:8080"},
		{"0.0.0.0:443->192.168.1.1:443", "0.0.0.0:443", "192.168.1.1:443"},
	}
	for _, tt := range tests {
		bind, target, ok := SplitMap(tt.input)
		if !ok {
			t.Fatalf("SplitMap(%q) returned false", tt.input)
		}
		if bind != tt.bind {
			t.Errorf("bind: got %q, want %q", bind, tt.bind)
		}
		if target != tt.target {
			t.Errorf("target: got %q, want %q", target, tt.target)
		}
	}
}

func TestSplitMap_Invalid(t *testing.T) {
	invalids := []string{"", "nope", "->", "->target", "bind->"}
	for _, s := range invalids {
		_, _, ok := SplitMap(s)
		if ok {
			t.Errorf("SplitMap(%q) should return false", s)
		}
	}
}

func TestSplitTarget(t *testing.T) {
	network, addr := splitTarget("tcp://127.0.0.1:80")
	if network != "tcp" || addr != "127.0.0.1:80" {
		t.Errorf("tcp: got %s://%s", network, addr)
	}

	network, addr = splitTarget("udp://10.0.0.1:53")
	if network != "udp" || addr != "10.0.0.1:53" {
		t.Errorf("udp: got %s://%s", network, addr)
	}
}

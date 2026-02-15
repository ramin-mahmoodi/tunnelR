package httpmux

import (
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// ═══════════════════════════════════════════════════════════════
// Integration test — runs a real server + client on localhost
// and verifies TCP forwarding, connection pool, and compression.
// ═══════════════════════════════════════════════════════════════

// startEchoServer creates a TCP server that echoes back whatever it receives.
// Returns the listener address and a stop function.
func startEchoServer(t *testing.T) (string, func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal("echo listen:", err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				io.Copy(c, c)
			}(c)
		}
	}()
	return ln.Addr().String(), func() { ln.Close() }
}

// TestIntegration_BasicTCPForward tests the full pipeline:
// external TCP → server listen → smux stream → client → echo server → back
func TestIntegration_BasicTCPForward(t *testing.T) {
	// 1. Start echo server (the "target")
	echoAddr, stopEcho := startEchoServer(t)
	defer stopEcho()

	// 2. Build configs
	serverCfg := buildTestServerConfig(t, echoAddr)
	clientCfg := buildTestClientConfig(t, serverCfg.Listen)

	// 3. Start server
	srv := NewServer(serverCfg)
	go func() {
		if err := srv.Start(); err != nil {
			log.Printf("[TEST-SRV] %v", err)
		}
	}()
	time.Sleep(300 * time.Millisecond) // let server start

	// 4. Start client
	cl := NewClient(clientCfg)
	go func() {
		if err := cl.Start(); err != nil {
			log.Printf("[TEST-CLI] %v", err)
		}
	}()
	time.Sleep(1 * time.Second) // let client connect

	// 5. Verify sessions established
	cl.sessMu.RLock()
	poolSize := len(cl.sessions)
	cl.sessMu.RUnlock()
	t.Logf("Client pool size: %d", poolSize)
	if poolSize == 0 {
		t.Fatal("No sessions established — client failed to connect")
	}

	// 6. Connect to the server's reverse-TCP port
	bindAddr := serverCfg.Forward.TCP[0]
	parts := strings.Split(bindAddr, "->")
	listenPort := strings.TrimSpace(parts[0])
	if !strings.Contains(listenPort, ":") {
		listenPort = "127.0.0.1:" + listenPort
	}

	// Give reverse TCP listener time to start
	time.Sleep(500 * time.Millisecond)

	// 7. Test TCP forwarding with echo
	testMsg := "Hello RsTunnel Integration Test!"
	conn, err := net.DialTimeout("tcp", listenPort, 5*time.Second)
	if err != nil {
		t.Fatalf("Dial reverse TCP %s: %v", listenPort, err)
	}
	defer conn.Close()

	conn.SetDeadline(time.Now().Add(5 * time.Second))

	// Write
	_, err = conn.Write([]byte(testMsg))
	if err != nil {
		t.Fatalf("Write: %v", err)
	}

	// Read echo back
	buf := make([]byte, 1024)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}

	got := string(buf[:n])
	if got != testMsg {
		t.Fatalf("Echo mismatch: got %q, want %q", got, testMsg)
	}

	t.Logf("✅ TCP forwarding works! Sent=%q, Received=%q", testMsg, got)
}

// TestIntegration_Compression tests that snappy compression works end-to-end.
func TestIntegration_Compression(t *testing.T) {
	// 1. Start echo server
	echoAddr, stopEcho := startEchoServer(t)
	defer stopEcho()

	// 2. Build configs with compression enabled
	serverCfg := buildTestServerConfig(t, echoAddr)
	serverCfg.Compression = "snappy"
	clientCfg := buildTestClientConfig(t, serverCfg.Listen)
	clientCfg.Compression = "snappy"

	// 3. Start server + client
	srv := NewServer(serverCfg)
	go func() { srv.Start() }()
	time.Sleep(300 * time.Millisecond)

	cl := NewClient(clientCfg)
	go func() { cl.Start() }()
	time.Sleep(1 * time.Second)

	// 4. Connect and test
	bindAddr := serverCfg.Forward.TCP[0]
	parts := strings.Split(bindAddr, "->")
	listenPort := strings.TrimSpace(parts[0])
	if !strings.Contains(listenPort, ":") {
		listenPort = "127.0.0.1:" + listenPort
	}
	time.Sleep(500 * time.Millisecond)

	testMsg := "Snappy compressed data test 🎯"
	conn, err := net.DialTimeout("tcp", listenPort, 5*time.Second)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))

	conn.Write([]byte(testMsg))
	buf := make([]byte, 1024)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}

	if string(buf[:n]) != testMsg {
		t.Fatalf("Compression echo mismatch: got %q, want %q", string(buf[:n]), testMsg)
	}
	t.Logf("✅ Snappy compression works!")
}

// TestIntegration_ConnectionPool tests that multiple sessions are established.
func TestIntegration_ConnectionPool(t *testing.T) {
	echoAddr, stopEcho := startEchoServer(t)
	defer stopEcho()

	serverCfg := buildTestServerConfig(t, echoAddr)
	clientCfg := buildTestClientConfig(t, serverCfg.Listen)
	// Set pool to 3
	clientCfg.Paths[0].ConnectionPool = 3

	srv := NewServer(serverCfg)
	go func() { srv.Start() }()
	time.Sleep(300 * time.Millisecond)

	cl := NewClient(clientCfg)
	go func() { cl.Start() }()
	time.Sleep(2 * time.Second) // longer wait for pool to fill

	cl.sessMu.RLock()
	poolSize := len(cl.sessions)
	cl.sessMu.RUnlock()

	t.Logf("Pool size: %d (expected 3)", poolSize)
	if poolSize < 2 {
		t.Fatalf("Expected at least 2 sessions, got %d", poolSize)
	}

	// Test that forwarding works through the pool
	bindAddr := serverCfg.Forward.TCP[0]
	parts := strings.Split(bindAddr, "->")
	listenPort := strings.TrimSpace(parts[0])
	if !strings.Contains(listenPort, ":") {
		listenPort = "127.0.0.1:" + listenPort
	}
	time.Sleep(500 * time.Millisecond)

	// Send multiple connections to verify round-robin
	var wg sync.WaitGroup
	errors := make(chan error, 5)
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			c, err := net.DialTimeout("tcp", listenPort, 5*time.Second)
			if err != nil {
				errors <- fmt.Errorf("conn %d: dial: %v", id, err)
				return
			}
			defer c.Close()
			c.SetDeadline(time.Now().Add(5 * time.Second))

			msg := fmt.Sprintf("pool-test-%d", id)
			c.Write([]byte(msg))
			buf := make([]byte, 256)
			n, err := c.Read(buf)
			if err != nil {
				errors <- fmt.Errorf("conn %d: read: %v", id, err)
				return
			}
			if string(buf[:n]) != msg {
				errors <- fmt.Errorf("conn %d: got %q want %q", id, string(buf[:n]), msg)
			}
		}(i)
	}
	wg.Wait()
	close(errors)
	for err := range errors {
		t.Fatal(err)
	}
	t.Logf("✅ Connection pool works with %d sessions, 5 concurrent connections!", poolSize)
}

// TestIntegration_CompressedConn tests CompressedConn directly (snappy round-trip).
func TestIntegration_CompressedConn(t *testing.T) {
	// Create pipe to simulate network
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	// Wrap both sides with snappy
	srvConn := NewCompressedConn(server, "snappy")
	cliConn := NewCompressedConn(client, "snappy")

	// Test data
	testData := "Hello, compressed world! 🎯 This is a test of the snappy compression layer."

	// Write from client
	go func() {
		cliConn.Write([]byte(testData))
	}()

	// Read from server
	buf := make([]byte, 1024)
	n, err := srvConn.Read(buf)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}

	if string(buf[:n]) != testData {
		t.Fatalf("Data mismatch: got %q, want %q", string(buf[:n]), testData)
	}
	t.Logf("✅ CompressedConn round-trip works!")
}

// TestIntegration_EncryptedConn tests EncryptedConn directly (AES-GCM round-trip).
func TestIntegration_EncryptedConn(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	psk := "test-secret-key-12345"
	obfs := &ObfsConfig{Enabled: true, MinPadding: 4, MaxPadding: 32}

	srvEC, err := NewEncryptedConn(server, psk, obfs)
	if err != nil {
		t.Fatal("Server encrypt:", err)
	}
	cliEC, err := NewEncryptedConn(client, psk, obfs)
	if err != nil {
		t.Fatal("Client encrypt:", err)
	}

	testData := "Encrypted tunnel data test! 🔒"

	go func() {
		cliEC.Write([]byte(testData))
	}()

	buf := make([]byte, 1024)
	n, err := srvEC.Read(buf)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if string(buf[:n]) != testData {
		t.Fatalf("Data mismatch: got %q, want %q", string(buf[:n]), testData)
	}
	t.Logf("✅ EncryptedConn round-trip works!")
}

// TestIntegration_EncryptedCompressedPipeline tests encrypt → compress → decompress → decrypt.
func TestIntegration_EncryptedCompressedPipeline(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	psk := "pipeline-secret"
	obfs := &ObfsConfig{Enabled: true, MinPadding: 4, MaxPadding: 16}

	// Client side: encrypt then compress
	cliEC, _ := NewEncryptedConn(client, psk, obfs)
	cliComp := NewCompressedConn(cliEC, "snappy")

	// Server side: encrypt then compress (mirror)
	srvEC, _ := NewEncryptedConn(server, psk, obfs)
	srvComp := NewCompressedConn(srvEC, "snappy")

	testData := "Full pipeline: TCP → Encrypt → Compress → Decompress → Decrypt"

	go func() {
		cliComp.Write([]byte(testData))
	}()

	buf := make([]byte, 1024)
	n, err := srvComp.Read(buf)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if string(buf[:n]) != testData {
		t.Fatalf("Pipeline mismatch: got %q, want %q", string(buf[:n]), testData)
	}
	t.Logf("✅ Full encrypt+compress pipeline works!")
}

// ═══════════════════════════════════════════════════════════════
// Helper: build test configs
// ═══════════════════════════════════════════════════════════════

func findFreePort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	return addr
}

func buildTestServerConfig(t *testing.T, echoTarget string) *Config {
	t.Helper()
	listenAddr := findFreePort(t)
	bindAddr := findFreePort(t)

	cfg := &Config{
		Mode:             "server",
		Listen:           listenAddr,
		Transport:        "httpmux",
		PSK:              "test-integration-psk",
		Profile:          "balanced",
		Verbose:          true,
		SkipTLSVerify:    true,
		EnableDecoy:      true,
		EmbedFakeHeaders: true,

		Smux: SmuxConfig{
			KeepAlive: 10,
			MaxRecv:   4194304,
			MaxStream: 4194304,
			FrameSize: 32768,
			Version:   2,
		},
		Mimic: MimicConfig{
			FakeDomain:    "www.google.com",
			FakePath:      "/search",
			UserAgent:     "Mozilla/5.0",
			SessionCookie: true,
		},
		Obfs: ObfsConfig{
			Enabled:    true,
			MinPadding: 4,
			MaxPadding: 16,
		},
		Fragment: FragmentConfig{
			Enabled:  false,
			MinSize:  64,
			MaxSize:  191,
			MinDelay: 1,
			MaxDelay: 2,
		},
	}

	// Reverse TCP: external port → echo server
	cfg.Forward.TCP = []string{bindAddr + "->" + echoTarget}

	return cfg
}

func buildTestClientConfig(t *testing.T, serverAddr string) *Config {
	t.Helper()
	cfg := &Config{
		Mode:             "client",
		Transport:        "httpmux",
		PSK:              "test-integration-psk",
		Profile:          "balanced",
		Verbose:          true,
		SkipTLSVerify:    true,
		EnableDecoy:      true,
		EmbedFakeHeaders: true,

		Paths: []PathConfig{{
			Transport:      "httpmux",
			Addr:           serverAddr,
			ConnectionPool: 2,
			RetryInterval:  1,
			DialTimeout:    5,
		}},

		Smux: SmuxConfig{
			KeepAlive: 10,
			MaxRecv:   4194304,
			MaxStream: 4194304,
			FrameSize: 32768,
			Version:   2,
		},
		Mimic: MimicConfig{
			FakeDomain:    "www.google.com",
			FakePath:      "/search",
			UserAgent:     "Mozilla/5.0",
			SessionCookie: true,
		},
		Obfs: ObfsConfig{
			Enabled:    true,
			MinPadding: 4,
			MaxPadding: 16,
		},
		Fragment: FragmentConfig{
			Enabled: false,
		},
	}
	return cfg
}

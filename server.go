package httpmux

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xtaci/smux"
)

// relayBufPool reuses 128KB buffers for relay operations to reduce GC pressure.
var relayBufPool = sync.Pool{
	New: func() interface{} {
		buf := make([]byte, 128*1024)
		return &buf
	},
}

// ═══════════════════════════════════════════════════════════════
// Server — Dagger-style tunnel server
//
// Architecture (identical to DaggerConnect):
//   HTTP listen → validate mimicry headers → hijack TCP conn
//   → send 101 Switching Protocols → wrap EncryptedConn (AES-GCM)
//   → create xtaci/smux server session → accept/open streams
//
// Forward direction: client OpenStream → server AcceptStream → dial target
// Reverse direction: server OpenStream → client AcceptStream → dial target
// ═══════════════════════════════════════════════════════════════

type Server struct {
	Config  *Config
	Mimic   *MimicConfig
	Obfs    *ObfsConfig
	PSK     string
	Verbose bool

	sessMu         sync.RWMutex
	sessions       map[string]*smux.Session // keyed by remote addr
	sessionCreated map[string]time.Time     // Age tracking for zombie cleanup
}

func NewServer(cfg *Config) *Server {
	return &Server{
		Config:         cfg,
		Mimic:          &cfg.Mimic,
		Obfs:           &cfg.Obfs,
		PSK:            cfg.PSK,
		Verbose:        cfg.Verbose,
		sessions:       make(map[string]*smux.Session),
		sessionCreated: make(map[string]time.Time),
	}
}

// ──────────────────────────────────────────────────
//  Start — main entry point
// ──────────────────────────────────────────────────

func (s *Server) Start(ctx context.Context) error {
	var wg sync.WaitGroup

	// Reverse-tunnel port listeners
	// grouped by protocol
	for _, m := range s.Config.Forward.TCP {
		if bind, target, ok := SplitMap(m); ok {
			wg.Add(1)
			go func(b, t string) {
				defer wg.Done()
				s.startReverseTCP(ctx, b, t)
			}(bind, target)
		}
	}
	for _, m := range s.Config.Forward.UDP {
		if bind, target, ok := SplitMap(m); ok {
			wg.Add(1)
			go func(b, t string) {
				defer wg.Done()
				s.startReverseUDP(ctx, b, t)
			}(bind, target)
		}
	}

	// Session cleanup goroutine
	wg.Add(1)
	go func() {
		defer wg.Done()
		s.cleanupSessions(ctx)
	}()

	// HTTP Server
	tunnelPath := mimicPath(s.Mimic)
	prefix := strings.Split(tunnelPath, "{")[0]

	mux := http.NewServeMux()
	mux.HandleFunc(prefix, s.handleTunnel)
	if prefix != "/tunnel" {
		mux.HandleFunc("/tunnel", s.handleTunnel)
	}
	mux.HandleFunc("/", s.handleDecoy)

	srv := &http.Server{
		Addr:        s.Config.Listen,
		Handler:     mux,
		IdleTimeout: 0, // we manage our own keepalive
		BaseContext: func(_ net.Listener) context.Context { return ctx },
	}

	log.Printf("[SERVER] listening on %s  tunnel=%s  transport=httpmux", s.Config.Listen, prefix)

	// Server error channel
	errCh := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
		close(errCh)
	}()

	// Wait for context cancellation or server error
	select {
	case <-ctx.Done():
		// Graceful shutdown
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			log.Printf("[SERVER] HTTP shutdown error: %v", err)
		}
	case err := <-errCh:
		return fmt.Errorf("HTTP server failed: %w", err)
	}

	wg.Wait()
	return nil
}

// ──────────────────────────────────────────────────
//  HTTP handlers
// ──────────────────────────────────────────────────

func (s *Server) handleTunnel(w http.ResponseWriter, r *http.Request) {
	if ok, reason := s.validate(r); !ok {
		if s.Verbose {
			log.Printf("[REJECT] %s %s from %s — %s", r.Method, r.URL.Path, r.RemoteAddr, reason)
		}
		s.writeDecoy(w, r)
		return
	}
	if s.Verbose {
		log.Printf("[TUNNEL] accepted from %s", r.RemoteAddr)
	}
	s.upgrade(w, r)
}

func (s *Server) handleDecoy(w http.ResponseWriter, r *http.Request) {
	s.writeDecoy(w, r)
}

// ──────────────────────────────────────────────────
//  Tunnel upgrade — the heart of the Dagger approach
//
//  1. Hijack the HTTP connection (raw TCP)
//  2. Send 101 Switching Protocols
//  3. Wrap with EncryptedConn (AES-256-GCM per packet)
//  4. Create xtaci/smux server session
//  5. Accept streams from client (forward proxy)
// ──────────────────────────────────────────────────

func (s *Server) upgrade(w http.ResponseWriter, r *http.Request) {
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack not supported", http.StatusInternalServerError)
		return
	}
	conn, _, err := hj.Hijack()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// ① 101 Switching Protocols — fools firewalls into thinking this is WebSocket
	switchResp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
		"\r\n"
	if _, err := conn.Write([]byte(switchResp)); err != nil {
		conn.Close()
		return
	}

	// ② EncryptedConn — AES-256-GCM per-packet (like Dagger)
	ec, err := NewEncryptedConn(conn, s.PSK, s.Obfs)
	if err != nil {
		log.Printf("[ERR] encrypted conn: %v", err)
		conn.Close()
		return
	}

	// ②.5 Optional compression (snappy) — must match client
	var smuxConn net.Conn = ec
	if s.Config.Compression != "" && s.Config.Compression != "none" {
		smuxConn = NewCompressedConn(ec, s.Config.Compression)
	}

	// ③ xtaci/smux session (like Dagger)
	sc := buildSmuxConfig(s.Config)
	sess, err := smux.Server(smuxConn, sc)
	if err != nil {
		log.Printf("[ERR] smux server: %v", err)
		smuxConn.Close()
		return
	}

	key := conn.RemoteAddr().String()
	s.setSession(key, sess)
	log.Printf("[SESSION] new smux session from %s", conn.RemoteAddr())

	// ⑤ Accept streams (forward direction: client → server → target)
	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			log.Printf("[SESSION] closed: %v", err)
			s.clearSession(key, sess)
			return
		}
		go s.handleForwardStream(stream)
	}
}

// ──────────────────────────────────────────────────
//  Forward stream handler
//  Protocol: [2B target_len][target_string]  then bidirectional relay
//  target_string can be "tcp://host:port" or "udp://host:port"
// ──────────────────────────────────────────────────

func (s *Server) handleForwardStream(stream *smux.Stream) {
	defer stream.Close()

	// Set read deadline for header — prevents stuck streams
	stream.SetReadDeadline(time.Now().Add(10 * time.Second))

	// Read target header
	hdr := make([]byte, 2)
	if _, err := io.ReadFull(stream, hdr); err != nil {
		return
	}
	tLen := binary.BigEndian.Uint16(hdr)
	if tLen == 0 || tLen > 4096 {
		return
	}
	tBuf := make([]byte, tLen)
	if _, err := io.ReadFull(stream, tBuf); err != nil {
		return
	}

	// Clear deadline for data transfer
	stream.SetReadDeadline(time.Time{})

	network, addr := splitTarget(string(tBuf))
	if s.Verbose {
		log.Printf("[FWD] → %s://%s", network, addr)
	}

	remote, err := net.DialTimeout(network, addr, 10*time.Second)
	if err != nil {
		if s.Verbose {
			log.Printf("[FWD] dial fail %s: %v", addr, err)
		}
		return
	}
	defer remote.Close()

	relay(stream, remote)
}

// ──────────────────────────────────────────────────
//  Session management
// ──────────────────────────────────────────────────

func (s *Server) setSession(key string, sess *smux.Session) {
	s.sessMu.Lock()
	old := s.sessions[key]
	s.sessions[key] = sess
	s.sessionCreated[key] = time.Now()
	s.sessMu.Unlock()
	atomic.AddInt64(&GlobalStats.ActiveSessions, 1)
	if old != nil && old != sess {
		atomic.AddInt64(&GlobalStats.ActiveSessions, -1)
		old.Close()
	}
}

func (s *Server) clearSession(key string, sess *smux.Session) {
	s.sessMu.Lock()
	defer s.sessMu.Unlock()
	if s.sessions[key] == sess {
		delete(s.sessions, key)
		delete(s.sessionCreated, key)
		atomic.AddInt64(&GlobalStats.ActiveSessions, -1)
	}
}

func (s *Server) openStream() (*smux.Stream, error) {
	s.sessMu.RLock()
	defer s.sessMu.RUnlock()
	var lastErr error
	for _, sess := range s.sessions {
		if sess.IsClosed() {
			continue
		}
		// Load balancing: skip overloaded sessions
		if sess.NumStreams() > 200 {
			continue
		}
		stream, err := sess.OpenStream()
		if err == nil {
			return stream, nil
		}
		lastErr = err
		// OpenStream failed but IsClosed() was false → zombie
		sess.Close()
	}
	if lastErr != nil {
		return nil, fmt.Errorf("all sessions failed: %v", lastErr)
	}
	return nil, fmt.Errorf("no active client session")
}

// cleanupSessions periodically removes dead/closed sessions from the map.
func (s *Server) cleanupSessions(ctx context.Context) {
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			s.sessMu.Lock()
			for key, sess := range s.sessions {
				if sess.IsClosed() {
					delete(s.sessions, key)
					delete(s.sessionCreated, key)
					atomic.AddInt64(&GlobalStats.ActiveSessions, -1)
					if s.Verbose {
						log.Printf("[CLEANUP] removed dead session %s", key)
					}
					continue
				}

				// Zombie Check: If session has 0 streams (idle) for > 3 minutes, kill it.
				// This handles mobile clients that switch IPs leaving old connections 'open' but unused.
				if created, ok := s.sessionCreated[key]; ok {
					if sess.NumStreams() == 0 && time.Since(created) > 3*time.Minute {
						sess.Close()
						delete(s.sessions, key)
						delete(s.sessionCreated, key)
						atomic.AddInt64(&GlobalStats.ActiveSessions, -1)
						if s.Verbose {
							log.Printf("[CLEANUP] removed zombie session %s (age: %v)", key, time.Since(created))
						}
					}
				}
			}
			s.sessMu.Unlock()
		}
	}
}

// ──────────────────────────────────────────────────
//  Reverse TCP — server listens, forwards through smux to client
// ──────────────────────────────────────────────────

func (s *Server) startReverseTCP(ctx context.Context, bind, target string) {
	lc := net.ListenConfig{}
	ln, err := lc.Listen(ctx, "tcp", bind)
	if err != nil {
		log.Printf("[ERR] reverse tcp %s: %v", bind, err)
		return
	}
	defer ln.Close()
	log.Printf("[RTCP] %s → client → %s", bind, target)

	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return // Context cancelled
			}
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go s.handleReverseTCP(c, target)
	}
}

func (s *Server) handleReverseTCP(local net.Conn, target string) {
	defer local.Close()

	stream, err := s.openStream()
	if err != nil {
		// Brief retry — pool may be reconnecting
		time.Sleep(2 * time.Second)
		stream, err = s.openStream()
		if err != nil {
			if s.Verbose {
				log.Printf("[RTCP] no session: %v", err)
			}
			return
		}
	}
	defer stream.Close()

	// Tell client where to connect
	if err := sendTarget(stream, "tcp://"+target); err != nil {
		log.Printf("[RTCP] sendTarget failed: %v", err)
		return
	}

	if s.Verbose {
		log.Printf("[RTCP] %s → %s", local.RemoteAddr(), target)
	}
	relay(local, stream)
}

// ──────────────────────────────────────────────────
//  Reverse UDP
// ──────────────────────────────────────────────────

type udpPeer struct {
	conn     *net.UDPConn
	addr     *net.UDPAddr
	lastSeen int64
	stream   *smux.Stream
}

func (s *Server) startReverseUDP(ctx context.Context, bind, target string) {
	laddr, err := net.ResolveUDPAddr("udp", bind)
	if err != nil {
		log.Printf("[ERR] reverse udp resolve %s: %v", bind, err)
		return
	}
	ln, err := net.ListenUDP("udp", laddr)
	if err != nil {
		log.Printf("[ERR] reverse udp %s: %v", bind, err)
		return
	}
	defer ln.Close()
	log.Printf("[RUDP] %s → client → %s", bind, target)

	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	var mu sync.Mutex
	peers := map[string]*udpPeer{}

	// Stale peer cleanup
	go func() {
		tick := time.NewTicker(30 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case nowTime := <-tick.C:
				now := nowTime.Unix()
				mu.Lock()
				for k, p := range peers {
					if now-atomic.LoadInt64(&p.lastSeen) > 120 {
						p.stream.Close()
						delete(peers, k)
					}
				}
				mu.Unlock()
			}
		}
	}()

	buf := make([]byte, 65535)
	for {
		n, raddr, err := ln.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		if n == 0 {
			continue
		}

		key := raddr.String()
		mu.Lock()
		p, ok := peers[key]
		if !ok {
			stream, err := s.openStream()
			if err != nil {
				mu.Unlock()
				continue
			}
			if err := sendTarget(stream, "udp://"+target); err != nil {
				stream.Close()
				mu.Unlock()
				continue
			}

			p = &udpPeer{
				conn:     ln,
				addr:     raddr,
				lastSeen: time.Now().Unix(),
				stream:   stream,
			}
			peers[key] = p

			// Read replies from client → send back to UDP peer
			go func(p *udpPeer) {
				rb := make([]byte, 65535)
				for {
					rn, err := p.stream.Read(rb)
					if err != nil {
						break
					}
					p.conn.WriteToUDP(rb[:rn], p.addr)
				}
			}(p)
		}
		atomic.StoreInt64(&p.lastSeen, time.Now().Unix())
		mu.Unlock()

		// Send packet to client
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		p.stream.Write(pkt)
	}
}

// ──────────────────────────────────────────────────
//  Request validation & decoy responses
// ──────────────────────────────────────────────────

func (s *Server) validate(r *http.Request) (bool, string) {
	if r.Method != "GET" {
		return false, "method"
	}

	// Host check
	if s.Mimic != nil && s.Mimic.FakeDomain != "" {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		if host != s.Mimic.FakeDomain && !strings.HasSuffix(host, "."+s.Mimic.FakeDomain) {
			// Allow IP-based connections (no domain match needed)
			if net.ParseIP(host) == nil {
				return false, "host"
			}
		}
	}

	// WebSocket upgrade headers
	if r.Header.Get("Upgrade") == "" ||
		!strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade") {
		return false, "no upgrade"
	}

	// Path check
	expected := "/tunnel"
	if s.Mimic != nil && s.Mimic.FakePath != "" {
		expected = strings.Split(s.Mimic.FakePath, "{")[0]
	}
	if !strings.HasPrefix(r.URL.Path, expected) {
		return false, "path"
	}

	return true, ""
}

func (s *Server) writeDecoy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Server", "nginx/1.18.0")
	w.Header().Set("Date", time.Now().UTC().Format(http.TimeFormat))
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Frame-Options", "SAMEORIGIN")

	body := buildDecoyBody(r.URL.Path)
	status := http.StatusNotFound
	if r.URL.Path == "/" || r.URL.Path == "/index.html" {
		status = http.StatusOK
	}
	w.WriteHeader(status)
	w.Write(body)
}

func buildDecoyBody(path string) []byte {
	if strings.Contains(path, "api") || strings.Contains(path, "json") {
		return []byte(fmt.Sprintf(`{"status":"error","code":404,"ts":%d}`, time.Now().Unix()))
	}
	return []byte(`<!DOCTYPE html><html><head><title>Welcome to nginx!</title>` +
		`<style>body{width:35em;margin:0 auto;font-family:Tahoma,Verdana,Arial,sans-serif}</style>` +
		`</head><body><h1>Welcome to nginx!</h1>` +
		`<p>If you see this page, the nginx web server is successfully installed.</p>` +
		`</body></html>`)
}

// ──────────────────────────────────────────────────
//  Shared helpers
// ──────────────────────────────────────────────────

func buildSmuxConfig(cfg *Config) *smux.Config {
	sc := smux.DefaultConfig()
	sc.Version = cfg.Smux.Version
	if sc.Version < 1 {
		sc.Version = 2
	}
	sc.KeepAliveInterval = time.Duration(cfg.Smux.KeepAlive) * time.Second
	if sc.KeepAliveInterval <= 0 {
		sc.KeepAliveInterval = 10 * time.Second
	}
	// Timeout MUST be generous enough for high-latency links
	// Minimum 30 seconds to handle 189ms+ RTT with packet loss
	sc.KeepAliveTimeout = sc.KeepAliveInterval * 6
	if sc.KeepAliveTimeout < 30*time.Second {
		sc.KeepAliveTimeout = 30 * time.Second
	}
	if cfg.Smux.MaxRecv > 0 {
		sc.MaxReceiveBuffer = cfg.Smux.MaxRecv
	}
	if cfg.Smux.MaxStream > 0 {
		sc.MaxStreamBuffer = cfg.Smux.MaxStream
	}
	if cfg.Smux.FrameSize > 0 {
		sc.MaxFrameSize = cfg.Smux.FrameSize
	}
	return sc
}

func mimicPath(m *MimicConfig) string {
	p := "/tunnel"
	if m != nil && m.FakePath != "" {
		p = m.FakePath
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}

func splitTarget(s string) (network, addr string) {
	if strings.HasPrefix(s, "udp://") {
		return "udp", strings.TrimPrefix(s, "udp://")
	}
	return "tcp", strings.TrimPrefix(s, "tcp://")
}

func sendTarget(w io.Writer, target string) error {
	b := []byte(target)
	hdr := make([]byte, 2)
	binary.BigEndian.PutUint16(hdr, uint16(len(b)))
	if _, err := w.Write(hdr); err != nil {
		return err
	}
	_, err := w.Write(b)
	return err
}

// relay does bidirectional copy between two read-writers.
// MeasuredReader wraps an io.Reader and updates a counter on every Read.
type MeasuredReader struct {
	R io.Reader
	N *int64
}

func (m *MeasuredReader) Read(p []byte) (n int, err error) {
	n, err = m.R.Read(p)
	if n > 0 {
		atomic.AddInt64(m.N, int64(n))
	}
	return
}

// relay does bidirectional copy between two read-writers.
// Uses pooled 128KB buffers for high throughput on multiplexed connections.
// Properly closes both sides when either direction finishes.
// Tracks bytes transferred in GlobalStats REAL-TIME.
func relay(a, b io.ReadWriteCloser) {
	atomic.AddInt64(&GlobalStats.ActiveConns, 1)
	atomic.AddInt64(&GlobalStats.TotalConns, 1)
	defer atomic.AddInt64(&GlobalStats.ActiveConns, -1)

	done := make(chan struct{}, 2)
	cp := func(dst io.WriteCloser, src io.Reader, counter *int64) {
		bufPtr := relayBufPool.Get().(*[]byte)
		// Wrap src with MeasuredReader to update stats during transfer
		mr := &MeasuredReader{R: src, N: counter}
		io.CopyBuffer(dst, mr, *bufPtr)
		relayBufPool.Put(bufPtr)
		dst.Close()
		done <- struct{}{}
	}
	go cp(a, b, &GlobalStats.BytesSent)
	go cp(b, a, &GlobalStats.BytesRecv)
	<-done
	<-done
}

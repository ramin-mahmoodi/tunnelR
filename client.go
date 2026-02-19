package httpmux

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	utls "github.com/refraction-networking/utls"
	"github.com/xtaci/smux"
)

// Adaptive FrameSize levels: start small (DPI-safe) → ramp up for speed
var frameSizes = [5]int{16384, 32768, 65536, 131072, 262144} // Tuned for 400Mbps+

// sessionMaxAge defines how long a session can live before being recycled.
// Recycling prevents ISP/DPI throttling of long-lived connections.
const sessionMaxAge = 20 * time.Minute
const maxFailsBeforeSwitch = 3

// pooledSession wraps a smux.Session with its creation timestamp
// for connection recycling (anti-throttle).
type pooledSession struct {
	session   *smux.Session
	createdAt time.Time
}

// Client implements the Dagger-style tunnel client.
// Flow: TCP/TLS connect → mimicry handshake → EncryptedConn → Compress → smux → streams
type Client struct {
	cfg     *Config
	mimic   *MimicConfig
	obfs    *ObfsConfig
	psk     string
	paths   []PathConfig
	verbose bool

	sessMu   sync.RWMutex
	sessions []*pooledSession // connection pool with age tracking
	sessIdx  uint64           // atomic round-robin index

	// Warm Standby: pre-built session ready for instant promotion
	standbyCh chan *smux.Session

	// Adaptive FrameSize: 0-4 index into frameSizes[]
	frameLevel int32 // atomic

	// Latency-Based Routing: RTT per path in nanoseconds
	pathLatency []int64 // atomic per-element
}

func NewClient(cfg *Config) *Client {
	paths := cfg.Paths
	if len(paths) == 0 && cfg.ServerURL != "" {
		paths = []PathConfig{{
			Transport:      cfg.Transport,
			Addr:           cfg.ServerURL,
			ConnectionPool: 2,
			RetryInterval:  3,
			DialTimeout:    10,
		}}
	}

	return &Client{
		cfg:         cfg,
		mimic:       &cfg.Mimic,
		obfs:        &cfg.Obfs,
		psk:         cfg.PSK,
		paths:       paths,
		verbose:     cfg.Verbose,
		standbyCh:   make(chan *smux.Session, 1),
		pathLatency: make([]int64, len(paths)),
	}
}

// Start connects to the server using a pool of concurrent smux sessions.
// Pool workers cycle through paths on failure (Multi-IP Failover).
func (c *Client) Start(ctx context.Context) error {
	if len(c.paths) == 0 {
		return fmt.Errorf("no paths configured")
	}

	var wg sync.WaitGroup

	poolSize := c.paths[0].ConnectionPool
	if poolSize <= 0 {
		poolSize = 4
	}

	sc := buildSmuxConfig(c.cfg)
	log.Printf("[CLIENT] pool=%d paths=%d profile=%s",
		poolSize, len(c.paths), c.cfg.Profile)
	for i, p := range c.paths {
		log.Printf("[CLIENT]   path[%d]: %s (%s)", i, p.Addr, p.Transport)
	}
	log.Printf("[CLIENT] smux: keepalive=%v timeout=%v frame=%d",
		sc.KeepAliveInterval, sc.KeepAliveTimeout, sc.MaxFrameSize)

	wg.Add(1)
	go func() {
		defer wg.Done()
		c.sessionHealthCheck(ctx)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		c.standbyManager(ctx)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		c.latencyProber(ctx)
	}()

	// Set initial frame level from config
	if c.cfg.Smux.FrameSize >= 32768 {
		atomic.StoreInt32(&c.frameLevel, 4)
	} else {
		atomic.StoreInt32(&c.frameLevel, 0)
	}

	for i := 0; i < poolSize; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			c.poolWorker(ctx, id)
		}(i)
		// Stagger connections to avoid DPI pattern detection
		if i < poolSize-1 {
			time.Sleep(500 * time.Millisecond)
		}
	}

	// Start DNS-over-Tunnel proxy if enabled
	if c.cfg.DNS.Enabled {
		go func() {
			select {
			case <-time.After(2 * time.Second):
			case <-ctx.Done():
				return
			}

			dns := &DNSProxy{
				Listen:   c.cfg.DNS.Listen,
				Upstream: c.cfg.DNS.Upstream,
				Client:   c,
				Verbose:  c.verbose,
			}
			if dns.Listen == "" {
				dns.Listen = "127.0.0.1:53"
			}
			if dns.Upstream == "" {
				dns.Upstream = "8.8.8.8:53"
			}
			if err := dns.Start(); err != nil {
				log.Printf("[DNS] proxy failed: %v", err)
			}
		}()
	}

	// Block until context is done
	<-ctx.Done()
	log.Println("[CLIENT] stopping...")
	wg.Wait()
	return nil
}

// poolWorker — one goroutine that cycles through paths on failure.
// Uses latency-based routing to pick the best path, with failover on consecutive failures.
func (c *Client) poolWorker(ctx context.Context, id int) {
	pathIdx := c.bestPath()
	failCount := 0

	for {
		// Check for cancellation
		if ctx.Err() != nil {
			return
		}

		path := c.paths[pathIdx]
		retryInterval := time.Duration(path.RetryInterval) * time.Second
		if retryInterval <= 0 {
			retryInterval = 3 * time.Second
		}

		// Try warm standby first for instant recovery
		reused := false
		select {
		case <-ctx.Done():
			return
		case standby := <-c.standbyCh:
			if !standby.IsClosed() {
				log.Printf("[POOL#%d] using warm standby session", id)
				c.addSession(standby)
				// Block accepting streams until session dies
				for {
					if ctx.Err() != nil {
						c.removeSession(standby)
						standby.Close()
						return
					}
					stream, err := standby.AcceptStream()
					if err != nil {
						c.removeSession(standby)
						standby.Close()
						break
					}
					go c.handleReverseStream(stream)
				}
				reused = true
			}
		default:
			// No standby available — normal connect
		}

		if reused {
			failCount = 0
			continue
		}

		connStart := time.Now()
		err := c.connectAndServe(ctx, id, path)
		connDuration := time.Since(connStart)

		if ctx.Err() != nil {
			return
		}

		if err != nil {
			alive := c.sessionCount()

			// Adaptive FrameSize: short-lived → decrease level
			if connDuration < 30*time.Second {
				failCount++
				c.adjustFrameLevel(-1)
			} else {
				failCount = 0
			}

			// Switch to next path after N consecutive short failures
			if failCount >= maxFailsBeforeSwitch && len(c.paths) > 1 {
				oldIdx := pathIdx
				// Try latency-based selection first
				newIdx := c.bestPath()
				if newIdx == pathIdx {
					newIdx = (pathIdx + 1) % len(c.paths)
				}
				pathIdx = newIdx
				failCount = 0
				log.Printf("[POOL#%d] path[%d] seems blocked → switching to path[%d] %s",
					id, oldIdx, pathIdx, c.paths[pathIdx].Addr)

				if pathIdx == 0 {
					log.Printf("[POOL#%d] all paths tried, backing off 10s", id)
					select {
					case <-ctx.Done():
						return
					case <-time.After(10 * time.Second):
					}
					continue
				}
			} else {
				log.Printf("[POOL#%d] disconnected from %s (alive: %d) — retry %v",
					id, path.Addr, alive, retryInterval)
			}

			atomic.AddInt64(&GlobalStats.Reconnects, 1)
			select {
			case <-ctx.Done():
				return
			case <-time.After(retryInterval):
			}
		} else {
			failCount = 0
			select {
			case <-ctx.Done():
				return
			case <-time.After(retryInterval):
			}
		}
	}
}

// addSession adds a session to the pool with current timestamp.
func (c *Client) addSession(sess *smux.Session) {
	c.sessMu.Lock()
	c.sessions = append(c.sessions, &pooledSession{session: sess, createdAt: time.Now()})
	c.sessMu.Unlock()
}

// removeSession removes a specific session from the pool.
func (c *Client) removeSession(sess *smux.Session) {
	c.sessMu.Lock()
	for i, ps := range c.sessions {
		if ps.session == sess {
			c.sessions = append(c.sessions[:i], c.sessions[i+1:]...)
			break
		}
	}
	c.sessMu.Unlock()
}

func (c *Client) sessionCount() int {
	c.sessMu.RLock()
	defer c.sessMu.RUnlock()
	return len(c.sessions)
}

// connectAndServe establishes one smux session on the given path and blocks until it dies.
func (c *Client) connectAndServe(ctx context.Context, id int, path PathConfig) error {
	transport := strings.ToLower(strings.TrimSpace(path.Transport))
	if transport == "" {
		transport = c.cfg.Transport
	}
	addr := strings.TrimSpace(path.Addr)
	if addr == "" {
		return fmt.Errorf("empty address")
	}

	dialTimeout := time.Duration(path.DialTimeout) * time.Second
	if dialTimeout <= 0 {
		dialTimeout = 10 * time.Second
	}

	// Parse address
	host, port := parseAddr(addr, transport)
	dialAddr := net.JoinHostPort(host, port)

	level := atomic.LoadInt32(&c.frameLevel)
	if c.verbose {
		log.Printf("[POOL#%d] connecting to %s (%s) frame=%dB",
			id, dialAddr, transport, frameSizes[level])
	}

	// ① Dial TCP/TLS connection
	var conn net.Conn
	var err error

	// TODO: Make dialers context-aware
	switch transport {
	case "httpsmux", "wssmux":
		conn, err = c.dialFragmentedTLS(dialAddr, dialTimeout)
	case "httpmux", "wsmux":
		conn, err = DialFragmented(dialAddr, c.fragmentCfg(), dialTimeout)
	default:
		conn, err = net.DialTimeout("tcp", dialAddr, dialTimeout)
	}
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}

	// If context cancelled during dial
	if ctx.Err() != nil {
		conn.Close()
		return ctx.Err()
	}

	c.setTCPOptions(conn)

	// ② Mimicry handshake — returns bufferedConn
	conn, err = ClientHandshake(conn, c.mimic)
	if err != nil {
		conn.Close()
		return fmt.Errorf("handshake: %w", err)
	}

	// ③ Encrypted connection (AES-256-GCM)
	ec, err := NewEncryptedConn(conn, c.psk, c.obfs)
	if err != nil {
		conn.Close()
		return fmt.Errorf("encrypt: %w", err)
	}

	// ③.5 Optional compression (snappy)
	var smuxConn net.Conn = ec
	if c.cfg.Compression != "" && c.cfg.Compression != "none" {
		smuxConn = NewCompressedConn(ec, c.cfg.Compression)
	}

	// ④ smux session — uses adaptive frame size
	sc := buildSmuxConfig(c.cfg)
	sc.MaxFrameSize = frameSizes[level]
	sess, err := smux.Client(smuxConn, sc)
	if err != nil {
		smuxConn.Close()
		return fmt.Errorf("smux: %w", err)
	}

	c.addSession(sess)
	// Force close if context ends
	go func() {
		<-ctx.Done()
		sess.Close()
	}()

	count := c.sessionCount()
	log.Printf("[POOL#%d] connected to %s (pool: %d, frame: %dB)",
		id, dialAddr, count, frameSizes[level])

	// ⑤ Accept reverse streams — blocks until session dies
	connStart := time.Now()
	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			c.removeSession(sess)
			sess.Close()
			// Adaptive: if session lived > 2min, increase frame level
			if time.Since(connStart) > 2*time.Minute {
				c.adjustFrameLevel(1)
			}
			return fmt.Errorf("session closed: %w", err)
		}
		go c.handleReverseStream(stream)
	}
}

// adjustFrameLevel safely changes the adaptive frame level by delta.
func (c *Client) adjustFrameLevel(delta int32) {
	for {
		old := atomic.LoadInt32(&c.frameLevel)
		new_ := old + delta
		if new_ < 0 {
			new_ = 0
		}
		if new_ > 4 {
			new_ = 4
		}
		if new_ == old {
			return
		}
		if atomic.CompareAndSwapInt32(&c.frameLevel, old, new_) {
			log.Printf("[ADAPTIVE] frame %dB→%dB (level %d→%d)",
				frameSizes[old], frameSizes[new_], old, new_)
			return
		}
	}
}

// dialSession establishes a full session to the best path (used by standbyManager).
func (c *Client) dialSession() (*smux.Session, error) {
	pathIdx := c.bestPath()
	path := c.paths[pathIdx]
	transport := strings.ToLower(strings.TrimSpace(path.Transport))
	if transport == "" {
		transport = c.cfg.Transport
	}
	addr := strings.TrimSpace(path.Addr)
	dialTimeout := time.Duration(path.DialTimeout) * time.Second
	if dialTimeout <= 0 {
		dialTimeout = 10 * time.Second
	}
	host, port := parseAddr(addr, transport)
	dialAddr := net.JoinHostPort(host, port)

	var conn net.Conn
	var err error
	switch transport {
	case "httpsmux", "wssmux":
		conn, err = c.dialFragmentedTLS(dialAddr, dialTimeout)
	case "httpmux", "wsmux":
		conn, err = DialFragmented(dialAddr, c.fragmentCfg(), dialTimeout)
	default:
		conn, err = net.DialTimeout("tcp", dialAddr, dialTimeout)
	}
	if err != nil {
		return nil, err
	}
	c.setTCPOptions(conn)

	conn, err = ClientHandshake(conn, c.mimic)
	if err != nil {
		conn.Close()
		return nil, err
	}

	ec, err := NewEncryptedConn(conn, c.psk, c.obfs)
	if err != nil {
		conn.Close()
		return nil, err
	}

	var smuxConn net.Conn = ec
	if c.cfg.Compression != "" && c.cfg.Compression != "none" {
		smuxConn = NewCompressedConn(ec, c.cfg.Compression)
	}

	sc := buildSmuxConfig(c.cfg)
	level := atomic.LoadInt32(&c.frameLevel)
	sc.MaxFrameSize = frameSizes[level]
	sess, err := smux.Client(smuxConn, sc)
	if err != nil {
		smuxConn.Close()
		return nil, err
	}
	return sess, nil
}

// standbyManager keeps one pre-built session ready for instant promotion.
func (c *Client) standbyManager(ctx context.Context) {
	// Wait for primary pool to establish first
	select {
	case <-ctx.Done():
		return
	case <-time.After(5 * time.Second):
	}

	for {
		if ctx.Err() != nil {
			return
		}
		sess, err := c.dialSession()
		if err != nil {
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
			continue
		}
		log.Printf("[STANDBY] warm session ready")
		// Block until someone consumes the standby OR context dies
		select {
		case <-ctx.Done():
			sess.Close()
			return
		case c.standbyCh <- sess:
			// Consumed
		}
		// Small delay before building next standby
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
	}
}

// latencyProber periodically measures TCP RTT to each path.
func (c *Client) latencyProber(ctx context.Context) {
	select {
	case <-ctx.Done():
		return
	case <-time.After(3 * time.Second):
	}

	for {
		for i, path := range c.paths {
			if ctx.Err() != nil {
				return
			}
			addr := strings.TrimSpace(path.Addr)
			transport := strings.ToLower(strings.TrimSpace(path.Transport))
			if transport == "" {
				transport = c.cfg.Transport
			}
			host, port := parseAddr(addr, transport)
			dialAddr := net.JoinHostPort(host, port)

			start := time.Now()
			// Use shorter timeout for probing
			d := net.Dialer{Timeout: 5 * time.Second}
			conn, err := d.DialContext(ctx, "tcp", dialAddr)
			if err != nil {
				atomic.StoreInt64(&c.pathLatency[i], int64(999*time.Second))
				continue
			}
			rtt := time.Since(start)
			conn.Close()
			atomic.StoreInt64(&c.pathLatency[i], int64(rtt))
		}

		if c.verbose && len(c.paths) > 1 {
			msg := "[LATENCY]"
			for i := range c.paths {
				rtt := time.Duration(atomic.LoadInt64(&c.pathLatency[i]))
				msg += fmt.Sprintf(" path[%d]=%v", i, rtt.Round(time.Millisecond))
			}
			log.Println(msg)
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(30 * time.Second):
		}
	}
}

// bestPath returns the index of the path with lowest measured RTT.
func (c *Client) bestPath() int {
	if len(c.paths) <= 1 {
		return 0
	}
	best := 0
	bestRTT := atomic.LoadInt64(&c.pathLatency[0])
	for i := 1; i < len(c.paths); i++ {
		rtt := atomic.LoadInt64(&c.pathLatency[i])
		if rtt > 0 && (bestRTT == 0 || rtt < bestRTT) {
			best = i
			bestRTT = rtt
		}
	}
	return best
}

// setTCPOptions applies keep-alive and no-delay options to TCP connections.
func (c *Client) setTCPOptions(conn net.Conn) {
	type hasTCP interface {
		SetKeepAlive(bool) error
		SetKeepAlivePeriod(time.Duration) error
		SetNoDelay(bool) error
		SetReadBuffer(int) error
		SetWriteBuffer(int) error
	}
	if tc, ok := conn.(hasTCP); ok {
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(time.Duration(c.cfg.Advanced.TCPKeepAlive) * time.Second)
		tc.SetNoDelay(c.cfg.Advanced.TCPNoDelay)
		// Force large kernel buffers for high BDP (Bandwidth-Delay Product)
		// 4MB is sufficient for ~330Mbps @ 100ms RTT
		// c.cfg.Advanced.TCPReadBuffer usually 0 (default), so we enforce a high minimum
		tc.SetReadBuffer(4 * 1024 * 1024)
		tc.SetWriteBuffer(4 * 1024 * 1024)
	}
}

// handleReverseStream: server opened a stream asking us to dial a target.
func (c *Client) handleReverseStream(stream *smux.Stream) {
	defer stream.Close()

	// Read deadline for header — prevents stuck streams
	stream.SetReadDeadline(time.Now().Add(10 * time.Second))

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
	if c.verbose {
		log.Printf("[REVERSE] dial %s://%s", network, addr)
	}

	remote, err := net.DialTimeout(network, addr, 10*time.Second)
	if err != nil {
		if c.verbose {
			log.Printf("[REVERSE] dial failed %s: %v", addr, err)
		}
		return
	}
	defer remote.Close()

	relay(stream, remote)
}

// OpenStream opens a new stream using round-robin across the pool.
func (c *Client) OpenStream(target string) (*smux.Stream, error) {
	c.sessMu.RLock()
	pool := make([]*pooledSession, len(c.sessions))
	copy(pool, c.sessions)
	c.sessMu.RUnlock()

	if len(pool) == 0 {
		return nil, fmt.Errorf("no active sessions")
	}

	// Round-robin across healthy sessions
	for attempts := 0; attempts < len(pool); attempts++ {
		idx := int(atomic.AddUint64(&c.sessIdx, 1)) % len(pool)
		ps := pool[idx]
		if ps.session.IsClosed() {
			continue
		}
		stream, err := ps.session.OpenStream()
		if err != nil {
			continue
		}
		if err := sendTarget(stream, target); err != nil {
			stream.Close()
			continue
		}
		return stream, nil
	}
	return nil, fmt.Errorf("all sessions exhausted")
}

func (c *Client) sessionHealthCheck(ctx context.Context) {
	// 1. Cleanup ticker (fast check for explicitly closed sessions)
	cleanTicker := time.NewTicker(3 * time.Second)
	// 2. Recycle ticker (close old sessions to prevent ISP throttling)
	recycleTicker := time.NewTicker(1 * time.Minute)

	defer cleanTicker.Stop()
	defer recycleTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-cleanTicker.C:
			c.sessMu.Lock()
			alive := c.sessions[:0]
			removed := 0
			for _, ps := range c.sessions {
				if ps.session.IsClosed() {
					ps.session.Close()
					removed++
				} else {
					alive = append(alive, ps)
				}
			}
			c.sessions = alive
			c.sessMu.Unlock()
			if removed > 0 && c.verbose {
				log.Printf("[POOL] cleaned %d dead (alive: %d)", removed, len(alive))
			}

		case <-recycleTicker.C:
			// CONNECTION RECYCLING: Close the oldest expired session.
			// Only ONE at a time to minimize disruption.
			// The reconnect loop in Start() will automatically create a fresh replacement.
			now := time.Now()
			c.sessMu.RLock()
			var oldest *pooledSession
			for _, ps := range c.sessions {
				if ps.session.IsClosed() {
					continue
				}
				age := now.Sub(ps.createdAt)
				if age > sessionMaxAge {
					if oldest == nil || ps.createdAt.Before(oldest.createdAt) {
						oldest = ps
					}
				}
			}
			c.sessMu.RUnlock()

			if oldest != nil {
				oldest.session.Close()
				if c.verbose {
					age := now.Sub(oldest.createdAt).Round(time.Second)
					log.Printf("[RECYCLE] closed session (age: %v) -> fresh connection incoming", age)
				}
			}
		}
	}
}

// ───────────── TLS with fragmentation + uTLS fingerprint ─────────────

// dialFragmentedTLS establishes a TLS connection with:
//  1. TCP connection with ClientHello fragmentation (anti-DPI)
//  2. uTLS Chrome 120 fingerprint (anti-fingerprinting)
//  3. Random cipher suite order (like Dagger)
func (c *Client) dialFragmentedTLS(addr string, timeout time.Duration) (net.Conn, error) {
	// Step 1: TCP connect with fragmentation support
	fragCfg := c.fragmentCfg()
	rawConn, err := DialFragmented(addr, fragCfg, timeout)
	if err != nil {
		return nil, err
	}

	// Step 2: SNI — use FakeDomain if set, else host from addr
	sni := c.mimic.FakeDomain
	if sni == "" {
		sni, _, _ = net.SplitHostPort(addr)
	}

	// Step 3: uTLS handshake with Chrome 120 fingerprint
	// The underlying conn is FragmentedConn — the first Write (ClientHello)
	// will be automatically split into fragments
	uConn := utls.UClient(rawConn, &utls.Config{
		ServerName:         sni,
		InsecureSkipVerify: c.cfg.SkipTLSVerify,
	}, utls.HelloChrome_120)

	if err := uConn.Handshake(); err != nil {
		uConn.Close()
		return nil, fmt.Errorf("tls handshake: %w", err)
	}

	if c.verbose {
		log.Printf("[TLS] connected to %s (SNI=%s, fragmented=%v)", addr, sni, fragCfg != nil && fragCfg.Enabled)
	}

	return uConn, nil
}

// fragmentCfg returns the fragment config, or nil if disabled.
func (c *Client) fragmentCfg() *FragmentConfig {
	if c.cfg.Fragment.Enabled {
		return &c.cfg.Fragment
	}
	// Default: enabled for httpsmux/wssmux
	if c.cfg.Transport == "httpsmux" || c.cfg.Transport == "wssmux" {
		cfg := DefaultFragmentConfig()
		return &cfg
	}
	return nil
}

// ───────────── Helpers ─────────────

func parseAddr(addr, transport string) (host, port string) {
	// If addr already has scheme, strip it
	addr = strings.TrimPrefix(addr, "http://")
	addr = strings.TrimPrefix(addr, "https://")
	addr = strings.TrimPrefix(addr, "ws://")
	addr = strings.TrimPrefix(addr, "wss://")

	// Remove path
	if idx := strings.Index(addr, "/"); idx != -1 {
		addr = addr[:idx]
	}

	h, p, err := net.SplitHostPort(addr)
	if err != nil {
		// No port specified
		h = addr
		switch transport {
		case "httpsmux", "wssmux":
			p = "443"
		default:
			p = "80"
		}
	}
	return h, p
}

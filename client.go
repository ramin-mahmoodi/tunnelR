package httpmux

import (
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
		cfg:     cfg,
		mimic:   &cfg.Mimic,
		obfs:    &cfg.Obfs,
		psk:     cfg.PSK,
		paths:   paths,
		verbose: cfg.Verbose,
	}
}

// Start connects to the server using a pool of concurrent smux sessions.
// Pool workers cycle through paths on failure (Multi-IP Failover).
func (c *Client) Start() error {
	if len(c.paths) == 0 {
		return fmt.Errorf("no paths configured")
	}

	errCh := make(chan error, 1)

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

	go c.sessionHealthCheck()

	for i := 0; i < poolSize; i++ {
		go c.poolWorker(i)
		// Stagger connections to avoid DPI pattern detection
		if i < poolSize-1 {
			time.Sleep(500 * time.Millisecond)
		}
	}

	// Start DNS-over-Tunnel proxy if enabled
	if c.cfg.DNS.Enabled {
		go func() {
			// Wait briefly for at least one session to establish
			time.Sleep(2 * time.Second)
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

	// Block forever (individual goroutines reconnect on their own)
	return <-errCh
}

// poolWorker — one goroutine that cycles through paths on failure.
// After maxFailsBeforeSwitch consecutive short-lived failures, switches to next path.
func (c *Client) poolWorker(id int) {
	pathIdx := 0
	failCount := 0

	for {
		path := c.paths[pathIdx]
		retryInterval := time.Duration(path.RetryInterval) * time.Second
		if retryInterval <= 0 {
			retryInterval = 3 * time.Second
		}

		connStart := time.Now()
		err := c.connectAndServe(id, path)
		connDuration := time.Since(connStart)

		if err != nil {
			alive := c.sessionCount()

			// Only count short-lived failures as "blocked"
			if connDuration < 30*time.Second {
				failCount++
			} else {
				failCount = 0
			}

			// Switch to next path after N consecutive short failures
			if failCount >= maxFailsBeforeSwitch && len(c.paths) > 1 {
				oldIdx := pathIdx
				pathIdx = (pathIdx + 1) % len(c.paths)
				failCount = 0
				log.Printf("[POOL#%d] path[%d] seems blocked → switching to path[%d] %s",
					id, oldIdx, pathIdx, c.paths[pathIdx].Addr)

				if pathIdx == 0 {
					log.Printf("[POOL#%d] all paths tried, backing off 10s", id)
					time.Sleep(10 * time.Second)
					continue
				}
			} else {
				log.Printf("[POOL#%d] disconnected from %s (alive: %d) — retry %v",
					id, path.Addr, alive, retryInterval)
			}

			atomic.AddInt64(&GlobalStats.Reconnects, 1)
			time.Sleep(retryInterval)
		} else {
			failCount = 0
			time.Sleep(retryInterval)
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
func (c *Client) connectAndServe(id int, path PathConfig) error {
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

	if c.verbose {
		log.Printf("[POOL#%d] connecting to %s (%s)", id, dialAddr, transport)
	}

	// ① Dial TCP/TLS connection
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
		return fmt.Errorf("dial: %w", err)
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

	// ④ smux session
	sc := buildSmuxConfig(c.cfg)
	sess, err := smux.Client(smuxConn, sc)
	if err != nil {
		smuxConn.Close()
		return fmt.Errorf("smux: %w", err)
	}

	c.addSession(sess)
	count := c.sessionCount()
	log.Printf("[POOL#%d] connected to %s (pool: %d)", id, dialAddr, count)

	// ⑤ Accept reverse streams — blocks until session dies
	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			c.removeSession(sess)
			sess.Close()
			return fmt.Errorf("session closed: %w", err)
		}
		go c.handleReverseStream(stream)
	}
}

// setTCPOptions applies keep-alive and no-delay options to TCP connections.
func (c *Client) setTCPOptions(conn net.Conn) {
	type hasTCP interface {
		SetKeepAlive(bool) error
		SetKeepAlivePeriod(time.Duration) error
		SetNoDelay(bool) error
	}
	if tc, ok := conn.(hasTCP); ok {
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(time.Duration(c.cfg.Advanced.TCPKeepAlive) * time.Second)
		tc.SetNoDelay(c.cfg.Advanced.TCPNoDelay)
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

func (c *Client) sessionHealthCheck() {
	// 1. Cleanup ticker (fast check for explicitly closed sessions)
	cleanTicker := time.NewTicker(3 * time.Second)
	// 2. Recycle ticker (close old sessions to prevent ISP throttling)
	recycleTicker := time.NewTicker(1 * time.Minute)

	defer cleanTicker.Stop()
	defer recycleTicker.Stop()

	for {
		select {
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

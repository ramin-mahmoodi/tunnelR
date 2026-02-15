package httpmux

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	utls "github.com/refraction-networking/utls"
	"github.com/xtaci/smux"
)

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
	sessions []*smux.Session // connection pool
	sessIdx  uint64          // atomic round-robin index
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
// Each path spawns ConnectionPool goroutines, each managing one session.
func (c *Client) Start() error {
	if len(c.paths) == 0 {
		return fmt.Errorf("no paths configured")
	}

	errCh := make(chan error, 1)

	for pathIdx, path := range c.paths {
		poolSize := path.ConnectionPool
		if poolSize <= 0 {
			poolSize = 1
		}
		for i := 0; i < poolSize; i++ {
			go func(pIdx, slotID int) {
				attempt := 0
				for {
					start := time.Now()
					err := c.connectAndServe(pIdx)
					elapsed := time.Since(start)

					if elapsed > 30*time.Second {
						attempt = 0
					}

					attempt++
					backoff := math.Min(float64(attempt)*2, 30)
					delay := time.Duration(backoff) * time.Second

					log.Printf("[POOL-%d] path[%d] disconnected: %v — reconnecting in %v", slotID, pIdx, err, delay)
					atomic.AddInt64(&GlobalStats.Reconnects, 1)
					time.Sleep(delay)
				}
			}(pathIdx, i)
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

// addSession adds a session to the pool.
func (c *Client) addSession(sess *smux.Session) {
	c.sessMu.Lock()
	c.sessions = append(c.sessions, sess)
	c.sessMu.Unlock()
}

// removeSession removes a specific session from the pool.
func (c *Client) removeSession(sess *smux.Session) {
	c.sessMu.Lock()
	for i, s := range c.sessions {
		if s == sess {
			c.sessions = append(c.sessions[:i], c.sessions[i+1:]...)
			break
		}
	}
	c.sessMu.Unlock()
}

// connectAndServe establishes one smux session on the given path index and blocks until it dies.
func (c *Client) connectAndServe(pathIdx int) error {
	path := c.paths[pathIdx]
	transport := strings.ToLower(strings.TrimSpace(path.Transport))
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
		log.Printf("[CLIENT] connecting to %s (%s)", dialAddr, transport)
	}

	// 1. Establish TCP/TLS connection (with optional TLS fragmentation)
	var conn net.Conn
	var err error

	switch transport {
	case "httpsmux", "wssmux":
		conn, err = c.dialFragmentedTLS(dialAddr, dialTimeout)
	case "httpmux", "wsmux":
		// HTTP without TLS — still use fragmentation for TCP_NODELAY benefit
		conn, err = DialFragmented(dialAddr, c.fragmentCfg(), dialTimeout)
	default:
		conn, err = net.DialTimeout("tcp", dialAddr, dialTimeout)
		if err == nil {
			// Enforce TCP_NODELAY for standard dials too
			if tc, ok := conn.(*net.TCPConn); ok {
				tc.SetNoDelay(true)
			}
		}
	}
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}

	// 2. Mimicry handshake (HTTP GET + WebSocket Upgrade → 101)
	if err := ClientHandshake(conn, c.mimic); err != nil {
		conn.Close()
		return fmt.Errorf("handshake: %w", err)
	}
	if c.verbose {
		log.Printf("[CLIENT] handshake OK")
	}

	// 3. Wrap with EncryptedConn (AES-GCM, like Dagger)
	ec, err := NewEncryptedConn(conn, c.psk, c.obfs)
	if err != nil {
		conn.Close()
		return fmt.Errorf("encrypt: %w", err)
	}

	// 3.5. Optional compression (snappy) between encryption and smux
	var smuxConn net.Conn = ec
	if c.cfg.Compression != "" && c.cfg.Compression != "none" {
		smuxConn = NewCompressedConn(ec, c.cfg.Compression)
		if c.verbose {
			log.Printf("[CLIENT] compression: %s", c.cfg.Compression)
		}
	}

	// 4. smux client session (like Dagger)
	sc := buildSmuxConfig(c.cfg)
	sess, err := smux.Client(smuxConn, sc)
	if err != nil {
		smuxConn.Close()
		return fmt.Errorf("smux: %w", err)
	}

	c.addSession(sess)
	log.Printf("[CLIENT] session established to %s (pool size: %d)", dialAddr, len(c.sessions))

	// 5. Accept streams from server (reverse tunnel direction)
	//    Server opens stream → client dials target → relay
	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			c.removeSession(sess)
			sess.Close()
			return fmt.Errorf("accept: %w", err)
		}
		go c.handleReverseStream(stream)
	}
}

// handleReverseStream: server opened a stream asking us to dial a target.
// Protocol: [2B target_len][target_string][... data ...]
func (c *Client) handleReverseStream(stream *smux.Stream) {
	defer stream.Close()

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
	pool := make([]*smux.Session, len(c.sessions))
	copy(pool, c.sessions)
	c.sessMu.RUnlock()

	if len(pool) == 0 {
		return nil, fmt.Errorf("no active sessions")
	}

	// Round-robin across healthy sessions
	for attempts := 0; attempts < len(pool); attempts++ {
		idx := int(atomic.AddUint64(&c.sessIdx, 1)) % len(pool)
		sess := pool[idx]
		if sess.IsClosed() {
			continue
		}
		stream, err := sess.OpenStream()
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

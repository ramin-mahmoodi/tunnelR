package httpmux

import (
	"log"
	"net"
	"sync"
	"time"
)

// ═══════════════════════════════════════════════════════════════
// DNS-over-Tunnel — Local DNS proxy that forwards through tunnel
//
// Prevents DNS leaks by routing all DNS queries through the
// encrypted tunnel instead of the local network.
//
// Config:
//   dns:
//     enabled: true
//     listen: "127.0.0.1:53"
//     upstream: "8.8.8.8:53"
//
// How it works:
//   1. Local app sends DNS query to 127.0.0.1:53 (UDP)
//   2. DNSProxy opens a smux stream with target "udp://8.8.8.8:53"
//   3. Stream reaches client → client dials upstream DNS via UDP
//   4. DNS response flows back through the tunnel
//   5. DNSProxy sends response back to original client
//
// The stream is bidirectional raw data — the smux stream carries
// raw DNS packets and the client-side UDP relay handles framing.
// ═══════════════════════════════════════════════════════════════

// DNSProxy listens on a local UDP port and forwards DNS queries
// through the tunnel to a remote upstream DNS server.
type DNSProxy struct {
	Listen   string  // local listen address (e.g. "127.0.0.1:53")
	Upstream string  // remote DNS server (e.g. "8.8.8.8:53")
	Client   *Client // tunnel client for opening streams
	Verbose  bool
}

// Start begins listening for DNS queries and forwarding them.
func (d *DNSProxy) Start() error {
	addr, err := net.ResolveUDPAddr("udp", d.Listen)
	if err != nil {
		return err
	}

	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()

	log.Printf("[DNS] listening on %s → upstream %s (via tunnel)", d.Listen, d.Upstream)

	// Start periodic cache cleanup
	go func() {
		tick := time.NewTicker(60 * time.Second)
		defer tick.Stop()
		for range tick.C {
			globalDNSCache.Cleanup()
		}
	}()

	buf := make([]byte, 4096) // DNS packets are max ~512B (UDP) or ~4096B (EDNS)
	for {
		n, clientAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("[DNS] read error: %v", err)
			continue
		}

		// Handle each query in a goroutine
		query := make([]byte, n)
		copy(query, buf[:n])
		go d.handleQuery(conn, clientAddr, query)
	}
}

// handleQuery forwards a single DNS query through the tunnel and returns the response.
func (d *DNSProxy) handleQuery(conn *net.UDPConn, clientAddr *net.UDPAddr, query []byte) {
	if d.Verbose {
		log.Printf("[DNS] query from %s (%d bytes)", clientAddr, len(query))
	}

	// Check cache first (use raw query as key — includes question section)
	cacheKey := string(query[2:]) // skip transaction ID (2 bytes) for cache key
	if resp, ok := globalDNSCache.Get(cacheKey); ok {
		// Restore original transaction ID from query
		reply := make([]byte, len(resp))
		copy(reply, resp)
		copy(reply[:2], query[:2]) // set matching transaction ID
		conn.WriteToUDP(reply, clientAddr)
		if d.Verbose {
			log.Printf("[DNS] cache hit for %s", clientAddr)
		}
		return
	}

	// Open a stream through the tunnel to the upstream DNS
	stream, err := d.Client.OpenStream("udp://" + d.Upstream)
	if err != nil {
		log.Printf("[DNS] tunnel stream error: %v", err)
		return
	}
	defer stream.Close()

	// Set deadline for the entire DNS transaction
	stream.SetDeadline(time.Now().Add(5 * time.Second))

	// Send raw DNS query through the stream
	// The smux stream carries raw data; the client-side handleReverseStream
	// dials the upstream UDP and relays data bidirectionally.
	if _, err := stream.Write(query); err != nil {
		return
	}

	// Read DNS response (raw data from stream)
	resp := make([]byte, 4096)
	n, err := stream.Read(resp)
	if err != nil || n == 0 {
		if d.Verbose {
			log.Printf("[DNS] response read error: %v", err)
		}
		return
	}
	resp = resp[:n]

	// Cache the response (default 60s TTL — could parse DNS TTL for accuracy)
	globalDNSCache.Set(cacheKey, resp, 60*time.Second)

	// Send response back to the original client
	if _, err := conn.WriteToUDP(resp, clientAddr); err != nil {
		if d.Verbose {
			log.Printf("[DNS] write response error: %v", err)
		}
	}
}

// ═══════════════════════════════════════════════════════════════
// DNS Cache — in-memory cache for faster repeated lookups
// ═══════════════════════════════════════════════════════════════

type dnsCache struct {
	mu      sync.RWMutex
	entries map[string]dnsCacheEntry
}

type dnsCacheEntry struct {
	response  []byte
	expiresAt time.Time
}

var globalDNSCache = &dnsCache{
	entries: make(map[string]dnsCacheEntry),
}

// Get returns a cached response if available and not expired.
func (c *dnsCache) Get(key string) ([]byte, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	entry, ok := c.entries[key]
	if !ok || time.Now().After(entry.expiresAt) {
		return nil, false
	}
	return entry.response, true
}

// Set stores a response in the cache with a TTL.
func (c *dnsCache) Set(key string, response []byte, ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[key] = dnsCacheEntry{
		response:  response,
		expiresAt: time.Now().Add(ttl),
	}
}

// Cleanup removes expired entries.
func (c *dnsCache) Cleanup() {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	for k, v := range c.entries {
		if now.After(v.expiresAt) {
			delete(c.entries, k)
		}
	}
}

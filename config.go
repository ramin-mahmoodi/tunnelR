package httpmux

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Mode          string `yaml:"mode"`
	Listen        string `yaml:"listen"`
	Transport     string `yaml:"transport"`
	PSK           string `yaml:"psk"`
	Profile       string `yaml:"profile"`
	Verbose       bool   `yaml:"verbose"`
	CertFile      string `yaml:"cert_file"`
	KeyFile       string `yaml:"key_file"`
	MaxSessions   int    `yaml:"max_sessions"`
	Heartbeat     int    `yaml:"heartbeat"`
	SkipTLSVerify bool   `yaml:"skip_tls_verify"` // default true for backward compat
	Compression   string `yaml:"compression"`     // "snappy" or "" (none)

	// ✅ NEW: Dagger-like features
	NumConnections   int  `yaml:"num_connections"`
	EnableDecoy      bool `yaml:"enable_decoy"`
	DecoyInterval    int  `yaml:"decoy_interval"` // seconds
	EmbedFakeHeaders bool `yaml:"embed_fake_headers"`

	Maps  []DaggerMap  `yaml:"maps"`
	Paths []PathConfig `yaml:"paths"`

	Smux        SmuxConfig      `yaml:"smux"`
	Advanced    AdvancedConfig  `yaml:"advanced"`
	Obfuscation ObfsCompat      `yaml:"obfuscation"`
	HTTPMimic   HTTPMimicCompat `yaml:"http_mimic"`
	Fragment    FragmentConfig  `yaml:"fragment"`

	ServerURL string `yaml:"server_url"`
	SessionID string `yaml:"session_id"`

	Forward struct {
		TCP []string `yaml:"tcp"`
		UDP []string `yaml:"udp"`
	} `yaml:"forward"`

	Mimic MimicConfig `yaml:"mimic"`
	Obfs  ObfsConfig  `yaml:"obfs"`

	SessionTimeout int `yaml:"session_timeout"`

	DNS       DNSConfig       `yaml:"dns"`
	Dashboard DashboardConfig `yaml:"dashboard"`
}

type DNSConfig struct {
	Enabled  bool   `yaml:"enabled"`
	Listen   string `yaml:"listen"`   // e.g. "127.0.0.1:53"
	Upstream string `yaml:"upstream"` // e.g. "8.8.8.8:53"
}

type PathConfig struct {
	Transport      string `yaml:"transport"`
	Addr           string `yaml:"addr"`
	ConnectionPool int    `yaml:"connection_pool"`
	AggressivePool bool   `yaml:"aggressive_pool"`
	RetryInterval  int    `yaml:"retry_interval"`
	DialTimeout    int    `yaml:"dial_timeout"`
}

type DaggerMap struct {
	Type   string `yaml:"type"`
	Bind   string `yaml:"bind"`
	Target string `yaml:"target"`
}

type SmuxConfig struct {
	KeepAlive int `yaml:"keepalive"`
	MaxRecv   int `yaml:"max_recv"`
	MaxStream int `yaml:"max_stream"`
	FrameSize int `yaml:"frame_size"`
	Version   int `yaml:"version"`
}

type AdvancedConfig struct {
	TCPNoDelay           bool `yaml:"tcp_nodelay"`
	TCPKeepAlive         int  `yaml:"tcp_keepalive"`
	TCPReadBuffer        int  `yaml:"tcp_read_buffer"`
	TCPWriteBuffer       int  `yaml:"tcp_write_buffer"`
	WebSocketReadBuffer  int  `yaml:"websocket_read_buffer"`
	WebSocketWriteBuffer int  `yaml:"websocket_write_buffer"`
	WebSocketCompression bool `yaml:"websocket_compression"`
	CleanupInterval      int  `yaml:"cleanup_interval"`
	SessionTimeout       int  `yaml:"session_timeout"`
	ConnectionTimeout    int  `yaml:"connection_timeout"`
	StreamTimeout        int  `yaml:"stream_timeout"`
	MaxConnections       int  `yaml:"max_connections"`
	MaxUDPFlows          int  `yaml:"max_udp_flows"`
	UDPFlowTimeout       int  `yaml:"udp_flow_timeout"`
	UDPBufferSize        int  `yaml:"udp_buffer_size"`
}

type HTTPMimicCompat struct {
	FakeDomain      string   `yaml:"fake_domain"`
	FakePath        string   `yaml:"fake_path"`
	UserAgent       string   `yaml:"user_agent"`
	ChunkedEncoding bool     `yaml:"chunked_encoding"`
	SessionCookie   bool     `yaml:"session_cookie"`
	CustomHeaders   []string `yaml:"custom_headers"`
}

type ObfsCompat struct {
	Enabled     bool    `yaml:"enabled"`
	MinPadding  int     `yaml:"min_padding"`
	MaxPadding  int     `yaml:"max_padding"`
	MinDelayMS  int     `yaml:"min_delay_ms"`
	MaxDelayMS  int     `yaml:"max_delay_ms"`
	BurstChance float64 `yaml:"burst_chance"`
}

func normalizePath(p string) string {
	p = strings.TrimSpace(p)
	if p == "" {
		return ""
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}

func applyBaseDefaults(c *Config) {
	if c.Profile == "" {
		c.Profile = "balanced"
	}
	if c.Heartbeat <= 0 {
		c.Heartbeat = 10
	}
	if c.SessionTimeout <= 0 {
		c.SessionTimeout = 30
	}
	if c.Advanced.SessionTimeout > 0 {
		c.SessionTimeout = c.Advanced.SessionTimeout
	}
	// NOTE: SkipTLSVerify default is set in LoadConfig before Unmarshal
	// so user-specified `false` is respected
	// ─── smux defaults (MUST match between server & client) ───
	if c.Smux.KeepAlive <= 0 {
		c.Smux.KeepAlive = 10 // 10s — safe for high-latency links
	}
	if c.Smux.MaxRecv <= 0 {
		c.Smux.MaxRecv = 4194304 // 4MB
	}
	if c.Smux.MaxStream <= 0 {
		c.Smux.MaxStream = 4194304 // 4MB
	}
	if c.Smux.FrameSize <= 0 {
		c.Smux.FrameSize = 32768 // 32KB
	}
	if c.Smux.Version <= 0 {
		c.Smux.Version = 2
	}
	if c.HTTPMimic.FakeDomain == "" {
		c.HTTPMimic.FakeDomain = "www.google.com"
	}
	if c.HTTPMimic.FakePath == "" {
		c.HTTPMimic.FakePath = "/search"
	}
	c.HTTPMimic.FakePath = normalizePath(c.HTTPMimic.FakePath)
	if c.HTTPMimic.UserAgent == "" {
		c.HTTPMimic.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
	}
	// NOTE: SessionCookie default is set in LoadConfig before Unmarshal

	// ─── Obfuscation: padding ONLY, NO delay by default ───
	// IMPORTANT: delay_ms=0 means NO delay — don't override it!
	if c.Obfuscation.MinPadding <= 0 {
		c.Obfuscation.MinPadding = 4
	}
	if c.Obfuscation.MaxPadding <= 0 {
		c.Obfuscation.MaxPadding = 32
	}
	// NOTE: We intentionally do NOT set default delay — user's 0 means 0!
	// ObfuscationDelay kills throughput on high-latency links.

	// ✅ Dagger-like feature defaults
	if c.NumConnections <= 0 {
		c.NumConnections = 4
	}
	if c.DecoyInterval <= 0 {
		c.DecoyInterval = 5
	}
	// NOTE: EnableDecoy and EmbedFakeHeaders defaults are set in LoadConfig before Unmarshal

	// ✅ Default Advanced TCP Settings (Fix for "Speed Drop" & "Disconnects")
	if c.Advanced.TCPKeepAlive <= 0 {
		c.Advanced.TCPKeepAlive = 15 // 15s keeps NAT/Firewalls open
	}
	if !c.Advanced.TCPNoDelay {
		c.Advanced.TCPNoDelay = true // Disable Nagle's algo for lower latency
	}

	// TLS Fragment defaults
	if c.Fragment.MinSize <= 0 {
		c.Fragment.MinSize = 64
	}
	if c.Fragment.MaxSize <= 0 {
		c.Fragment.MaxSize = 191
	}
	if c.Fragment.MinDelay <= 0 {
		c.Fragment.MinDelay = 1
	}
	if c.Fragment.MaxDelay <= 0 {
		c.Fragment.MaxDelay = 2
	}
	transport := strings.ToLower(c.Transport)
	if !c.Fragment.Enabled && (transport == "httpsmux" || transport == "wssmux") {
		c.Fragment.Enabled = false // v3.6.6: Disabled to reduce overhead
	}
}

func applyProfile(c *Config) {
	switch c.Profile {
	case "aggressive":
		// Aggressive = MAX SPEED: bigger buffers, zero delay, small padding
		// v3.6.6: Force disable overhead
		c.Fragment.Enabled = false
		c.Obfuscation.Enabled = false
		if c.Smux.KeepAlive <= 0 || c.Smux.KeepAlive > 5 {
			c.Smux.KeepAlive = 5
		}
		if c.Smux.FrameSize < 32768 {
			c.Smux.FrameSize = 32768
		}
		if c.Smux.MaxRecv < 4194304 {
			c.Smux.MaxRecv = 4194304
		}
		if c.Smux.MaxStream < 4194304 {
			c.Smux.MaxStream = 4194304
		}
		// NO delay — speed is king
		c.Obfuscation.MinDelayMS = 0
		c.Obfuscation.MaxDelayMS = 0
		// Small padding only
		if c.Obfuscation.MaxPadding > 64 {
			c.Obfuscation.MaxPadding = 64
		}
		c.HTTPMimic.ChunkedEncoding = false
		for i := range c.Paths {
			if c.Paths[i].ConnectionPool < 4 {
				c.Paths[i].ConnectionPool = 4
			}
			c.Paths[i].AggressivePool = true
			if c.Paths[i].RetryInterval <= 0 || c.Paths[i].RetryInterval > 2 {
				c.Paths[i].RetryInterval = 2
			}
			if c.Paths[i].DialTimeout <= 0 {
				c.Paths[i].DialTimeout = 10
			}
		}

	case "stable":
		// Stable = CONSISTENCY over burst speed: smaller buffers to prevent bloat
		if c.Smux.KeepAlive <= 0 || c.Smux.KeepAlive > 15 {
			c.Smux.KeepAlive = 15
		}
		if c.Smux.FrameSize <= 0 {
			c.Smux.FrameSize = 32768 // Revert to 32KB (2KB caused high-PPS overhead)
		}
		// Increase buffers to support ~400Mbps @ 200ms RTT (BDP tuning)
		if c.Smux.MaxRecv <= 0 || c.Smux.MaxRecv > 2097152 {
			c.Smux.MaxRecv = 2097152 // 2MB
		}
		if c.Smux.MaxStream <= 0 || c.Smux.MaxStream > 1048576 {
			c.Smux.MaxStream = 1048576 // 1MB
		}
		// Moderate delay helps jitter but hurts throughput if too high
		c.Obfuscation.MinDelayMS = 0
		c.Obfuscation.MaxDelayMS = 0
		for i := range c.Paths {
			if c.Paths[i].ConnectionPool <= 0 {
				c.Paths[i].ConnectionPool = 2
			}
			if c.Paths[i].RetryInterval <= 0 {
				c.Paths[i].RetryInterval = 3
			}
			if c.Paths[i].DialTimeout <= 0 {
				c.Paths[i].DialTimeout = 10
			}
		}

	case "latency":
		// Low latency: similar to aggressive but slightly more conservative
		if c.Smux.KeepAlive <= 0 || c.Smux.KeepAlive > 5 {
			c.Smux.KeepAlive = 5
		}
		if c.Smux.FrameSize < 32768 {
			c.Smux.FrameSize = 32768
		}
		c.Obfuscation.MinDelayMS = 0
		c.Obfuscation.MaxDelayMS = 0
		for i := range c.Paths {
			if c.Paths[i].ConnectionPool <= 0 {
				c.Paths[i].ConnectionPool = 3
			}
			if c.Paths[i].RetryInterval <= 0 {
				c.Paths[i].RetryInterval = 2
			}
			if c.Paths[i].DialTimeout <= 0 {
				c.Paths[i].DialTimeout = 10
			}
		}

	default: // balanced, cpu-efficient, gaming, etc.
		for i := range c.Paths {
			if c.Paths[i].ConnectionPool <= 0 {
				c.Paths[i].ConnectionPool = 2
			}
			if c.Paths[i].RetryInterval <= 0 {
				c.Paths[i].RetryInterval = 3
			}
			if c.Paths[i].DialTimeout <= 0 {
				c.Paths[i].DialTimeout = 10
			}
		}
	}
}

func syncAliases(c *Config) {
	if c.Mimic.FakeDomain == "" {
		c.Mimic.FakeDomain = c.HTTPMimic.FakeDomain
	}
	if c.Mimic.FakePath == "" {
		c.Mimic.FakePath = c.HTTPMimic.FakePath
	}
	if c.Mimic.UserAgent == "" {
		c.Mimic.UserAgent = c.HTTPMimic.UserAgent
	}
	if len(c.Mimic.CustomHeaders) == 0 && len(c.HTTPMimic.CustomHeaders) > 0 {
		c.Mimic.CustomHeaders = append([]string{}, c.HTTPMimic.CustomHeaders...)
	}
	c.Mimic.Chunked = c.HTTPMimic.ChunkedEncoding
	c.Mimic.SessionCookie = c.HTTPMimic.SessionCookie

	if !c.Obfs.Enabled {
		c.Obfs.Enabled = c.Obfuscation.Enabled
	}
	if c.Obfs.MinPadding <= 0 {
		c.Obfs.MinPadding = c.Obfuscation.MinPadding
	}
	if c.Obfs.MaxPadding <= 0 {
		c.Obfs.MaxPadding = c.Obfuscation.MaxPadding
	}
	if c.Obfs.MinDelayMS <= 0 {
		c.Obfs.MinDelayMS = c.Obfuscation.MinDelayMS
	}
	if c.Obfs.MaxDelayMS <= 0 {
		c.Obfs.MaxDelayMS = c.Obfuscation.MaxDelayMS
	}
	if c.Obfs.BurstChance <= 0 {
		c.Obfs.BurstChance = int(c.Obfuscation.BurstChance * 1000)
	}
}

func mapDaggerToLegacy(c *Config) {
	if len(c.Forward.TCP) == 0 && len(c.Forward.UDP) == 0 {
		for _, m := range c.Maps {
			entry := strings.TrimSpace(m.Bind) + "->" + strings.TrimSpace(m.Target)
			switch strings.ToLower(strings.TrimSpace(m.Type)) {
			case "udp":
				c.Forward.UDP = append(c.Forward.UDP, entry)
			case "both":
				c.Forward.TCP = append(c.Forward.TCP, entry)
				c.Forward.UDP = append(c.Forward.UDP, entry)
			default:
				c.Forward.TCP = append(c.Forward.TCP, entry)
			}
		}
	}
}

func LoadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	// Set bool defaults BEFORE Unmarshal so user-specified `false` is respected
	c := Config{
		SkipTLSVerify:    true,
		EnableDecoy:      true,
		EmbedFakeHeaders: true,
	}
	c.HTTPMimic.SessionCookie = true
	if err := yaml.Unmarshal(b, &c); err != nil {
		return nil, err
	}

	c.Mode = strings.ToLower(strings.TrimSpace(c.Mode))
	c.Transport = strings.ToLower(strings.TrimSpace(c.Transport))
	c.Profile = strings.ToLower(strings.TrimSpace(c.Profile))
	c.Listen = strings.TrimSpace(c.Listen)
	c.ServerURL = strings.TrimSpace(c.ServerURL)
	c.SessionID = strings.TrimSpace(c.SessionID)

	if c.SessionID == "" {
		c.SessionID = "sess-default"
	}
	if c.Mode == "server" && c.Listen == "" {
		c.Listen = "0.0.0.0:2020"
	}

	applyBaseDefaults(&c)
	applyProfile(&c)
	mapDaggerToLegacy(&c)
	syncAliases(&c)

	if err := c.Validate(); err != nil {
		return nil, err
	}

	return &c, nil
}

// Validate checks the configuration for common errors and misconfigurations.
func (c *Config) Validate() error {
	if c.Mode != "server" && c.Mode != "client" {
		return fmt.Errorf("invalid mode %q: expected 'server' or 'client'", c.Mode)
	}

	validTransports := map[string]bool{
		"tcpmux": true, "httpmux": true, "httpsmux": true,
		"wsmux": true, "wssmux": true, "": true,
	}
	if !validTransports[c.Transport] {
		return fmt.Errorf("invalid transport %q: expected tcpmux/httpmux/httpsmux/wsmux/wssmux", c.Transport)
	}

	if c.Mode == "server" {
		if c.Listen == "" {
			return fmt.Errorf("server mode requires 'listen' address")
		}
	}

	if c.Mode == "client" {
		if c.ServerURL == "" && len(c.Paths) == 0 {
			return fmt.Errorf("client mode requires 'server_url' or 'paths'")
		}
		for i, p := range c.Paths {
			if strings.TrimSpace(p.Addr) == "" {
				return fmt.Errorf("paths[%d].addr is empty", i)
			}
		}
	}

	if c.Smux.Version != 1 && c.Smux.Version != 2 {
		return fmt.Errorf("invalid smux version %d: expected 1 or 2", c.Smux.Version)
	}

	validCompression := map[string]bool{"": true, "none": true, "snappy": true}
	if !validCompression[c.Compression] {
		return fmt.Errorf("invalid compression %q: expected 'snappy' or 'none'", c.Compression)
	}

	return nil
}

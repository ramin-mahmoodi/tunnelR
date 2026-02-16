package httpmux

import (
	"bufio"
	cryptoRand "crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
)

// ═══════════════════════════════════════════════════════════════
// bufferedConn — CRITICAL FIX for data loss bug.
//
// Problem: bufio.NewReader(conn) in http.ReadResponse may read
// ahead beyond the HTTP response boundary. Those extra bytes are
// the first smux frames (keepalive, version negotiation).
// If we discard the bufio.Reader and use raw conn for EncryptedConn,
// those buffered bytes are LOST → smux session dies in ~30 seconds.
//
// Solution: wrap conn + bufio.Reader so Read() goes through the
// buffer first, preserving any pre-read smux data.
// ═══════════════════════════════════════════════════════════════

type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	return c.r.Read(p)
}

// init() removed — rand.Seed is deprecated in Go 1.22+
// All random generation now uses crypto/rand for security

// MimicConfig تنظیمات مربوط به مخفی‌سازی ترافیک
type MimicConfig struct {
	FakeDomain    string   `yaml:"fake_domain"`
	FakePath      string   `yaml:"fake_path"`
	UserAgent     string   `yaml:"user_agent"`
	CustomHeaders []string `yaml:"custom_headers"`
	SessionCookie bool     `yaml:"session_cookie"`
	Chunked       bool     `yaml:"chunked"`
}

// ClientHandshake سمت کلاینت: ارسال درخواست HTTP جعلی برای فریب فایروال
// Returns a wrapped net.Conn that preserves any buffered data.
func ClientHandshake(conn net.Conn, cfg *MimicConfig) (net.Conn, error) {
	// تنظیم مقادیر پیش‌فرض
	domain := "www.google.com"
	path := "/"
	ua := "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

	if cfg != nil {
		if cfg.FakeDomain != "" {
			domain = cfg.FakeDomain
		}
		if cfg.FakePath != "" {
			path = cfg.FakePath
		}
		if cfg.UserAgent != "" {
			ua = cfg.UserAgent
		}
	}

	// ساخت URL کامل
	fullURL := "http://" + domain + path
	// اگر {rand} در مسیر باشد، با مقدار تصادفی جایگزین می‌شود
	if strings.Contains(path, "{rand}") {
		fullURL, _ = BuildURLWithFakePath("http://"+domain, path)
	}

	req, err := http.NewRequest("GET", fullURL, nil)
	if err != nil {
		return nil, err
	}

	// تنظیم هدرهای ضروری برای شبیه‌سازی WebSocket
	req.Header.Set("Host", domain)
	req.Header.Set("User-Agent", ua)
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Key", generateWebSocketKey())
	req.Header.Set("Sec-WebSocket-Version", "13")
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")

	// افزودن هدرهای سفارشی کاربر
	if cfg != nil {
		for _, h := range cfg.CustomHeaders {
			parts := strings.SplitN(h, ":", 2)
			if len(parts) == 2 {
				req.Header.Set(strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1]))
			}
		}
		// افزودن کوکی جعلی در صورت فعال بودن
		if cfg.SessionCookie {
			req.AddCookie(&http.Cookie{Name: "session", Value: generateSessionID()})
		}
	}

	// نوشتن درخواست روی کانکشن TCP به صورت خام
	reqDump, err := httputil.DumpRequest(req, false)
	if err != nil {
		return nil, err
	}
	_, err = conn.Write(reqDump)
	if err != nil {
		return nil, err
	}

	// خواندن پاسخ سرور
	// سرور باید 101 Switching Protocols برگرداند
	// ── Read response using bufio.Reader ──
	// CRITICAL: Keep the bufio.Reader — it may contain pre-read smux data!
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, req)
	if err != nil {
		return nil, err
	}
	// Close the response body to avoid resource leaks
	if resp.Body != nil {
		resp.Body.Close()
	}

	if resp.StatusCode != 101 && resp.StatusCode != 200 {
		return nil, fmt.Errorf("handshake failed: expected 101 or 200, got %d", resp.StatusCode)
	}

	// Return wrapped conn that reads through bufio first
	return &bufferedConn{Conn: conn, r: br}, nil
}

// BuildURLWithFakePath مسیر جعلی تصادفی می‌سازد
func BuildURLWithFakePath(baseURL, fakePath string) (string, error) {
	if fakePath == "" {
		return baseURL, nil
	}
	u, err := url.Parse(baseURL)
	if err != nil {
		return "", err
	}
	fp := fakePath
	if strings.Contains(fp, "{rand}") {
		fp = strings.ReplaceAll(fp, "{rand}", randAlphaNum(8))
	}
	if !strings.HasPrefix(fp, "/") {
		fp = "/" + fp
	}
	u.Path = fp
	return u.String(), nil
}

// توابع کمکی
func randAlphaNum(n int) string {
	b := make([]byte, n)
	if _, err := cryptoRand.Read(b); err != nil {
		return strings.Repeat("x", n) // fallback
	}
	const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	for i := range b {
		b[i] = letters[int(b[i])%len(letters)]
	}
	return string(b)
}

func generateWebSocketKey() string {
	b := make([]byte, 16)
	if _, err := cryptoRand.Read(b); err != nil {
		return "dGhlIHNhbXBsZSBub25jZQ==" // fallback
	}
	return base64.StdEncoding.EncodeToString(b)
}

func generateSessionID() string {
	b := make([]byte, 16)
	if _, err := cryptoRand.Read(b); err != nil {
		return "0000000000000000" // fallback
	}
	return hex.EncodeToString(b)
}

package httpmux

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"sync/atomic"
	"time"
)

// DashboardConfig configures the web dashboard.
type DashboardConfig struct {
	Enabled       bool   `yaml:"enabled"`
	Listen        string `yaml:"listen"`         // e.g. "0.0.0.0:8080"
	User          string `yaml:"user"`           // Basic Auth Username
	Pass          string `yaml:"pass"`           // Basic Auth Password
	SessionSecret string `yaml:"session_secret"` // Cookie encryption key
}

// dashboardState holds references needed by the dashboard API.
type dashboardState struct {
	mode      string
	version   string
	client    *Client
	server    *Server
	latency   int64 // atomic ns
	startTime time.Time
	cfg       DashboardConfig
}

var dashState dashboardState

// StartDashboard launches the web dashboard HTTP server.
func StartDashboard(cfg DashboardConfig, mode, version string, client *Client, server *Server) {
	if !cfg.Enabled {
		return
	}
	addr := cfg.Listen
	if addr == "" {
		addr = "0.0.0.0:8080"
	}
	// Default credentials if missing
	if cfg.User == "" {
		cfg.User = "admin"
	}
	if cfg.Pass == "" {
		cfg.Pass = "admin"
	}

	dashState = dashboardState{
		mode:      mode,
		version:   version,
		client:    client,
		server:    server,
		startTime: time.Now(),
		cfg:       cfg,
	}

	go startPingMonitor()

	mux := http.NewServeMux()

	// Assets & Pages
	mux.HandleFunc("/", authMiddleware(handleDashboardPage))
	mux.HandleFunc("/login", handleLoginPage)

	// API
	mux.HandleFunc("/api/stats", authMiddleware(handleAPIStats))
	mux.HandleFunc("/api/logs/stream", authMiddleware(handleLogsStream))
	mux.HandleFunc("/api/config", authMiddleware(handleConfigAPI))
	mux.HandleFunc("/api/restart", authMiddleware(handleRestartAPI))

	go func() {
		log.Printf("[DASHBOARD] Listening on http://%s (User: %s)", addr, cfg.User)
		if err := http.ListenAndServe(addr, mux); err != nil {
			log.Printf("[DASHBOARD] failed: %v", err)
		}
	}()
}

// ─── Middleware & Auth ───

func authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("session_token")
		if err != nil || cookie.Value == "" {
			// API vs Browser check
			if r.Header.Get("Accept") == "application/json" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			http.Redirect(w, r, "/login", http.StatusFound)
			return
		}
		// Validate simple session (in real app, use JWT or store)
		// For now, we trust the cookie if present (simplified)
		next(w, r)
	}
}

func handleLoginPage(w http.ResponseWriter, r *http.Request) {
	if r.Method == "POST" {
		u := r.FormValue("username")
		p := r.FormValue("password")
		if u == dashState.cfg.User && p == dashState.cfg.Pass {
			// Set Cookie
			http.SetCookie(w, &http.Cookie{
				Name:     "session_token",
				Value:    "valid_session", // In prod use crypto token
				Path:     "/",
				HttpOnly: true,
			})
			http.Redirect(w, r, "/", http.StatusFound)
			return
		}
		// Failed
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(loginHTML(true)))
		return
	}
	w.Header().Set("Content-Type", "text/html")
	w.Write([]byte(loginHTML(false)))
}

// ─── API Handlers ───

func handleAPIStats(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	snap := GlobalStats.Snapshot()
	uptime := time.Since(dashState.startTime)

	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	resp := map[string]interface{}{
		"mode":     dashState.mode,
		"version":  dashState.version,
		"uptime":   uptime.String(),
		"uptime_s": uptime.Seconds(),
		"cpu":      runtime.NumGoroutine(), // Valid proxy for load
		"ram":      humanBytes(int64(m.Alloc)),
		"ram_val":  m.Alloc,

		"stats": map[string]interface{}{
			"active_conns":    snap.ActiveConns,
			"total_conns":     snap.TotalConns,
			"bytes_sent":      snap.BytesSent,
			"bytes_recv":      snap.BytesRecv,
			"sent_human":      humanBytes(snap.BytesSent),
			"recv_human":      humanBytes(snap.BytesRecv),
			"reconnects":      snap.Reconnects,
			"active_sessions": snap.ActiveSessions,
		},
	}

	lat := atomic.LoadInt64(&dashState.latency)
	if lat > 0 {
		resp["ping_ms"] = float64(lat) / 1e6
	} else {
		resp["ping_ms"] = -1
	}

	if dashState.server != nil {
		s := dashState.server
		s.sessMu.RLock()
		sessions := []map[string]interface{}{}
		for addr, sess := range s.sessions {
			sessions = append(sessions, map[string]interface{}{
				"addr": addr, "streams": sess.NumStreams(), "closed": sess.IsClosed(),
			})
		}
		s.sessMu.RUnlock()
		resp["server"] = map[string]interface{}{
			"sessions": sessions,
			"count":    len(sessions),
		}
	}

	if dashState.client != nil {
		c := dashState.client
		c.sessMu.RLock()
		sessions := []map[string]interface{}{}
		for i, ps := range c.sessions {
			age := time.Since(ps.createdAt)
			sessions = append(sessions, map[string]interface{}{
				"id": i, "age": age.String(), "streams": ps.session.NumStreams(), "closed": ps.session.IsClosed(),
			})
		}
		c.sessMu.RUnlock()

		paths := []map[string]interface{}{}
		for i, p := range c.paths {
			rtt := time.Duration(atomic.LoadInt64(&c.pathLatency[i]))
			paths = append(paths, map[string]interface{}{
				"index": i, "addr": p.Addr, "rtt": rtt.String(), "rtt_ms": float64(rtt) / 1e6,
			})
		}

		level := int(atomic.LoadInt32(&c.frameLevel))
		resp["client"] = map[string]interface{}{
			"sessions": sessions,
			"paths":    paths,
			"adaptive": map[string]interface{}{
				"level": level, "size": frameSizes[level], "label": fmt.Sprintf("%dKB", frameSizes[level]/1024),
			},
		}
	}

	json.NewEncoder(w).Encode(resp)
}

func handleLogsStream(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	serviceName := "picotun-" + dashState.mode
	// Tail logs
	cmd := exec.Command("journalctl", "-u", serviceName, "-f", "-n", "100", "--output=cat")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}

	disconnect := r.Context().Done()
	scanner := bufio.NewScanner(stdout)

	// Stream logs
	go func() {
		<-disconnect
		cmd.Process.Kill()
	}()

	for scanner.Scan() {
		msg := scanner.Text()
		fmt.Fprintf(w, "data: %s\n\n", msg)
		w.(http.Flusher).Flush()
	}
}

func handleConfigAPI(w http.ResponseWriter, r *http.Request) {
	// Simple config path resolution
	configPath := "/etc/picotun/" + dashState.mode + ".yaml"
	// Fallback for older setups: server.yaml or client.yaml
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		if dashState.mode == "server" {
			configPath = "/etc/picotun/server.yaml"
		} else {
			configPath = "/etc/picotun/config.yaml"
		}
	}

	if r.Method == "POST" {
		body, _ := io.ReadAll(r.Body)
		if len(body) > 0 {
			// Write file
			err := os.WriteFile(configPath, body, 0644)
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			w.Write([]byte("saved"))
		}
		return
	}

	// GET
	data, err := os.ReadFile(configPath)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Write(data)
}

func handleRestartAPI(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		return
	}
	serviceName := "picotun-" + dashState.mode
	go func() {
		time.Sleep(500 * time.Millisecond)
		exec.Command("systemctl", "restart", serviceName).Run()
	}()
	w.Write([]byte("restarting"))
}

func handleDashboardPage(w http.ResponseWriter, r *http.Request) {
	dashboardDir := "/var/lib/picotun/dashboard"
	indexFile := dashboardDir + "/index.html"

	if _, err := os.Stat(indexFile); os.IsNotExist(err) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(`
<!DOCTYPE html>
<html>
<head><title>TunnelR</title><style>body{background:#0f172a;color:#fff;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh}a{color:#3b82f6}</style></head>
<body>
  <div style="text-align:center">
    <h1>Dashboard Not Installed</h1>
    <p>Please run <code>setup.sh</code> and select <b>Dashboard Panel</b> to install the interface.</p>
  </div>
</body>
</html>`))
		return
	}

	// Serve static files
	fs := http.FileServer(http.Dir(dashboardDir))
	fs.ServeHTTP(w, r)
}

func humanBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}

func startPingMonitor() {
	for {
		start := time.Now()
		// Ping Google DNS port 53 (reliable, usually unblocked)
		conn, err := net.DialTimeout("tcp", "8.8.8.8:53", 2*time.Second)
		if err == nil {
			conn.Close()
			dur := time.Since(start).Nanoseconds()
			atomic.StoreInt64(&dashState.latency, dur)
		} else {
			atomic.StoreInt64(&dashState.latency, -1)
		}
		time.Sleep(5 * time.Second)
	}
}

// ─── Frontend Assets ───

func loginHTML(error bool) string {
	errDiv := ""
	if error {
		errDiv = `<div style="color:#ef4444;margin-bottom:10px;font-size:14px">Invalid credentials</div>`
	}
	return fmt.Sprintf(`<!DOCTYPE html>
<html><head><title>Login - TunnelR</title>
<style>
body{background:#0a0e1a;color:#e2e8f0;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.box{background:#111827;padding:40px;border-radius:16px;border:1px solid #1e293b;width:300px;text-align:center}
h1{margin:0 0 20px 0;font-size:20px;color:#3b82f6}
input{width:100%%;padding:10px;margin-bottom:15px;background:#1e293b;border:1px solid #334155;color:#fff;border-radius:6px;box-sizing:border-box}
button{width:100%%;padding:10px;background:#3b82f6;color:white;border:none;border-radius:6px;cursor:pointer;font-weight:bold}
button:hover{background:#2563eb}
</style>
</head><body>
<div class="box">
  <h1>TunnelR Pro</h1>
  %s
  <form method="POST">
    <input type="text" name="username" placeholder="Username" required autofocus>
    <input type="password" name="password" placeholder="Password" required>
    <button type="submit">Login</button>
  </form>
</div>
</body></html>`, errDiv)
}

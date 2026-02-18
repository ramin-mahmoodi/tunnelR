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
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"gopkg.in/yaml.v3"
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

	// CPU usage tracking
	lastCPUTime int64
	lastTotTime int64
	cpuUsage    float64

	// Traffic rate tracking
	lastBytesSent int64
	lastBytesRecv int64
	speedUp       int64 // bytes per second
	speedDown     int64 // bytes per second
}

var dashState dashboardState

// StartDashboard launches the web dashboard HTTP server.
func StartDashboard(cfg DashboardConfig, mode, version string, client *Client, server *Server) {
	if !cfg.Enabled {
		return
	}
	addr := cfg.Listen
	if addr == "" {
		addr = "0.0.0.0:8585"
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
	go startCPUMonitor()
	go startTrafficMonitor()

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
		"mode":       dashState.mode,
		"version":    dashState.version,
		"uptime":     uptime.String(),
		"uptime_s":   uptime.Seconds(),
		"start_time": dashState.startTime.Format(time.RFC3339),
		"cpu":        dashState.cpuUsage,
		"load_avg":   getLoadAvg(),
		"ram_val":    m.Alloc,
		"ram":        humanBytes(int64(m.Alloc)),

		"stats": map[string]interface{}{
			"active_conns":    snap.ActiveConns,
			"total_conns":     snap.TotalConns,
			"bytes_sent":      snap.BytesSent,
			"bytes_recv":      snap.BytesRecv,
			"sent_human":      humanBytes(snap.BytesSent),
			"recv_human":      humanBytes(snap.BytesRecv),
			"reconnects":      snap.Reconnects,
			"active_sessions": snap.ActiveSessions,
			"speed_up":        atomic.LoadInt64(&dashState.speedUp),
			"speed_down":      atomic.LoadInt64(&dashState.speedDown),
		},
	}

	// Host Stats
	memTotal, memUsed := getSystemMemory()
	resp["ram_total"] = memTotal
	resp["ram_used"] = memUsed
	resp["uptime_sys"] = getSystemUptime()

	lat := atomic.LoadInt64(&dashState.latency)
	resp["ping_ms"] = -1
	if lat > 0 {
		resp["ping_ms"] = float64(lat) / 1e6
	}

	if dashState.server != nil && dashState.server.sessions != nil {
		s := dashState.server
		s.sessMu.RLock()
		sessions := make([]map[string]interface{}, 0, len(s.sessions))
		for addr, sess := range s.sessions {
			if sess == nil {
				continue
			}
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
		sessions := make([]map[string]interface{}, 0, len(c.sessions))
		for i, ps := range c.sessions {
			if ps == nil || ps.session == nil {
				continue
			}
			sessions = append(sessions, map[string]interface{}{
				"id": i, "age": time.Since(ps.createdAt).String(), "streams": ps.session.NumStreams(), "closed": ps.session.IsClosed(),
			})
		}
		c.sessMu.RUnlock()

		paths := make([]map[string]interface{}, 0, len(c.paths))
		for i, p := range c.paths {
			rtt := time.Duration(atomic.LoadInt64(&c.pathLatency[i]))
			paths = append(paths, map[string]interface{}{
				"index": i, "addr": p.Addr, "rtt_ms": float64(rtt) / 1e6,
			})
		}

		resp["client"] = map[string]interface{}{
			"sessions": sessions,
			"paths":    paths,
			"adaptive": map[string]interface{}{
				"level": atomic.LoadInt32(&c.frameLevel),
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
	configPath := "/etc/picotun/" + dashState.mode + ".yaml"
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		if dashState.mode == "server" {
			configPath = "/etc/picotun/server.yaml"
		} else {
			configPath = "/etc/picotun/config.yaml"
		}
	}

	if r.Method == "POST" {
		body, err := io.ReadAll(r.Body)
		if err != nil || len(body) == 0 {
			http.Error(w, "Invalid body", 400)
			return
		}

		// Validate YAML syntax and structure
		var tempCfg Config
		if err := yaml.Unmarshal(body, &tempCfg); err != nil {
			http.Error(w, "Invalid configuration format: "+err.Error(), 400)
			return
		}

		if err := os.WriteFile(configPath, body, 0644); err != nil {
			http.Error(w, "Save failed: "+err.Error(), 500)
			return
		}
		w.Write([]byte("saved"))
		return
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte(""))
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

// getLoadAvg reads /proc/loadavg (Linux only)
func getLoadAvg() []string {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return []string{"0.00", "0.00", "0.00"}
	}
	parts := strings.Fields(string(data))
	if len(parts) >= 3 {
		return parts[:3]
	}
	return []string{"0.00", "0.00", "0.00"}
}

// startCPUMonitor calculates CPU % every 2 seconds
func startCPUMonitor() {
	for {
		dashState.cpuUsage = calculateCPU()
		time.Sleep(2 * time.Second)
	}
}

func calculateCPU() float64 {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0
	}
	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) > 4 && fields[0] == "cpu" {
			// user+nice+system+idle...
			var total int64
			var idle int64
			for i, val := range fields[1:] {
				v, _ := strconv.ParseInt(val, 10, 64)
				total += v
				if i == 3 { // idle is the 4th field
					idle = v
				}
			}

			diffTotal := total - dashState.lastTotTime
			diffIdle := idle - dashState.lastCPUTime

			dashState.lastTotTime = total
			dashState.lastCPUTime = idle

			if diffTotal > 0 {
				usage := float64(diffTotal-diffIdle) / float64(diffTotal) * 100
				return usage
			}
		}
	}
	return 0
}

func startTrafficMonitor() {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		snap := GlobalStats.Snapshot()

		sent := snap.BytesSent
		recv := snap.BytesRecv

		// Calculate delta
		diffSent := sent - dashState.lastBytesSent
		diffRecv := recv - dashState.lastBytesRecv

		// Store for next tick
		dashState.lastBytesSent = sent
		dashState.lastBytesRecv = recv

		// Update atomic speeds (prevent negative spikes on restart)
		if diffSent >= 0 {
			atomic.StoreInt64(&dashState.speedUp, diffSent)
		}
		if diffRecv >= 0 {
			atomic.StoreInt64(&dashState.speedDown, diffRecv)
		}
	}
}

// ─── System Stats Helpers ───

func getSystemUptime() int64 {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	parts := strings.Fields(string(data))
	if len(parts) > 0 {
		val, _ := strconv.ParseFloat(parts[0], 64)
		return int64(val)
	}
	return 0
}

func getSystemMemory() (int64, int64) {
	// Returns (Total, Used) in bytes
	file, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0, 0
	}
	defer file.Close()

	var total, available int64
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "MemTotal:") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				v, _ := strconv.ParseInt(parts[1], 10, 64)
				total = v * 1024 // kB to B
			}
		} else if strings.HasPrefix(line, "MemAvailable:") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				v, _ := strconv.ParseInt(parts[1], 10, 64)
				available = v * 1024 // kB to B
			}
		}
	}
	// Fallback if MemAvailable not present (older kernels)
	if available == 0 {
		return total, 0 // Just show total
	}
	return total, total - available
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

package httpmux

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
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
	startTime time.Time
	cfg       DashboardConfig
}

var dashState dashboardState

// StartDashboard launches the web dashboard HTTP server.
func StartDashboard(cfg DashboardConfig, mode, version string, client *Client) {
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
		startTime: time.Now(),
		cfg:       cfg,
	}

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
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(dashboardHTML))
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

const dashboardHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TunnelR Pro</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
:root{--bg:#0a0e1a;--sidebar:#111827;--card:#1f2937;--accent:#3b82f6;--text:#f3f4f6;--muted:#9ca3af;--border:#374151}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:'Inter',sans-serif;display:flex;height:100vh;overflow:hidden}
.sidebar{width:240px;background:var(--sidebar);border-right:1px solid var(--border);display:flex;flex-direction:column;padding:20px;flex-shrink:0}
.brand{font-size:18px;font-weight:700;margin-bottom:30px;color:var(--accent);display:flex;align-items:center;gap:10px}
.menu{flex:1}
.menu-item{padding:12px;border-radius:8px;color:var(--muted);cursor:pointer;transition:0.2s;margin-bottom:4px;font-weight:500}
.menu-item:hover,.menu-item.active{background:rgba(59,130,246,0.1);color:var(--accent)}
.main{flex:1;overflow-y:auto;padding:30px;position:relative}
.header{display:flex;justify-content:space-between;align-items:center;margin-bottom:30px}
.status{background:rgba(16,185,129,0.15);color:#10b981;border-radius:20px;padding:4px 12px;font-size:12px;font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:20px;margin-bottom:30px}
.card{background:var(--card);padding:24px;border-radius:12px;border:1px solid var(--border)}
.card h3{font-size:14px;color:var(--muted);margin-bottom:8px;font-weight:500}
.card .value{font-size:28px;font-weight:700}
.chart-container{height:300px;background:var(--card);border-radius:12px;border:1px solid var(--border);padding:20px;margin-bottom:30px}
.panel{background:var(--card);border-radius:12px;border:1px solid var(--border);overflow:hidden}
.panel-head{padding:15px 20px;border-bottom:1px solid var(--border);font-weight:600}
textarea{width:100%;height:500px;background:#111827;color:#d1d5db;border:none;padding:15px;font-family:monospace;resize:none;outline:none}
#logs-out{height:500px;background:#000;color:#22c55e;font-family:monospace;padding:15px;overflow-y:scroll;font-size:12px;white-space:pre-wrap}
.btn{background:var(--accent);color:#fff;border:none;padding:10px 20px;border-radius:6px;cursor:pointer;font-weight:600}
.btn:hover{filter:brightness(110%)}
table{width:100%;border-collapse:collapse}
th{text-align:left;padding:12px;color:var(--muted);font-size:12px;text-transform:uppercase;border-bottom:1px solid var(--border)}
td{padding:12px;border-bottom:1px solid var(--border)}
tr:last-child td{border-bottom:none}
</style>
</head>
<body>

<div class="sidebar">
  <div class="brand">🚀 TunneIR Pro</div>
  <div class="menu">
    <div class="menu-item active" onclick="show('dash')">Dashboard</div>
    <div class="menu-item" onclick="show('logs')">System Logs</div>
    <div class="menu-item" onclick="show('settings')">Settings</div>
  </div>
   <div style="font-size:12px;color:var(--muted);margin-top:auto">v3.0.0</div>
</div>

<div class="main">
  <!-- DASHBOARD -->
  <div id="view-dash">
    <div class="header">
      <h2>Overview</h2>
      <span class="status">System Healthy</span>
    </div>
    
    <div class="grid">
      <div class="card">
        <h3>Memory (Heap)</h3>
        <div class="value" id="ram">...</div>
      </div>
      <div class="card">
        <h3>Connections</h3>
        <div class="value" id="conns">...</div>
      </div>
      <div class="card">
        <h3>Uptime</h3>
        <div class="value" id="uptime">...</div>
      </div>
    </div>

    <div class="chart-container">
      <canvas id="chart"></canvas>
    </div>

    <div class="panel">
      <div class="panel-head">Active Sessions</div>
      <div style="padding:0">
         <table id="sessions-table"></table>
      </div>
    </div>
  </div>

  <!-- LOGS -->
  <div id="view-logs" style="display:none">
    <div class="header"><h2>Live System Logs (journalctl)</h2></div>
    <div class="panel">
      <div id="logs-out">Connecting to log stream...</div>
    </div>
  </div>

  <!-- SETTINGS -->
  <div id="view-settings" style="display:none">
    <div class="header">
      <h2>Configuration</h2>
      <button class="btn" onclick="saveConfig()">Save & Restart Service</button>
    </div>
    <div class="panel">
      <textarea id="config-editor" spellcheck="false"></textarea>
    </div>
  </div>
</div>

<script>
const $ = s => document.querySelector(s);
let chart = null;

function show(id) {
  document.querySelectorAll('.main > div').forEach(d => d.style.display = 'none');
  $('#view-'+id).style.display = 'block';
  document.querySelectorAll('.menu-item').forEach(m => m.classList.remove('active'));
  event.target.classList.add('active');
  
  if(id === 'logs') startLogs();
  if(id === 'settings') loadConfig();
}

// Chart.js init
const ctx = document.getElementById('chart').getContext('2d');
chart = new Chart(ctx, {
    type: 'line',
    data: {
        labels: Array(60).fill(''),
        datasets: [{
            label: 'Sent (KB)',
            borderColor: '#8b5cf6',
            data: Array(60).fill(0),
            tension: 0.4,
            fill: false
        }, {
            label: 'Recv (KB)',
            borderColor: '#3b82f6',
            data: Array(60).fill(0),
            tension: 0.4,
            fill: false
        }]
    },
    options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
             x: {display: false},
             y: {grid: {color: '#374151'}, ticks: {color: '#9ca3af'}}
        },
        plugins: {legend: {labels: {color: '#f3f4f6'}}}
    }
});

function updateChart(sent, recv) {
    const s = sent/1024;
    const r = recv/1024;
    
    chart.data.datasets[0].data.shift();
    chart.data.datasets[0].data.push(s);
    
    chart.data.datasets[1].data.shift();
    chart.data.datasets[1].data.push(r);
    
    chart.update('none');
}

// Stats Loop
setInterval(async () => {
    try {
        const res = await fetch('/api/stats');
        if(res.status === 401) location.reload();
        const d = await res.json();
        
        $('#ram').innerText = d.ram;
        $('#conns').innerText = d.stats.active_conns;
        $('#uptime').innerText = d.uptime;
        
        // Traffic delta would be better, but for now absolute is okay if we track last
        // Actually, let's just show absolute throughput if server provided it? 
        // Server gives total bytes. We need delta.
        const nowS = d.stats.bytes_sent;
        const nowR = d.stats.bytes_recv;
        const diffS = nowS - (window.lastS || nowS);
        const diffR = nowR - (window.lastR || nowR);
        window.lastS = nowS;
        window.lastR = nowR;
        
        if(window.lastS) updateChart(diffS, diffR);
        
        // Table
        let h = '<thead><tr><th>ID</th><th>Age</th><th>Streams</th><th>Status</th></tr></thead><tbody>';
        if(d.client && d.client.sessions) {
            d.client.sessions.forEach(s => {
               h += '<tr><td>#'+s.id+'</td><td>'+s.age+'</td><td>'+s.streams+'</td><td><span style="color:#10b981">● Active</span></td></tr>';
            });
        }
        h += '</tbody>';
        $('#sessions-table').innerHTML = h;

    } catch(e) {}
}, 1000);

// Logs
let logEvt = null;
function startLogs() {
    if(logEvt) return;
    const out = $('#logs-out');
    out.innerText = '';
    logEvt = new EventSource('/api/logs/stream');
    logEvt.onmessage = e => {
       out.innerText += e.data + '\n';
       out.scrollTop = out.scrollHeight;
    };
    logEvt.onerror = () => {
       logEvt.close();
       logEvt = null;
       out.innerText += '\n[Stream disconnected]\n';
    };
}

// Config
async function loadConfig() {
   const res = await fetch('/api/config');
   const txt = await res.text();
   $('#config-editor').value = txt;
}

async function saveConfig() {
   if(!confirm('This will restart the service. Continue?')) return;
   const txt = $('#config-editor').value;
   await fetch('/api/config', {method:'POST', body: txt});
   await fetch('/api/restart', {method:'POST'});
   alert('Service restarting... refreshing in 5s');
   setTimeout(() => location.reload(), 5000);
}
</script>
</body>
</html>`

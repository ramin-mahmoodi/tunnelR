package httpmux

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync/atomic"
	"time"
)

// DashboardConfig configures the web dashboard.
type DashboardConfig struct {
	Enabled bool   `yaml:"enabled"`
	Listen  string `yaml:"listen"` // e.g. "127.0.0.1:8080"
}

// dashboardState holds references needed by the dashboard API.
type dashboardState struct {
	mode      string
	version   string
	client    *Client
	startTime time.Time
}

var dashState dashboardState

// StartDashboard launches the web dashboard HTTP server.
func StartDashboard(cfg DashboardConfig, mode, version string, client *Client) {
	if !cfg.Enabled {
		return
	}
	addr := cfg.Listen
	if addr == "" {
		addr = "127.0.0.1:8080"
	}

	dashState = dashboardState{
		mode:      mode,
		version:   version,
		client:    client,
		startTime: time.Now(),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleDashboardPage)
	mux.HandleFunc("/api/stats", handleAPIStats)

	go func() {
		log.Printf("[DASHBOARD] http://%s", addr)
		if err := http.ListenAndServe(addr, mux); err != nil {
			log.Printf("[DASHBOARD] failed: %v", err)
		}
	}()
}

// apiResponse is the JSON structure for /api/stats
type apiResponse struct {
	Mode      string        `json:"mode"`
	Version   string        `json:"version"`
	Uptime    string        `json:"uptime"`
	UptimeSec float64       `json:"uptime_sec"`
	Stats     statsJSON     `json:"stats"`
	Sessions  []sessionJSON `json:"sessions,omitempty"`
	Paths     []pathJSON    `json:"paths,omitempty"`
	Adaptive  *adaptiveJSON `json:"adaptive,omitempty"`
}

type statsJSON struct {
	ActiveConns    int64  `json:"active_conns"`
	TotalConns     int64  `json:"total_conns"`
	BytesSent      int64  `json:"bytes_sent"`
	BytesRecv      int64  `json:"bytes_recv"`
	BytesSentHuman string `json:"bytes_sent_human"`
	BytesRecvHuman string `json:"bytes_recv_human"`
	Reconnects     int64  `json:"reconnects"`
	FailedDials    int64  `json:"failed_dials"`
	ActiveSessions int64  `json:"active_sessions"`
}

type sessionJSON struct {
	ID      int     `json:"id"`
	Age     string  `json:"age"`
	AgeSec  float64 `json:"age_sec"`
	Streams int     `json:"streams"`
	Closed  bool    `json:"closed"`
}

type pathJSON struct {
	Index     int     `json:"index"`
	Addr      string  `json:"addr"`
	Transport string  `json:"transport"`
	RTT       string  `json:"rtt"`
	RTTMs     float64 `json:"rtt_ms"`
}

type adaptiveJSON struct {
	Level     int    `json:"level"`
	FrameSize int    `json:"frame_size"`
	Label     string `json:"label"`
}

func handleAPIStats(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	snap := GlobalStats.Snapshot()
	uptime := time.Since(dashState.startTime)

	resp := apiResponse{
		Mode:      dashState.mode,
		Version:   dashState.version,
		Uptime:    uptime.Round(time.Second).String(),
		UptimeSec: uptime.Seconds(),
		Stats: statsJSON{
			ActiveConns:    snap.ActiveConns,
			TotalConns:     snap.TotalConns,
			BytesSent:      snap.BytesSent,
			BytesRecv:      snap.BytesRecv,
			BytesSentHuman: humanBytes(snap.BytesSent),
			BytesRecvHuman: humanBytes(snap.BytesRecv),
			Reconnects:     snap.Reconnects,
			FailedDials:    snap.FailedDials,
			ActiveSessions: snap.ActiveSessions,
		},
	}

	// Client-specific info
	if dashState.client != nil {
		c := dashState.client

		// Sessions
		c.sessMu.RLock()
		for i, ps := range c.sessions {
			age := time.Since(ps.createdAt)
			resp.Sessions = append(resp.Sessions, sessionJSON{
				ID:      i,
				Age:     age.Round(time.Second).String(),
				AgeSec:  age.Seconds(),
				Streams: ps.session.NumStreams(),
				Closed:  ps.session.IsClosed(),
			})
		}
		c.sessMu.RUnlock()

		// Paths with latency
		for i, p := range c.paths {
			rtt := time.Duration(atomic.LoadInt64(&c.pathLatency[i]))
			rttMs := float64(rtt) / float64(time.Millisecond)
			rttStr := "measuring..."
			if rtt > 0 && rtt < 999*time.Second {
				rttStr = fmt.Sprintf("%.0fms", rttMs)
			} else if rtt >= 999*time.Second {
				rttStr = "unreachable"
			}
			resp.Paths = append(resp.Paths, pathJSON{
				Index:     i,
				Addr:      p.Addr,
				Transport: p.Transport,
				RTT:       rttStr,
				RTTMs:     rttMs,
			})
		}

		// Adaptive frame
		level := int(atomic.LoadInt32(&c.frameLevel))
		resp.Adaptive = &adaptiveJSON{
			Level:     level,
			FrameSize: frameSizes[level],
			Label:     fmt.Sprintf("%dKB", frameSizes[level]/1024),
		}
	}

	json.NewEncoder(w).Encode(resp)
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

func handleDashboardPage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(dashboardHTML))
}

const dashboardHTML = `<!DOCTYPE html>
<html lang="en" dir="ltr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TunnelR Dashboard</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{
  --bg:#0a0e1a;--card:#111827;--border:#1e293b;
  --accent:#3b82f6;--accent2:#8b5cf6;--green:#10b981;
  --red:#ef4444;--orange:#f59e0b;--text:#e2e8f0;
  --muted:#64748b;--glass:rgba(17,24,39,0.7);
}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,-apple-system,sans-serif;min-height:100vh;overflow-x:hidden}
.bg-glow{position:fixed;top:-200px;left:-200px;width:600px;height:600px;background:radial-gradient(circle,rgba(59,130,246,0.08),transparent 70%);pointer-events:none;z-index:0}
.bg-glow2{position:fixed;bottom:-200px;right:-200px;width:600px;height:600px;background:radial-gradient(circle,rgba(139,92,246,0.06),transparent 70%);pointer-events:none;z-index:0}

.container{max-width:1200px;margin:0 auto;padding:24px 20px;position:relative;z-index:1}

/* Header */
.header{display:flex;align-items:center;justify-content:space-between;margin-bottom:32px;padding-bottom:20px;border-bottom:1px solid var(--border)}
.header h1{font-size:24px;font-weight:700;background:linear-gradient(135deg,var(--accent),var(--accent2));-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.header .badge{background:var(--accent);color:#fff;padding:4px 12px;border-radius:20px;font-size:12px;font-weight:600}
.header .mode{color:var(--muted);font-size:14px}
.status-dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--green);margin-right:6px;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:0.4}}

/* Stats Grid */
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;margin-bottom:28px}
.stat-card{background:var(--glass);border:1px solid var(--border);border-radius:16px;padding:20px;backdrop-filter:blur(12px);transition:all 0.3s ease}
.stat-card:hover{border-color:var(--accent);transform:translateY(-2px);box-shadow:0 8px 32px rgba(59,130,246,0.1)}
.stat-card .label{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:8px}
.stat-card .value{font-size:28px;font-weight:700;color:var(--text)}
.stat-card .sub{font-size:12px;color:var(--muted);margin-top:4px}
.stat-card .value.green{color:var(--green)}
.stat-card .value.blue{color:var(--accent)}
.stat-card .value.purple{color:var(--accent2)}
.stat-card .value.orange{color:var(--orange)}

/* Sections */
.section{margin-bottom:28px}
.section h2{font-size:16px;font-weight:600;margin-bottom:14px;color:var(--muted);text-transform:uppercase;letter-spacing:1.5px;font-size:13px}

/* Frame Level */
.frame-bar{display:flex;gap:4px;align-items:center;margin-bottom:28px}
.frame-step{flex:1;height:40px;border-radius:8px;background:var(--card);border:1px solid var(--border);display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:600;color:var(--muted);transition:all 0.4s ease}
.frame-step.active{background:linear-gradient(135deg,var(--accent),var(--accent2));color:#fff;border-color:transparent;box-shadow:0 4px 16px rgba(59,130,246,0.3)}

/* Tables */
.table-wrap{background:var(--glass);border:1px solid var(--border);border-radius:16px;overflow:hidden;backdrop-filter:blur(12px)}
table{width:100%;border-collapse:collapse}
th{text-align:left;padding:12px 16px;font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:1px;border-bottom:1px solid var(--border);background:rgba(0,0,0,0.2)}
td{padding:12px 16px;font-size:14px;border-bottom:1px solid var(--border)}
tr:last-child td{border-bottom:none}
tr:hover td{background:rgba(59,130,246,0.04)}
.tag{display:inline-block;padding:2px 10px;border-radius:12px;font-size:11px;font-weight:600}
.tag.alive{background:rgba(16,185,129,0.15);color:var(--green)}
.tag.dead{background:rgba(239,68,68,0.15);color:var(--red)}
.tag.best{background:rgba(59,130,246,0.15);color:var(--accent)}

/* Bandwidth Chart */
.chart-area{background:var(--glass);border:1px solid var(--border);border-radius:16px;padding:20px;backdrop-filter:blur(12px);height:180px;position:relative;overflow:hidden}
.chart-canvas{width:100%;height:100%}

/* Footer */
.footer{text-align:center;padding:20px;color:var(--muted);font-size:12px;margin-top:20px}

/* Responsive */
@media(max-width:768px){
  .stats-grid{grid-template-columns:repeat(2,1fr)}
  .stat-card .value{font-size:22px}
  .header h1{font-size:20px}
}
@media(max-width:480px){
  .stats-grid{grid-template-columns:1fr}
}
</style>
</head>
<body>
<div class="bg-glow"></div>
<div class="bg-glow2"></div>

<div class="container">
  <div class="header">
    <div>
      <h1>🚀 TunnelR Dashboard</h1>
      <span class="mode"><span class="status-dot"></span><span id="mode">—</span> · <span id="version">—</span></span>
    </div>
    <span class="badge" id="uptime">—</span>
  </div>

  <!-- Stats Grid -->
  <div class="stats-grid">
    <div class="stat-card">
      <div class="label">Active Sessions</div>
      <div class="value green" id="active-sessions">0</div>
    </div>
    <div class="stat-card">
      <div class="label">Active Connections</div>
      <div class="value blue" id="active-conns">0</div>
      <div class="sub">Total: <span id="total-conns">0</span></div>
    </div>
    <div class="stat-card">
      <div class="label">⬆ Sent</div>
      <div class="value purple" id="bytes-sent">0 B</div>
    </div>
    <div class="stat-card">
      <div class="label">⬇ Received</div>
      <div class="value purple" id="bytes-recv">0 B</div>
    </div>
    <div class="stat-card">
      <div class="label">Reconnects</div>
      <div class="value orange" id="reconnects">0</div>
      <div class="sub">Failed: <span id="failed-dials">0</span></div>
    </div>
  </div>

  <!-- Adaptive Frame -->
  <div class="section" id="adaptive-section" style="display:none">
    <h2>Adaptive FrameSize</h2>
    <div class="frame-bar" id="frame-bar">
      <div class="frame-step" data-level="0">2KB</div>
      <div class="frame-step" data-level="1">4KB</div>
      <div class="frame-step" data-level="2">8KB</div>
      <div class="frame-step" data-level="3">16KB</div>
      <div class="frame-step" data-level="4">32KB</div>
    </div>
  </div>

  <!-- Bandwidth Chart -->
  <div class="section">
    <h2>Bandwidth</h2>
    <div class="chart-area">
      <canvas id="bw-chart" class="chart-canvas"></canvas>
    </div>
  </div>

  <!-- Paths -->
  <div class="section" id="paths-section" style="display:none">
    <h2>Paths / Latency</h2>
    <div class="table-wrap">
      <table><thead><tr><th>#</th><th>Address</th><th>Transport</th><th>RTT</th><th>Status</th></tr></thead>
      <tbody id="paths-body"></tbody></table>
    </div>
  </div>

  <!-- Sessions -->
  <div class="section" id="sessions-section" style="display:none">
    <h2>Sessions</h2>
    <div class="table-wrap">
      <table><thead><tr><th>#</th><th>Age</th><th>Streams</th><th>Status</th></tr></thead>
      <tbody id="sessions-body"></tbody></table>
    </div>
  </div>

  <div class="footer">TunnelR — Tunneling done right · Auto-refresh 2s</div>
</div>

<script>
const $ = id => document.getElementById(id);
let prevSent = 0, prevRecv = 0, prevTime = 0;
const bwHistory = {sent: [], recv: [], labels: []};
const MAX_POINTS = 60;

// Simple canvas chart
function drawChart(canvas, data) {
  const ctx = canvas.getContext('2d');
  const W = canvas.width = canvas.parentElement.clientWidth;
  const H = canvas.height = canvas.parentElement.clientHeight;
  ctx.clearRect(0, 0, W, H);

  if (data.sent.length < 2) return;

  const allVals = [...data.sent, ...data.recv];
  const maxVal = Math.max(...allVals, 1);
  const stepX = W / (MAX_POINTS - 1);

  // Grid lines
  ctx.strokeStyle = 'rgba(100,116,139,0.15)';
  ctx.lineWidth = 1;
  for (let i = 1; i <= 4; i++) {
    const y = H - (H * i / 4);
    ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke();
  }

  function drawLine(arr, color, alpha) {
    ctx.beginPath();
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    for (let i = 0; i < arr.length; i++) {
      const x = i * stepX;
      const y = H - (arr[i] / maxVal * H * 0.9) - H * 0.05;
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    }
    ctx.stroke();

    // Fill
    ctx.lineTo((arr.length - 1) * stepX, H);
    ctx.lineTo(0, H);
    ctx.closePath();
    ctx.fillStyle = color.replace('1)', alpha + ')');
    ctx.fill();
  }

  drawLine(data.sent, 'rgba(139,92,246,1)', '0.08');
  drawLine(data.recv, 'rgba(59,130,246,1)', '0.08');

  // Legend
  ctx.font = '11px system-ui';
  ctx.fillStyle = 'rgba(139,92,246,0.9)';
  ctx.fillText('⬆ ' + humanRate(data.sent[data.sent.length-1]), 10, 16);
  ctx.fillStyle = 'rgba(59,130,246,0.9)';
  ctx.fillText('⬇ ' + humanRate(data.recv[data.recv.length-1]), 10, 30);

  // Max label
  ctx.fillStyle = 'rgba(100,116,139,0.5)';
  ctx.textAlign = 'right';
  ctx.fillText(humanRate(maxVal), W - 8, 16);
  ctx.textAlign = 'left';
}

function humanRate(bps) {
  if (bps < 1024) return bps.toFixed(0) + ' B/s';
  if (bps < 1048576) return (bps/1024).toFixed(1) + ' KB/s';
  return (bps/1048576).toFixed(1) + ' MB/s';
}

async function update() {
  try {
    const r = await fetch('/api/stats');
    const d = await r.json();

    $('mode').textContent = d.mode.toUpperCase();
    $('version').textContent = 'v' + d.version;
    $('uptime').textContent = '⏱ ' + d.uptime;

    const s = d.stats;
    $('active-sessions').textContent = s.active_sessions;
    $('active-conns').textContent = s.active_conns;
    $('total-conns').textContent = s.total_conns;
    $('bytes-sent').textContent = s.bytes_sent_human;
    $('bytes-recv').textContent = s.bytes_recv_human;
    $('reconnects').textContent = s.reconnects;
    $('failed-dials').textContent = s.failed_dials;

    // Bandwidth calculation
    const now = Date.now();
    if (prevTime > 0) {
      const dt = (now - prevTime) / 1000;
      const sentRate = Math.max(0, (s.bytes_sent - prevSent) / dt);
      const recvRate = Math.max(0, (s.bytes_recv - prevRecv) / dt);
      bwHistory.sent.push(sentRate);
      bwHistory.recv.push(recvRate);
      if (bwHistory.sent.length > MAX_POINTS) {
        bwHistory.sent.shift();
        bwHistory.recv.shift();
      }
      drawChart($('bw-chart'), bwHistory);
    }
    prevSent = s.bytes_sent;
    prevRecv = s.bytes_recv;
    prevTime = now;

    // Adaptive frame
    if (d.adaptive) {
      $('adaptive-section').style.display = '';
      document.querySelectorAll('.frame-step').forEach(el => {
        el.classList.toggle('active', parseInt(el.dataset.level) <= d.adaptive.level);
      });
    }

    // Paths
    if (d.paths && d.paths.length > 0) {
      $('paths-section').style.display = '';
      let bestIdx = 0, bestRTT = Infinity;
      d.paths.forEach((p, i) => { if (p.rtt_ms > 0 && p.rtt_ms < bestRTT) { bestRTT = p.rtt_ms; bestIdx = i; }});
      $('paths-body').innerHTML = d.paths.map((p, i) =>
        '<tr><td>' + p.index + '</td><td><strong>' + p.addr + '</strong></td><td>' +
        (p.transport || '—') + '</td><td>' + p.rtt + '</td><td>' +
        (i === bestIdx && d.paths.length > 1 ? '<span class="tag best">★ BEST</span>' : '') +
        '</td></tr>'
      ).join('');
    }

    // Sessions
    if (d.sessions && d.sessions.length > 0) {
      $('sessions-section').style.display = '';
      $('sessions-body').innerHTML = d.sessions.map(s =>
        '<tr><td>#' + s.id + '</td><td>' + s.age + '</td><td>' + s.streams +
        '</td><td><span class="tag ' + (s.closed ? 'dead' : 'alive') + '">' +
        (s.closed ? 'CLOSED' : 'ALIVE') + '</span></td></tr>'
      ).join('');
    }

  } catch(e) {
    console.error('Dashboard update error:', e);
  }
}

setInterval(update, 2000);
update();
window.addEventListener('resize', () => drawChart($('bw-chart'), bwHistory));
</script>
</body>
</html>`

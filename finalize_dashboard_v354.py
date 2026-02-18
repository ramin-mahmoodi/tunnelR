import os
import re

# 1. READ SETUP.SH
file_path = r"C:\GGNN\RsTunnel-main\setup.sh"
with open(file_path, 'r', encoding='utf-8') as f:
    setup_content = f.read()

# 2. DEFINE REFINED DASHBOARD CONTENT v3.5.4
# Changes:
# - Chart Title: "Traffic Overview"
# - Subtitle: "Real-time throughput monitor"
# - Legend: Dynamic HTML legend at top right (Upload (X MB/s) | Download (Y MB/s))
# - Chart: Time on X-Axis

html_content = r'''<!DOCTYPE html>
<html class="dark" lang="en">
<head>
    <meta charset="utf-8"/>
    <meta content="width=device-width, initial-scale=1.0" name="viewport"/>
    <title>TunnelR v3.5.4</title>
    <script src="https://cdn.tailwindcss.com?plugins=forms"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/js-yaml@4.1.0/dist/js-yaml.min.js"></script>
    <style>
        :root {
            --bg-body: #0f172a;
            --bg-card: #1e293b;
            --bg-nav: #1e293b;
            --text-main: #f1f5f9;
            --text-muted: #94a3b8;
            --accent: #3b82f6;
            --border: #334155;
        }
        body { background-color: var(--bg-body); color: var(--text-main); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
        .card { background-color: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06); }
        .view { display: none; }
        .view.active { display: block; animation: fadeIn 0.3s ease-in-out; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
        
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-body); }
        ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: #475569; }

        .icon-box { background: rgba(59, 130, 246, 0.1); padding: 8px; border-radius: 8px; color: #60a5fa; }
        .icon { width: 24px; height: 24px; stroke: currentColor; fill: none; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
        
        .legend-dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }
    </style>
</head>
<body class="h-screen flex overflow-hidden">

    <!-- Sidebar -->
    <aside class="w-64 bg-nav border-r border-slate-700 flex flex-col hidden md:flex" style="background-color: var(--bg-nav);">
        <div class="p-6 flex items-center gap-3 border-b border-slate-700/50">
            <div class="w-8 h-8 bg-blue-600 rounded-lg flex items-center justify-center text-white font-bold shadow-lg shadow-blue-500/20">T</div>
            <h1 class="font-bold text-lg tracking-tight text-white">TunnelR <span class="text-xs font-normal text-blue-400 bg-blue-900/30 px-1.5 py-0.5 rounded ml-1">v3.5.4</span></h1>
        </div>

        <nav class="flex-1 px-4 space-y-2 mt-6">
            <button onclick="setView('dash')" id="nav-dash" class="nav-item w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium transition-all text-white bg-blue-600 shadow-lg shadow-blue-900/20">
                <svg class="icon w-5 h-5"><rect x="3" y="3" width="7" height="7"></rect><rect x="14" y="3" width="7" height="7"></rect><rect x="14" y="14" width="7" height="7"></rect><rect x="3" y="14" width="7" height="7"></rect></svg>
                Overview
            </button>
            <button onclick="setView('logs')" id="nav-logs" class="nav-item w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium text-slate-400 hover:bg-slate-800 hover:text-white transition-all">
                <svg class="icon w-5 h-5"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line><polyline points="10 9 9 9 8 9"></polyline></svg>
                Real-time Logs
            </button>
            <button onclick="setView('settings')" id="nav-settings" class="nav-item w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium text-slate-400 hover:bg-slate-800 hover:text-white transition-all">
                <svg class="icon w-5 h-5"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>
                Configuration
            </button>
        </nav>
    </aside>

    <!-- Main Content -->
    <main class="flex-1 flex flex-col min-w-0 overflow-hidden bg-slate-900">
        <!-- Top Bar -->
        <header class="h-16 border-b border-slate-700/50 flex items-center justify-between px-8 bg-slate-800/50 backdrop-blur-sm sticky top-0 z-10">
            <h2 class="text-xl font-bold text-white tracking-tight" id="page-title">Dashboard</h2>
            <div class="flex items-center gap-4">
                <span class="text-xs font-mono text-slate-400 bg-slate-800 px-3 py-1.5 rounded-full border border-slate-700 flex items-center gap-2">
                    <span class="w-2 h-2 rounded-full bg-emerald-500 animate-pulse"></span>
                    Running
                </span>
            </div>
        </header>

        <div class="flex-1 overflow-y-auto p-8 space-y-8">
            
            <!-- VIEW: DASHBOARD -->
            <div id="view-dash" class="view active">
                <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
                    
                    <!-- CPU & RAM -->
                    <div class="card p-5 relative overflow-hidden group hover:border-slate-600 transition-colors">
                        <div class="grid grid-cols-2 gap-8">
                            <div>
                                <div class="text-slate-400 text-xs font-bold uppercase tracking-wider mb-1">CPU Usage</div>
                                <div class="text-3xl font-bold text-white tabular-nums"><span id="cpu-val">0</span>%</div>
                                <div class="w-full bg-slate-700/50 h-1.5 rounded-full overflow-hidden mt-2">
                                    <div id="cpu-bar" class="bg-blue-500 h-full transition-all duration-500" style="width:0%"></div>
                                </div>
                            </div>
                             <div>
                                <div class="text-slate-400 text-xs font-bold uppercase tracking-wider mb-1">RAM</div>
                                <div class="text-3xl font-bold text-white tabular-nums text-sm"><span id="ram-used">0</span> / <span id="ram-total">0</span></div>
                                <div class="w-full bg-slate-700/50 h-1.5 rounded-full overflow-hidden mt-2">
                                    <div id="ram-bar" class="bg-emerald-500 h-full transition-all duration-500" style="width:0%"></div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Uptime & Sessions -->
                    <div class="card p-5 relative overflow-hidden group hover:border-slate-600 transition-colors">
                        <div class="grid grid-cols-2 gap-8">
                            <div>
                                <div class="text-slate-400 text-xs font-bold uppercase tracking-wider mb-1">Service Uptime</div>
                                <div class="text-2xl font-bold text-white tabular-nums mt-1" id="svc-uptime">00:00:00</div>
                            </div>
                            <div>
                                <div class="text-slate-400 text-xs font-bold uppercase tracking-wider mb-1">Active Sessions</div>
                                <div class="text-3xl font-bold text-white tabular-nums mt-1" id="sess-count">0</div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Traffic Chart (MATCHING REFERENCE IMAGE) -->
                <div class="card p-6 mb-6">
                    <div class="flex flex-col md:flex-row justify-between items-start md:items-center mb-6">
                        <div>
                            <h3 class="text-lg font-bold text-white">Traffic Overview</h3>
                            <p class="text-slate-500 text-sm">Real-time throughput monitor</p>
                        </div>
                        <div class="flex gap-6 mt-4 md:mt-0 text-sm font-medium">
                            <div class="flex items-center text-slate-300">
                                <span class="legend-dot bg-blue-500"></span> Upload (<span id="lg-up" class="font-mono">0 B/s</span>)
                            </div>
                            <div class="flex items-center text-slate-300">
                                <span class="legend-dot bg-emerald-500"></span> Download (<span id="lg-down" class="font-mono">0 B/s</span>)
                            </div>
                        </div>
                    </div>
                    <div class="h-80 w-full">
                        <canvas id="trafficChart"></canvas>
                    </div>
                </div>
            </div>

             <!-- VIEW: LOGS -->
            <div id="view-logs" class="view">
                <div class="card flex flex-col h-[calc(100vh-160px)] border-slate-700/50">
                    <div class="p-4 border-b border-slate-700/50 flex justify-between bg-slate-800/30 rounded-t-xl items-center">
                        <span class="font-bold text-sm uppercase text-slate-300 tracking-wide">System Logs</span>
                        <div class="flex bg-slate-800 rounded-lg p-1 border border-slate-700">
                            <button onclick="setLogFilter('all')" class="px-3 py-1 rounded text-xs font-medium text-slate-300 hover:bg-slate-700 hover:text-white transition-colors" id="btn-log-all">All</button>
                            <button onclick="setLogFilter('warn')" class="px-3 py-1 rounded text-xs font-medium text-yellow-500 hover:bg-slate-700 transition-colors" id="btn-log-warn">Warn</button>
                            <button onclick="setLogFilter('error')" class="px-3 py-1 rounded text-xs font-medium text-red-500 hover:bg-slate-700 transition-colors" id="btn-log-error">Error</button>
                        </div>
                    </div>
                    <div id="logs-container" class="flex-1 overflow-y-auto p-4 font-mono text-xs text-slate-300 space-y-1.5 bg-[#0d1117]/50">
                        <div class="text-center text-slate-500 mt-20 flex flex-col items-center gap-2">
                            <div class="loader"></div>
                            <span>Connecting to log stream...</span>
                        </div>
                    </div>
                </div>
            </div>

            <!-- VIEW: SETTINGS -->
            <div id="view-settings" class="view">
                <div class="flex justify-between items-center mb-8">
                    <div>
                        <h3 class="text-2xl font-bold text-white">Configuration</h3>
                        <p class="text-slate-500 text-sm mt-1">Manage global tunnel settings</p>
                    </div>
                    <button onclick="saveConfig()" class="bg-blue-600 hover:bg-blue-500 text-white px-6 py-2.5 rounded-lg text-sm font-bold shadow-lg shadow-blue-500/20 transition-all flex items-center gap-2">
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7H5a2 2 0 00-2 2v9a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-3m-1 4l-3 3m0 0l-3-3m3 3V4"></path></svg>
                        Save & Restart
                    </button>
                </div>

                <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
                    <!-- General -->
                    <div class="card p-6 space-y-6">
                        <h4 class="text-xs font-bold text-blue-400 uppercase tracking-widest border-b border-slate-700/50 pb-3">General Settings</h4>
                        <div class="grid grid-cols-2 gap-5">
                            <div><label class="label">Mode</label><input disabled id="f-mode" class="input disabled"></div>
                            <div><label class="label">Transport</label><select id="f-transport" class="input">
                                <option value="httpmux">httpmux</option><option value="httpsmux">httpsmux</option>
                                <option value="tcpmux">tcpmux</option><option value="wsmux">wsmux</option><option value="wssmux">wssmux</option>
                            </select></div>
                            <div class="col-span-2"><label class="label">Listen Address</label><input id="f-listen" class="input font-mono"></div>
                            <div class="col-span-2"><label class="label">PSK (Secret Key)</label><input type="password" id="f-psk" class="input font-mono"></div>
                        </div>
                    </div>

                    <!-- TLS & Mimic -->
                    <div class="card p-6 space-y-6">
                        <h4 class="text-xs font-bold text-blue-400 uppercase tracking-widest border-b border-slate-700/50 pb-3">TLS & Mimicry</h4>
                        <div class="grid grid-cols-1 gap-5">
                            <div class="grid grid-cols-2 gap-5">
                                <div><label class="label">Cert File</label><input id="f-cert" class="input"></div>
                                <div><label class="label">Key File</label><input id="f-key" class="input"></div>
                            </div>
                            <div><label class="label">Fake Domain (SNI)</label><input id="f-domain" class="input" placeholder="www.google.com"></div>
                            <div><label class="label">User Agent</label><input id="f-ua" class="input text-xs" placeholder="Mozilla/5.0..."></div>
                        </div>
                    </div>

                    <!-- Smux & Obfuscation -->
                    <div class="card p-6 space-y-6">
                        <h4 class="text-xs font-bold text-blue-400 uppercase tracking-widest border-b border-slate-700/50 pb-3">Smux & Obfuscation</h4>
                        <div class="grid grid-cols-2 gap-5">
                            <div><label class="label">Version</label><input type="number" id="f-smux-ver" class="input"></div>
                            <div><label class="label">KeepAlive (s)</label><input type="number" id="f-smux-ka" class="input"></div>
                            <div><label class="label">Max Stream</label><input type="number" id="f-smux-stream" class="input"></div>
                            <div><label class="label">Max Recv</label><input type="number" id="f-smux-recv" class="input"></div>
                            
                            <div class="col-span-2 bg-slate-800/50 p-4 rounded-lg border border-slate-700/50">
                                <label class="flex items-center gap-3 text-sm text-white font-medium mb-3 cursor-pointer">
                                    <input type="checkbox" id="f-obfs-en" class="rounded bg-slate-700 border-slate-600 text-blue-500 focus:ring-blue-500">
                                    Enable Obfuscation (Padding)
                                </label>
                                <div class="flex gap-4">
                                    <div class="flex-1"><label class="label text-xs">Min Pad</label><input type="number" id="f-obfs-min" class="input text-center"></div>
                                    <div class="flex-1"><label class="label text-xs">Max Pad</label><input type="number" id="f-obfs-max" class="input text-center"></div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Advanced -->
                    <div class="card p-6 space-y-6">
                        <h4 class="text-xs font-bold text-blue-400 uppercase tracking-widest border-b border-slate-700/50 pb-3">Advanced TCP</h4>
                        <div class="grid grid-cols-2 gap-5">
                            <div><label class="label">TCP Buffer</label><input type="number" id="f-tcp-buf" class="input"></div>
                            <div><label class="label">TCP KeepAlive</label><input type="number" id="f-tcp-ka" class="input"></div>
                            <div class="col-span-2 pt-2">
                                <label class="flex items-center gap-2 text-sm text-slate-300"><input type="checkbox" id="f-nodelay" class="rounded bg-slate-700 border-slate-600 text-blue-500 focus:ring-blue-500"> Enable TCP NoDelay</label>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

        </div>
    </main>

    <script>
        const $ = s => document.querySelector(s);
        let chart = null;
        let config = {};
        
        function setView(id) {
            document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
            document.querySelectorAll('.nav-item').forEach(n => {
                n.classList.remove('bg-blue-600', 'text-white', 'shadow-lg');
                n.classList.add('text-slate-400', 'hover:bg-slate-800');
            });
            $(`#view-${id}`).classList.add('active');
            const nav = $(`#nav-${id}`);
            nav.classList.remove('text-slate-400', 'hover:bg-slate-800');
            nav.classList.add('bg-blue-600', 'text-white', 'shadow-lg');
            $('#page-title').innerText = nav.innerText.trim();
            if(id === 'logs') initLogs();
            if(id === 'settings') loadConfig();
        }

        setInterval(async () => {
            try {
                const res = await fetch('/api/stats');
                const data = await res.json();
                
                $('#cpu-val').innerText = data.cpu.toFixed(1);
                $('#cpu-bar').style.width = Math.min(data.cpu, 100) + '%';
                
                // RAM
                const usedBytes = data.ram_used || 0;
                const totalBytes = data.ram_total || 1; 
                const usedGB = (usedBytes / 1024 / 1024 / 1024).toFixed(1);
                const totalGB = (totalBytes / 1024 / 1024 / 1024).toFixed(1);
                
                if (totalBytes > 1024*1024) {
                     $('#ram-used').innerText = usedGB;
                     $('#ram-total').innerText = totalGB + 'GB';
                     const ramPct = (usedBytes / totalBytes) * 100;
                     $('#ram-bar').style.width = Math.min(ramPct, 100) + '%';
                } else {
                    $('#ram-used').innerText = humanBytes(data.ram_val);
                    $('#ram-total').innerText = 'System';
                }
                
                $('#sess-count').innerText = data.stats.total_conns;
                
                // Service Uptime
                if (data.uptime_s) {
                     $('#svc-uptime').innerText = formatUptime(data.uptime_s);
                } else {
                     $('#svc-uptime').innerText = "00:00:00";
                }

                // Update Legend
                const up = humanBytes(data.stats.speed_up || 0);
                const down = humanBytes(data.stats.speed_down || 0);
                $('#lg-up').innerText = up + '/s';
                $('#lg-down').innerText = down + '/s';

                updateChart(data.stats.speed_down || 0, data.stats.speed_up || 0);

            } catch(e) {/* quiet */}
        }, 1000);

        function formatUptime(s) {
            const days = Math.floor(s / 86400);
            s %= 86400;
            const hours = Math.floor(s / 3600);
            s %= 3600;
            const minutes = Math.floor(s / 60);
            s = Math.floor(s % 60);
            
            let res = "";
            if(days > 0) res += `${days}d `;
            res += `${String(hours).padStart(2, '0')}:`;
            res += `${String(minutes).padStart(2, '0')}:`;
            res += `${String(s).padStart(2, '0')}`;
            return res;
        }

        function updateChart(rx, tx) {
            const now = new Date();
            const timeLabel = now.getHours().toString().padStart(2,'0') + ':' + now.getMinutes().toString().padStart(2,'0');

            if(!chart) {
                const ctx = $('#trafficChart').getContext('2d');
                chart = new Chart(ctx, {
                    type: 'line',
                    data: {
                        labels: Array(30).fill(''),
                        datasets: [
                            { label: 'Download', data: Array(30).fill(0), borderColor: '#10b981', backgroundColor: (ctx) => {
                                const bg = ctx.chart.ctx.createLinearGradient(0,0,0,300);
                                bg.addColorStop(0, 'rgba(16, 185, 129, 0.4)');
                                bg.addColorStop(1, 'rgba(16, 185, 129, 0)');
                                return bg;
                            }, fill:true, borderWidth: 2, pointRadius:0, tension: 0.4 },
                            { label: 'Upload', data: Array(30).fill(0), borderColor: '#3b82f6', backgroundColor: (ctx) => {
                                const bg = ctx.chart.ctx.createLinearGradient(0,0,0,300);
                                bg.addColorStop(0, 'rgba(59, 130, 246, 0.4)');
                                bg.addColorStop(1, 'rgba(59, 130, 246, 0)');
                                return bg;
                            }, fill:true, borderWidth: 2, pointRadius:0, tension: 0.4 }
                        ]
                    },
                    options: { 
                        responsive: true, 
                        maintainAspectRatio: false, 
                        scales: { 
                            x:{display:true, grid:{display:false}, ticks:{color:'#64748b', maxTicksLimit: 6} }, 
                            y:{display:true, position:'right', grid:{color:'#1e293b'}, ticks:{color:'#64748b', callback: function(val){ return humanBytes(val) }} } 
                        }, 
                        plugins: { legend:{display:false} }, 
                        animation: false, 
                        interaction: {intersect: false} 
                    }
                });
            }
            
            chart.data.labels.push(timeLabel);
            chart.data.labels.shift();

            chart.data.datasets[0].data.push(rx);
            chart.data.datasets[1].data.push(tx);
            chart.data.datasets[0].data.shift();
            chart.data.datasets[1].data.shift();
            chart.update();
        }

        function humanBytes(b) {
            if(b==0) return '0 B';
            const u = ['B', 'KB', 'MB', 'GB'];
            let i=0;
            while(b >= 1024 && i < u.length-1) { b/=1024; i++; }
            return b.toFixed(1) + ' ' + u[i];
        }

        // --- CONFIG LOADER & LOGS (Unchanged) ---
        // ... (Keep existing logic for brevity in python script construction) ...
        // Re-injecting full script for safety
        
        async function loadConfig() {
            const t = await (await fetch('/api/config')).text();
            config = jsyaml.load(t);
            if(!config) return;
            setVal('mode', config.mode);
            setVal('transport', config.transport);
            setVal('listen', config.listen);
            setVal('psk', config.psk);
            setVal('cert', config.cert_file);
            setVal('key', config.key_file);
            const http = config.http_mimic || {};
            setVal('domain', http.fake_domain);
            setVal('ua', http.user_agent);
            const smux = config.smux || {};
            setVal('smux-ver', smux.version);
            setVal('smux-ka', smux.keepalive);
            setVal('smux-stream', smux.max_stream);
            setVal('smux-recv', smux.max_recv);
            const obfs = config.obfuscation || {};
            $('#f-obfs-en').checked = obfs.enabled;
            setVal('obfs-min', obfs.min_padding);
            setVal('obfs-max', obfs.max_padding);
            const adv = config.advanced || {};
            setVal('tcp-buf', adv.tcp_read_buffer);
            setVal('tcp-ka', adv.tcp_keepalive);
            $('#f-nodelay').checked = adv.tcp_nodelay;
        }
        function setVal(id, val) { const el = $(`#f-${id}`); if(el) el.value = (val !== undefined && val !== null) ? val : ''; }
        async function saveConfig() {
            if(!confirm('Apply changes and restart?')) return;
            config.listen = $('#f-listen').value;
            config.psk = $('#f-psk').value;
            config.transport = $('#f-transport').value;
            config.cert_file = $('#f-cert').value;
            config.key_file = $('#f-key').value;
            if(!config.http_mimic) config.http_mimic = {};
            config.http_mimic.fake_domain = $('#f-domain').value;
            config.http_mimic.user_agent = $('#f-ua').value;
            if(!config.smux) config.smux = {};
            config.smux.version = parseInt($('#f-smux-ver').value);
            config.smux.keepalive = parseInt($('#f-smux-ka').value);
            config.smux.max_stream = parseInt($('#f-smux-stream').value);
            config.smux.max_recv = parseInt($('#f-smux-recv').value);
            if(!config.obfuscation) config.obfuscation = {};
            config.obfuscation.enabled = $('#f-obfs-en').checked;
            config.obfuscation.min_padding = parseInt($('#f-obfs-min').value);
            config.obfuscation.max_padding = parseInt($('#f-obfs-max').value);
            if(!config.advanced) config.advanced = {};
            config.advanced.tcp_read_buffer = parseInt($('#f-tcp-buf').value);
            config.advanced.tcp_write_buffer = parseInt($('#f-tcp-buf').value); 
            config.advanced.tcp_keepalive = parseInt($('#f-tcp-ka').value);
            config.advanced.tcp_nodelay = $('#f-nodelay').checked;
            const yaml = jsyaml.dump(config);
            try {
                const r = await fetch('/api/config', { method:'POST', body: yaml });
                if(r.ok) { await fetch('/api/restart', { method:'POST' }); alert('Restarting...'); setTimeout(()=>location.reload(), 3000); } 
                else { const txt = await r.text(); alert('Error: '+txt); }
            } catch(e) { alert(e); }
        }
        let logSrc;
        function initLogs() {
            if(logSrc) return;
            $('#logs-container').innerHTML = '';
            logSrc = new EventSource('/api/logs/stream');
            logSrc.onmessage = e => {
                const d = document.createElement('div');
                const t = e.data;
                d.textContent = t;
                if(t.includes('ERR') || t.includes('fail')) d.className = 'text-red-400 border-l-2 border-red-500 pl-2 bg-red-400/10 rounded-r';
                else if(t.includes('WARN')) d.className = 'text-yellow-400 border-l-2 border-yellow-500 pl-2 bg-yellow-400/10 rounded-r';
                else d.className = 'text-slate-300 border-l-2 border-transparent pl-2 hover:bg-slate-800/50 rounded-r transition-colors';
                d.classList.add(t.includes('ERR')||t.includes('fail') ? 'log-error' : (t.includes('WARN')?'log-warn':'log-info'));
                const c = $('#logs-container');
                c.appendChild(d);
                if(c.children.length > 200) c.removeChild(c.firstChild);
                c.scrollTop = c.scrollHeight;
                if(window.logFilter) applyFilter(d);
            };
        }
        window.logFilter = 'all';
        function setLogFilter(f) { 
            window.logFilter = f; 
            document.querySelectorAll('#logs-container div').forEach(applyFilter); 
            ['all','warn','error'].forEach(id => { $(`#btn-log-${id}`).classList.remove('bg-slate-700', 'text-white'); if(id === 'all') $(`#btn-log-${id}`).classList.add('text-slate-300'); });
            $(`#btn-log-${f}`).classList.add('bg-slate-700', 'text-white');
        }
        function applyFilter(d) {
            if(window.logFilter === 'all') d.style.display = 'block';
            else d.style.display = d.classList.contains('log-'+window.logFilter) ? 'block' : 'none';
        }
    </script>
    <style>.label { display: block; font-size: 11px; font-weight: 700; color: #94a3b8; text-transform: uppercase; margin-bottom: 6px; letter-spacing: 0.05em; } .input { width: 100%; background: #0f172a; border: 1px solid #334155; color: white; padding: 8px 12px; border-radius: 8px; font-size: 13px; transition: border-color 0.15s ease-in-out; } .input:focus { border-color: #3b82f6; ring: 2px solid #3b82f630; outline: none; } .input.disabled { opacity: 0.5; cursor: not-allowed; background-color: #1e293b; }</style>
</body>
</html>
'''

def create_install_func(html):
    return f"""install_dashboard_assets() {{
    local DASH_DIR="/var/lib/picotun/dashboard"
    mkdir -p "$DASH_DIR"
    
    echo "Creating Dashboard Assets (v3.5.4)..."

    cat <<'EOF' > "$DASH_DIR/index.html"
{html}
EOF
}}
"""

pattern = r"install_dashboard_assets\(\) \{.*?^\}"
replacement = create_install_func(html_content)

# Regex safety: escape backslashes
replacement = replacement.replace('\\', '\\\\')

new_content = re.sub(pattern, replacement, setup_content, flags=re.DOTALL|re.MULTILINE)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(new_content)

print("Fix Dashboard v3.5.4 injected successfully.")

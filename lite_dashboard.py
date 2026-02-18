import os

# 1. READ SETUP.SH
file_path = r"C:\GGNN\RsTunnel-main\setup.sh"
with open(file_path, 'r', encoding='utf-8') as f:
    setup_content = f.read()

# 2. DEFINE LITE DASHBOARD CONTENT
# Modern, High-Performance, Solid Colors, No external fonts (using system sans + embedded SVG)

lite_html = r'''<!DOCTYPE html>
<html class="dark" lang="en">
<head>
    <meta charset="utf-8"/>
    <meta content="width=device-width, initial-scale=1.0" name="viewport"/>
    <title>TunnelR Lite</title>
    <script src="https://cdn.tailwindcss.com?plugins=forms"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/js-yaml@4.1.0/dist/js-yaml.min.js"></script>
    <style>
        /* Lite Theme: Solid Colors, High Contrast, Performance Focused */
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
        .card { background-color: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; box-shadow: 0 1px 2px 0 rgba(0,0,0,0.05); }
        .view { display: none; }
        .view.active { display: block; }
        
        /* Custom Scrollbar */
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-body); }
        ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: #475569; }

        /* Icon sizing */
        .icon { width: 20px; height: 20px; fill: currentColor; }
        
        /* Spinner */
        .loader { border: 2px solid #334155; border-top: 2px solid var(--accent); border-radius: 50%; width: 16px; height: 16px; animation: spin 1s linear infinite; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body class="h-screen flex overflow-hidden">

    <!-- Sidebar -->
    <aside class="w-64 bg-nav border-r border-slate-700 flex flex-col z-20 hidden md:flex" style="background-color: var(--bg-nav);">
        <div class="p-4 flex items-center gap-3 border-b border-slate-700">
            <div class="w-8 h-8 bg-blue-500 rounded flex items-center justify-center text-white font-bold">T</div>
            <h1 class="font-bold text-lg tracking-tight text-white">TunnelR <span class="text-xs font-normal text-blue-400 bg-blue-900/30 px-1 py-0.5 rounded">Lite</span></h1>
        </div>

        <nav class="flex-1 px-2 space-y-1 mt-4">
            <button onclick="setView('dash')" id="nav-dash" class="nav-item w-full flex items-center gap-3 px-3 py-2 rounded text-sm font-medium transition-colors text-white bg-blue-600">
                <!-- Dashboard Icon -->
                <svg class="icon" viewBox="0 0 24 24"><path d="M3 13h8V3H3v10zm0 8h8v-6H3v6zm10 0h8V11h-8v10zm0-18v6h8V3h-8z"/></svg>
                Overview
            </button>
            <button onclick="setView('logs')" id="nav-logs" class="nav-item w-full flex items-center gap-3 px-3 py-2 rounded text-sm font-medium text-slate-400 hover:bg-slate-700 hover:text-white transition-colors">
                <!-- Logs Icon -->
                <svg class="icon" viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                Real-time Logs
            </button>
            <button onclick="setView('settings')" id="nav-settings" class="nav-item w-full flex items-center gap-3 px-3 py-2 rounded text-sm font-medium text-slate-400 hover:bg-slate-700 hover:text-white transition-colors">
                <!-- Settings Icon -->
                <svg class="icon" viewBox="0 0 24 24"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.488.488 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.04.17 0 .34.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.58 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.04-.17 0-.34-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>
                Configuration
            </button>
        </nav>
        
        <div class="p-4 text-xs text-slate-500 border-t border-slate-700">
            v<span id="version-disp">3.5.0</span>
        </div>
    </aside>

    <!-- Main Content -->
    <main class="flex-1 flex flex-col min-w-0 overflow-hidden bg-slate-900">
        <!-- Top Bar -->
        <header class="h-14 border-b border-slate-700 flex items-center justify-between px-6 bg-slate-800">
            <h2 class="text-lg font-semibold text-white" id="page-title">Overview</h2>
            <div class="flex items-center gap-4">
                <span class="text-xs font-mono text-slate-400">UPTIME: <span id="uptime-val" class="text-white">00:00:00</span></span>
            </div>
        </header>

        <div class="flex-1 overflow-y-auto p-6 space-y-6">
            
            <!-- VIEW: DASHBOARD -->
            <div id="view-dash" class="view active">
                <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-6">
                    <!-- Stat Cards -->
                    <div class="card p-4">
                        <div class="text-slate-400 text-xs font-bold uppercase">CPU Usage</div>
                        <div class="text-2xl font-bold text-white mt-1"><span id="cpu-val">0</span>%</div>
                        <div class="w-full bg-slate-700 h-1 mt-2 rounded overflow-hidden"><div id="cpu-bar" class="bg-blue-500 h-full" style="width:0%"></div></div>
                    </div>
                    <div class="card p-4">
                        <div class="text-slate-400 text-xs font-bold uppercase">RAM Usage</div>
                        <div class="text-2xl font-bold text-white mt-1"><span id="ram-val">0</span></div>
                        <div class="text-xs text-slate-500 mt-1">System Memory</div>
                    </div>
                    <div class="card p-4">
                        <div class="text-slate-400 text-xs font-bold uppercase">Load Avg</div>
                        <div class="text-2xl font-bold text-white mt-1" id="load-val">0.00</div>
                        <div class="text-xs text-slate-500 mt-1 font-mono" id="load-full">1m 5m 15m</div>
                    </div>
                    <div class="card p-4">
                        <div class="text-slate-400 text-xs font-bold uppercase">Sessions</div>
                        <div class="text-2xl font-bold text-white mt-1" id="sess-count">0</div>
                        <div class="text-xs text-slate-500 mt-1">Active Connections</div>
                    </div>
                </div>

                <!-- Traffic Chart -->
                <div class="card p-4 mb-6">
                    <div class="flex justify-between items-center mb-4">
                        <h3 class="text-sm font-bold text-white uppercase">Traffic</h3>
                        <div class="flex gap-4 text-xs font-mono">
                            <span class="text-blue-400">â†‘ <span id="speed-up">0 B/s</span></span>
                            <span class="text-emerald-400">â†“ <span id="speed-down">0 B/s</span></span>
                        </div>
                    </div>
                    <div class="h-64 w-full">
                        <canvas id="trafficChart"></canvas>
                    </div>
                </div>
            </div>

            <!-- VIEW: LOGS -->
            <div id="view-logs" class="view">
                <div class="card flex flex-col h-[calc(100vh-140px)]">
                    <div class="p-3 border-b border-slate-700 flex justify-between bg-slate-800 rounded-t">
                        <span class="font-bold text-xs uppercase text-slate-400">System Logs</span>
                        <div class="flex gap-2">
                            <button onclick="setLogFilter('all')" class="text-xs text-white hover:text-blue-400">All</button>
                            <button onclick="setLogFilter('warn')" class="text-xs text-yellow-400 hover:text-white">Warn</button>
                            <button onclick="setLogFilter('error')" class="text-xs text-red-400 hover:text-white">Error</button>
                        </div>
                    </div>
                    <div id="logs-container" class="flex-1 overflow-y-auto p-4 font-mono text-xs text-slate-300 space-y-1 bg-[#0d1117]">
                        <div class="text-center text-slate-500 mt-10">Waiting for logs...</div>
                    </div>
                </div>
            </div>

            <!-- VIEW: SETTINGS -->
            <div id="view-settings" class="view">
                <div class="flex justify-between items-center mb-6">
                    <h3 class="text-xl font-bold text-white">Full Configuration</h3>
                    <button onclick="saveConfig()" class="bg-blue-600 hover:bg-blue-500 text-white px-4 py-2 rounded text-sm font-bold shadow">Save & Restart</button>
                </div>

                <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
                    <!-- General -->
                    <div class="card p-5 space-y-4">
                        <h4 class="text-xs font-bold text-blue-400 uppercase border-b border-slate-700 pb-2">General</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><label class="label">Mode</label><input disabled id="f-mode" class="input disabled"></div>
                            <div><label class="label">Transport</label><select id="f-transport" class="input">
                                <option value="httpmux">httpmux</option><option value="httpsmux">httpsmux</option>
                                <option value="tcpmux">tcpmux</option><option value="wsmux">wsmux</option><option value="wssmux">wssmux</option>
                            </select></div>
                            <div><label class="label">Listen Addr</label><input id="f-listen" class="input"></div>
                            <div><label class="label">PSK (Secret)</label><input type="password" id="f-psk" class="input"></div>
                        </div>
                    </div>

                    <!-- TLS & Mimic -->
                    <div class="card p-5 space-y-4">
                        <h4 class="text-xs font-bold text-blue-400 uppercase border-b border-slate-700 pb-2">TLS / Mimicry</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><label class="label">Cert File</label><input id="f-cert" class="input"></div>
                            <div><label class="label">Key File</label><input id="f-key" class="input"></div>
                            <div><label class="label">Fake Domain</label><input id="f-domain" class="input"></div>
                            <div><label class="label">User Agent</label><input id="f-ua" class="input text-xs"></div>
                        </div>
                    </div>

                    <!-- Smux & Obfuscation -->
                    <div class="card p-5 space-y-4">
                        <h4 class="text-xs font-bold text-blue-400 uppercase border-b border-slate-700 pb-2">Smux & Obfuscation</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><label class="label">Smux Ver</label><input type="number" id="f-smux-ver" class="input"></div>
                            <div><label class="label">KeepAlive</label><input type="number" id="f-smux-ka" class="input"></div>
                            <div><label class="label">Max Stream</label><input type="number" id="f-smux-stream" class="input"></div>
                            <div><label class="label">Max Recv</label><input type="number" id="f-smux-recv" class="input"></div>
                            <div class="col-span-2 flex items-center gap-4 mt-2">
                                <label class="flex items-center gap-2 text-sm text-slate-300"><input type="checkbox" id="f-obfs-en" class="rounded bg-slate-800 border-slate-600"> Enable Obfs</label>
                                <input placeholder="Min Pad" type="number" id="f-obfs-min" class="input w-24">
                                <input placeholder="Max Pad" type="number" id="f-obfs-max" class="input w-24">
                            </div>
                        </div>
                    </div>

                    <!-- Advanced -->
                    <div class="card p-5 space-y-4">
                        <h4 class="text-xs font-bold text-blue-400 uppercase border-b border-slate-700 pb-2">Advanced Network</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><label class="label">TCP Buffer</label><input type="number" id="f-tcp-buf" class="input"></div>
                            <div><label class="label">TCP KeepAlive</label><input type="number" id="f-tcp-ka" class="input"></div>
                            <div class="col-span-2">
                                <label class="flex items-center gap-2 text-sm text-slate-300"><input type="checkbox" id="f-nodelay" class="rounded bg-slate-800 border-slate-600"> TCP NoDelay</label>
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
        
        // --- VIEW LOGIC ---
        function setView(id) {
            document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
            document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('bg-blue-600', 'text-white'));
            document.querySelectorAll('.nav-item').forEach(n => n.classList.add('text-slate-400'));
            
            $(`#view-${id}`).classList.add('active');
            const nav = $(`#nav-${id}`);
            nav.classList.remove('text-slate-400', 'hover:bg-slate-700');
            nav.classList.add('bg-blue-600', 'text-white');
            
            if(id === 'logs') initLogs();
            if(id === 'settings') loadConfig();
        }

        // --- STATS LOOP ---
        setInterval(async () => {
            try {
                const res = await fetch('/api/stats');
                const data = await res.json();
                
                $('#cpu-val').innerText = data.cpu.toFixed(1);
                $('#cpu-bar').style.width = Math.min(data.cpu, 100) + '%';
                $('#ram-val').innerText = data.ram;
                $('#uptime-val').innerText = data.uptime.split('.')[0];
                $('#version-disp').innerText = data.version;
                $('#sess-count').innerText = data.stats.total_conns;
                
                if(data.load_avg) {
                    $('#load-val').innerText = data.load_avg[0];
                    $('#load-full').innerText = data.load_avg.join('  ');
                }

                // Traffic (Server-calculated)
                const up = humanBytes(data.stats.speed_up || 0);
                const down = humanBytes(data.stats.speed_down || 0);
                $('#speed-up').innerText = up + '/s';
                $('#speed-down').innerText = down + '/s';

                updateChart(data.stats.speed_down || 0, data.stats.speed_up || 0);

            } catch(e) {/* quiet */}
        }, 1000);

        function updateChart(rx, tx) {
            if(!chart) {
                const ctx = $('#trafficChart').getContext('2d');
                chart = new Chart(ctx, {
                    type: 'line',
                    data: {
                        labels: Array(30).fill(''),
                        datasets: [
                            { label: 'DL', data: Array(30).fill(0), borderColor: '#10b981', borderWidth: 2, pointRadius:0, tension: 0.1 },
                            { label: 'UL', data: Array(30).fill(0), borderColor: '#3b82f6', borderWidth: 2, pointRadius:0, tension: 0.1 }
                        ]
                    },
                    options: { responsive: true, maintainAspectRatio: false, scales: { x:{display:false}, y:{display:false, min:0} }, plugins: { legend:{display:false} }, animation: false }
                });
            }
            // Add new data
            chart.data.datasets[0].data.push(rx);
            chart.data.datasets[1].data.push(tx);
            chart.data.datasets[0].data.shift();
            chart.data.datasets[1].data.shift();
            chart.update();
        }

        function humanBytes(b) {
            const u = ['B', 'KB', 'MB', 'GB'];
            let i=0;
            while(b >= 1024 && i < u.length-1) { b/=1024; i++; }
            return b.toFixed(1) + ' ' + u[i];
        }

        // --- CONFIG LOADER ---
        async function loadConfig() {
            const t = await (await fetch('/api/config')).text();
            config = jsyaml.load(t);
            if(!config) return;

            // Map fields (Flat + Nested)
            setVal('mode', config.mode);
            setVal('transport', config.transport);
            setVal('listen', config.listen);
            setVal('psk', config.psk);
            setVal('cert', config.cert_file);
            setVal('key', config.key_file);
            
            // Nested
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

        function setVal(id, val) {
            const el = $(`#f-${id}`);
            if(el) el.value = (val !== undefined && val !== null) ? val : '';
        }

        async function saveConfig() {
            if(!confirm('Apply changes and restart?')) return;
            
            // Read back
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
            config.advanced.tcp_write_buffer = parseInt($('#f-tcp-buf').value); // sync
            config.advanced.tcp_keepalive = parseInt($('#f-tcp-ka').value);
            config.advanced.tcp_nodelay = $('#f-nodelay').checked;

            const yaml = jsyaml.dump(config);
            try {
                const r = await fetch('/api/config', { method:'POST', body: yaml });
                if(r.ok) {
                    await fetch('/api/restart', { method:'POST' });
                    alert('Restarting...');
                    setTimeout(()=>location.reload(), 3000);
                } else {
                    const txt = await r.text();
                    alert('Error: '+txt);
                }
            } catch(e) { alert(e); }
        }

        // --- LOGS ---
        let logSrc;
        function initLogs() {
            if(logSrc) return;
            $('#logs-container').innerHTML = '';
            logSrc = new EventSource('/api/logs/stream');
            logSrc.onmessage = e => {
                const d = document.createElement('div');
                const t = e.data;
                d.textContent = t;
                if(t.includes('ERR') || t.includes('fail')) d.className = 'text-red-400';
                else if(t.includes('WARN')) d.className = 'text-yellow-400';
                
                // Add class for filtering
                d.classList.add(t.includes('ERR')||t.includes('fail') ? 'log-error' : (t.includes('WARN')?'log-warn':'log-info'));
                
                const c = $('#logs-container');
                c.appendChild(d);
                if(c.children.length > 200) c.removeChild(c.firstChild);
                c.scrollTop = c.scrollHeight;
                
                // Apply current filter
                if(window.logFilter) applyFilter(d);
            };
        }
        
        window.logFilter = 'all';
        function setLogFilter(f) { window.logFilter = f; document.querySelectorAll('#logs-container div').forEach(applyFilter); }
        function applyFilter(d) {
            if(window.logFilter === 'all') d.style.display = 'block';
            else d.style.display = d.classList.contains('log-'+window.logFilter) ? 'block' : 'none';
        }
    </script>
    <style>.label { display: block; font-size: 11px; font-weight: 700; color: #94a3b8; text-transform: uppercase; margin-bottom: 4px; } .input { width: 100%; background: #0f172a; border: 1px solid #334155; color: white; padding: 6px 10px; border-radius: 4px; font-size: 13px; } .input:focus { border-color: #3b82f6; outline: none; } .input.disabled { opacity: 0.5; cursor: not-allowed; }</style>
</body>
</html>
'''

# 3. EMBED NEW DASHBOARD INTO SETUP.SH
# We define a function to construct the shell heredoc
def create_install_func(html):
    return f"""install_dashboard_assets() {{
    local DASH_DIR="/var/lib/picotun/dashboard"
    mkdir -p "$DASH_DIR"
    
    echo "Creating Lite Dashboard Assets (v3.5.0)..."

    cat <<'EOF' > "$DASH_DIR/index.html"
{html}
EOF
}}
"""

import re
# Regex to replace existing install_dashboard_assets function
pattern = r"install_dashboard_assets\(\) \{.*?^\}"
replacement = create_install_func(lite_html)

# Escape backslashes for re.sub to prevents it from interpreting \n, \t, etc.
replacement = replacement.replace('\\', '\\\\')

new_content = re.sub(pattern, replacement, setup_content, flags=re.DOTALL|re.MULTILINE)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(new_content)

print("Lite Dashboard injected successfully.")

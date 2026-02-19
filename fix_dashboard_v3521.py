import os
import re

# 1. READ SETUP.SH
file_path = r"C:\GGNN\RsTunnel-main\setup.sh"
with open(file_path, 'r', encoding='utf-8') as f:
    setup_content = f.read()

# 2. DEFINE REFINED DASHBOARD CONTENT v3.5.21
# Changes:
# - Fix: Sessions Count now shows ACTIVE connections (goes up/down) instead of TOTAL (only up).
# - Retained: All previous fixes (Units, Snappy Chart, Data Keys).

html_content = r'''<!DOCTYPE html>
<html class="dark" lang="en">
<head>
    <meta charset="utf-8"/>
    <meta content="width=device-width, initial-scale=1.0" name="viewport"/>
    <title>TunnelR v3.5.21</title>
    <script src="https://cdn.tailwindcss.com?plugins=forms"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/js-yaml/4.1.0/js-yaml.min.js"></script>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
        :root {
            --bg-body: #0d1117;
            --bg-card: #161b22; 
            --bg-nav: #0d1117;
            --text-main: #f0f6fc;
            --text-muted: #8b949e;
            --border: #30363d;
            --accent: #58a6ff;
        }
        body { background-color: var(--bg-body); color: var(--text-main); font-family: 'Inter', sans-serif; }
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-body); }
        ::-webkit-scrollbar-thumb { background: #30363d; border-radius: 4px; }
        
        .premium-card { background-color: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 24px; position: relative; transition: transform 0.2s, border-color 0.2s; min-height: 180px; display: flex; flex-direction: column; justify-content: space-between; }
        .premium-card:hover { border-color: var(--accent); }
        
        /* Typography Standards */
        .card-label { font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); margin-bottom: 4px; }
        .card-value { font-size: 1.875rem; line-height: 2.25rem; font-weight: 700; color: var(--text-main); letter-spacing: -0.02em; }
        .unit-span { font-size: 1.125rem; font-weight: 400; color: #6e7681; margin-left: 2px; }
        .card-footer-text { font-size: 0.75rem; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; color: var(--text-muted); margin-top: auto; padding-top: 16px; display: flex; align-items: center; gap: 6px; }

        .icon-box { width: 40px; height: 40px; border-radius: 10px; display: flex; align-items: center; justify-content: center; position: absolute; top: 24px; right: 24px; }
        .icon-blue { background: rgba(56, 139, 253, 0.15); color: #58a6ff; }
        .icon-green { background: rgba(63, 185, 80, 0.15); color: #3fb950; }
        .icon-orange { background: rgba(210, 153, 34, 0.15); color: #d29922; }
        .icon-purple { background: rgba(163, 113, 247, 0.15); color: #a371f7; }

        .progress-track { background-color: #21262d; height: 6px; border-radius: 9999px; margin-top: 12px; overflow: hidden; width: 100%; }
        .progress-bar { height: 100%; border-radius: 9999px; transition: width 0.5s ease-out; }
        .bar-blue { background-color: #58a6ff; }
        .bar-green { background-color: #3fb950; }

        .view { display: none; }
        .view.active { display: block; animation: fadeIn 0.3s ease-in-out; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
        
        .sidebar { transition: width 0.3s cubic-bezier(0.4, 0, 0.2, 1); width: 260px; background-color: var(--bg-nav); z-index: 50; flex-shrink: 0; }
        .sidebar.collapsed { width: 72px; }
        .sidebar.collapsed .logo-text, .sidebar.collapsed .nav-text { display: none; opacity: 0; }
        .sidebar.collapsed .nav-btn { justify-content: center; padding: 12px; }
        .sidebar.collapsed .sidebar-header { padding: 0; justify-content: center; }
        .mobile-overlay { background: rgba(0,0,0,0.7); opacity: 0; pointer-events: none; transition: opacity 0.3s; }
        .mobile-overlay.open { opacity: 1; pointer-events: auto; }
        
        .nav-btn { display: flex; align-items: center; gap: 12px; width: 100%; padding: 12px 16px; border-radius: 8px; font-size: 0.9rem; font-weight: 500; color: var(--text-muted); transition: all 0.2s; white-space: nowrap; }
        .nav-btn:hover { background: #21262d; color: #fff; }
        .nav-btn.active { background: #1f6feb; color: #fff; }

        .code-editor { font-family: 'Consolas', 'Monaco', monospace; font-size: 13px; background-color: #0d1117; color: #e6edf3; border: 1px solid var(--border); border-radius: 6px; width: 100%; height: 600px; padding: 16px; resize: vertical; outline: none; }
        .tab-btn { padding: 8px 16px; border-bottom: 2px solid transparent; color: var(--text-muted); font-weight: 500; transition: all 0.2s; }
        .log-error { color: #f87171 !important; background-color: rgba(69, 10, 10, 0.3); border-left: 2px solid #ef4444; }
        
        @media (max-width: 768px) {
            .sidebar { position: fixed; left: -260px; height: 100%; border-right: 1px solid var(--border); box-shadow: 4px 0 24px rgba(0,0,0,0.5); }
            .sidebar.mobile-open { left: 0; }
        }
    </style>
</head>
<body class="h-screen flex overflow-hidden bg-[#0d1117]">
    <div id="mobile-overlay" class="mobile-overlay fixed inset-0 z-40 md:hidden backdrop-blur-sm" onclick="toggleSidebar()"></div>
    <!-- Sidebar -->
    <aside id="sidebar" class="sidebar border-r border-gray-800 flex flex-col">
        <div class="h-16 flex items-center justify-between px-6 border-b border-gray-800 sidebar-header shrink-0">
             <div class="flex items-center gap-3 overflow-hidden transition-all logo-box">
                <div class="w-8 h-8 min-w-[32px] bg-blue-600 rounded-lg flex items-center justify-center text-white font-bold shadow-lg shadow-blue-900/40">R</div>
                <h1 class="font-bold text-lg text-white logo-text whitespace-nowrap">TunnelR <span class="text-xs font-mono text-gray-500 ml-1">v3.5.21</span></h1>
             </div>
             <button onclick="toggleSidebarDesktop()" class="text-gray-500 hover:text-white hidden md:block transition-colors p-1 rounded hover:bg-gray-800"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"></path></svg></button>
        </div>
        <nav class="flex-1 px-4 py-6 space-y-2 overflow-y-auto">
            <button onclick="setView('dash')" id="nav-dash" class="nav-btn active"><svg class="w-6 h-6 min-w-[24px]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z"></path></svg> <span class="nav-text">Dashboard</span></button>
            <button onclick="setView('logs')" id="nav-logs" class="nav-btn"><svg class="w-6 h-6 min-w-[24px]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"></path></svg> <span class="nav-text">Live Logs</span></button>
            <button onclick="setView('settings')" id="nav-settings" class="nav-btn"><svg class="w-6 h-6 min-w-[24px]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path></svg> <span class="nav-text">Editor</span></button>
        </nav>
    </aside>

    <main class="flex-1 flex flex-col min-w-0 transition-all">
        <!-- Header -->
        <header class="h-16 shrink-0 flex items-center justify-between px-4 md:px-8 bg-card border-b border-gray-800 sticky top-0 z-20 backdrop-blur-md" style="background-color: rgba(22, 27, 34, 0.85);">
            <div class="flex items-center gap-4">
                <button onclick="toggleSidebar()" class="md:hidden text-gray-400 hover:text-white p-1"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"></path></svg></button>
                <div class="flex items-center gap-3"><span class="text-sm font-medium text-gray-300 hidden md:inline">Status:</span><span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-900 text-green-300 border border-green-700 shadow-sm shadow-green-900/20"><span class="w-1.5 h-1.5 mr-1.5 bg-green-500 rounded-full animate-pulse"></span> Running</span></div>
            </div>
            <div class="flex gap-2">
                <button onclick="control('restart')" class="flex items-center gap-2 px-3 py-1.5 md:px-4 md:py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg text-xs md:text-sm transition-all border border-slate-600 shadow-sm">Restart</button>
                <button onclick="control('stop')" class="flex items-center gap-2 px-3 py-1.5 md:px-4 md:py-2 bg-red-900/50 hover:bg-red-900 text-red-300 rounded-lg text-xs md:text-sm transition-all border border-red-800 shadow-sm">Stop</button>
            </div>
        </header>

        <div class="flex-1 overflow-y-auto w-full">
            <div class="w-full p-6 md:p-8 space-y-6 max-w-6xl mx-auto">
                <!-- VIEW: DASHBOARD -->
                <div id="view-dash" class="view active">
                    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 md:gap-6">
                        <!-- CPU -->
                        <div class="premium-card">
                            <div class="icon-box icon-blue"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z"></path></svg></div>
                            <div><div class="card-label">CPU Usage</div><div class="card-value"><span id="cpu-val">0</span><span class="unit-span">%</span></div></div>
                            <div class="w-full"><div class="progress-track"><div id="cpu-bar" class="progress-bar bar-blue" style="width: 0%"></div></div></div>
                        </div>
                        <!-- RAM -->
                        <div class="premium-card">
                            <div class="icon-box icon-green"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4"></path></svg></div>
                            <div><div class="card-label">RAM Usage</div><div class="card-value"><span id="ram-used">0</span><span class="unit-span" id="ram-total">/ 0GB</span></div></div>
                            <div class="w-full"><div class="progress-track"><div id="ram-bar" class="progress-bar bar-green" style="width: 0%"></div></div></div>
                        </div>
                         <!-- Uptime -->
                        <div class="premium-card">
                             <div class="icon-box icon-orange"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg></div>
                             <div><div class="card-label">Uptime</div><div class="card-value" id="svc-uptime">0<span class="unit-span">d</span> 0<span class="unit-span">h</span> 0<span class="unit-span">m</span></div></div>
                             <div class="card-footer-text"><span>Started: <span id="start-time" class="text-gray-400">...</span></span></div>
                        </div>
                        <!-- Sessions (FIXED: Now showing ACTIVE connections) -->
                        <div class="premium-card">
                             <div class="icon-box icon-purple"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"></path></svg></div>
                             <div><div class="card-label">Sessions</div><div class="card-value" id="sess-count">0</div></div>
                             <!-- TOTAL VOLUME -->
                             <div class="card-footer-text justify-between w-full"><span class="text-blue-400">↑ <span id="vol-sent">0 B</span></span> <span class="text-green-400">↓ <span id="vol-recv">0 B</span></span></div>
                        </div>
                    </div>

                    <div class="premium-card mt-6" style="min-height: auto;">
                        <div class="flex flex-col md:flex-row justify-between items-start md:items-center mb-6">
                            <h3 class="text-lg font-bold text-white">Traffic Overview</h3>
                             <div class="flex gap-4 md:gap-6 text-sm mt-2 md:mt-0">
                                <span class="text-blue-400">Upload <span id="lg-up" class="font-mono text-white">0 B/s</span></span>
                                <span class="text-green-400">Download <span id="lg-down" class="font-mono text-white">0 B/s</span></span>
                            </div>
                        </div>
                        <div class="h-60 md:h-80 w-full relative">
                            <canvas id="trafficChart"></canvas>
                        </div>
                    </div>
                </div>

                <!-- (Logs & Settings unchanged) -->
                <div id="view-logs" class="view">
                     <div class="premium-card h-[calc(100vh-140px)] flex flex-col p-0 overflow-hidden" style="min-height: 400px;">
                        <div class="p-4 border-b border-gray-800 flex justify-between bg-black/20">
                            <span class="font-bold text-sm text-gray-300">SYSTEM LOGS</span>
                            <div class="flex bg-gray-900 rounded p-1 border border-gray-700"><button onclick="setLogFilter('all')" class="px-3 py-1 text-xs rounded hover:bg-gray-800 text-white" id="btn-log-all">All</button><button onclick="setLogFilter('error')" class="px-3 py-1 text-xs rounded hover:bg-gray-800 text-red-500" id="btn-log-error">Errors</button></div>
                        </div>
                        <div id="logs-container" class="flex-1 overflow-y-auto p-4 font-mono text-xs text-gray-300 space-y-1 bg-[#0d1117]"></div>
                     </div>
                </div>

                <div id="view-settings" class="view">
                    <div class="flex flex-col md:flex-row justify-between items-center mb-6 gap-4">
                        <div class="flex gap-4 w-full md:w-auto bg-gray-900 p-1 rounded-lg"><button onclick="setCfgMode('visual')" id="tab-visual" class="flex-1 md:flex-none px-4 py-2 rounded-md text-sm font-medium transition-colors hover:bg-gray-800 text-white bg-gray-800 shadow">Visual Form</button><button onclick="setCfgMode('code')" id="tab-code" class="flex-1 md:flex-none px-4 py-2 rounded-md text-sm font-medium transition-colors text-gray-400 hover:text-white hover:bg-gray-800">Raw Editor</button></div>
                        <button onclick="saveConfig()" class="w-full md:w-auto bg-blue-600 hover:bg-blue-500 text-white px-5 py-2 rounded-lg text-sm font-semibold shadow-lg shadow-blue-900/50">Save & Restart</button>
                    </div>
                    <div id="cfg-code" class="premium-card p-0 overflow-hidden hidden" style="min-height: 600px;"><textarea id="config-editor" class="code-editor" spellcheck="false"></textarea></div>
                    <div id="cfg-visual" class="premium-card space-y-8" style="min-height: auto;">
                        <div><h4 class="text-sm font-bold text-blue-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Core Connection</h4><div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6"><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Bind Address</label><input type="text" id="v-listen" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:border-blue-500"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">PSK</label><input type="text" id="v-psk" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:border-blue-500"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Mimic</label><input type="text" id="v-mimic" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Transport</label><select id="v-transport" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"><option value="httpsmux">HTTPS</option><option value="wssmux">WSS</option></select></div></div></div>
                        <div><h4 class="text-sm font-bold text-green-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Obfuscation</h4><div class="grid grid-cols-1 md:grid-cols-2 gap-6"><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Key</label><input type="text" id="v-obfs-key" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">IV</label><input type="text" id="v-obfs-iv" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div></div></div>
                        <div><h4 class="text-sm font-bold text-orange-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Load Balancing</h4><div class="grid grid-cols-1 md:grid-cols-3 gap-6"><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Pool</label><input type="number" id="v-pool" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Retry (s)</label><input type="number" id="v-retry" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Timeout (s)</label><input type="number" id="v-timeout" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div></div></div>
                        <div class="grid grid-cols-1 md:grid-cols-2 gap-8"><div><h4 class="text-sm font-bold text-purple-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Rules</h4><div class="space-y-4"><div><label class="block text-xs font-medium text-gray-400 mb-1.5">TCP Rules</label><textarea id="v-tcp" rows="4" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white font-mono text-xs placeholder-gray-700"></textarea></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">UDP Rules</label><textarea id="v-udp" rows="4" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white font-mono text-xs placeholder-gray-700"></textarea></div></div></div><div><h4 class="text-sm font-bold text-blue-300 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Upstreams</h4><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Upstream Servers</label><textarea id="v-upstreams" rows="9" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white font-mono text-xs placeholder-gray-700"></textarea></div></div></div>
                    </div>
                </div>
            </div>
        </div>
    </main>
    
    <script>
        const $ = s => document.querySelector(s);
        let chart = null;

        function toggleSidebar() { $('#sidebar').classList.toggle('mobile-open'); $('#mobile-overlay').classList.toggle('open'); }
        function toggleSidebarDesktop() { $('#sidebar').classList.toggle('collapsed'); }
        function setView(id) {
            document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
            document.querySelectorAll('.nav-btn').forEach(n => n.classList.remove('active'));
            $(`#view-${id}`).classList.add('active');
            $(`#nav-${id}`).classList.add('active');
            $('#sidebar').classList.remove('mobile-open'); $('#mobile-overlay').classList.remove('open');
            if(id === 'logs') initLogs();
            if(id === 'settings') loadConfig();
        }
        async function control(action) { if(!confirm('Are you sure?')) return; await fetch('/api/restart', {method:'POST'}); setTimeout(()=>location.reload(), 3000); }
        function setCfgMode(m) { $('#cfg-code').classList.toggle('hidden', m !== 'code'); $('#cfg-visual').classList.toggle('hidden', m !== 'visual'); const btn = $(m === 'code' ? '#tab-code' : '#tab-visual'); document.querySelectorAll('.tab-btn').forEach(b=>{b.classList.remove('bg-gray-800','text-white');b.classList.add('text-gray-400')}); btn.classList.add('bg-gray-800','text-white'); btn.classList.remove('text-gray-400'); if(m === 'visual') parseYamlToForm(); }
        function parseYamlToForm() { try { const doc = jsyaml.load($('#config-editor').value); if(!doc) return; $('#v-listen').value=doc.listen||''; $('#v-psk').value=doc.psk||''; $('#v-mimic').value=(doc.mimic?.fake_domain)||''; $('#v-transport').value=doc.transport||'httpsmux'; $('#v-obfs-key').value=doc.obfs?.key||''; $('#v-obfs-iv').value=doc.obfs?.iv||''; $('#v-pool').value=doc.paths?.[0]?.pool||4; $('#v-retry').value=doc.paths?.[0]?.retry||3; $('#v-timeout').value=doc.paths?.[0]?.dial_timeout||10; $('#v-upstreams').value=doc.upstreams?jsyaml.dump(doc.upstreams):''; $('#v-tcp').value=doc.forward?.tcp?jsyaml.dump(doc.forward.tcp):''; $('#v-udp').value=doc.forward?.udp?jsyaml.dump(doc.forward.udp):''; } catch(e){} }
        function updateYamlFromForm() { try { let doc = jsyaml.load($('#config-editor').value) || {}; doc.listen=$('#v-listen').value; doc.psk=$('#v-psk').value; doc.transport=$('#v-transport').value; if(!doc.mimic) doc.mimic={}; doc.mimic.fake_domain=$('#v-mimic').value; if(!doc.obfs) doc.obfs={}; doc.obfs.key=$('#v-obfs-key').value; doc.obfs.iv=$('#v-obfs-iv').value; if(!doc.paths) doc.paths=[{}]; doc.paths.forEach(p=>{p.pool=parseInt($('#v-pool').value);p.retry=parseInt($('#v-retry').value);p.dial_timeout=parseInt($('#v-timeout').value)}); try{doc.upstreams=jsyaml.load($('#v-upstreams').value)}catch(e){} if(!doc.forward) doc.forward={}; try{doc.forward.tcp=jsyaml.load($('#v-tcp').value)}catch(e){} try{doc.forward.udp=jsyaml.load($('#v-udp').value)}catch(e){} $('#config-editor').value=jsyaml.dump(doc); } catch(e) { alert('YAML Error: '+e); } }
        async function loadConfig() { const r = await fetch('/api/config'); if(r.ok) { $('#config-editor').value=await r.text(); parseYamlToForm(); } }
        async function saveConfig() { if(!$('#cfg-visual').classList.contains('hidden')) updateYamlFromForm(); if(!confirm('Save?')) return; await fetch('/api/config', {method:'POST', body:$('#config-editor').value}); await fetch('/api/restart', {method:'POST'}); }
        let logSrc; function initLogs() { if(logSrc) return; $('#logs-container').innerHTML=''; logSrc=new EventSource('/api/logs/stream'); logSrc.onmessage=e=>{ const d=document.createElement('div'); d.textContent=e.data; if(e.data.toLowerCase().includes('err')) d.classList.add('log-error','p-1','rounded'); else d.classList.add('p-0.5'); $('#logs-container').appendChild(d); } }
        function setLogFilter(f) { document.querySelectorAll('#logs-container div').forEach(d=>{ d.style.display=(f==='all'||d.classList.contains('log-error'))?'block':'none' }) }

        setInterval(async () => {
            try {
                const res = await fetch('/api/stats');
                const data = await res.json();
                $('#cpu-val').innerText = data.cpu.toFixed(1);
                $('#cpu-bar').style.width = Math.min(data.cpu, 100) + '%';
                
                const usedBytes = data.ram_used || 0; const totalBytes = data.ram_total || 1;
                const usedGB = (usedBytes / 1024**3).toFixed(1); const totalGB = (totalBytes > 1024**2) ? (totalBytes / 1024**3).toFixed(1)+'GB' : '';
                $('#ram-used').innerText = usedGB; $('#ram-total').innerText = '/ '+totalGB;
                $('#ram-bar').style.width = Math.min((usedBytes/totalBytes)*100, 100) + '%';
                
                // --- FIX: Use ACTIVE connections, NOT total (which only goes up) ---
                $('#sess-count').innerText = data.stats.active_conns || 0;
                
                if(data.uptime_s){const s=data.uptime_s;const d=Math.floor(s/86400);const h=Math.floor((s%86400)/3600);const m=Math.floor((s%3600)/60);$('#svc-uptime').innerHTML=`${d}<span class="unit-span">d</span> ${h}<span class="unit-span">h</span> ${m}<span class="unit-span">m</span>`;}
                if(data.start_time){const s=new Date(data.start_time);$('#start-time').innerText=s.toLocaleTimeString();}
                
                const hb=b=>{const u=['B','KB','MB','GB'];let i=0;while(b>=1024&&i<3){b/=1024;i++}return b.toFixed(1)+' '+u[i];};
                $('#vol-sent').innerText = hb(data.stats.bytes_recv||0); 
                $('#vol-recv').innerText = hb(data.stats.bytes_sent||0);
                $('#lg-up').innerText=hb(data.stats.speed_up||0)+'/s'; $('#lg-down').innerText=hb(data.stats.speed_down||0)+'/s';
                updateChart(data.stats.speed_down||0, data.stats.speed_up||0);
            } catch(e) {}
        }, 1000);
        
        function updateChart(rx, tx) {
             const hb=b=>{const u=['B','KB','MB','GB'];let i=0;while(b>=1024&&i<3){b/=1024;i++}return b.toFixed(1)+' '+u[i]};
             if(!chart) { const ctx=$('#trafficChart').getContext('2d'); 
                 chart=new Chart(ctx,{
                     type:'line',
                     data:{labels:Array(30).fill(''),datasets:[
                         {label:'DL',data:Array(30).fill(0),borderColor:'#3fb950',backgroundColor:'rgba(63, 185, 80, 0.1)',fill:true,tension:0.4,pointRadius:0},
                         {label:'UL',data:Array(30).fill(0),borderColor:'#58a6ff',backgroundColor:'rgba(56, 139, 253, 0.1)',fill:true,tension:0.4,pointRadius:0}
                     ]},
                     options:{
                         responsive:true, maintainAspectRatio:false,
                         scales:{
                             x:{display:false}, 
                             y:{position:'right',ticks:{color:'#8b949e',maxTicksLimit:5,callback:v=>hb(v)},grid:{color:'#30363d'}}
                         },
                         plugins:{legend:{display:false}},
                         animation: false,
                         interaction:{intersect:false}
                    }
                }); 
             }
             chart.data.labels.push(''); chart.data.labels.shift();
             chart.data.datasets[0].data.push(rx); chart.data.datasets[0].data.shift();
             chart.data.datasets[1].data.push(tx); chart.data.datasets[1].data.shift();
             chart.update();
        }
    </script>
</body>
</html>
'''

def create_install_func(html):
    return f"""install_dashboard_assets() {{
    local DASH_DIR="/var/lib/picotun/dashboard"
    mkdir -p "$DASH_DIR"
    
    echo "Creating Dashboard Assets (v3.5.21)..."

    cat <<'EOF' > "$DASH_DIR/index.html"
{html}
EOF
}}
"""

pattern = r"install_dashboard_assets\(\) \{.*?^\}"
replacement = create_install_func(html_content)
replacement = replacement.replace('\\', '\\\\')

new_content = re.sub(pattern, replacement, setup_content, flags=re.DOTALL|re.MULTILINE)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(new_content)

print("Fix Dashboard v3.5.21 injected successfully.")

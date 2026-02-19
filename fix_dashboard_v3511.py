import os
import re

# 1. READ SETUP.SH
file_path = r"C:\GGNN\RsTunnel-main\setup.sh"
with open(file_path, 'r', encoding='utf-8') as f:
    setup_content = f.read()

# 2. DEFINE REFINED DASHBOARD CONTENT v3.5.11
# Changes:
# - Responsive Sidebar (Mobile Drawer + Desktop Collapse)
# - Full Visual Config (All parameters)

html_content = r'''<!DOCTYPE html>
<html class="dark" lang="en">
<head>
    <meta charset="utf-8"/>
    <meta content="width=device-width, initial-scale=1.0" name="viewport"/>
    <title>TunnelR v3.5.11</title>
    <script src="https://cdn.tailwindcss.com?plugins=forms"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/js-yaml/4.1.0/js-yaml.min.js"></script>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
        :root {
            --bg-body: #0d1117;
            --bg-card: #161b22; 
            --bg-nav: #161b22;
            --text-main: #f0f6fc;
            --text-muted: #8b949e;
            --border: #30363d;
            --accent: #58a6ff;
        }
        body { background-color: var(--bg-body); color: var(--text-main); font-family: 'Inter', sans-serif; }
        
        /* Custom Scrollbar */
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-body); }
        ::-webkit-scrollbar-thumb { background: #30363d; border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: #58a6ff; }
        
        /* Premium Card Style */
        .premium-card {
            background-color: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px;
            position: relative;
            transition: transform 0.2s, border-color 0.2s;
        }
        .premium-card:hover { border-color: var(--accent); }
        
        .card-label { font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); margin-bottom: 8px; }
        .card-value { font-size: 1.875rem; font-weight: 700; color: var(--text-main); line-height: 1.2; letter-spacing: -0.02em; }
        .card-footer-text { font-size: 0.75rem; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; color: var(--text-muted); margin-top: 12px; display: flex; align-items: center; gap: 6px; }

        .icon-box { width: 40px; height: 40px; border-radius: 10px; display: flex; align-items: center; justify-content: center; position: absolute; top: 20px; right: 20px; }
        .icon-blue { background: rgba(56, 139, 253, 0.15); color: #58a6ff; }
        .icon-green { background: rgba(63, 185, 80, 0.15); color: #3fb950; }
        .icon-orange { background: rgba(210, 153, 34, 0.15); color: #d29922; }
        .icon-purple { background: rgba(163, 113, 247, 0.15); color: #a371f7; }

        .progress-track { background-color: #21262d; height: 6px; border-radius: 9999px; margin-top: 16px; overflow: hidden; }
        .progress-bar { height: 100%; border-radius: 9999px; transition: width 0.5s ease-out; }
        .bar-blue { background-color: #58a6ff; }
        .bar-green { background-color: #3fb950; }

        .view { display: none; }
        .view.active { display: block; animation: fadeIn 0.3s ease-in-out; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
        
        /* Sidebar & Nav */
        .sidebar { transition: width 0.3s ease; width: 260px; }
        .sidebar.collapsed { width: 80px; }
        .sidebar.collapsed .logo-text, .sidebar.collapsed .nav-text { display: none; }
        .sidebar.collapsed .nav-btn { justify-content: center; padding: 12px; }
        
        .mobile-overlay { background: rgba(0,0,0,0.5); opacity: 0; pointer-events: none; transition: opacity 0.3s; }
        .mobile-overlay.open { opacity: 1; pointer-events: auto; }
        
        .nav-btn { display: flex; align-items: center; gap: 12px; width: 100%; padding: 12px 16px; border-radius: 8px; font-size: 0.9rem; font-weight: 500; color: var(--text-muted); transition: all 0.2s; white-space: nowrap; }
        .nav-btn:hover { background: #21262d; color: #fff; }
        .nav-btn.active { background: #1f6feb; color: #fff; }

        .code-editor { font-family: 'Consolas', 'Monaco', monospace; font-size: 13px; background-color: #0d1117; color: #e6edf3; border: 1px solid var(--border); border-radius: 6px; width: 100%; height: 600px; padding: 16px; resize: vertical; outline: none; }
        
        .tab-btn { padding: 8px 16px; border-bottom: 2px solid transparent; color: var(--text-muted); font-weight: 500; transition: all 0.2s; }
        .tab-btn.active { border-bottom-color: var(--accent); color: var(--text-main); }
        
        .log-error { color: #f87171 !important; background-color: rgba(69, 10, 10, 0.3); border-left: 2px solid #ef4444; }
        
        @media (max-width: 768px) {
            .sidebar { position: fixed; left: -260px; height: 100%; z-index: 50; }
            .sidebar.mobile-open { left: 0; }
        }
    </style>
</head>
<body class="h-screen flex overflow-hidden">

    <!-- Mobile Overlay -->
    <div id="mobile-overlay" class="mobile-overlay fixed inset-0 z-40 md:hidden" onclick="toggleSidebar()"></div>

    <!-- Sidebar -->
    <aside id="sidebar" class="sidebar bg-nav border-r border-gray-800 flex flex-col z-50">
        <div class="h-16 flex items-center justify-between px-6 border-b border-gray-800">
             <div class="flex items-center gap-3 overflow-hidden">
                <div class="w-8 h-8 min-w-[32px] bg-blue-600 rounded-lg flex items-center justify-center text-white font-bold">R</div>
                <h1 class="font-bold text-lg text-white logo-text whitespace-nowrap">TunnelR <span class="text-xs font-mono text-gray-500 ml-1">v3.5.11</span></h1>
             </div>
             <!-- Desktop Collapse Toggle -->
             <button onclick="toggleSidebarDesktop()" class="text-gray-500 hover:text-white hidden md:block">
                 <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 19l-7-7 7-7m8 14l-7-7 7-7"></path></svg>
             </button>
        </div>

        <nav class="flex-1 px-4 py-6 space-y-1">
            <button onclick="setView('dash')" id="nav-dash" class="nav-btn active">
                <svg class="w-6 h-6 min-w-[24px]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z"></path></svg>
                <span class="nav-text">Dashboard</span>
            </button>
            <button onclick="setView('logs')" id="nav-logs" class="nav-btn">
                <svg class="w-6 h-6 min-w-[24px]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"></path></svg>
                <span class="nav-text">Live Logs</span>
            </button>
            <button onclick="setView('settings')" id="nav-settings" class="nav-btn">
                <svg class="w-6 h-6 min-w-[24px]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path></svg>
                <span class="nav-text">Editor</span>
            </button>
        </nav>
    </aside>

    <!-- Main Content -->
    <main class="flex-1 flex flex-col min-w-0 overflow-y-auto w-full transition-all">
        
        <!-- Header Controls -->
        <header class="h-16 flex items-center justify-between px-4 md:px-8 bg-card border-b border-gray-800 sticky top-0 z-20 backdrop-blur" style="background-color: rgba(22, 27, 34, 0.8);">
            
            <div class="flex items-center gap-3">
                 <!-- Mobile Menu Button -->
                <button onclick="toggleSidebar()" class="md:hidden text-gray-400 hover:text-white">
                    <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"></path></svg>
                </button>
                
                <span class="text-sm font-medium text-gray-300 hidden md:inline">Status:</span>
                <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-900 text-green-300 border border-green-700">
                    <span class="w-1.5 h-1.5 mr-1.5 bg-green-500 rounded-full animate-pulse"></span>
                    Running
                </span>
            </div>
            
            <div class="flex gap-2">
                <button onclick="control('restart')" class="flex items-center gap-2 px-3 py-1.5 md:px-4 md:py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg text-xs md:text-sm transition-colors border border-slate-600">
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path></svg>
                    <span class="hidden md:inline">Restart</span>
                </button>
                <button onclick="control('stop')" class="flex items-center gap-2 px-3 py-1.5 md:px-4 md:py-2 bg-red-900/50 hover:bg-red-900 text-red-300 rounded-lg text-xs md:text-sm transition-colors border border-red-800">
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path></svg>
                    <span class="hidden md:inline">Stop</span>
                </button>
            </div>
        </header>

        <div class="w-full p-4 md:p-8 space-y-6 md:space-y-8">
            
            <!-- VIEW: DASHBOARD -->
            <div id="view-dash" class="view active">
                <!-- Top Cards -->
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 md:gap-6">
                    <!-- CPU -->
                    <div class="premium-card">
                        <div class="icon-box icon-blue">
                             <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z"></path></svg>
                        </div>
                        <div class="card-label">CPU Usage</div>
                        <div class="card-value"><span id="cpu-val">0</span>%</div>
                        <div class="progress-track"><div id="cpu-bar" class="progress-bar bar-blue" style="width: 0%"></div></div>
                    </div>
                    <!-- RAM -->
                    <div class="premium-card">
                        <div class="icon-box icon-green">
                             <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4"></path></svg>
                        </div>
                        <div class="card-label">RAM Usage</div>
                        <div class="card-value"><span id="ram-used">0</span> / <span id="ram-total" class="text-xl">0</span></div>
                        <div class="progress-track"><div id="ram-bar" class="progress-bar bar-green" style="width: 0%"></div></div>
                    </div>
                    <!-- Uptime -->
                    <div class="premium-card">
                         <div class="icon-box icon-orange">
                             <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg>
                         </div>
                         <div class="card-label">Service Uptime</div>
                         <div class="card-value text-xl" id="svc-uptime">00:00:00</div>
                         <div class="card-footer-text mt-6">
                            <span>Started: <span id="start-time" class="text-gray-400">...</span></span>
                        </div>
                    </div>
                    <!-- Sessions -->
                    <div class="premium-card">
                         <div class="icon-box icon-purple">
                             <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"></path></svg>
                         </div>
                         <div class="card-label">Active Sessions</div>
                         <div class="card-value" id="sess-count">0</div>
                         <div class="card-footer-text mt-6 justify-between">
                            <span class="text-blue-400">↑ <span id="vol-sent">0 B</span></span>
                            <span class="text-green-400">↓ <span id="vol-recv">0 B</span></span>
                        </div>
                    </div>
                </div>

                <!-- Traffic Chart -->
                <div class="premium-card mt-6">
                    <div class="flex flex-col md:flex-row justify-between items-start md:items-center mb-6">
                        <h3 class="text-lg font-bold text-white">Traffic Overview</h3>
                         <div class="flex gap-4 md:gap-6 text-sm mt-2 md:mt-0">
                            <span class="text-blue-400">Upload <span id="lg-up" class="font-mono text-white">0 B/s</span></span>
                            <span class="text-green-400">Download <span id="lg-down" class="font-mono text-white">0 B/s</span></span>
                        </div>
                    </div>
                    <div class="h-60 md:h-80 w-full">
                        <canvas id="trafficChart"></canvas>
                    </div>
                </div>
            </div>

            <!-- VIEW: LOGS -->
            <div id="view-logs" class="view">
                 <div class="premium-card h-[calc(100vh-140px)] flex flex-col p-0 overflow-hidden">
                    <div class="p-4 border-b border-gray-800 flex justify-between bg-black/20">
                        <span class="font-bold text-sm text-gray-300">SYSTEM LOGS</span>
                        <div class="flex bg-gray-900 rounded p-1 border border-gray-700">
                             <button onclick="setLogFilter('all')" class="px-3 py-1 text-xs rounded hover:bg-gray-800 text-white" id="btn-log-all">All</button>
                             <button onclick="setLogFilter('error')" class="px-3 py-1 text-xs rounded hover:bg-gray-800 text-red-500" id="btn-log-error">Errors</button>
                        </div>
                    </div>
                    <div id="logs-container" class="flex-1 overflow-y-auto p-4 font-mono text-xs text-gray-300 space-y-1 bg-[#0d1117]"></div>
                 </div>
            </div>

            <!-- VIEW: SETTINGS -->
            <div id="view-settings" class="view">
                <div class="flex flex-col md:flex-row justify-between items-center mb-6 gap-4">
                    <div class="flex gap-4 w-full md:w-auto bg-gray-900 p-1 rounded-lg">
                        <button onclick="setCfgMode('visual')" id="tab-visual" class="flex-1 md:flex-none px-4 py-2 rounded-md text-sm font-medium transition-colors hover:bg-gray-800 text-white bg-gray-800 shadow">Visual Form</button>
                        <button onclick="setCfgMode('code')" id="tab-code" class="flex-1 md:flex-none px-4 py-2 rounded-md text-sm font-medium transition-colors text-gray-400 hover:text-white hover:bg-gray-800">Raw Editor</button>
                    </div>
                    <button onclick="saveConfig()" class="w-full md:w-auto bg-blue-600 hover:bg-blue-500 text-white px-5 py-2 rounded-lg text-sm font-semibold shadow-lg shadow-blue-900/50">Save & Restart</button>
                </div>

                <!-- MODE: RAW -->
                <div id="cfg-code" class="premium-card p-0 overflow-hidden hidden">
                    <textarea id="config-editor" class="code-editor" spellcheck="false"></textarea>
                </div>
                
                <!-- MODE: VISUAL (FULL) -->
                <div id="cfg-visual" class="premium-card space-y-8">
                    
                    <!-- Section: Connection -->
                    <div>
                        <h4 class="text-sm font-bold text-blue-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Connection Settings</h4>
                        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                             <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">Bind Address</label>
                                <input type="text" id="v-listen" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500">
                             </div>
                             <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">PSK (Password)</label>
                                <input type="text" id="v-psk" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500">
                             </div>
                             <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">Mimic Domain (Decoy)</label>
                                <input type="text" id="v-mimic" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm" placeholder="www.google.com">
                             </div>
                             <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">Transport Mode</label>
                                <select id="v-transport" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm">
                                    <option value="httpsmux">HTTPS (Mux)</option>
                                    <option value="wssmux">WSS (WebSocket)</option>
                                    <option value="tcpmux">TCP (Mux)</option>
                                </select>
                             </div>
                        </div>
                    </div>

                    <!-- Section: Obfuscation -->
                     <div>
                        <h4 class="text-sm font-bold text-green-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Obfuscation (Optional)</h4>
                        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                            <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">Key</label>
                                <input type="text" id="v-obfs-key" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm" placeholder="hex string">
                            </div>
                             <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">IV</label>
                                <input type="text" id="v-obfs-iv" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm" placeholder="hex string">
                            </div>
                        </div>
                    </div>

                    <!-- Section: Tuning -->
                    <div>
                        <h4 class="text-sm font-bold text-orange-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Performance Tuning</h4>
                        <div class="grid grid-cols-1 md:grid-cols-4 gap-6">
                             <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">Pool Size</label>
                                <input type="number" id="v-pool" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm">
                             </div>
                              <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">Dial Timeout (s)</label>
                                <input type="number" id="v-timeout" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm">
                             </div>
                              <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">Retry Interval (s)</label>
                                <input type="number" id="v-retry" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm">
                             </div>
                        </div>
                    </div>

                    <!-- Section: Routing -->
                    <div>
                        <h4 class="text-sm font-bold text-purple-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Forwarding Rules</h4>
                        <div class="space-y-4">
                            <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">TCP Rules</label>
                                <textarea id="v-tcp" rows="3" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white font-mono text-xs" placeholder="- 0.0.0.0:2080: 127.0.0.1:80"></textarea>
                            </div>
                             <div>
                                <label class="block text-xs font-medium text-gray-400 mb-1.5">UDP Rules</label>
                                <textarea id="v-udp" rows="3" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white font-mono text-xs" placeholder="- 0.0.0.0:5353: 1.1.1.1:53"></textarea>
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

        function toggleSidebar() {
            const sb = $('#sidebar');
            const ov = $('#mobile-overlay');
            sb.classList.toggle('mobile-open');
            ov.classList.toggle('open');
        }

        function toggleSidebarDesktop() {
            const sb = $('#sidebar');
            sb.classList.toggle('collapsed');
        }

        function setView(id) {
            document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
            document.querySelectorAll('.nav-btn').forEach(n => n.classList.remove('active'));
            $(`#view-${id}`).classList.add('active');
            $(`#nav-${id}`).classList.add('active');
            
            // Close mobile menu on nav click
            $('#sidebar').classList.remove('mobile-open');
            $('#mobile-overlay').classList.remove('open');

            if(id === 'logs') initLogs();
            if(id === 'settings') loadConfig();
        }

        async function control(action) {
            if(!confirm(`Are you sure you want to ${action} the service?`)) return;
            await fetch('/api/restart', {method:'POST'});
            setTimeout(()=>location.reload(), 3000);
        }

        function setCfgMode(m) {
            $('#cfg-code').classList.toggle('hidden', m !== 'code');
            $('#cfg-visual').classList.toggle('hidden', m !== 'visual');
            
            // Tab styling
             document.querySelectorAll('.tab-btn').forEach(b => {
                 b.classList.remove('bg-gray-800', 'text-white', 'shadow');
                 b.classList.add('text-gray-400');
             }); // reset
             // Active style
             const btn = $(m === 'code' ? '#tab-code' : '#tab-visual');
             btn.classList.add('bg-gray-800', 'text-white', 'shadow');
             btn.classList.remove('text-gray-400');
            
            if(m === 'visual') parseYamlToForm();
        }

        function parseYamlToForm() {
            try {
                const doc = jsyaml.load($('#config-editor').value);
                if(doc) {
                    $('#v-listen').value = doc.listen || '';
                    $('#v-psk').value = doc.psk || '';
                    $('#v-mimic').value = (doc.mimic && doc.mimic.fake_domain) ? doc.mimic.fake_domain : '';
                    $('#v-transport').value = doc.transport || 'httpsmux';
                    
                    if(doc.obfs) {
                        $('#v-obfs-key').value = doc.obfs.key || '';
                        $('#v-obfs-iv').value = doc.obfs.iv || '';
                    }

                    // Defaults if missing (from Go code)
                    $('#v-pool').value = (doc.paths && doc.paths[0] && doc.paths[0].pool) || 4;
                    $('#v-timeout').value = (doc.paths && doc.paths[0] && doc.paths[0].dial_timeout) || 10;
                    $('#v-retry').value = (doc.paths && doc.paths[0] && doc.paths[0].retry) || 3;

                    if(doc.forward) {
                        if(doc.forward.tcp) $('#v-tcp').value = doc.forward.tcp.map(x => `- ${Object.keys(x)[0]}: ${Object.values(x)[0]}`).join('\n');
                        if(doc.forward.udp) $('#v-udp').value = doc.forward.udp.map(x => `- ${Object.keys(x)[0]}: ${Object.values(x)[0]}`).join('\n');
                    }
                }
            } catch(e) { console.log('Parse error', e); }
        }

        // Stats Loop
        setInterval(async () => {
            try {
                const res = await fetch('/api/stats');
                const data = await res.json();
                
                $('#cpu-val').innerText = data.cpu.toFixed(1);
                $('#cpu-bar').style.width = Math.min(data.cpu, 100) + '%';
                
                const usedBytes = data.ram_used || 0;
                const totalBytes = data.ram_total || 1; 
                const usedGB = (usedBytes / 1024 / 1024 / 1024).toFixed(1);
                const totalGB = (totalBytes > 1024*1024) ? (totalBytes / 1024 / 1024 / 1024).toFixed(1) + 'GB' : 'System';
                
                $('#ram-used').innerText = usedGB;
                $('#ram-total').innerText = totalGB;
                const ramPct = (usedBytes / totalBytes) * 100;
                $('#ram-bar').style.width = Math.min(ramPct, 100) + '%';
                
                $('#sess-count').innerText = data.stats.total_conns || 0;
                
                if (data.uptime_s) $('#svc-uptime').innerText = formatUptime(data.uptime_s);
                if (data.start_time) {
                    const start = new Date(data.start_time);
                    $('#start-time').innerText = start.toLocaleTimeString();
                }

                $('#vol-sent').innerText = data.stats.recv_human || '0 B'; 
                $('#vol-recv').innerText = data.stats.sent_human || '0 B';

                const up = humanBytes(data.stats.speed_up || 0);
                const down = humanBytes(data.stats.speed_down || 0);
                $('#lg-up').innerText = up + '/s';
                $('#lg-down').innerText = down + '/s';
                updateChart(data.stats.speed_down || 0, data.stats.speed_up || 0);

            } catch(e) {}
        }, 1000);

        function formatUptime(s) {
            const d = Math.floor(s / 86400); s %= 86400;
            const h = Math.floor(s / 3600); s %= 3600;
            const m = Math.floor(s / 60); s = Math.floor(s % 60);
            return `${d}d ${h}h ${m}m`;
        }
        
        function humanBytes(b) {
            const u = ['B', 'KB', 'MB', 'GB'];
            let i=0; while(b>=1024 && i<3){b/=1024;i++}
            return b.toFixed(1)+' '+u[i];
        }

        function updateChart(rx, tx) {
            const now = new Date();
            const lb = now.getHours().toString().padStart(2,'0') + ':' + now.getMinutes().toString().padStart(2,'0');
            if(!chart) {
                const ctx = $('#trafficChart').getContext('2d');
                chart = new Chart(ctx, {
                    type: 'line',
                    data: {
                        labels: Array(30).fill(''),
                        datasets: [
                            { label: 'DL', data: Array(30).fill(0), borderColor: '#3fb950', backgroundColor: 'rgba(63, 185, 80, 0.1)', fill:true, tension:0.4, borderWidth:2, pointRadius:0 },
                            { label: 'UL', data: Array(30).fill(0), borderColor: '#58a6ff', backgroundColor: 'rgba(56, 139, 253, 0.1)', fill:true, tension:0.4, borderWidth:2, pointRadius:0 }
                        ]
                    },
                    options: { responsive:true, maintainAspectRatio:false, scales:{x:{grid:{display:false}, ticks:{maxTicksLimit:6, color:'#8b949e'}}, y:{position:'right', grid:{color:'#30363d'}, ticks:{color:'#8b949e', callback:v=>humanBytes(v)}}}, plugins:{legend:{display:false}}, animation:false, interaction:{intersect:false} }
                });
            }
            chart.data.labels.push(lb); chart.data.labels.shift();
            chart.data.datasets[0].data.push(rx); chart.data.datasets[0].data.shift();
            chart.data.datasets[1].data.push(tx); chart.data.datasets[1].data.shift();
            chart.update();
        }

        async function loadConfig() {
            const r = await fetch('/api/config');
            if(r.ok) {
                const txt = await r.text();
                $('#config-editor').value = txt;
                parseYamlToForm();
            }
        }
        async function saveConfig() {
            if(!confirm('Save & Restart?')) return;
            // Always save from Raw Editor
            const r = await fetch('/api/config', {method:'POST', body:$('#config-editor').value});
            if(r.ok) { await fetch('/api/restart', {method:'POST'}); alert('Restarting...'); setTimeout(()=>location.reload(), 3000); }
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
                const tl = t.toLowerCase();
                 if(tl.includes('err') || tl.includes('fail')) d.classList.add('log-error', 'p-1', 'rounded', 'mb-1');
                 else d.classList.add('p-0.5');
                const c = $('#logs-container');
                c.appendChild(d);
                if(c.children.length > 200) c.removeChild(c.firstChild);
                c.scrollTop = c.scrollHeight;
            };
        }
        window.logFilter = 'all';
        function setLogFilter(f) { 
             window.logFilter = f; 
             document.querySelectorAll('#logs-container div').forEach(d => {
                 if(f==='all') d.style.display='block';
                 else d.style.display = (d.classList.contains('log-error')) ? 'block' : 'none';
             }); 
        }
    </script>
</body>
</html>
'''

def create_install_func(html):
    return f"""install_dashboard_assets() {{
    local DASH_DIR="/var/lib/picotun/dashboard"
    mkdir -p "$DASH_DIR"
    
    echo "Creating Dashboard Assets (v3.5.11)..."

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

print("Fix Dashboard v3.5.11 injected successfully.")

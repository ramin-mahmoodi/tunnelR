import os

# FILES
server_file = r"C:\GGNN\RsTunnel-main\server.go"

# 1. TUNE SERVER BUFFERS (server.go)
# We need to inject buffer setting logic into the upgrade function
# right after "conn, _, err := hj.Hijack()".

with open(server_file, 'r', encoding='utf-8') as f:
    server_code = f.read()

# The injection point:
# 	conn, _, err := hj.Hijack()
# 	if err != nil {
# 		http.Error(w, err.Error(), http.StatusInternalServerError)
# 		return
# 	}

injection = r'''	// v3.6.11: Server-Side BDP Tuning (Force 8MB buffers)
	if tcp, ok := conn.(*net.TCPConn); ok {
		tcp.SetNoDelay(true)
		tcp.SetKeepAlive(true)
		tcp.SetKeepAlivePeriod(15 * time.Second)
		// Default to strict 8MB if not set in config, or use config if available
		// Since s.Config is available:
		if s.Config.Advanced.TCPReadBuffer > 0 {
			tcp.SetReadBuffer(s.Config.Advanced.TCPReadBuffer)
		} else {
			tcp.SetReadBuffer(8388608)
		}
		if s.Config.Advanced.TCPWriteBuffer > 0 {
			tcp.SetWriteBuffer(s.Config.Advanced.TCPWriteBuffer)
		} else {
			tcp.SetWriteBuffer(8388608)
		}
	}'''

# Attempt to locate insertion point
target = r'''	conn, _, err := hj.Hijack()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}'''

if target in server_code:
    server_code = server_code.replace(target, target + '\n\n' + injection)
else:
    print("Could not find injection point in server.go")

with open(server_file, 'w', encoding='utf-8') as f:
    f.write(server_code)

print("Server-side BDP tuning applied (v3.6.11).")

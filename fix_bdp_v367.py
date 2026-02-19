import os
import re

# FILES
client_file = r"C:\GGNN\RsTunnel-main\client.go"
config_file = r"C:\GGNN\RsTunnel-main\config.go"

# 1. RESTORE KERNEL BUFFERS (client.go)
# Add SetReadBuffer/SetWriteBuffer back to setTCPOptions
# We need to cast to *net.TCPConn if the interface doesn't support it directly, 
# or add it to the interface definition if we want to be generic. 
# Best way: check for SetReadBuffer method or try to assert *net.TCPConn.

with open(client_file, 'r', encoding='utf-8') as f:
    client_code = f.read()

# Replace setTCPOptions with version that sets buffers
new_tcp_opts = r'''func (c *Client) setTCPOptions(conn net.Conn) {
	// Try to set buffers on the underlying TCP connection
	if tcp, ok := conn.(*net.TCPConn); ok {
		tcp.SetKeepAlive(true)
		tcp.SetKeepAlivePeriod(time.Duration(c.cfg.Advanced.TCPKeepAlive) * time.Second)
		tcp.SetNoDelay(c.cfg.Advanced.TCPNoDelay)
		if c.cfg.Advanced.TCPReadBuffer > 0 {
			tcp.SetReadBuffer(c.cfg.Advanced.TCPReadBuffer)
		}
		if c.cfg.Advanced.TCPWriteBuffer > 0 {
			tcp.SetWriteBuffer(c.cfg.Advanced.TCPWriteBuffer)
		}
		return
	}

	// Fallback for wrapped conns or interfaces
	type hasTCP interface {
		SetKeepAlive(bool) error
		SetKeepAlivePeriod(time.Duration) error
		SetNoDelay(bool) error
		SetReadBuffer(int) error
		SetWriteBuffer(int) error
	}
	if tc, ok := conn.(hasTCP); ok {
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(time.Duration(c.cfg.Advanced.TCPKeepAlive) * time.Second)
		tc.SetNoDelay(c.cfg.Advanced.TCPNoDelay)
		if c.cfg.Advanced.TCPReadBuffer > 0 {
			tc.SetReadBuffer(c.cfg.Advanced.TCPReadBuffer)
		}
		if c.cfg.Advanced.TCPWriteBuffer > 0 {
			tc.SetWriteBuffer(c.cfg.Advanced.TCPWriteBuffer)
		}
	}
}'''

client_code = re.sub(r'func \(c \*Client\) setTCPOptions.*?^}', new_tcp_opts, client_code, flags=re.DOTALL|re.MULTILINE)

# 2. TUNE BUFFERS TO 8MB (config.go)
# Modify "aggressive" profile defaults in applyProfile
# Increase MaxRecv/MaxStream/TCPBuffers to 8MB (8388608)
with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

# Replace aggressive block
# We look for the block we modified in v3.6.6 or v3.6.1
aggressive_match = r'case "aggressive":.*?c\.Obfuscation\.Enabled = false'
# But regex spanning lines is tricky. Let's targeting specific lines.

# Update buffer enforcement in aggressive profile
# Old: 4194304 (4MB)
# New: 8388608 (8MB)
config_code = config_code.replace(
    'c.Smux.MaxRecv < 4194304',
    'c.Smux.MaxRecv < 8388608'
).replace(
    'c.Smux.MaxRecv = 4194304',
    'c.Smux.MaxRecv = 8388608'
).replace(
    'c.Smux.MaxStream < 4194304',
    'c.Smux.MaxStream < 8388608'
).replace(
    'c.Smux.MaxStream = 4194304',
    'c.Smux.MaxStream = 8388608'
)

# Add TCP Buffer defaults to aggressive profile
# We insert them after MaxStream setting
insertion = r'''
		c.Smux.MaxStream = 8388608
		}
		// v3.6.7: BDP Tuning for 400Mbps+ @ 120ms (Target ~6MB, setting 8MB safety)
		if c.Advanced.TCPReadBuffer < 8388608 {
			c.Advanced.TCPReadBuffer = 8388608
		}
		if c.Advanced.TCPWriteBuffer < 8388608 {
			c.Advanced.TCPWriteBuffer = 8388608
		}'''

# This replace relies on the context being exact.
# Current code in aggressive:
# if c.Smux.MaxStream < 8388608 { (after replace above)
# 	c.Smux.MaxStream = 8388608
# }
# So we replace the closing brace with our block + closing brace
config_code = config_code.replace(
    'c.Smux.MaxStream = 8388608\n		}',
    'c.Smux.MaxStream = 8388608\n		}' + insertion
)

with open(client_file, 'w', encoding='utf-8') as f:
    f.write(client_code)

with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)

print("BDP Tuning applied (8MB buffers) v3.6.7.")

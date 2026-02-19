import os
import re

# FILES
client_file = r"C:\GGNN\RsTunnel-main\client.go"
config_file = r"C:\GGNN\RsTunnel-main\config.go"
server_file = r"C:\GGNN\RsTunnel-main\server.go"

# 1. UPGRADE FRAME SIZES (Client)
# Old: var frameSizes = [5]int{2048, 4096, 8192, 16384, 32768}
# New: var frameSizes = [5]int{16384, 32768, 65536, 131072, 262144} (Start bigger, go huge)
with open(client_file, 'r', encoding='utf-8') as f:
    client_code = f.read()

client_code = client_code.replace(
    'var frameSizes = [5]int{2048, 4096, 8192, 16384, 32768}',
    'var frameSizes = [5]int{16384, 32768, 65536, 131072, 262144} // Tuned for 400Mbps+'
)

# 2. INCREASE DEFAULT BUFFERS (Config)
# Boost TCP/WS defaults in applyProfile
with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

# Aggressive Profile upgrades
config_code = config_code.replace(
    'c.Smux.FrameSize < 32768 {',
    'c.Smux.FrameSize < 131072 {'
).replace(
    'c.Smux.FrameSize = 32768',
    'c.Smux.FrameSize = 131072'
).replace(
    'c.Smux.MaxRecv < 4194304 {',
    'c.Smux.MaxRecv < 16777216 {' # 16MB
).replace(
    'c.Smux.MaxRecv = 4194304',
    'c.Smux.MaxRecv = 16777216'
).replace(
    'c.Smux.MaxStream < 4194304 {',
    'c.Smux.MaxStream < 8388608 {' # 8MB
).replace(
    'c.Smux.MaxStream = 4194304',
    'c.Smux.MaxStream = 8388608'
)

# 3. SET KERNEL BUFFERS (Client Dial)
# In setTCPOptions(conn net.Conn)
tcp_opt_replacement = r'''func (c *Client) setTCPOptions(conn net.Conn) {
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
		// Force large kernel buffers for high BDP (Bandwidth-Delay Product)
		// 4MB is sufficient for ~330Mbps @ 100ms RTT
		// c.cfg.Advanced.TCPReadBuffer usually 0 (default), so we enforce a high minimum
		tc.SetReadBuffer(4 * 1024 * 1024)
		tc.SetWriteBuffer(4 * 1024 * 1024)
	}
}'''

# Replace the existing setTCPOptions function using regex to match dynamic content if needed, 
# but simple replacement works if code is exact.
# Using a regex to be safe against minor whitespace.
client_code = re.sub(
    r'func \(c \*Client\) setTCPOptions\(conn net\.Conn\) \{.*?^}',
    tcp_opt_replacement,
    client_code,
    flags=re.DOTALL|re.MULTILINE
)

# 4. WRITE FILES
with open(client_file, 'w', encoding='utf-8') as f:
    f.write(client_code)

with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)

print("Performance fixes v3.6.0 applied.")

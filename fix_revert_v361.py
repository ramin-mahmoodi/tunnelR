import os
import re

# FILES
client_file = r"C:\GGNN\RsTunnel-main\client.go"
config_file = r"C:\GGNN\RsTunnel-main\config.go"

# 1. REVERT FRAME SIZES (Client)
# Old (v3.6.0): var frameSizes = [5]int{16384, 32768, 65536, 131072, 262144}
# New (v3.6.1): var frameSizes = [5]int{2048, 4096, 8192, 16384, 32768} (Back to safe defaults)
with open(client_file, 'r', encoding='utf-8') as f:
    client_code = f.read()

client_code = client_code.replace(
    'var frameSizes = [5]int{16384, 32768, 65536, 131072, 262144} // Tuned for 400Mbps+',
    'var frameSizes = [5]int{2048, 4096, 8192, 16384, 32768}'
)

# 2. REVERT DEFAULT BUFFERS (Config)
# Back to 4MB max for Aggressive
with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

config_code = config_code.replace(
    'c.Smux.FrameSize < 131072 {',
    'c.Smux.FrameSize < 32768 {'
).replace(
    'c.Smux.FrameSize = 131072',
    'c.Smux.FrameSize = 32768'
).replace(
    'c.Smux.MaxRecv < 16777216 {',
    'c.Smux.MaxRecv < 4194304 {'
).replace(
    'c.Smux.MaxRecv = 16777216',
    'c.Smux.MaxRecv = 4194304'
).replace(
    'c.Smux.MaxStream < 8388608 {',
    'c.Smux.MaxStream < 4194304 {'
).replace(
    'c.Smux.MaxStream = 8388608',
    'c.Smux.MaxStream = 4194304'
)

# 3. REMOVE KERNEL BUFFER ENFORCEMENT (Client Dial)
# Revert setTCPOptions to standard logic without SetReadBuffer/SetWriteBuffer
tcp_opt_original = r'''func (c *Client) setTCPOptions(conn net.Conn) {
	type hasTCP interface {
		SetKeepAlive(bool) error
		SetKeepAlivePeriod(time.Duration) error
		SetNoDelay(bool) error
	}
	if tc, ok := conn.(hasTCP); ok {
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(time.Duration(c.cfg.Advanced.TCPKeepAlive) * time.Second)
		tc.SetNoDelay(c.cfg.Advanced.TCPNoDelay)
	}
}'''

# Match the v3.6.0 version and replace it
client_code = re.sub(
    r'func \(c \*Client\) setTCPOptions\(conn net\.Conn\) \{.*?^}',
    tcp_opt_original,
    client_code,
    flags=re.DOTALL|re.MULTILINE
)

# 4. WRITE FILES
with open(client_file, 'w', encoding='utf-8') as f:
    f.write(client_code)

with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)

print("Performance settings reverted to v3.6.1 (Safe Mode).")

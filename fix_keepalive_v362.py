import os
import re

# FILES
config_file = r"C:\GGNN\RsTunnel-main\config.go"

# 1. ENFORCE TCP KEEPALIVE & NODELAY (Config)
# We inject these defaults into `applyBaseDefaults`.

with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

# We look for the end of applyBaseDefaults to append our checks
# Logic: Find `// TLS Fragment defaults` and insert above it
insertion_point = '// TLS Fragment defaults'
new_defaults = r'''// ✅ Default Advanced TCP Settings (Fix for "Speed Drop" & "Disconnects")
	if c.Advanced.TCPKeepAlive <= 0 {
		c.Advanced.TCPKeepAlive = 15 // 15s keeps NAT/Firewalls open
	}
	if !c.Advanced.TCPNoDelay {
		c.Advanced.TCPNoDelay = true // Disable Nagle's algo for lower latency
	}

	'''

if insertion_point in config_code:
    config_code = config_code.replace(insertion_point, new_defaults + insertion_point)
else:
    print("Warning: Insertion point not found!")

# 2. WRITE FILE
with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)

print("TCP KeepAlive & NoDelay enforcement applied (v3.6.2).")

import os

# FILES
config_file = r"C:\GGNN\RsTunnel-main\config.go"
client_file = r"C:\GGNN\RsTunnel-main\client.go"
main_file = r"C:\GGNN\RsTunnel-main\cmd\picotun\main.go"

# 1. REVERT CONFIG.GO
with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

# Remove SocksListen field
if 'SocksListen' in config_code:
    config_code = config_code.replace(
        'Compression   string `yaml:"compression"`\n\tSocksListen   string `yaml:"socks_listen"` // v3.6.12: Local SOCKS5 Listener',
        'Compression   string `yaml:"compression"`'
    )

# Remove default logic in applyBaseDefaults
# The injection was:
# 	if c.Mode == "client" && c.SocksListen == "" {
# 		c.SocksListen = "127.0.0.1:1080"
# 	}
# We need to find and remove this block.
# Since we know exact string from previous script:
removal = r'''	if c.Mode == "client" && c.SocksListen == "" {
		c.SocksListen = "127.0.0.1:1080"
	}
'''
config_code = config_code.replace(removal, "")

with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)
print("Reverted config.go (Removed SocksListen)")


# 2. REVERT CLIENT.GO
with open(client_file, 'r', encoding='utf-8') as f:
    client_code = f.read()

# Remove imports (encoding/binary was added)
# We can't easily revert imports safely with regex if they were reordered,
# but we can try to revert the specific change or just leave unused imports (go fmt will fix, or build might fail if unused but we are removing usage).
# Actually, go build fails heavily on unused imports.
# The previous script replaced "context" with "context"\n\t"encoding/binary"\n\t"errors"
client_code = client_code.replace(
    '"context"\n\t"encoding/binary"\n\t"errors"',
    '"context"'
)

# Remove StartSocks and handleSocks methods
# We appended them at the end.
# We can search for the start marker.
marker = r'// ───────────── SOCKS5 Server (v3.6.12) ─────────────'
if marker in client_code:
    parts = client_code.split(marker)
    client_code = parts[0] # Keep everything before the marker

with open(client_file, 'w', encoding='utf-8') as f:
    f.write(client_code)
print("Reverted client.go (Removed SOCKS5 logic)")


# 3. REVERT MAIN.GO
with open(main_file, 'r', encoding='utf-8') as f:
    main_code = f.read()

# Remove cl.StartSocks(ctx)
# The replace was:
# 'go func() { errCh <- cl.Start(ctx) }()\n\t\tgo func() { errCh <- cl.StartSocks(ctx) }()'
main_code = main_code.replace(
    'go func() { errCh <- cl.Start(ctx) }()\n\t\tgo func() { errCh <- cl.StartSocks(ctx) }()',
    'go func() { errCh <- cl.Start(ctx) }()'
)

with open(main_file, 'w', encoding='utf-8') as f:
    f.write(main_code)
print("Reverted main.go (Removed StartSocks call)")

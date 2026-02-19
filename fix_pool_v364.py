import os

# FILES
config_file = r"C:\GGNN\RsTunnel-main\config.go"
setup_file = r"C:\GGNN\RsTunnel-main\setup.sh"

# 1. REVERT CONFIG (config.go)
# v3.6.3 forced: if c.Paths[i].ConnectionPool < 16 { c.Paths[i].ConnectionPool = 16 }
# Revert to: if c.Paths[i].ConnectionPool < 4 { c.Paths[i].ConnectionPool = 4 }
with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

config_code = config_code.replace(
    'if c.Paths[i].ConnectionPool < 16 {',
    'if c.Paths[i].ConnectionPool < 4 {'
).replace(
    'c.Paths[i].ConnectionPool = 16',
    'c.Paths[i].ConnectionPool = 4'
)

# 2. REVERT SETUP SCRIPT (setup.sh)
# v3.6.3 default: [16]
# Revert to: [8]
with open(setup_file, 'r', encoding='utf-8') as f:
    setup_code = f.read()

setup_code = setup_code.replace(
    'read -p "Connection Pool Size [16]: " POOL_SIZE',
    'read -p "Connection Pool Size [8]: " POOL_SIZE'
).replace(
    'POOL_SIZE=${POOL_SIZE:-16}',
    'POOL_SIZE=${POOL_SIZE:-8}'
)

# 3. WRITE FILES
with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)

with open(setup_file, 'w', encoding='utf-8') as f:
    f.write(setup_code)

print("Connection Pool and defaults reverted to 8 (v3.6.4).")

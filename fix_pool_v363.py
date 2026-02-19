import os
import re

# FILES
config_file = r"C:\GGNN\RsTunnel-main\config.go"
setup_file = r"C:\GGNN\RsTunnel-main\setup.sh"

# 1. UPGRADE AGGRESSIVE PROFILE (config.go)
# Force minimum 16 connections for "aggressive" profile (was 4)
# This overrides the '8' in the config file automatically.

with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

config_code = config_code.replace(
    'if c.Paths[i].ConnectionPool < 4 {',
    'if c.Paths[i].ConnectionPool < 16 {'
).replace(
    'c.Paths[i].ConnectionPool = 4',
    'c.Paths[i].ConnectionPool = 16'
)

# 2. UPDATE SETUP SCRIPT DEFAULT (setup.sh)
# Change prompt default from 8 to 16
with open(setup_file, 'r', encoding='utf-8') as f:
    setup_code = f.read()

setup_code = setup_code.replace(
    'read -p "Connection Pool Size [8]: " POOL_SIZE',
    'read -p "Connection Pool Size [16]: " POOL_SIZE'
).replace(
    'POOL_SIZE=${POOL_SIZE:-8}',
    'POOL_SIZE=${POOL_SIZE:-16}'
)

# 3. WRITE FILES
with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)

with open(setup_file, 'w', encoding='utf-8') as f:
    f.write(setup_code)

print("Connection Pool upgraded to 16 (v3.6.3).")

import os

# FILES
config_file = r"C:\GGNN\RsTunnel-main\config.go"

# 1. RESTORE FEATURES (config.go)
# We need to revert the changes made in v3.6.6 and v3.6.9

with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

# Revert v3.6.6: Overhead Reduction
# change "c.Fragment.Enabled = false" -> "true"
config_code = config_code.replace(
    'c.Fragment.Enabled = false',
    'c.Fragment.Enabled = true // v3.6.10: Restored (User request)'
)

# change "c.Obfuscation.Enabled = false" -> "true"
config_code = config_code.replace(
    'c.Obfuscation.Enabled = false',
    'c.Obfuscation.Enabled = true // v3.6.10: Restored (User request)'
)

# Revert v3.6.9: CPU Optimization
# Remove "c.Compression = "none""
# We can just comment it out or set it to "snappy"
# Explicit "snappy" is safer to ensure it's back.
config_code = config_code.replace(
    'c.Compression = "none"',
    'c.Compression = "snappy" // v3.6.10: Restored (User request)'
)

with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)

print("Features restored for Aggressive profile (v3.6.10).")

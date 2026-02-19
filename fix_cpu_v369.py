import os

# FILES
config_file = r"C:\GGNN\RsTunnel-main\config.go"

# 1. DISABLE COMPRESSION (config.go)
# Modify "aggressive" profile to disable snappy
with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

# Current aggressive block starts around lines 225-230
# We want to add `c.Compression = "none"` to it.
# We also want to ensure chunked encoding is off (already is).

# We'll replace the existing `c.HTTPMimic.ChunkedEncoding = false` 
# with the compression disable line as well.
replacement = r'''c.HTTPMimic.ChunkedEncoding = false
		// v3.6.9: Disable Compression to save CPU at high speeds (>100Mbps)
		c.Compression = "none"'''

config_code = config_code.replace(
    'c.HTTPMimic.ChunkedEncoding = false',
    replacement
)

with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)

print("Compression disabled for Aggressive profile (v3.6.9).")

import os

# FILES
config_file = r"C:\GGNN\RsTunnel-main\config.go"

# 1. DISABLE OVERHEAD DEFAULTS (config.go)
# We modify applyBaseDefaults logic
# - Remove "c.Fragment.Enabled = true" enforcement
# - Set Obfuscation.Enabled default to false? (It's bool, defaults false. We need to check if we enforce true)

with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

# Disable Fragment Enforcement
# Was:
# if !c.Fragment.Enabled && (transport == "httpsmux" || transport == "wssmux") {
# 	c.Fragment.Enabled = true
# }
config_code = config_code.replace(
    'c.Fragment.Enabled = true',
    'c.Fragment.Enabled = false // v3.6.6: Disabled to reduce overhead'
)

# Disable Obfuscation Default enforcement (if any)
# Currently ApplyBaseDefaults doesn't enforce Enabled=true, but LoadConfig might.
# Looking at LoadConfig:
# c := Config{ ... EnableDecoy: true, ... }
# It doesn't seem to set Obfusction.Enabled=true explicitly in LoadConfig snippet I saw, 
# BUT `setup.sh` generates config with `obfuscation: enabled: true`.

# We can't easily change existing configs via Go code (they are on disk).
# BUT we can modify `setup.sh` to generate `enabled: false` for NEW configs/updates.
# AND we can force it off in `applyProfile` "aggressive".

# Modify applyProfile "aggressive" to force disable overhead
aggressive_tweak = r'''case "aggressive":
		// Aggressive = MAX SPEED: bigger buffers, zero delay, small padding
		// v3.6.6: Force disable overhead
		c.Fragment.Enabled = false
		c.Obfuscation.Enabled = false'''

config_code = config_code.replace(
    'case "aggressive":\n		// Aggressive = MAX SPEED: bigger buffers, zero delay, small padding',
    aggressive_tweak
)

with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)

print("Protocol overhead disabled for Aggressive profile (v3.6.6).")

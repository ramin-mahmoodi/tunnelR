import re

file_path = r"C:\GGNN\RsTunnel-main\setup.sh"

# Read as UTF-8 (replace errors to handle immediate issues)
with open(file_path, 'r', encoding='utf-8', errors='replace') as f:
    text = f.read()

# Manual mapping for known artifacts to make them look nice
# These often appear as multi-byte sequences in UTF-8
replacements = {
    # Arrows
    "\u25b6": ">",  # â–¶
    "\u279c": "->", 
    "\u2192": "->",
    
    # Emojis / Symbols
    "\u274c": "[!]", # âŒ / ❌
    "\u2714": "[OK]", # ✓
    "\u2699": "[*]",  # ⚙
    "\U0001f4e6": "[PK]", # 📦
    "\U0001f680": "[*]",  # 🚀
    "\U0001f50e": "[?]",  # 🔎
    "\u26a0": "[!]",      # ⚠️
    
    # Mojibake remnants (Bytes interpreted as chars in specialized encodings)
    "â–¶": ">",
    "ðŸ": "*",
    "âŒ": "[!]",
    "âœ": "[OK]",
    "âš": "[*]",
}

for k, v in replacements.items():
    text = text.replace(k, v)

# Final Aggressive Sweep:
# Filter out ANY character with code point > 127
clean_chars = []
for char in text:
    if ord(char) < 128:
        clean_chars.append(char)
    else:
        # Optional: Replace unknown non-ASCII with ? or nothing
        # User said "fix everything", so removing them is safest 
        # to avoid random '?' appearing in UI.
        pass 

final_text = "".join(clean_chars)

with open(file_path, 'w', encoding='ascii') as f:
    f.write(final_text)

print(f"Force ASCII complete. Original size: {len(text)}, New size: {len(final_text)}")

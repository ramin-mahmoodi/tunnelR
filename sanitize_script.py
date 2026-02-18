import re

file_path = r"C:\GGNN\RsTunnel-main\setup.sh"

# Read as binary to avoid encoding errors and see raw bytes
with open(file_path, 'rb') as f:
    content = f.read()

# Decode with utf-8, replace errors to see what's there (though we want to replace specific bytes)
# Actually, better to read as text with utf-8 and replace specific chars
with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
    text = f.read()

# Replacements (Emojis -> ASCII)
replacements = {
    "âŒ": "[ERROR]", # Mojibake for ❌
    "❌": "[ERROR]",
    "📦": "[INFO]",
    "ðŸ“¦": "[INFO]", # Mojibake for 📦
    "✓": "[OK]",
    "âœ“": "[OK]",   # Mojibake for ✓
    "âœ–": "[ERROR]", # Mojibake for ✖
    "✖": "[ERROR]",
    "⚙️": "[*]",
    "âš™ï¸": "[*]",   # Mojibake for ⚙️
    "🚀": "[*]",
    "ðŸš€": "[*]",   # Mojibake for 🚀
    "â¬‡ï¸": "[DOWN]", # Mojibake for ⬇️
    "⬇️": "[DOWN]",
    "ðŸ”": "[*]",    # Mojibake for 🔎
    "🔎": "[*]",
    "âš ï¸": "[WARN]", # Mojibake for ⚠️
    "⚠️": "[WARN]",
    "â•¯": "+",      # Spinner/bullet
}

for k, v in replacements.items():
    text = text.replace(k, v)

# Final cleanup: Remove any other non-ASCII characters
# Keep only printable ASCII (32-126) and newlines/tabs
clean_text = ""
for char in text:
    if 32 <= ord(char) <= 126 or char in '\n\t\r':
        clean_text += char
    else:
        continue # Drop it

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(clean_text)

print("Sanitized setup.sh.")

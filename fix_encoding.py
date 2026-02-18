import os

file_path = r"C:\GGNN\RsTunnel-main\setup.sh"

with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
    lines = f.readlines()

# Fix Header
lines[2] = "# ===============================================================\n"
lines[5] = "# ===============================================================\n"

# Fix Banner
for i, line in enumerate(lines):
    if "show_banner() {" in line:
        lines[i+3] = '    echo "  +=======================================+"\n'
        lines[i+4] = '    echo "  |           TunnelR (PicoTun)           |"\n'
        lines[i+5] = '    echo "  |          Script v${SCRIPT_VERSION}          |"\n'
        lines[i+6] = '    echo "  +=======================================+"\n'
        break # Found banner

# Fix other corruptions blindly
for i, line in enumerate(lines):
    if "â" in line: # Broad match for the corrupted prefix
        if "echo" in line and "CYAN" in line: # likely a separator
             lines[i] = '    echo -e "${CYAN}--------------------------------------------------${NC}"\n'
        elif "#" in line and len(line) > 20: # likely a comment separator
             lines[i] = '# ----------------------------------------------------------------\n'

with open(file_path, 'w', encoding='utf-8') as f:
    f.writelines(lines)

print("Fixed setup.sh encoding.")

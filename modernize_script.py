import re
import os

file_path = r"C:\GGNN\RsTunnel-main\setup.sh"

with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. NEW COLORS & HELPERS
new_colors = r'''
# Colors & Styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# Modern Separators
draw_line() {
    printf "${CYAN}â”€%.0s${NC}" {1..60}
    echo ""
}

draw_header() {
    echo ""
    printf "${BG_BLUE}${WHITE}  %s  ${NC}\n" "$1"
    draw_line
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}
'''

# Replace old colors ref (heuristic)
content = re.sub(r"RED='\\033\[0;31m'.*?NC='\\033\[0m'", new_colors, content, flags=re.DOTALL)

# 2. NEW BANNER
new_banner = r'''
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "   ____  _           _____              "
    echo "  |  _ \(_) ___ ___ |_   _|   _ _ __    "
    echo "  | |_) | |/ __/ _ \  | || | | | '_ \   "
    echo "  |  __/| | (_| (_) | | || |_| | | | |  "
    echo "  |_|   |_|\___\___/  |_| \__,_|_| |_|  "
    echo -e "${NC}"
    echo -e "${PURPLE}   â–¶ Dagger-Compatible Reverse Tunnel v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}   â–¶ github.com/${GITHUB_REPO}${NC}"
    echo ""
}
'''
content = re.sub(r"show_banner\(\) \{.*?^\}", new_banner, content, flags=re.DOTALL|re.MULTILINE)

# 3. NEW DOWNLOAD (with Animation)
new_download = r'''
download_binary() {
    draw_header "Downloading PicoTun Core"
    mkdir -p "$INSTALL_DIR"
    detect_arch

    echo -e "  â•¯ Checking latest release..."
    LATEST_VERSION=$(curl -s "$LATEST_RELEASE_API" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}  ! API Rate Limit / Network Error${NC} -> Fallback v1.8.8"
        LATEST_VERSION="v1.8.8"
    fi

    TAR_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_VERSION}/picotun-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
    echo -e "  â•¯ Version: ${GREEN}${LATEST_VERSION}${NC} (${ARCH})"

    # Backup
    [ -f "$INSTALL_DIR/$BINARY_NAME" ] && cp "$INSTALL_DIR/$BINARY_NAME" "$INSTALL_DIR/${BINARY_NAME}.bak"

    TMP_DIR=$(mktemp -d)
    
    # Download with animation
    echo -ne "  â•¯ Downloading... "
    (wget -q "$TAR_URL" -O "$TMP_DIR/picotun.tar.gz") &
    spinner $!
    echo -e "${GREEN}Done${NC}"

    if [ -f "$TMP_DIR/picotun.tar.gz" ]; then
        tar -xzf "$TMP_DIR/picotun.tar.gz" -C "$TMP_DIR"
        mv "$TMP_DIR/picotun" "$INSTALL_DIR/$BINARY_NAME"
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        rm -rf "$TMP_DIR"
        rm -f "$INSTALL_DIR/${BINARY_NAME}.bak"
        echo -e "\n${GREEN}  âœ“ Installation Successful${NC}"
    else
        rm -rf "$TMP_DIR"
        [ -f "$INSTALL_DIR/${BINARY_NAME}.bak" ] && mv "$INSTALL_DIR/${BINARY_NAME}.bak" "$INSTALL_DIR/$BINARY_NAME"
        echo -e "\n${RED}  âœ– Download Failed${NC}"
        exit 1
    fi
}
'''
content = re.sub(r"download_binary\(\) \{.*?^\}", new_download, content, flags=re.DOTALL|re.MULTILINE)

# 4. NEW MENUS
new_main_menu = r'''
main_menu() {
    show_banner
    CUR=$(get_current_version)
    [ "$CUR" != "not-installed" ] && echo -e "   Current Version: ${GREEN}${CUR}${NC}\n"

    draw_header "MAIN MENU"
    
    printf "  ${CYAN}1)${NC} Install Server ${Purple}(Iran)${NC}\n"
    printf "  ${CYAN}2)${NC} Install Client ${PURPLE}(Kharej)${NC}\n"
    printf "  -----------------------------\n"
    printf "  ${CYAN}3)${NC} Dashboard Management\n"
    printf "  ${CYAN}4)${NC} Service Settings\n"
    printf "  ${CYAN}5)${NC} System Optimizer\n"
    printf "  ${CYAN}6)${NC} Update PicoTun\n"
    printf "  ${CYAN}7)${NC} Uninstall\n"
    echo ""
    printf "  ${RED}0)${NC} Exit\n"
    echo ""
    read -p "  Select option: " c

    case $c in
        1) install_server ;;
        2) install_client ;;
        3) dashboard_menu ;;
        4) settings_menu ;;
        5) optimize_system; echo ""; read -p "Press Enter..."; main_menu ;;
        6) update_binary ;;
        7) uninstall ;;
        0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) main_menu ;;
    esac
}
'''
content = re.sub(r"main_menu\(\) \{.*?^\}", new_main_menu, content, flags=re.DOTALL|re.MULTILINE)

# 5. Fix corrupted borders globally
# Remove old border lines
content = re.sub(r'echo -e "\$\{CYAN\}-+\$\{NC\}"', 'draw_line', content)
content = re.sub(r'echo -e "\$\{CYAN\}[^"]*MENU\$\{NC\}"', '', content) # Remove old headers
# (We rely on manual re-adds or just cleaner looks)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Setup script modernized.")

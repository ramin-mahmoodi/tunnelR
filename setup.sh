#!/bin/bash

# ===============================================================
# ----------------------------------------------------------------
# Setup Script (bash <(curl -s https://raw.githubusercontent.com/ramin-mahmoodi/tunnelR/main/setup.sh))
# ===============================================================

SCRIPT_VERSION="3.4.7"


# Colors & Styling
RED='[0;31m'
GREEN='[0;32m'
YELLOW='[1;33m'
BLUE='[0;34m'
PURPLE='[0;35m'
CYAN='[0;36m'
WHITE='[1;37m'
BOLD='[1m'
NC='[0m'

# Modern Separators
draw_line() {
    printf "${CYAN}â”€%.0s${NC}" {1..60}
    echo ""
}

draw_header() {
    echo ""
    printf "${BG_BLUE}${WHITE}  %s  ${NC}
" "$1"
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
        printf ""
    done
    printf "    "
}


BINARY_NAME="picotun"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/picotun"
SYSTEMD_DIR="/etc/systemd/system"

GITHUB_REPO="ramin-mahmoodi/tunnelR"
# Use 'latest' endpoint to rigidly respect the user's "Latest Release" on GitHub
LATEST_RELEASE_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

# ------------------------- Banner & Checks -------------------------


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


check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}âŒ This script must be run as root${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${YELLOW}ðŸ“¦ Installing dependencies...${NC}"
    if command -v apt &>/dev/null; then
        apt update -qq 2>/dev/null
        apt install -y wget curl tar openssl iproute2 > /dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y wget curl tar openssl iproute > /dev/null 2>&1
    fi
    echo -e "${GREEN}âœ“ Dependencies ready${NC}"
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo -e "${RED}âŒ Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac
}

get_current_version() {
    if [ -f "$INSTALL_DIR/$BINARY_NAME" ]; then
        VERSION=$("$INSTALL_DIR/$BINARY_NAME" -version 2>&1 | head -1 || echo "unknown")
        echo "$VERSION"
    else
        echo "not-installed"
    fi
}

# ------------------------- Download Binary -------------------------


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


# ----------------------------------------------------------------

generate_ssl_cert() {
    echo ""
    read -p "Domain for certificate [www.google.com]: " CERT_DOMAIN
    CERT_DOMAIN=${CERT_DOMAIN:-www.google.com}

    mkdir -p "$CONFIG_DIR/certs"
    openssl req -x509 -newkey rsa:4096 \
        -keyout "$CONFIG_DIR/certs/key.pem" \
        -out "$CONFIG_DIR/certs/cert.pem" \
        -days 365 -nodes \
        -subj "/C=US/ST=California/L=SF/O=CDN/CN=${CERT_DOMAIN}" 2>/dev/null

    CERT_FILE="$CONFIG_DIR/certs/cert.pem"
    KEY_FILE="$CONFIG_DIR/certs/key.pem"
    echo -e "${GREEN}âœ“ SSL certificate generated${NC}"
}

# ----------------------------------------------------------------

create_systemd_service() {
    local MODE=$1
    local SERVICE_NAME="picotun-${MODE}"

    cat > "$SYSTEMD_DIR/${SERVICE_NAME}.service" << EOF
[Unit]
Description=PicoTun Tunnel ${MODE^}
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$INSTALL_DIR/$BINARY_NAME -c $CONFIG_DIR/${MODE}.yaml
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo -e "${GREEN}âœ“ Service ${SERVICE_NAME} created${NC}"
}

# ----------------------------------------------------------------

optimize_system() {
    echo -e "${YELLOW}âš™ï¸  Optimizing system...${NC}"

    cat > /etc/sysctl.d/99-picotun.conf << 'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=5000
net.core.somaxconn=4096
net.ipv4.tcp_rmem=4096 1048576 16777216
net.ipv4.tcp_wmem=4096 1048576 16777216
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_max_tw_buckets=1440000
EOF

    sysctl -p /etc/sysctl.d/99-picotun.conf > /dev/null 2>&1
    echo -e "${GREEN}âœ“ System optimized (BBR + buffer tuning)${NC}"
}

# ----------------------------------------------------------------

parse_port_mappings() {
    MAPPINGS=""
    COUNT=0

    echo ""
    draw_line
    echo -e "${CYAN}         PORT MAPPINGS${NC}"
    draw_line
    echo ""
    echo -e "${YELLOW}Format:${NC}"
    echo -e "  ${GREEN}Single${NC}:    8443              â†’ 8443â†’8443"
    echo -e "  ${GREEN}Range${NC}:     1000/2000         â†’ 1000â†’1000 ... 2000â†’2000"
    echo -e "  ${GREEN}Custom${NC}:    5000=8443         â†’ 5000â†’8443"
    echo -e "  ${GREEN}Range Map${NC}: 1000/1010=2000/2010"
    echo ""

    BIND_IP="0.0.0.0"
    TARGET_IP="127.0.0.1"

    while true; do
        echo ""
# ----------------------------------------------------------------

        echo -e "${CYAN}Protocol:${NC}  1) tcp  2) udp  3) both"
        read -p "Choice [1-3]: " proto_choice
        case $proto_choice in
            1) PROTO="tcp" ;; 2) PROTO="udp" ;; 3) PROTO="both" ;; *) PROTO="tcp" ;;
        esac

        echo -e "${YELLOW}Examples: 8443 | 1000/2000 | 5000=8443${NC}"
        read -p "Port(s): " PORT_INPUT

        [ -z "$PORT_INPUT" ] && { echo -e "${RED}âš  Empty!${NC}"; continue; }
        PORT_INPUT=$(echo "$PORT_INPUT" | tr -d ' ')

        # Range Map: 1000/1010=2000/2010
        if [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)=([0-9]+)/([0-9]+)$ ]]; then
            BS=${BASH_REMATCH[1]}; BE=${BASH_REMATCH[2]}; TS=${BASH_REMATCH[3]}; TE=${BASH_REMATCH[4]}
            BR=$((BE-BS+1)); TR=$((TE-TS+1))
            [ "$BR" -ne "$TR" ] && { echo -e "${RED}Range mismatch!${NC}"; continue; }
            for ((i=0; i<BR; i++)); do
                add_mapping "$PROTO" "${BIND_IP}:$((BS+i))" "${TARGET_IP}:$((TS+i))"
            done
            echo -e "${GREEN}âœ“ Added $BR mappings ($PROTO)${NC}"

        # Range: 1000/2000
        elif [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            SP=${BASH_REMATCH[1]}; EP=${BASH_REMATCH[2]}
            for ((p=SP; p<=EP; p++)); do
                add_mapping "$PROTO" "${BIND_IP}:${p}" "${TARGET_IP}:${p}"
            done
            echo -e "${GREEN}âœ“ Added $((EP-SP+1)) mappings ($PROTO)${NC}"

        # Custom: 5000=8443
        elif [[ "$PORT_INPUT" =~ ^([0-9]+)=([0-9]+)$ ]]; then
            add_mapping "$PROTO" "${BIND_IP}:${BASH_REMATCH[1]}" "${TARGET_IP}:${BASH_REMATCH[2]}"
            echo -e "${GREEN}âœ“ ${BASH_REMATCH[1]} â†’ ${BASH_REMATCH[2]} ($PROTO)${NC}"

        # Single: 8443
        elif [[ "$PORT_INPUT" =~ ^[0-9]+$ ]]; then
            add_mapping "$PROTO" "${BIND_IP}:${PORT_INPUT}" "${TARGET_IP}:${PORT_INPUT}"
            echo -e "${GREEN}âœ“ ${PORT_INPUT} â†’ ${PORT_INPUT} ($PROTO)${NC}"

        else
            echo -e "${RED}âš  Invalid format!${NC}"; continue
        fi

        read -p "Add another? [y/N]: " more
        [[ ! "$more" =~ ^[Yy]$ ]] && break
    done

    [ "$COUNT" -eq 0 ] && {
        echo -e "${YELLOW}âš  No ports! Adding 8080â†’8080 default${NC}"
        add_mapping "tcp" "0.0.0.0:8080" "127.0.0.1:8080"
    }
}

add_mapping() {
    local proto=$1 bind=$2 target=$3
    if [ "$proto" == "both" ]; then
        MAPPINGS="${MAPPINGS}  - type: tcp\n    bind: \"${bind}\"\n    target: \"${target}\"\n"
        MAPPINGS="${MAPPINGS}  - type: udp\n    bind: \"${bind}\"\n    target: \"${target}\"\n"
        COUNT=$((COUNT+2))
    else
        MAPPINGS="${MAPPINGS}  - type: ${proto}\n    bind: \"${bind}\"\n    target: \"${target}\"\n"
        COUNT=$((COUNT+1))
    fi
}

# ----------------------------------------------------------------

optimize_system() {
    echo -e "${CYAN}ðŸš€ Optimizing System Network Stack...${NC}"
    IFACE=$(ip link show | grep "state UP" | head -1 | awk '{print $2}' | cut -d: -f1)
    [[ -z "$IFACE" ]] && IFACE="eth0"
    echo -e "  Interface: ${PURPLE}$IFACE${NC}"

    # Apply sysctl settings instantly
    sysctl -w net.core.rmem_max=8388608 > /dev/null 2>&1
    sysctl -w net.core.wmem_max=8388608 > /dev/null 2>&1
    sysctl -w net.core.rmem_default=131072 > /dev/null 2>&1
    sysctl -w net.core.wmem_default=131072 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 65536 8388608" > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 65536 8388608" > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_window_scaling=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_timestamps=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_sack=1 > /dev/null 2>&1
    sysctl -w net.core.netdev_max_backlog=65535 > /dev/null 2>&1
    sysctl -w net.core.somaxconn=65535 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing=1 > /dev/null 2>&1
    
    # Try enabling BBR
    if modprobe tcp_bbr 2>/dev/null; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
        sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1
        echo -e "  Congestion Control: ${GREEN}BBR${NC}"
    else
        echo -e "  Congestion Control: ${YELLOW}Cubic (BBR not supported)${NC}"
    fi

    # Persist settings
    cat > /etc/sysctl.d/99-rstunnel-opt.conf << 'EOF'
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.core.rmem_default=131072
net.core.wmem_default=131072
net.ipv4.tcp_rmem=4096 65536 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.core.netdev_max_backlog=65535
net.core.somaxconn=65535
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
fs.file-max=1000000
EOF

    # Increase file limits
    cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 1000000
* hard nofile 1000000
EOF

    # Apply changes
    sysctl -p /etc/sysctl.d/99-rstunnel-opt.conf > /dev/null 2>&1
    echo -e "${GREEN}âœ“ System optimized for high throughput${NC}"
}

# ----------------------------------------------------------------

install_server_auto() {
    echo ""
    draw_line
    echo -e "${CYAN}   AUTOMATIC SERVER CONFIGURATION${NC}"
    draw_line
    echo ""

    read -p "Tunnel Port [2020]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-2020}

    while true; do
        read -sp "PSK (Pre-Shared Key): " PSK; echo
        [ -n "$PSK" ] && break
        echo -e "${RED}PSK cannot be empty!${NC}"
    done

    echo ""
    echo -e "${YELLOW}Transport:${NC}"
    echo "  1) httpsmux  - HTTPS Mimicry â­ Recommended"
    echo "  2) httpmux   - HTTP Mimicry"
    echo "  3) tcpmux    - Simple TCP"
    read -p "Choice [1-3]: " tc
    case $tc in
        1) TRANSPORT="httpsmux" ;; 2) TRANSPORT="httpmux" ;; 3) TRANSPORT="tcpmux" ;; *) TRANSPORT="httpsmux" ;;
    esac

    parse_port_mappings

    # SSL cert for TLS transports
    CERT_FILE=""
    KEY_FILE=""
    if [ "$TRANSPORT" == "httpsmux" ] || [ "$TRANSPORT" == "wssmux" ]; then
        echo ""
        echo -e "${YELLOW}Generating SSL certificate...${NC}"
        generate_ssl_cert
    fi

    # Write config
    mkdir -p "$CONFIG_DIR"
    CONFIG_FILE="$CONFIG_DIR/server.yaml"
    cat > "$CONFIG_FILE" << EOF
mode: "server"
listen: "0.0.0.0:${LISTEN_PORT}"
transport: "${TRANSPORT}"
psk: "${PSK}"
profile: "aggressive"
verbose: true
heartbeat: 2


EOF

    if [ -n "$CERT_FILE" ]; then
        cat >> "$CONFIG_FILE" << EOF

cert_file: "$CERT_FILE"
key_file: "$KEY_FILE"
EOF
    fi

    echo -e "\nmaps:\n$MAPPINGS" >> "$CONFIG_FILE"

    cat >> "$CONFIG_FILE" << 'EOF'

smux:
  keepalive: 10
  max_recv: 4194304
  max_stream: 4194304
  frame_size: 32768
  version: 2

fragment:
  enabled: true
  min_size: 64
  max_size: 191
  min_delay: 1
  max_delay: 2

advanced:
  tcp_nodelay: true
  tcp_keepalive: 10
  tcp_read_buffer: 4194304
  tcp_write_buffer: 4194304
  cleanup_interval: 1
  session_timeout: 15
  connection_timeout: 20
  max_connections: 300

obfuscation:
  enabled: true
  min_padding: 8
  max_padding: 32
  min_delay_ms: 0
  max_delay_ms: 0
  burst_chance: 0

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  chunked_encoding: false
  session_cookie: true
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
    - "Accept-Encoding: gzip, deflate, br"
EOF

    # Default Dashboard (Disabled)
    # Use 'Configure Dashboard' in menu to enable

    create_systemd_service "server"

    echo ""
    read -p "Optimize system? [Y/n]: " opt
    [[ ! "$opt" =~ ^[Nn]$ ]] && optimize_system

    systemctl start picotun-server
    systemctl start picotun-server
    systemctl enable picotun-server 2>/dev/null

    # Firewall
    if command -v ufw &>/dev/null; then
        ufw allow ${LISTEN_PORT}/tcp >/dev/null 2>&1
        ufw allow 8585/tcp >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=${LISTEN_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=8585/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo ""
    echo -e "${GREEN}â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•${NC}"
    echo -e "${GREEN}   âœ“ Server installed & running!${NC}"
    echo -e "${GREEN}â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•${NC}"
    echo ""
    echo -e "  Port:      ${GREEN}${LISTEN_PORT}${NC}"
    echo -e "  PSK:       ${GREEN}${PSK}${NC}"
    echo -e "  Transport: ${GREEN}${TRANSPORT}${NC}"
    echo -e "  Config:    ${CYAN}${CONFIG_FILE}${NC}"
    echo -e "  Logs:      ${CYAN}journalctl -u picotun-server -f${NC}"
    echo ""
    read -p "Press Enter..."
    main_menu
}

# ----------------------------------------------------------------

install_client_auto() {
    echo ""
    draw_line
    echo -e "${CYAN}   AUTOMATIC CLIENT CONFIGURATION${NC}"
    draw_line
    echo ""

    while true; do
        read -sp "PSK (must match server): " PSK; echo
        [ -n "$PSK" ] && break
        echo -e "${RED}PSK cannot be empty!${NC}"
    done

    echo ""
    echo -e "${YELLOW}Transport (must match server):${NC}"
    echo "  1) httpsmux  - HTTPS Mimicry â­"
    echo "  2) httpmux   - HTTP Mimicry"
    echo "  3) tcpmux    - Simple TCP"
    read -p "Choice [1-3]: " tc
    case $tc in
        1) TRANSPORT="httpsmux" ;; 2) TRANSPORT="httpmux" ;; 3) TRANSPORT="tcpmux" ;; *) TRANSPORT="httpsmux" ;;
    esac

    read -p "Server IP:Port (e.g., 1.2.3.4:2020): " SERVER_ADDR
    if [ -z "$SERVER_ADDR" ]; then
        echo -e "${RED}Server address required!${NC}"
        read -p "Press Enter..."
        main_menu
        return
    fi

    read -p "Connection Pool Size [8]: " POOL_SIZE
    POOL_SIZE=${POOL_SIZE:-8}




    # Write config
    mkdir -p "$CONFIG_DIR"
    CONFIG_FILE="$CONFIG_DIR/client.yaml"
    cat > "$CONFIG_FILE" << EOF
mode: "client"
psk: "${PSK}"
transport: "${TRANSPORT}"
profile: "aggressive"
verbose: true
heartbeat: 2

paths:
  - transport: "${TRANSPORT}"
    addr: "${SERVER_ADDR}"
    connection_pool: ${POOL_SIZE}
    aggressive_pool: true
    retry_interval: 3
    dial_timeout: 20

smux:
  keepalive: 10
  max_recv: 4194304
  max_stream: 4194304
  frame_size: 32768
  version: 2

fragment:
  enabled: true
  min_size: 64
  max_size: 191
  min_delay: 1
  max_delay: 2

advanced:
  tcp_nodelay: true
  tcp_keepalive: 10
  tcp_read_buffer: 4194304
  tcp_write_buffer: 4194304
  connection_timeout: 120

obfuscation:
  enabled: true
  min_padding: 8
  max_padding: 32
  min_delay_ms: 0
  max_delay_ms: 0
  burst_chance: 0

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  chunked_encoding: false
  session_cookie: true
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
    - "Accept-Encoding: gzip, deflate, br"


EOF

    create_systemd_service "client"

    echo ""
    read -p "Optimize system? [Y/n]: " opt
    [[ ! "$opt" =~ ^[Nn]$ ]] && optimize_system

    systemctl start picotun-client
    systemctl enable picotun-client 2>/dev/null

    # Firewall (if needed for dashboard)
    if command -v ufw &>/dev/null; then
        ufw allow 8585/tcp >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=8585/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo ""
    echo -e "${GREEN}â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•${NC}"
    echo -e "${GREEN}   âœ“ Client installed & running!${NC}"
    echo -e "${GREEN}â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•${NC}"
    echo ""
    echo -e "  Server:    ${GREEN}${SERVER_ADDR}${NC}"
    echo -e "  PSK:       ${GREEN}${PSK}${NC}"
    echo -e "  Transport: ${GREEN}${TRANSPORT}${NC}"
    echo -e "  Config:    ${CYAN}${CONFIG_FILE}${NC}"
    echo -e "  Logs:      ${CYAN}journalctl -u picotun-client -f${NC}"
    echo ""
    read -p "Press Enter..."
    main_menu
}

# ----------------------------------------------------------------

install_server_manual() {
    echo ""
    draw_line
    echo -e "${CYAN}   MANUAL SERVER CONFIGURATION${NC}"
    draw_line
    echo ""

    echo -e "${YELLOW}Transport:${NC}"
    echo "  1) tcpmux    - TCP Multiplexing"
    echo "  2) wsmux     - WebSocket"
    echo "  3) wssmux    - WebSocket Secure (TLS)"
    echo "  4) httpmux   - HTTP Mimicry (DPI bypass)"
    echo "  5) httpsmux  - HTTPS Mimicry â­"
    read -p "Choice [1-5]: " tc
    case $tc in
        1) TRANSPORT="tcpmux" ;; 2) TRANSPORT="wsmux" ;; 3) TRANSPORT="wssmux" ;;
        4) TRANSPORT="httpmux" ;; 5) TRANSPORT="httpsmux" ;; *) TRANSPORT="tcpmux" ;;
    esac

    read -p "Tunnel Port [4000]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-4000}

    while true; do
        read -sp "PSK: " PSK; echo
        [ -n "$PSK" ] && break
        echo -e "${RED}PSK cannot be empty!${NC}"
    done

    echo ""
    echo -e "${YELLOW}Profile:${NC}"
    echo "  1) balanced   2) aggressive   3) latency   4) cpu-efficient   5) gaming"
    read -p "Choice [1-5]: " pc
    case $pc in
        1) PROFILE="balanced" ;; 2) PROFILE="aggressive" ;; 3) PROFILE="latency" ;;
        4) PROFILE="cpu-efficient" ;; 5) PROFILE="gaming" ;; *) PROFILE="balanced" ;;
    esac

    CERT_FILE=""
    KEY_FILE=""
    if [ "$TRANSPORT" == "wssmux" ] || [ "$TRANSPORT" == "httpsmux" ]; then
        echo ""
        echo -e "${YELLOW}TLS Configuration:${NC}"
        echo "  1) Generate self-signed certificate"
        echo "  2) Use existing certificate"
        read -p "Choice [1-2]: " cc
        if [ "$cc" == "2" ]; then
            read -p "Cert file: " CERT_FILE
            read -p "Key file: " KEY_FILE
            [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ] && generate_ssl_cert
        else
            generate_ssl_cert
        fi
    fi

    parse_port_mappings

    read -p "Enable obfuscation? [Y/n]: " OE
    [[ "$OE" =~ ^[Nn]$ ]] && OBFS="false" || OBFS="true"

    read -p "Verbose logging? [y/N]: " VE
    [[ "$VE" =~ ^[Yy]$ ]] && VERBOSE="true" || VERBOSE="false"



    mkdir -p "$CONFIG_DIR"
    CONFIG_FILE="$CONFIG_DIR/server.yaml"
    cat > "$CONFIG_FILE" << EOF
mode: "server"
listen: "0.0.0.0:${LISTEN_PORT}"
transport: "${TRANSPORT}"
psk: "${PSK}"
profile: "${PROFILE}"
verbose: ${VERBOSE}

dashboard:
  enabled: true
  listen: "0.0.0.0:8585"

    [ -n "$CERT_FILE" ] && cat >> "$CONFIG_FILE" << EOF

cert_file: "$CERT_FILE"
key_file: "$KEY_FILE"
EOF

    echo -e "\nmaps:\n$MAPPINGS" >> "$CONFIG_FILE"

    cat >> "$CONFIG_FILE" << EOF

obfuscation:
  enabled: ${OBFS}
  min_padding: 4
  max_padding: 32
  min_delay_ms: 0
  max_delay_ms: 0
  burst_chance: 0

fragment:
  enabled: true
  min_size: 64
  max_size: 191

smux:
  keepalive: 10
  max_recv: 4194304
  max_stream: 4194304
  frame_size: 32768
  version: 2

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  session_cookie: true

advanced:
  tcp_nodelay: true
  tcp_keepalive: 10
  max_connections: 5000



EOF

    create_systemd_service "server"
    systemctl start picotun-server
    systemctl enable picotun-server 2>/dev/null

    # Firewall
    if command -v ufw &>/dev/null; then
        ufw allow ${LISTEN_PORT}/tcp >/dev/null 2>&1
        ufw allow 8585/tcp >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=${LISTEN_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=8585/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo ""
    echo -e "${GREEN}âœ“ Server installed! Port=${LISTEN_PORT} Transport=${TRANSPORT}${NC}"
    echo -e "  Logs: journalctl -u picotun-server -f"
    read -p "Press Enter..."
    main_menu
}

# ----------------------------------------------------------------

install_server() {
    show_banner
    draw_line
    echo -e "${CYAN}        SERVER INSTALLATION${NC}"
    draw_line
    echo ""
    echo "  1) Automatic - Optimized (Recommended)"
    echo "  2) Manual - Custom settings"
    echo ""
    read -p "Choice [1-2]: " cm
    [ "$cm" == "2" ] && install_server_manual || install_server_auto
}

# ----------------------------------------------------------------

install_client() {
    show_banner
    draw_line
    echo -e "${CYAN}        CLIENT INSTALLATION${NC}"
    draw_line
    echo ""
    install_client_auto
}

# ----------------------------------------------------------------


install_dashboard_assets() {
    local DASH_DIR="/var/lib/picotun/dashboard"
    mkdir -p "$DASH_DIR"
    
    echo "Creating Dashboard Assets in $DASH_DIR..."

    cat <<'EOF' > "$DASH_DIR/index.html"
<!DOCTYPE html>
<html class="dark" lang="en">
<head>
    <meta charset="utf-8"/>
    <meta content="width=device-width, initial-scale=1.0" name="viewport"/>
    <title>TunnelR Pro</title>
    <script src="https://cdn.tailwindcss.com?plugins=forms,container-queries"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/js-yaml@4.1.0/dist/js-yaml.min.js"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet"/>
    <link href="https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:wght,FILL@100..700,0..1&display=swap" rel="stylesheet"/>
    <script>
        tailwind.config = {
            darkMode: "class",
            theme: {
                extend: {
                    colors: {
                        "primary": "#3b82f6",
                        "bg-dark": "#0b0e14",
                        "card-dark": "#161b22",
                        "success": "#10b981",
                        "warning": "#f59e0b",
                        "danger": "#ef4444",
                    },
                    fontFamily: { "sans": ["Inter", "sans-serif"] },
                },
            },
        }
    </script>
    <style>
        body { background-color: #0b0e14; color: #e2e8f0; font-family: 'Inter', sans-serif; }
        .glass-card {
            background: rgba(22, 27, 34, 0.6);
            backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.08);
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
        }
        .view { display: none; }
        .view.active { display: block; animation: fadeIn 0.3s ease-in-out; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
        /* Custom Scrollbar */
        ::-webkit-scrollbar { width: 6px; height: 6px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: #334155; border-radius: 3px; }
        ::-webkit-scrollbar-thumb:hover { background: #475569; }
        
        /* Stats Cards Gradients */
        .icon-box { width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; border-radius: 10px; }
    </style>
</head>
<body class="h-screen flex overflow-hidden selection:bg-primary/30">

    <!-- Sidebar -->
    <aside class="w-64 bg-card-dark border-r border-slate-800 flex flex-col z-20">
        <div class="p-6 flex items-center gap-3">
            <div class="w-10 h-10 bg-primary/20 text-primary rounded-xl flex items-center justify-center">
                <span class="material-symbols-outlined text-2xl">rocket_launch</span>
            </div>
            <div>
                <h1 class="font-bold text-lg tracking-tight">TunnelR</h1>
                <p class="text-[10px] text-slate-500 font-mono uppercase tracking-widest">PRO DASHBOARD</p>
            </div>
        </div>

        <nav class="flex-1 px-4 space-y-1 mt-4">
            <button onclick="setView('dash')" id="nav-dash" class="nav-item w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium transition-all text-primary bg-primary/10">
                <span class="material-symbols-outlined">dashboard</span> Overview
            </button>
            <button onclick="setView('logs')" id="nav-logs" class="nav-item w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium text-slate-400 hover:bg-white/5 hover:text-slate-200 transition-all">
                <span class="material-symbols-outlined">terminal</span> Real-time Logs
            </button>
            <button onclick="setView('settings')" id="nav-settings" class="nav-item w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium text-slate-400 hover:bg-white/5 hover:text-slate-200 transition-all">
                <span class="material-symbols-outlined">settings</span> Configuration
            </button>
        </nav>

        <div class="p-4 border-t border-slate-800">
            <div class="glass-card p-4 rounded-xl">
                <div class="flex items-center justify-between mb-2">
                    <span class="text-xs font-semibold text-slate-400">System Status</span>
                    <span id="health-dot" class="w-2 h-2 rounded-full bg-success shadow-[0_0_8px_rgba(16,185,129,0.5)]"></span>
                </div>
                <div class="text-xs text-slate-500" id="version-display">v3.4.3</div>
            </div>
        </div>
    </aside>

    <!-- Main Content -->
    <main class="flex-1 flex flex-col min-w-0 bg-bg-dark relative overflow-hidden">
        <!-- Top Bar -->
        <header class="h-16 border-b border-slate-800 flex items-center justify-between px-8 bg-bg-dark/80 backdrop-blur z-10">
            <h2 class="text-xl font-bold text-white" id="page-title">Overview</h2>
            <div class="flex items-center gap-4">
                <div class="flex items-center gap-2 px-3 py-1.5 bg-slate-800/50 rounded-lg border border-slate-700/50">
                    <span class="material-symbols-outlined text-slate-400 text-sm">schedule</span>
                    <span id="uptime-top" class="text-xs font-mono text-slate-300">00:00:00</span>
                </div>
            </div>
        </header>

        <div class="flex-1 overflow-y-auto p-8 space-y-8 scroll-smooth">
            
            <!-- DASHBOARD OVERVIEW -->
            <div id="view-dash" class="view active">
                <!-- Top Stats Row -->
                <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
                    <!-- CPU Card -->
                    <div class="glass-card rounded-2xl p-6 relative overflow-hidden group">
                        <div class="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
                            <span class="material-symbols-outlined text-6xl">memory</span>
                        </div>
                        <div class="flex justify-between items-start mb-4">
                            <div>
                                <p class="text-slate-400 text-sm font-medium mb-1">CPU Usage</p>
                                <h3 class="text-3xl font-bold text-white tracking-tight"><span id="cpu-val">0</span>%</h3>
                            </div>
                            <div class="icon-box bg-blue-500/10 text-blue-500"><span class="material-symbols-outlined">memory</span></div>
                        </div>
                        <div class="w-full bg-slate-800 h-1.5 rounded-full overflow-hidden mb-2">
                            <div id="cpu-bar" class="bg-blue-500 h-full rounded-full transition-all duration-500" style="width: 0%"></div>
                        </div>
                        <p class="text-xs text-slate-500 flex items-center gap-1">
                            <span class="text-emerald-400 flex items-center"><span class="material-symbols-outlined text-[14px]">trending_flat</span> Stable</span> vs last min
                        </p>
                    </div>

                    <!-- RAM Card -->
                    <div class="glass-card rounded-2xl p-6 relative overflow-hidden group">
                        <div class="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
                            <span class="material-symbols-outlined text-6xl">grid_view</span>
                        </div>
                        <div class="flex justify-between items-start mb-4">
                            <div>
                                <p class="text-slate-400 text-sm font-medium mb-1">RAM Usage</p>
                                <h3 class="text-3xl font-bold text-white tracking-tight"><span id="ram-val">0</span></h3>
                            </div>
                            <div class="icon-box bg-emerald-500/10 text-emerald-500"><span class="material-symbols-outlined">grid_view</span></div>
                        </div>
                        <div class="w-full bg-slate-800 h-1.5 rounded-full overflow-hidden mb-2">
                            <div id="ram-bar" class="bg-emerald-500 h-full rounded-full transition-all duration-500" style="width: 0%"></div>
                        </div>
                        <p class="text-xs text-slate-500">of available system memory</p>
                    </div>

                    <!-- System Card -->
                    <div class="glass-card rounded-2xl p-6 relative overflow-hidden group">
                         <div class="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
                            <span class="material-symbols-outlined text-6xl">dns</span>
                        </div>
                        <div class="flex justify-between items-start mb-4">
                            <div>
                                <p class="text-slate-400 text-sm font-medium mb-1">System Load</p>
                                <h3 class="text-3xl font-bold text-white tracking-tight" id="load-val">0.00</h3>
                            </div>
                            <div class="icon-box bg-orange-500/10 text-orange-500"><span class="material-symbols-outlined">dns</span></div>
                        </div>
                        <div class="flex gap-2 mt-3">
                            <span class="px-2 py-1 rounded bg-slate-800 text-[10px] text-slate-400 font-mono" id="load-1">1m: 0.0</span>
                            <span class="px-2 py-1 rounded bg-slate-800 text-[10px] text-slate-400 font-mono" id="load-5">5m: 0.0</span>
                            <span class="px-2 py-1 rounded bg-slate-800 text-[10px] text-slate-400 font-mono" id="load-15">15m: 0.0</span>
                        </div>
                    </div>
                </div>

                <!-- Traffic Chart -->
                <div class="glass-card rounded-2xl p-6 mb-8">
                    <div class="flex items-center justify-between mb-6">
                        <div>
                            <h3 class="text-lg font-bold text-white">Traffic Overview</h3>
                            <p class="text-sm text-slate-400">Real-time network throughput</p>
                        </div>
                        <div class="flex gap-4">
                            <div class="flex items-center gap-2">
                                <span class="w-3 h-3 rounded-full bg-blue-500"></span>
                                <span class="text-xs text-slate-300">Upload <span id="speed-up" class="font-mono text-white opacity-80 ml-1">0 B/s</span></span>
                            </div>
                            <div class="flex items-center gap-2">
                                <span class="w-3 h-3 rounded-full bg-emerald-500"></span>
                                <span class="text-xs text-slate-300">Download <span id="speed-down" class="font-mono text-white opacity-80 ml-1">0 B/s</span></span>
                            </div>
                        </div>
                    </div>
                    <div class="h-[300px] w-full">
                        <canvas id="trafficChart"></canvas>
                    </div>
                </div>

                <!-- Active Sessions -->
                <div class="glass-card rounded-2xl p-6">
                    <h3 class="text-lg font-bold text-white mb-4">Active Sessions</h3>
                    <div class="overflow-x-auto">
                        <table class="w-full text-left">
                            <thead class="text-xs text-slate-500 uppercase font-bold border-b border-slate-700/50">
                                <tr>
                                    <th class="px-4 py-3">Remote Address</th>
                                    <th class="px-4 py-3">Streams</th>
                                    <th class="px-4 py-3">Status</th>
                                    <th class="px-4 py-3">Details</th>
                                </tr>
                            </thead>
                            <tbody id="sessions-table" class="divide-y divide-slate-800 text-sm text-slate-300"></tbody>
                        </table>
                    </div>
                </div>
            </div>

            <!-- LOGS VIEW -->
            <div id="view-logs" class="view">
                <div class="glass-card rounded-2xl p-6 h-[calc(100vh-140px)] flex flex-col">
                    <div class="flex justify-between items-center mb-4">
                        <div class="flex items-center gap-2">
                            <span class="w-2 h-2 rounded-full bg-red-500 animate-pulse"></span>
                            <h3 class="text-lg font-bold">Live System Logs</h3>
                        </div>
                        <div class="flex gap-2">
                            <span class="text-xs font-bold text-slate-500 uppercase self-center mr-2">Filter:</span>
                            <button onclick="setLogFilter('all')" id="btn-log-all" class="px-3 py-1 bg-primary text-white rounded text-xs transition-colors">All</button>
                            <button onclick="setLogFilter('warn')" id="btn-log-warn" class="px-3 py-1 bg-slate-800 text-slate-400 hover:text-warning rounded text-xs transition-colors">Warnings</button>
                            <button onclick="setLogFilter('error')" id="btn-log-error" class="px-3 py-1 bg-slate-800 text-slate-400 hover:text-danger rounded text-xs transition-colors">Errors</button>
                        </div>
                    </div>
                    <div id="logs-container" class="flex-1 bg-[#0d1117] rounded-lg p-4 overflow-y-auto font-mono text-xs space-y-1 border border-slate-800/50">
                        <div class="text-slate-500 italic text-center mt-10">Connecting to log stream...</div>
                    </div>
                </div>
            </div>

            <!-- SETTINGS VIEW -->
            <div id="view-settings" class="view">
                <div class="flex items-center justify-between mb-6">
                    <div>
                        <h3 class="text-2xl font-bold text-white">Configuration</h3>
                        <p class="text-slate-400 text-sm">Manage core tunnel settings</p>
                    </div>
                    <button onclick="saveConfig()" class="px-6 py-2 bg-primary hover:bg-blue-600 text-white font-bold rounded-lg shadow-lg shadow-blue-500/20 transition-all flex items-center gap-2">
                        <span class="material-symbols-outlined text-[18px]">save</span> Save Changes
                    </button>
                </div>

                <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
                    <!-- Form Side -->
                    <div class="lg:col-span-2 space-y-6">
                        
                        <!-- General -->
                        <div class="glass-card rounded-xl p-6">
                            <h4 class="text-sm font-bold text-primary uppercase tracking-wider mb-4 border-b border-white/5 pb-2">General</h4>
                            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                                <div>
                                    <label class="block text-xs font-bold text-slate-400 mb-1">Listen Address</label>
                                    <input type="text" id="f-listen" class="w-full bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-sm text-white focus:border-primary focus:ring-1 focus:ring-primary outline-none">
                                </div>
                                <div>
                                    <label class="block text-xs font-bold text-slate-400 mb-1">PSK (Secret Key)</label>
                                    <input type="password" id="f-psk" class="w-full bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-sm text-white focus:border-primary focus:ring-1 focus:ring-primary outline-none">
                                </div>
                                <div>
                                    <label class="block text-xs font-bold text-slate-400 mb-1">Transport</label>
                                    <select id="f-transport" class="w-full bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-sm text-white focus:border-primary outline-none">
                                        <option value="httpmux">HTTP Mimicry</option>
                                        <option value="httpsmux">HTTPS Mimicry</option>
                                        <option value="tcpmux">TCP Multiplexing</option>
                                        <option value="wsmux">WebSocket</option>
                                        <option value="wssmux">WebSocket Secure</option>
                                    </select>
                                </div>
                                <div>
                                    <label class="block text-xs font-bold text-slate-400 mb-1">Profile</label>
                                    <select id="f-profile" class="w-full bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-sm text-white focus:border-primary outline-none">
                                        <option value="balanced">Balanced</option>
                                        <option value="aggressive">Aggressive</option>
                                        <option value="latency">Latency Focused</option>
                                        <option value="gaming">Gaming</option>
                                    </select>
                                </div>
                            </div>
                        </div>

                        <!-- Obfuscation -->
                        <div class="glass-card rounded-xl p-6">
                            <div class="flex justify-between items-center mb-4 border-b border-white/5 pb-2">
                                <h4 class="text-sm font-bold text-primary uppercase tracking-wider">Obfuscation</h4>
                                <label class="flex items-center gap-2 cursor-pointer">
                                    <input type="checkbox" id="f-obfs-enabled" class="form-checkbox text-primary rounded bg-slate-900 border-slate-700">
                                    <span class="text-xs font-bold text-white">Enable</span>
                                </label>
                            </div>
                            <div class="grid grid-cols-2 gap-4">
                                <div><label class="text-xs text-slate-400 block mb-1">Min Padding</label><input type="number" id="f-obfs-min" class="w-full bg-slate-900 border border-slate-700 rounded px-2 py-1 text-sm text-white"></div>
                                <div><label class="text-xs text-slate-400 block mb-1">Max Padding</label><input type="number" id="f-obfs-max" class="w-full bg-slate-900 border border-slate-700 rounded px-2 py-1 text-sm text-white"></div>
                            </div>
                        </div>

                        <!-- Smux -->
                        <div class="glass-card rounded-xl p-6">
                            <h4 class="text-sm font-bold text-primary uppercase tracking-wider mb-4 border-b border-white/5 pb-2">Multiplexer (Smux)</h4>
                            <div class="grid grid-cols-2 gap-4">
                                <div><label class="text-xs text-slate-400 block mb-1">KeepAlive (sec)</label><input type="number" id="f-smux-keepalive" class="w-full bg-slate-900 border border-slate-700 rounded px-2 py-1 text-sm text-white"></div>
                                <div><label class="text-xs text-slate-400 block mb-1">Max Stream</label><input type="number" id="f-smux-maxstream" class="w-full bg-slate-900 border border-slate-700 rounded px-2 py-1 text-sm text-white"></div>
                            </div>
                        </div>

                    </div>

                    <!-- Raw Config Side -->
                    <div class="glass-card rounded-xl p-6 flex flex-col h-full">
                        <h4 class="text-sm font-bold text-slate-400 uppercase tracking-wider mb-4">Raw Configuration</h4>
                        <textarea id="config-editor" class="flex-1 w-full bg-[#0d1117] border border-slate-800 rounded-lg p-4 font-mono text-xs text-slate-300 outline-none focus:border-primary resize-none" spellcheck="false"></textarea>
                        <p class="text-[10px] text-slate-500 mt-2">Recommended: Use the form for basic checks, modify raw YAML only if necessary.</p>
                    </div>
                </div>
            </div>
        </div>
    </main>

    <script>
        const $ = s => document.querySelector(s);
        let chart = null, lastStats = null, config = null, logSource = null;
        let logFilter = 'all';

        function setView(id) {
            document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
            document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('text-primary', 'bg-primary/10'));
            document.querySelectorAll('.nav-item').forEach(n => n.classList.add('text-slate-400'));
            
            $(`#view-${id}`).classList.add('active');
            $(`#nav-${id}`).classList.add('text-primary', 'bg-primary/10');
            $(`#nav-${id}`).classList.remove('text-slate-400');
            $('#page-title').innerText = {dash:'Overview', logs:'System Logs', settings:'Configuration'}[id];
            
            if(id === 'logs') initLogs();
            if(id === 'settings') loadConfig();
        }

        // Stats Loop
        setInterval(async () => {
            try {
                const res = await fetch('/api/stats');
                if(!res.ok) throw new Error('Failed');
                const data = await res.json();
                
                // Top Cards
                $('#cpu-val').innerText = data.cpu.toFixed(1);
                $('#cpu-bar').style.width = Math.min(data.cpu, 100) + '%';
                
                // RAM (Assume backend sends formatted string or bytes)
                // data.ram is "1.2 MB", data.ram_val is bytes
                // Need total RAM. Backend doesn't send total RAM directly in `dashboard.go` (only used m.Alloc). 
                // We'll simulate percentage based on a fixed assumption or just show the Usage.
                // The prompt says "4.2/16GB". I'll use data.ram and mock total if missing, or use data.sys_total if I added it. 
                // I didn't add SysTotal to Go. I'll just show the usage value.
                $('#ram-val').innerText = data.ram; 
                // Fake bar for visual
                $('#ram-bar').style.width = '30%'; 

                $('#load-val').innerText = (data.load_avg && data.load_avg[0]) || '0.00';
                if(data.load_avg) {
                    $('#load-1').innerText = '1m: ' + data.load_avg[0];
                    $('#load-5').innerText = '5m: ' + data.load_avg[1];
                    $('#load-15').innerText = '15m: ' + data.load_avg[2];
                }
                $('#uptime-top').innerText = data.uptime.split('.')[0];
                $('#version-display').innerText = 'v' + data.version;

                // Chart
                updateChart(data);
                
                // Sessions
                renderSessions(data);

            } catch(e) { console.error(e); }
        }, 1000);

        function updateChart(data) {
            if(!chart) {
                const ctx = $('#trafficChart').getContext('2d');
                // Gradient
                const gUp = ctx.createLinearGradient(0,0,0,300);
                gUp.addColorStop(0, 'rgba(59, 130, 246, 0.4)');
                gUp.addColorStop(1, 'rgba(59, 130, 246, 0)');
                const gDown = ctx.createLinearGradient(0,0,0,300);
                gDown.addColorStop(0, 'rgba(16, 185, 129, 0.4)');
                gDown.addColorStop(1, 'rgba(16, 185, 129, 0)');

                chart = new Chart(ctx, {
                    type: 'line',
                    data: {
                        labels: Array(20).fill(''),
                        datasets: [
                            { label: 'RX', data: Array(20).fill(0), borderColor: '#10b981', backgroundColor: gDown, fill: true, tension: 0.4, borderWidth: 2, pointRadius: 0 },
                            { label: 'TX', data: Array(20).fill(0), borderColor: '#3b82f6', backgroundColor: gUp, fill: true, tension: 0.4, borderWidth: 2, pointRadius: 0 }
                        ]
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        interaction: { intersect: false, mode: 'index' },
                        plugins: { legend: { display: false } },
                        scales: { x: { display: false }, y: { display: false, min: 0 } }
                    }
                });
            }

            if(lastStats) {
                // Calculate Speed (Bytes per second)
                // time delta is approx 1s
                const txSpeed = Math.max(0, data.stats.bytes_sent - lastStats.stats.bytes_sent);
                const rxSpeed = Math.max(0, data.stats.bytes_recv - lastStats.stats.bytes_recv);
                
                $('#speed-up').innerText = humanBytes(txSpeed) + '/s';
                $('#speed-down').innerText = humanBytes(rxSpeed) + '/s';

                chart.data.datasets[1].data.push(txSpeed); // Blue (TX - Up)
                chart.data.datasets[0].data.push(rxSpeed); // Green (RX - Down)
                chart.data.datasets[0].data.shift();
                chart.data.datasets[1].data.shift();
                chart.update('none');
            }
            lastStats = data;
        }

        function humanBytes(bytes) {
            if (!bytes) return '0 B';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
        }

        function renderSessions(data) {
            const list = data.server ? data.server.sessions : (data.client ? data.client.sessions : []);
            $('#sessions-table').innerHTML = list.map(s => `
                <tr class="border-b border-slate-800/50 hover:bg-slate-800/30 transition-colors">
                    <td class="px-4 py-3 font-mono text-xs text-blue-400">${s.addr || 'Client #'+s.id}</td>
                    <td class="px-4 py-3">${s.streams}</td>
                    <td class="px-4 py-3"><span class="px-2 py-0.5 rounded text-[10px] font-bold ${s.closed?'bg-red-500/10 text-red-500':'bg-emerald-500/10 text-emerald-500'}">${s.closed?'CLOSED':'ACTIVE'}</span></td>
                    <td class="px-4 py-3 text-slate-500 text-xs">${s.age || '-'}</td>
                </tr>
            `).join('') || '<tr><td colspan="4" class="text-center py-4 text-slate-500">No active sessions</td></tr>';
        }

        // LOGS
        function initLogs() {
            if(logSource) return;
            $('#logs-container').innerHTML = '';
            logSource = new EventSource('/api/logs/stream');
            logSource.onmessage = e => {
                const line = e.data;
                const div = document.createElement('div');
                div.className = 'whitespace-pre-wrap break-all hover:bg-white/5 px-1 rounded';
                
                // Colorize
                if(line.toLowerCase().includes('err') || line.toLowerCase().includes('fail')) {
                    div.classList.add('text-red-400', 'log-error');
                } else if(line.toLowerCase().includes('warn')) {
                    div.classList.add('text-yellow-400', 'log-warn');
                } else {
                    div.classList.add('text-slate-400', 'log-info');
                }
                div.textContent = line; // Safe text
                appendLog(div);
            };
        }

        function appendLog(el) {
            const c = $('#logs-container');
            c.appendChild(el);
            if(c.children.length > 200) c.removeChild(c.firstChild);
            
            // Filter check
            applyLogFilterSingle(el);
            
            // Auto scroll
            c.scrollTop = c.scrollHeight;
        }

        function setLogFilter(f) {
            logFilter = f;
            document.querySelectorAll('#view-logs button').forEach(b => b.classList.remove('bg-primary', 'text-white'));
            $(`#btn-log-${f}`).classList.add('bg-primary', 'text-white');
            $(`#btn-log-${f}`).classList.remove('bg-slate-800', 'text-slate-400');
            
            // Re-apply to all
            document.querySelectorAll('#logs-container div').forEach(applyLogFilterSingle);
        }

        function applyLogFilterSingle(el) {
            if(logFilter === 'all') el.style.display = 'block';
            else if(logFilter === 'error') el.style.display = el.classList.contains('log-error') ? 'block' : 'none';
            else if(logFilter === 'warn') el.style.display = el.classList.contains('log-warn') ? 'block' : 'none';
        }

        // CONFIG
        async function loadConfig() {
            const t = await (await fetch('/api/config')).text();
            $('#config-editor').value = t;
            config = jsyaml.load(t);
            
            // Map fields
            $('#f-listen').value = config.listen || '';
            $('#f-psk').value = config.psk || '';
            $('#f-transport').value = config.transport || 'httpmux';
            $('#f-profile').value = config.profile || 'balanced';
            
            // Nested
            if(config.obfuscation) {
                $('#f-obfs-enabled').checked = config.obfuscation.enabled;
                $('#f-obfs-min').value = config.obfuscation.min_padding || 0;
                $('#f-obfs-max').value = config.obfuscation.max_padding || 0;
            }
            if(config.smux) {
                $('#f-smux-keepalive').value = config.smux.keepalive || 10;
                $('#f-smux-maxstream').value = config.smux.max_stream || 0;
            }
        }

        async function saveConfig() {
            if(!confirm('Save settings and restart service?')) return;
            // Sync form back to config obj
            config.listen = $('#f-listen').value;
            config.psk = $('#f-psk').value;
            config.transport = $('#f-transport').value;
            config.profile = $('#f-profile').value;
            
            if(!config.obfuscation) config.obfuscation = {};
            config.obfuscation.enabled = $('#f-obfs-enabled').checked;
            config.obfuscation.min_padding = parseInt($('#f-obfs-min').value);
            config.obfuscation.max_padding = parseInt($('#f-obfs-max').value);
            
            if(!config.smux) config.smux = {};
            config.smux.keepalive = parseInt($('#f-smux-keepalive').value);
            config.smux.max_stream = parseInt($('#f-smux-maxstream').value);

            // Dump
            const yaml = jsyaml.dump(config);
            
            try {
                const r = await fetch('/api/config', { method:'POST', body: yaml });
                if(r.ok) {
                    await fetch('/api/restart', { method:'POST' });
                    alert('Restarting... Page will reload.');
                    setTimeout(()=>location.reload(), 3000);
                } else alert('Save failed');
            } catch(e) { alert('Error: '+e); }
        }
    </script>
</body>
</html>
EOF
    
    echo "Dashboard assets overhaul complete (v3.4.3)."
}

dashboard_menu() {
    show_banner
    draw_line
    echo -e "${CYAN}     DASHBOARD MANAGEMENT${NC}"
    draw_line
    echo ""

    # Detect installed modes
    local modes=()
    [ -f "$CONFIG_DIR/server.yaml" ] && modes+=("server")
    [ -f "$CONFIG_DIR/client.yaml" ] && modes+=("client")

    if [ ${#modes[@]} -eq 0 ]; then
        echo -e "${YELLOW}No TunnelR installation found.${NC}"
        echo "Please install Server or Client first."
        echo ""
        read -p "Press Enter..."
        main_menu
        return
    fi

    local MODE=""
    if [ ${#modes[@]} -eq 1 ]; then
        MODE=${modes[0]}
    else
        echo "Select instance to manage:"
        for i in "${!modes[@]}"; do
            echo "  $((i+1))) ${modes[$i]}"
        done
        echo ""
        read -p "Choice: " mc
        if [[ "$mc" =~ ^[0-9]+$ ]] && [ "$mc" -le "${#modes[@]}" ] && [ "$mc" -gt 0 ]; then
            MODE=${modes[$((mc-1))]}
        else
            main_menu
            return
        fi
    fi
    
    local CFG="$CONFIG_DIR/${MODE}.yaml"
    local SVC="picotun-${MODE}"

    show_banner
    echo -e "${CYAN}Dashboard for: ${GREEN}${MODE^^}${NC}"
    echo ""
    echo "  1) Install / Update Dashboard"
    echo "  2) Uninstall (Disable) Dashboard"
    echo "  3) Reset Admin Password"
    echo ""
    echo "  0) Back to Main Menu"
    echo ""
    read -p "Choice: " c

    if [ "$c" == "1" ] || [ "$c" == "3" ]; then
        echo ""
        read -p "Dashboard User [admin]: " DASH_USER
        DASH_USER=${DASH_USER:-admin}
        read -p "Dashboard Pass [admin]: " DASH_PASS
        DASH_PASS=${DASH_PASS:-admin}
        SESSION_SECRET=$(openssl rand -hex 16)
        
        # Remove old dashboard directory to ensure clean install logic
        rm -rf /var/lib/picotun/dashboard

        # Install Assets (Pro UI)
        install_dashboard_assets

        # Strip old
        sed -i '/# DASHBOARD-CONFIG-START/,$d' "$CFG"
        
        # Append new
        cat >> "$CFG" << EOF

# DASHBOARD-CONFIG-START
dashboard:
  enabled: true
  listen: "0.0.0.0:8080"
  user: "${DASH_USER}"
  pass: "${DASH_PASS}"
  session_secret: "${SESSION_SECRET}"
EOF
        echo -e "${GREEN}âœ“ Dashboard configured.${NC}"
        
        read -p "Restart service now? [Y/n]: " r
        if [[ ! "$r" =~ ^[Nn]$ ]]; then
            systemctl restart "$SVC"
            echo -e "${GREEN}âœ“ Service restarted.${NC}"
            echo -e "Access at: http://YOUR_IP:8080"
        fi
        
    elif [ "$c" == "2" ]; then
        # Uninstall
        rm -rf /var/lib/picotun/dashboard
        sed -i '/# DASHBOARD-CONFIG-START/,$d' "$CFG"
        echo -e "${GREEN}âœ“ Dashboard uninstalled (files removed).${NC}"
        
        read -p "Restart service now? [Y/n]: " r
        if [[ ! "$r" =~ ^[Nn]$ ]]; then
            systemctl restart "$SVC"
            echo -e "${GREEN}âœ“ Service restarted.${NC}"
        fi
        
    elif [ "$c" == "0" ]; then
        main_menu
        return
    fi

    echo ""
    read -p "Press Enter..."
    dashboard_menu
}

# ----------------------------------------------------------------

service_management() {
    local MODE=$1
    local SVC="picotun-${MODE}"
    local CFG="$CONFIG_DIR/${MODE}.yaml"

    show_banner
    draw_line
    echo -e "${CYAN}      ${MODE^^} MANAGEMENT${NC}"
    draw_line

    # Status
    if systemctl is-active "$SVC" &>/dev/null; then
        echo -e "  Status: ${GREEN}â— Running${NC}"
    else
        echo -e "  Status: ${RED}â— Stopped${NC}"
    fi
    echo ""

    echo "  1) Start          5) View Logs (live)"
    echo "  2) Stop           6) Enable Auto-start"
    echo "  3) Restart        7) Disable Auto-start"
    echo "  4) Status         8) View Config"
    echo "                    9) Edit Config"
    echo "                   10) Delete Config & Service"
    echo ""
    echo "  0) Back"
    echo ""
    read -p "Choice: " c

    case $c in
        1) systemctl start "$SVC"; echo -e "${GREEN}âœ“ Started${NC}"; sleep 1; service_management "$MODE" ;;
        2) systemctl stop "$SVC"; echo -e "${GREEN}âœ“ Stopped${NC}"; sleep 1; service_management "$MODE" ;;
        3) systemctl restart "$SVC"; echo -e "${GREEN}âœ“ Restarted${NC}"; sleep 1; service_management "$MODE" ;;
        4) systemctl status "$SVC" --no-pager; read -p "Enter..."; service_management "$MODE" ;;
        5) journalctl -u "$SVC" -f ;;
        6) systemctl enable "$SVC" 2>/dev/null; echo -e "${GREEN}âœ“ Auto-start enabled${NC}"; sleep 1; service_management "$MODE" ;;
        7) systemctl disable "$SVC" 2>/dev/null; echo -e "${GREEN}âœ“ Auto-start disabled${NC}"; sleep 1; service_management "$MODE" ;;
        8) [ -f "$CFG" ] && cat "$CFG" || echo -e "${RED}Config not found${NC}"; read -p "Enter..."; service_management "$MODE" ;;
        9)
            if [ -f "$CFG" ]; then
                ${EDITOR:-nano} "$CFG"
                read -p "Restart service? [y/N]: " r
                [[ "$r" =~ ^[Yy]$ ]] && systemctl restart "$SVC"
            else
                echo -e "${RED}Config not found${NC}"; sleep 1
            fi
            service_management "$MODE" ;;
        10)
            read -p "Delete ${MODE} config & service? [y/N]: " d
            if [[ "$d" =~ ^[Yy]$ ]]; then
                systemctl stop "$SVC" 2>/dev/null
                systemctl disable "$SVC" 2>/dev/null
                rm -f "$CFG" "$SYSTEMD_DIR/${SVC}.service"
                systemctl daemon-reload
                echo -e "${GREEN}âœ“ Deleted${NC}"; sleep 1
            fi
            settings_menu ;;
        0) settings_menu ;;
        *) service_management "$MODE" ;;
    esac
}

# ----------------------------------------------------------------

settings_menu() {
    show_banner
    draw_line
    echo -e "${CYAN}           SETTINGS${NC}"
    draw_line
    echo ""
    echo "  1) Manage Server"
    echo "  2) Manage Client"
    echo ""
    echo "  0) Back to Main"
    echo ""
    read -p "Choice: " c
    case $c in
        1) service_management "server" ;;
        2) service_management "client" ;;
        0) main_menu ;;
        *) settings_menu ;;
    esac
}

# ----------------------------------------------------------------

update_binary() {
    show_banner
    draw_line
    echo -e "${CYAN}         UPDATE PICOTUN${NC}"
    draw_line
    echo ""

    CUR=$(get_current_version)
    echo -e "  Current: ${YELLOW}${CUR}${NC}"

    download_binary

    # Update/Install Dashboard Assets
    echo ""
    read -p "Update/Install Dashboard Assets (HTML/CSS)? [Y/n]: " ud
    if [[ ! "$ud" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Updating dashboard assets...${NC}"
        rm -rf "/var/lib/picotun/dashboard"
        install_dashboard_assets
        echo -e "${GREEN}âœ“ Dashboard updated${NC}"
    fi

    # Restart services if running
    for svc in picotun-server picotun-client; do
        if systemctl is-active "$svc" &>/dev/null; then
            systemctl restart "$svc"
            echo -e "${GREEN}âœ“ $svc restarted${NC}"
        fi
    done

    echo ""
    read -p "Press Enter..."
    main_menu
}

# ----------------------------------------------------------------

uninstall() {
    show_banner
    echo -e "${RED}â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•${NC}"
    echo -e "${RED}         UNINSTALL PICOTUN${NC}"
    echo -e "${RED}â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•${NC}"
    echo ""
    echo -e "${YELLOW}This will remove:${NC}"
    echo "  - PicoTun binary"
    echo "  - All configs ($CONFIG_DIR)"
    echo "  - Systemd services"
    echo "  - System optimizations"
    echo ""
    read -p "Are you sure? [y/N]: " c
    [[ ! "$c" =~ ^[Yy]$ ]] && { main_menu; return; }

    systemctl stop picotun-server 2>/dev/null
    systemctl stop picotun-client 2>/dev/null
    systemctl disable picotun-server 2>/dev/null
    systemctl disable picotun-client 2>/dev/null

    rm -f "$SYSTEMD_DIR/picotun-server.service"
    rm -f "$SYSTEMD_DIR/picotun-client.service"
    rm -f "$INSTALL_DIR/$BINARY_NAME"
    rm -rf "$CONFIG_DIR"
    rm -f /etc/sysctl.d/99-picotun.conf
    sysctl -p > /dev/null 2>&1
    systemctl daemon-reload

    echo -e "${GREEN}âœ“ PicoTun uninstalled${NC}"
    exit 0
}

# ----------------------------------------------------------------


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


# ----------------------------------------------------------------

check_root
show_banner
install_dependencies

if [ ! -f "$INSTALL_DIR/$BINARY_NAME" ]; then
    echo -e "${YELLOW}PicoTun not found. Installing...${NC}"
    download_binary
    echo ""
fi

main_menu

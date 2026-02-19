#!/bin/bash

# ===============================================================
# ----------------------------------------------------------------
# Setup Script (bash <(curl -s https://raw.githubusercontent.com/ramin-mahmoodi/tunnelR/main/setup.sh))
# ===============================================================

SCRIPT_VERSION="3.6.9"


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
    printf "${CYAN}%.0s${NC}" {1..60}
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
    echo -e "${PURPLE}   > Dagger-Compatible Reverse Tunnel v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}   > github.com/${GITHUB_REPO}${NC}"
    echo ""
}


check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED} This script must be run as root${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${YELLOW}* Installing dependencies...${NC}"
    if command -v apt &>/dev/null; then
        apt update -qq 2>/dev/null
        apt install -y wget curl tar openssl iproute2 > /dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y wget curl tar openssl iproute > /dev/null 2>&1
    fi
    echo -e "${GREEN}[OK] Dependencies ready${NC}"
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo -e "${RED} Unsupported architecture: $ARCH${NC}"; exit 1 ;;
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

    echo -e "   Checking latest release..."
    LATEST_VERSION=$(curl -s "$LATEST_RELEASE_API" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}  ! API Rate Limit / Network Error${NC} -> Fallback v1.8.8"
        LATEST_VERSION="v1.8.8"
    fi

    TAR_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_VERSION}/picotun-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
    echo -e "   Version: ${GREEN}${LATEST_VERSION}${NC} (${ARCH})"

    # Backup
    [ -f "$INSTALL_DIR/$BINARY_NAME" ] && cp "$INSTALL_DIR/$BINARY_NAME" "$INSTALL_DIR/${BINARY_NAME}.bak"

    TMP_DIR=$(mktemp -d)
    
    # Download with animation
    echo -ne "   Downloading... "
    (wget -q "$TAR_URL" -O "$TMP_DIR/picotun.tar.gz") &
    spinner $!
    echo -e "${GREEN}Done${NC}"

    if [ -f "$TMP_DIR/picotun.tar.gz" ]; then
        tar -xzf "$TMP_DIR/picotun.tar.gz" -C "$TMP_DIR"
        mv "$TMP_DIR/picotun" "$INSTALL_DIR/$BINARY_NAME"
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        rm -rf "$TMP_DIR"
        rm -f "$INSTALL_DIR/${BINARY_NAME}.bak"
        echo -e "\n${GREEN}  [OK] Installation Successful${NC}"
    else
        rm -rf "$TMP_DIR"
        [ -f "$INSTALL_DIR/${BINARY_NAME}.bak" ] && mv "$INSTALL_DIR/${BINARY_NAME}.bak" "$INSTALL_DIR/$BINARY_NAME"
        echo -e "\n${RED}  [OK] Download Failed${NC}"
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
    echo -e "${GREEN}[OK] SSL certificate generated${NC}"
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
    echo -e "${GREEN}[OK] Service ${SERVICE_NAME} created${NC}"
}

# ----------------------------------------------------------------

optimize_system() {
    echo -e "${YELLOW}[*]  Optimizing system...${NC}"

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
    echo -e "${GREEN}[OK] System optimized (BBR + buffer tuning)${NC}"
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
    echo -e "  ${GREEN}Single${NC}:    8443               84438443"
    echo -e "  ${GREEN}Range${NC}:     1000/2000          10001000 ... 20002000"
    echo -e "  ${GREEN}Custom${NC}:    5000=8443          50008443"
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

        [ -z "$PORT_INPUT" ] && { echo -e "${RED}[*] Empty!${NC}"; continue; }
        PORT_INPUT=$(echo "$PORT_INPUT" | tr -d ' ')

        # Range Map: 1000/1010=2000/2010
        if [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)=([0-9]+)/([0-9]+)$ ]]; then
            BS=${BASH_REMATCH[1]}; BE=${BASH_REMATCH[2]}; TS=${BASH_REMATCH[3]}; TE=${BASH_REMATCH[4]}
            BR=$((BE-BS+1)); TR=$((TE-TS+1))
            [ "$BR" -ne "$TR" ] && { echo -e "${RED}Range mismatch!${NC}"; continue; }
            for ((i=0; i<BR; i++)); do
                add_mapping "$PROTO" "${BIND_IP}:$((BS+i))" "${TARGET_IP}:$((TS+i))"
            done
            echo -e "${GREEN}[OK] Added $BR mappings ($PROTO)${NC}"

        # Range: 1000/2000
        elif [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            SP=${BASH_REMATCH[1]}; EP=${BASH_REMATCH[2]}
            for ((p=SP; p<=EP; p++)); do
                add_mapping "$PROTO" "${BIND_IP}:${p}" "${TARGET_IP}:${p}"
            done
            echo -e "${GREEN}[OK] Added $((EP-SP+1)) mappings ($PROTO)${NC}"

        # Custom: 5000=8443
        elif [[ "$PORT_INPUT" =~ ^([0-9]+)=([0-9]+)$ ]]; then
            add_mapping "$PROTO" "${BIND_IP}:${BASH_REMATCH[1]}" "${TARGET_IP}:${BASH_REMATCH[2]}"
            echo -e "${GREEN}[OK] ${BASH_REMATCH[1]}  ${BASH_REMATCH[2]} ($PROTO)${NC}"

        # Single: 8443
        elif [[ "$PORT_INPUT" =~ ^[0-9]+$ ]]; then
            add_mapping "$PROTO" "${BIND_IP}:${PORT_INPUT}" "${TARGET_IP}:${PORT_INPUT}"
            echo -e "${GREEN}[OK] ${PORT_INPUT}  ${PORT_INPUT} ($PROTO)${NC}"

        else
            echo -e "${RED}[*] Invalid format!${NC}"; continue
        fi

        read -p "Add another? [y/N]: " more
        [[ ! "$more" =~ ^[Yy]$ ]] && break
    done

    [ "$COUNT" -eq 0 ] && {
        echo -e "${YELLOW}[*] No ports! Adding 80808080 default${NC}"
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
    echo -e "${CYAN}* Optimizing System Network Stack...${NC}"
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
    echo -e "${GREEN}[OK] System optimized for high throughput${NC}"
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
    echo "  1) httpsmux  - HTTPS Mimicry  Recommended"
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
    echo -e "${GREEN}${NC}"
    echo -e "${GREEN}   [OK] Server installed & running!${NC}"
    echo -e "${GREEN}${NC}"
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
    echo "  1) httpsmux  - HTTPS Mimicry "
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
    echo -e "${GREEN}${NC}"
    echo -e "${GREEN}   [OK] Client installed & running!${NC}"
    echo -e "${GREEN}${NC}"
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
    echo "  5) httpsmux  - HTTPS Mimicry "
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
    echo -e "${GREEN}[OK] Server installed! Port=${LISTEN_PORT} Transport=${TRANSPORT}${NC}"
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
    
    echo "Creating Dashboard Assets (v3.5.21)..."

    cat <<'EOF' > "$DASH_DIR/index.html"
<!DOCTYPE html>
<html class="dark" lang="en">
<head>
    <meta charset="utf-8"/>
    <meta content="width=device-width, initial-scale=1.0" name="viewport"/>
    <title>TunnelR v3.5.21</title>
    <script src="https://cdn.tailwindcss.com?plugins=forms"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/js-yaml/4.1.0/js-yaml.min.js"></script>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
        :root {
            --bg-body: #0d1117;
            --bg-card: #161b22; 
            --bg-nav: #0d1117;
            --text-main: #f0f6fc;
            --text-muted: #8b949e;
            --border: #30363d;
            --accent: #58a6ff;
        }
        body { background-color: var(--bg-body); color: var(--text-main); font-family: 'Inter', sans-serif; }
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-body); }
        ::-webkit-scrollbar-thumb { background: #30363d; border-radius: 4px; }
        
        .premium-card { background-color: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 24px; position: relative; transition: transform 0.2s, border-color 0.2s; min-height: 180px; display: flex; flex-direction: column; justify-content: space-between; }
        .premium-card:hover { border-color: var(--accent); }
        
        /* Typography Standards */
        .card-label { font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); margin-bottom: 4px; }
        .card-value { font-size: 1.875rem; line-height: 2.25rem; font-weight: 700; color: var(--text-main); letter-spacing: -0.02em; }
        .unit-span { font-size: 1.125rem; font-weight: 400; color: #6e7681; margin-left: 2px; }
        .card-footer-text { font-size: 0.75rem; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; color: var(--text-muted); margin-top: auto; padding-top: 16px; display: flex; align-items: center; gap: 6px; }

        .icon-box { width: 40px; height: 40px; border-radius: 10px; display: flex; align-items: center; justify-content: center; position: absolute; top: 24px; right: 24px; }
        .icon-blue { background: rgba(56, 139, 253, 0.15); color: #58a6ff; }
        .icon-green { background: rgba(63, 185, 80, 0.15); color: #3fb950; }
        .icon-orange { background: rgba(210, 153, 34, 0.15); color: #d29922; }
        .icon-purple { background: rgba(163, 113, 247, 0.15); color: #a371f7; }

        .progress-track { background-color: #21262d; height: 6px; border-radius: 9999px; margin-top: 12px; overflow: hidden; width: 100%; }
        .progress-bar { height: 100%; border-radius: 9999px; transition: width 0.5s ease-out; }
        .bar-blue { background-color: #58a6ff; }
        .bar-green { background-color: #3fb950; }

        .view { display: none; }
        .view.active { display: block; animation: fadeIn 0.3s ease-in-out; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
        
        .sidebar { transition: width 0.3s cubic-bezier(0.4, 0, 0.2, 1); width: 260px; background-color: var(--bg-nav); z-index: 50; flex-shrink: 0; }
        .sidebar.collapsed { width: 72px; }
        .sidebar.collapsed .logo-text, .sidebar.collapsed .nav-text { display: none; opacity: 0; }
        .sidebar.collapsed .nav-btn { justify-content: center; padding: 12px; }
        .sidebar.collapsed .sidebar-header { padding: 0; justify-content: center; }
        .mobile-overlay { background: rgba(0,0,0,0.7); opacity: 0; pointer-events: none; transition: opacity 0.3s; }
        .mobile-overlay.open { opacity: 1; pointer-events: auto; }
        
        .nav-btn { display: flex; align-items: center; gap: 12px; width: 100%; padding: 12px 16px; border-radius: 8px; font-size: 0.9rem; font-weight: 500; color: var(--text-muted); transition: all 0.2s; white-space: nowrap; }
        .nav-btn:hover { background: #21262d; color: #fff; }
        .nav-btn.active { background: #1f6feb; color: #fff; }

        .code-editor { font-family: 'Consolas', 'Monaco', monospace; font-size: 13px; background-color: #0d1117; color: #e6edf3; border: 1px solid var(--border); border-radius: 6px; width: 100%; height: 600px; padding: 16px; resize: vertical; outline: none; }
        .tab-btn { padding: 8px 16px; border-bottom: 2px solid transparent; color: var(--text-muted); font-weight: 500; transition: all 0.2s; }
        .log-error { color: #f87171 !important; background-color: rgba(69, 10, 10, 0.3); border-left: 2px solid #ef4444; }
        
        @media (max-width: 768px) {
            .sidebar { position: fixed; left: -260px; height: 100%; border-right: 1px solid var(--border); box-shadow: 4px 0 24px rgba(0,0,0,0.5); }
            .sidebar.mobile-open { left: 0; }
        }
    </style>
</head>
<body class="h-screen flex overflow-hidden bg-[#0d1117]">
    <div id="mobile-overlay" class="mobile-overlay fixed inset-0 z-40 md:hidden backdrop-blur-sm" onclick="toggleSidebar()"></div>
    <!-- Sidebar -->
    <aside id="sidebar" class="sidebar border-r border-gray-800 flex flex-col">
        <div class="h-16 flex items-center justify-between px-6 border-b border-gray-800 sidebar-header shrink-0">
             <div class="flex items-center gap-3 overflow-hidden transition-all logo-box">
                <div class="w-8 h-8 min-w-[32px] bg-blue-600 rounded-lg flex items-center justify-center text-white font-bold shadow-lg shadow-blue-900/40">R</div>
                <h1 class="font-bold text-lg text-white logo-text whitespace-nowrap">TunnelR <span class="text-xs font-mono text-gray-500 ml-1">v3.5.21</span></h1>
             </div>
             <button onclick="toggleSidebarDesktop()" class="text-gray-500 hover:text-white hidden md:block transition-colors p-1 rounded hover:bg-gray-800"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"></path></svg></button>
        </div>
        <nav class="flex-1 px-4 py-6 space-y-2 overflow-y-auto">
            <button onclick="setView('dash')" id="nav-dash" class="nav-btn active"><svg class="w-6 h-6 min-w-[24px]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z"></path></svg> <span class="nav-text">Dashboard</span></button>
            <button onclick="setView('logs')" id="nav-logs" class="nav-btn"><svg class="w-6 h-6 min-w-[24px]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"></path></svg> <span class="nav-text">Live Logs</span></button>
            <button onclick="setView('settings')" id="nav-settings" class="nav-btn"><svg class="w-6 h-6 min-w-[24px]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path></svg> <span class="nav-text">Editor</span></button>
        </nav>
    </aside>

    <main class="flex-1 flex flex-col min-w-0 transition-all">
        <!-- Header -->
        <header class="h-16 shrink-0 flex items-center justify-between px-4 md:px-8 bg-card border-b border-gray-800 sticky top-0 z-20 backdrop-blur-md" style="background-color: rgba(22, 27, 34, 0.85);">
            <div class="flex items-center gap-4">
                <button onclick="toggleSidebar()" class="md:hidden text-gray-400 hover:text-white p-1"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"></path></svg></button>
                <div class="flex items-center gap-3"><span class="text-sm font-medium text-gray-300 hidden md:inline">Status:</span><span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-900 text-green-300 border border-green-700 shadow-sm shadow-green-900/20"><span class="w-1.5 h-1.5 mr-1.5 bg-green-500 rounded-full animate-pulse"></span> Running</span></div>
            </div>
            <div class="flex gap-2">
                <button onclick="control('restart')" class="flex items-center gap-2 px-3 py-1.5 md:px-4 md:py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg text-xs md:text-sm transition-all border border-slate-600 shadow-sm">Restart</button>
                <button onclick="control('stop')" class="flex items-center gap-2 px-3 py-1.5 md:px-4 md:py-2 bg-red-900/50 hover:bg-red-900 text-red-300 rounded-lg text-xs md:text-sm transition-all border border-red-800 shadow-sm">Stop</button>
            </div>
        </header>

        <div class="flex-1 overflow-y-auto w-full">
            <div class="w-full p-6 md:p-8 space-y-6 max-w-6xl mx-auto">
                <!-- VIEW: DASHBOARD -->
                <div id="view-dash" class="view active">
                    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 md:gap-6">
                        <!-- CPU -->
                        <div class="premium-card">
                            <div class="icon-box icon-blue"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z"></path></svg></div>
                            <div><div class="card-label">CPU Usage</div><div class="card-value"><span id="cpu-val">0</span><span class="unit-span">%</span></div></div>
                            <div class="w-full"><div class="progress-track"><div id="cpu-bar" class="progress-bar bar-blue" style="width: 0%"></div></div></div>
                        </div>
                        <!-- RAM -->
                        <div class="premium-card">
                            <div class="icon-box icon-green"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4"></path></svg></div>
                            <div><div class="card-label">RAM Usage</div><div class="card-value"><span id="ram-used">0</span><span class="unit-span" id="ram-total">/ 0GB</span></div></div>
                            <div class="w-full"><div class="progress-track"><div id="ram-bar" class="progress-bar bar-green" style="width: 0%"></div></div></div>
                        </div>
                         <!-- Uptime -->
                        <div class="premium-card">
                             <div class="icon-box icon-orange"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg></div>
                             <div><div class="card-label">Uptime</div><div class="card-value" id="svc-uptime">0<span class="unit-span">d</span> 0<span class="unit-span">h</span> 0<span class="unit-span">m</span></div></div>
                             <div class="card-footer-text"><span>Started: <span id="start-time" class="text-gray-400">...</span></span></div>
                        </div>
                        <!-- Sessions (FIXED: Now showing ACTIVE connections) -->
                        <div class="premium-card">
                             <div class="icon-box icon-purple"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"></path></svg></div>
                             <div><div class="card-label">Sessions</div><div class="card-value" id="sess-count">0</div></div>
                             <!-- TOTAL VOLUME -->
                             <div class="card-footer-text justify-between w-full"><span class="text-blue-400">↑ <span id="vol-sent">0 B</span></span> <span class="text-green-400">↓ <span id="vol-recv">0 B</span></span></div>
                        </div>
                    </div>

                    <div class="premium-card mt-6" style="min-height: auto;">
                        <div class="flex flex-col md:flex-row justify-between items-start md:items-center mb-6">
                            <h3 class="text-lg font-bold text-white">Traffic Overview</h3>
                             <div class="flex gap-4 md:gap-6 text-sm mt-2 md:mt-0">
                                <span class="text-blue-400">Upload <span id="lg-up" class="font-mono text-white">0 B/s</span></span>
                                <span class="text-green-400">Download <span id="lg-down" class="font-mono text-white">0 B/s</span></span>
                            </div>
                        </div>
                        <div class="h-60 md:h-80 w-full relative">
                            <canvas id="trafficChart"></canvas>
                        </div>
                    </div>
                </div>

                <!-- (Logs & Settings unchanged) -->
                <div id="view-logs" class="view">
                     <div class="premium-card h-[calc(100vh-140px)] flex flex-col p-0 overflow-hidden" style="min-height: 400px;">
                        <div class="p-4 border-b border-gray-800 flex justify-between bg-black/20">
                            <span class="font-bold text-sm text-gray-300">SYSTEM LOGS</span>
                            <div class="flex bg-gray-900 rounded p-1 border border-gray-700"><button onclick="setLogFilter('all')" class="px-3 py-1 text-xs rounded hover:bg-gray-800 text-white" id="btn-log-all">All</button><button onclick="setLogFilter('error')" class="px-3 py-1 text-xs rounded hover:bg-gray-800 text-red-500" id="btn-log-error">Errors</button></div>
                        </div>
                        <div id="logs-container" class="flex-1 overflow-y-auto p-4 font-mono text-xs text-gray-300 space-y-1 bg-[#0d1117]"></div>
                     </div>
                </div>

                <div id="view-settings" class="view">
                    <div class="flex flex-col md:flex-row justify-between items-center mb-6 gap-4">
                        <div class="flex gap-4 w-full md:w-auto bg-gray-900 p-1 rounded-lg"><button onclick="setCfgMode('visual')" id="tab-visual" class="flex-1 md:flex-none px-4 py-2 rounded-md text-sm font-medium transition-colors hover:bg-gray-800 text-white bg-gray-800 shadow">Visual Form</button><button onclick="setCfgMode('code')" id="tab-code" class="flex-1 md:flex-none px-4 py-2 rounded-md text-sm font-medium transition-colors text-gray-400 hover:text-white hover:bg-gray-800">Raw Editor</button></div>
                        <button onclick="saveConfig()" class="w-full md:w-auto bg-blue-600 hover:bg-blue-500 text-white px-5 py-2 rounded-lg text-sm font-semibold shadow-lg shadow-blue-900/50">Save & Restart</button>
                    </div>
                    <div id="cfg-code" class="premium-card p-0 overflow-hidden hidden" style="min-height: 600px;"><textarea id="config-editor" class="code-editor" spellcheck="false"></textarea></div>
                    <div id="cfg-visual" class="premium-card space-y-8" style="min-height: auto;">
                        <div><h4 class="text-sm font-bold text-blue-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Core Connection</h4><div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6"><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Bind Address</label><input type="text" id="v-listen" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:border-blue-500"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">PSK</label><input type="text" id="v-psk" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:border-blue-500"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Mimic</label><input type="text" id="v-mimic" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Transport</label><select id="v-transport" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"><option value="httpsmux">HTTPS</option><option value="wssmux">WSS</option></select></div></div></div>
                        <div><h4 class="text-sm font-bold text-green-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Obfuscation</h4><div class="grid grid-cols-1 md:grid-cols-2 gap-6"><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Key</label><input type="text" id="v-obfs-key" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">IV</label><input type="text" id="v-obfs-iv" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div></div></div>
                        <div><h4 class="text-sm font-bold text-orange-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Load Balancing</h4><div class="grid grid-cols-1 md:grid-cols-3 gap-6"><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Pool</label><input type="number" id="v-pool" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Retry (s)</label><input type="number" id="v-retry" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Timeout (s)</label><input type="number" id="v-timeout" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white text-sm"></div></div></div>
                        <div class="grid grid-cols-1 md:grid-cols-2 gap-8"><div><h4 class="text-sm font-bold text-purple-400 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Rules</h4><div class="space-y-4"><div><label class="block text-xs font-medium text-gray-400 mb-1.5">TCP Rules</label><textarea id="v-tcp" rows="4" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white font-mono text-xs placeholder-gray-700"></textarea></div><div><label class="block text-xs font-medium text-gray-400 mb-1.5">UDP Rules</label><textarea id="v-udp" rows="4" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white font-mono text-xs placeholder-gray-700"></textarea></div></div></div><div><h4 class="text-sm font-bold text-blue-300 uppercase tracking-wider mb-4 border-b border-gray-800 pb-2">Upstreams</h4><div><label class="block text-xs font-medium text-gray-400 mb-1.5">Upstream Servers</label><textarea id="v-upstreams" rows="9" class="w-full bg-[#0d1117] border border-gray-700 rounded-lg px-3 py-2 text-white font-mono text-xs placeholder-gray-700"></textarea></div></div></div>
                    </div>
                </div>
            </div>
        </div>
    </main>
    
    <script>
        const $ = s => document.querySelector(s);
        let chart = null;

        function toggleSidebar() { $('#sidebar').classList.toggle('mobile-open'); $('#mobile-overlay').classList.toggle('open'); }
        function toggleSidebarDesktop() { $('#sidebar').classList.toggle('collapsed'); }
        function setView(id) {
            document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
            document.querySelectorAll('.nav-btn').forEach(n => n.classList.remove('active'));
            $(`#view-${id}`).classList.add('active');
            $(`#nav-${id}`).classList.add('active');
            $('#sidebar').classList.remove('mobile-open'); $('#mobile-overlay').classList.remove('open');
            if(id === 'logs') initLogs();
            if(id === 'settings') loadConfig();
        }
        async function control(action) { if(!confirm('Are you sure?')) return; await fetch('/api/restart', {method:'POST'}); setTimeout(()=>location.reload(), 3000); }
        function setCfgMode(m) { $('#cfg-code').classList.toggle('hidden', m !== 'code'); $('#cfg-visual').classList.toggle('hidden', m !== 'visual'); const btn = $(m === 'code' ? '#tab-code' : '#tab-visual'); document.querySelectorAll('.tab-btn').forEach(b=>{b.classList.remove('bg-gray-800','text-white');b.classList.add('text-gray-400')}); btn.classList.add('bg-gray-800','text-white'); btn.classList.remove('text-gray-400'); if(m === 'visual') parseYamlToForm(); }
        function parseYamlToForm() { try { const doc = jsyaml.load($('#config-editor').value); if(!doc) return; $('#v-listen').value=doc.listen||''; $('#v-psk').value=doc.psk||''; $('#v-mimic').value=(doc.mimic?.fake_domain)||''; $('#v-transport').value=doc.transport||'httpsmux'; $('#v-obfs-key').value=doc.obfs?.key||''; $('#v-obfs-iv').value=doc.obfs?.iv||''; $('#v-pool').value=doc.paths?.[0]?.pool||4; $('#v-retry').value=doc.paths?.[0]?.retry||3; $('#v-timeout').value=doc.paths?.[0]?.dial_timeout||10; $('#v-upstreams').value=doc.upstreams?jsyaml.dump(doc.upstreams):''; $('#v-tcp').value=doc.forward?.tcp?jsyaml.dump(doc.forward.tcp):''; $('#v-udp').value=doc.forward?.udp?jsyaml.dump(doc.forward.udp):''; } catch(e){} }
        function updateYamlFromForm() { try { let doc = jsyaml.load($('#config-editor').value) || {}; doc.listen=$('#v-listen').value; doc.psk=$('#v-psk').value; doc.transport=$('#v-transport').value; if(!doc.mimic) doc.mimic={}; doc.mimic.fake_domain=$('#v-mimic').value; if(!doc.obfs) doc.obfs={}; doc.obfs.key=$('#v-obfs-key').value; doc.obfs.iv=$('#v-obfs-iv').value; if(!doc.paths) doc.paths=[{}]; doc.paths.forEach(p=>{p.pool=parseInt($('#v-pool').value);p.retry=parseInt($('#v-retry').value);p.dial_timeout=parseInt($('#v-timeout').value)}); try{doc.upstreams=jsyaml.load($('#v-upstreams').value)}catch(e){} if(!doc.forward) doc.forward={}; try{doc.forward.tcp=jsyaml.load($('#v-tcp').value)}catch(e){} try{doc.forward.udp=jsyaml.load($('#v-udp').value)}catch(e){} $('#config-editor').value=jsyaml.dump(doc); } catch(e) { alert('YAML Error: '+e); } }
        async function loadConfig() { const r = await fetch('/api/config'); if(r.ok) { $('#config-editor').value=await r.text(); parseYamlToForm(); } }
        async function saveConfig() { if(!$('#cfg-visual').classList.contains('hidden')) updateYamlFromForm(); if(!confirm('Save?')) return; await fetch('/api/config', {method:'POST', body:$('#config-editor').value}); await fetch('/api/restart', {method:'POST'}); }
        let logSrc; function initLogs() { if(logSrc) return; $('#logs-container').innerHTML=''; logSrc=new EventSource('/api/logs/stream'); logSrc.onmessage=e=>{ const d=document.createElement('div'); d.textContent=e.data; if(e.data.toLowerCase().includes('err')) d.classList.add('log-error','p-1','rounded'); else d.classList.add('p-0.5'); $('#logs-container').appendChild(d); } }
        function setLogFilter(f) { document.querySelectorAll('#logs-container div').forEach(d=>{ d.style.display=(f==='all'||d.classList.contains('log-error'))?'block':'none' }) }

        setInterval(async () => {
            try {
                const res = await fetch('/api/stats');
                const data = await res.json();
                $('#cpu-val').innerText = data.cpu.toFixed(1);
                $('#cpu-bar').style.width = Math.min(data.cpu, 100) + '%';
                
                const usedBytes = data.ram_used || 0; const totalBytes = data.ram_total || 1;
                const usedGB = (usedBytes / 1024**3).toFixed(1); const totalGB = (totalBytes > 1024**2) ? (totalBytes / 1024**3).toFixed(1)+'GB' : '';
                $('#ram-used').innerText = usedGB; $('#ram-total').innerText = '/ '+totalGB;
                $('#ram-bar').style.width = Math.min((usedBytes/totalBytes)*100, 100) + '%';
                
                // --- FIX: Use ACTIVE connections, NOT total (which only goes up) ---
                $('#sess-count').innerText = data.stats.active_conns || 0;
                
                if(data.uptime_s){const s=data.uptime_s;const d=Math.floor(s/86400);const h=Math.floor((s%86400)/3600);const m=Math.floor((s%3600)/60);$('#svc-uptime').innerHTML=`${d}<span class="unit-span">d</span> ${h}<span class="unit-span">h</span> ${m}<span class="unit-span">m</span>`;}
                if(data.start_time){const s=new Date(data.start_time);$('#start-time').innerText=s.toLocaleTimeString();}
                
                const hb=b=>{const u=['B','KB','MB','GB'];let i=0;while(b>=1024&&i<3){b/=1024;i++}return b.toFixed(1)+' '+u[i];};
                $('#vol-sent').innerText = hb(data.stats.bytes_recv||0); 
                $('#vol-recv').innerText = hb(data.stats.bytes_sent||0);
                $('#lg-up').innerText=hb(data.stats.speed_up||0)+'/s'; $('#lg-down').innerText=hb(data.stats.speed_down||0)+'/s';
                updateChart(data.stats.speed_down||0, data.stats.speed_up||0);
            } catch(e) {}
        }, 1000);
        
        function updateChart(rx, tx) {
             const hb=b=>{const u=['B','KB','MB','GB'];let i=0;while(b>=1024&&i<3){b/=1024;i++}return b.toFixed(1)+' '+u[i]};
             if(!chart) { const ctx=$('#trafficChart').getContext('2d'); 
                 chart=new Chart(ctx,{
                     type:'line',
                     data:{labels:Array(30).fill(''),datasets:[
                         {label:'DL',data:Array(30).fill(0),borderColor:'#3fb950',backgroundColor:'rgba(63, 185, 80, 0.1)',fill:true,tension:0.4,pointRadius:0},
                         {label:'UL',data:Array(30).fill(0),borderColor:'#58a6ff',backgroundColor:'rgba(56, 139, 253, 0.1)',fill:true,tension:0.4,pointRadius:0}
                     ]},
                     options:{
                         responsive:true, maintainAspectRatio:false,
                         scales:{
                             x:{display:false}, 
                             y:{position:'right',ticks:{color:'#8b949e',maxTicksLimit:5,callback:v=>hb(v)},grid:{color:'#30363d'}}
                         },
                         plugins:{legend:{display:false}},
                         animation: false,
                         interaction:{intersect:false}
                    }
                }); 
             }
             chart.data.labels.push(''); chart.data.labels.shift();
             chart.data.datasets[0].data.push(rx); chart.data.datasets[0].data.shift();
             chart.data.datasets[1].data.push(tx); chart.data.datasets[1].data.shift();
             chart.update();
        }
    </script>
</body>
</html>

EOF
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
  listen: "0.0.0.0:8585"
  user: "${DASH_USER}"
  pass: "${DASH_PASS}"
  session_secret: "${SESSION_SECRET}"
EOF
        echo -e "${GREEN}[OK] Dashboard configured.${NC}"
        
        read -p "Restart service now? [Y/n]: " r
        if [[ ! "$r" =~ ^[Nn]$ ]]; then
            systemctl restart "$SVC"
            echo -e "${GREEN}[OK] Service restarted.${NC}"
            echo -e "Access at: http://YOUR_IP:8585"
        fi
        
    elif [ "$c" == "2" ]; then
        # Uninstall
        rm -rf /var/lib/picotun/dashboard
        sed -i '/# DASHBOARD-CONFIG-START/,$d' "$CFG"
        echo -e "${GREEN}[OK] Dashboard uninstalled (files removed).${NC}"
        
        read -p "Restart service now? [Y/n]: " r
        if [[ ! "$r" =~ ^[Nn]$ ]]; then
            systemctl restart "$SVC"
            echo -e "${GREEN}[OK] Service restarted.${NC}"
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
        echo -e "  Status: ${GREEN} Running${NC}"
    else
        echo -e "  Status: ${RED} Stopped${NC}"
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
        1) systemctl start "$SVC"; echo -e "${GREEN}[OK] Started${NC}"; sleep 1; service_management "$MODE" ;;
        2) systemctl stop "$SVC"; echo -e "${GREEN}[OK] Stopped${NC}"; sleep 1; service_management "$MODE" ;;
        3) systemctl restart "$SVC"; echo -e "${GREEN}[OK] Restarted${NC}"; sleep 1; service_management "$MODE" ;;
        4) systemctl status "$SVC" --no-pager; read -p "Enter..."; service_management "$MODE" ;;
        5) journalctl -u "$SVC" -f ;;
        6) systemctl enable "$SVC" 2>/dev/null; echo -e "${GREEN}[OK] Auto-start enabled${NC}"; sleep 1; service_management "$MODE" ;;
        7) systemctl disable "$SVC" 2>/dev/null; echo -e "${GREEN}[OK] Auto-start disabled${NC}"; sleep 1; service_management "$MODE" ;;
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
                echo -e "${GREEN}[OK] Deleted${NC}"; sleep 1
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
        echo -e "${GREEN}[OK] Dashboard updated${NC}"
    fi

    # Restart services if running
    for svc in picotun-server picotun-client; do
        if systemctl is-active "$svc" &>/dev/null; then
            systemctl restart "$svc"
            echo -e "${GREEN}[OK] $svc restarted${NC}"
        fi
    done

    echo ""
    read -p "Press Enter..."
    main_menu
}

# ----------------------------------------------------------------

uninstall() {
    show_banner
    echo -e "${RED}${NC}"
    echo -e "${RED}         UNINSTALL PICOTUN${NC}"
    echo -e "${RED}${NC}"
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

    echo -e "${GREEN}[OK] PicoTun uninstalled${NC}"
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

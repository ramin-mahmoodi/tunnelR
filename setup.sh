#!/bin/bash

# ===============================================================
# ----------------------------------------------------------------
# Setup Script (bash <(curl -s https://raw.githubusercontent.com/ramin-mahmoodi/tunnelR/main/setup.sh))
# ===============================================================

SCRIPT_VERSION="3.5.6"


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
    
    echo "Creating Dashboard Assets (v3.5.5)..."

    cat <<'EOF' > "$DASH_DIR/index.html"
<!DOCTYPE html>
<html class="dark" lang="en">
<head>
    <meta charset="utf-8"/>
    <meta content="width=device-width, initial-scale=1.0" name="viewport"/>
    <title>TunnelR v3.5.5</title>
    <script src="https://cdn.tailwindcss.com?plugins=forms"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/js-yaml@4.1.0/dist/js-yaml.min.js"></script>
    <style>
        :root {
            --bg-body: #0f172a;
            --bg-card: #1e293b;
            --bg-nav: #1e293b;
            --text-main: #f1f5f9;
            --text-muted: #94a3b8;
            --accent: #3b82f6;
            --border: #334155;
        }
        body { background-color: var(--bg-body); color: var(--text-main); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
        .card { background-color: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06); }
        .view { display: none; }
        .view.active { display: block; animation: fadeIn 0.3s ease-in-out; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
        
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-body); }
        ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: #475569; }

        .icon-box { background: rgba(59, 130, 246, 0.1); padding: 8px; border-radius: 8px; color: #60a5fa; }
        .icon { width: 24px; height: 24px; stroke: currentColor; fill: none; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
        
        .legend-dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }
    </style>
</head>
<body class="h-screen flex overflow-hidden">

    <!-- Sidebar -->
    <aside class="w-64 bg-nav border-r border-slate-700 flex flex-col hidden md:flex" style="background-color: var(--bg-nav);">
        <div class="p-6 flex items-center gap-3 border-b border-slate-700/50">
            <div class="w-8 h-8 bg-blue-600 rounded-lg flex items-center justify-center text-white font-bold shadow-lg shadow-blue-500/20">T</div>
            <h1 class="font-bold text-lg tracking-tight text-white">TunnelR <span class="text-xs font-normal text-blue-400 bg-blue-900/30 px-1.5 py-0.5 rounded ml-1">v3.5.5</span></h1>
        </div>

        <nav class="flex-1 px-4 space-y-2 mt-6">
            <button onclick="setView('dash')" id="nav-dash" class="nav-item w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium transition-all text-white bg-blue-600 shadow-lg shadow-blue-900/20">
                <svg class="icon w-5 h-5"><rect x="3" y="3" width="7" height="7"></rect><rect x="14" y="3" width="7" height="7"></rect><rect x="14" y="14" width="7" height="7"></rect><rect x="3" y="14" width="7" height="7"></rect></svg>
                Overview
            </button>
            <button onclick="setView('logs')" id="nav-logs" class="nav-item w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium text-slate-400 hover:bg-slate-800 hover:text-white transition-all">
                <svg class="icon w-5 h-5"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line><polyline points="10 9 9 9 8 9"></polyline></svg>
                Real-time Logs
            </button>
            <button onclick="setView('settings')" id="nav-settings" class="nav-item w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium text-slate-400 hover:bg-slate-800 hover:text-white transition-all">
                <svg class="icon w-5 h-5"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>
                Configuration
            </button>
        </nav>
    </aside>

    <!-- Main Content -->
    <main class="flex-1 flex flex-col min-w-0 overflow-hidden bg-slate-900">
        <!-- Top Bar -->
        <header class="h-16 border-b border-slate-700/50 flex items-center justify-between px-8 bg-slate-800/50 backdrop-blur-sm sticky top-0 z-10">
            <h2 class="text-xl font-bold text-white tracking-tight" id="page-title">Dashboard</h2>
            <div class="flex items-center gap-4">
                <span class="text-xs font-mono text-slate-400 bg-slate-800 px-3 py-1.5 rounded-full border border-slate-700 flex items-center gap-2">
                    <span class="w-2 h-2 rounded-full bg-emerald-500 animate-pulse"></span>
                    Running
                </span>
            </div>
        </header>

        <div class="flex-1 overflow-y-auto p-8 space-y-8">
            
            <!-- VIEW: DASHBOARD -->
            <div id="view-dash" class="view active">
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
                    
                    <!-- CPU Card -->
                    <div class="card p-5 relative overflow-hidden group hover:border-slate-600 transition-colors">
                        <div class="flex justify-between items-start mb-4">
                            <div>
                                <div class="text-slate-400 text-xs font-bold uppercase tracking-wider mb-1">CPU Usage</div>
                                <div class="text-3xl font-bold text-white tabular-nums"><span id="cpu-val">0</span>%</div>
                            </div>
                            <div class="icon-box text-blue-400 bg-blue-500/10">
                                <svg class="icon"><rect x="4" y="4" width="16" height="16" rx="2" ry="2"></rect><rect x="9" y="9" width="6" height="6"></rect><line x1="9" y1="1" x2="9" y2="4"></line><line x1="15" y1="1" x2="15" y2="4"></line><line x1="9" y1="20" x2="9" y2="23"></line><line x1="15" y1="20" x2="15" y2="23"></line><line x1="20" y1="9" x2="23" y2="9"></line><line x1="20" y1="14" x2="23" y2="14"></line><line x1="1" y1="9" x2="4" y2="9"></line><line x1="1" y1="14" x2="4" y2="14"></line></svg>
                            </div>
                        </div>
                        <div class="w-full bg-slate-700/50 h-1.5 rounded-full overflow-hidden">
                            <div id="cpu-bar" class="bg-blue-500 h-full transition-all duration-500" style="width:0%"></div>
                        </div>
                    </div>

                    <!-- RAM Card -->
                    <div class="card p-5 relative overflow-hidden group hover:border-slate-600 transition-colors">
                        <div class="flex justify-between items-start mb-4">
                            <div>
                                <div class="text-slate-400 text-xs font-bold uppercase tracking-wider mb-1">RAM</div>
                                <div class="text-3xl font-bold text-white tabular-nums text-sm flex items-baseline gap-1">
                                    <span id="ram-used">0</span> / <span id="ram-total">0</span>
                                </div>
                            </div>
                            <div class="icon-box text-emerald-400 bg-emerald-500/10">
                                <svg class="icon"><path d="M22 12h-4l-3 9L9 3l-3 9H2"></path></svg>
                            </div>
                        </div>
                        <div class="w-full bg-slate-700/50 h-1.5 rounded-full overflow-hidden">
                            <div id="ram-bar" class="bg-emerald-500 h-full transition-all duration-500" style="width:0%"></div>
                        </div>
                    </div>

                    <!-- Service Uptime -->
                    <div class="card p-5 relative overflow-hidden group hover:border-slate-600 transition-colors">
                        <div class="flex justify-between items-start">
                            <div>
                                <div class="text-slate-400 text-xs font-bold uppercase tracking-wider mb-1">Service Uptime</div>
                                <div class="text-2xl font-bold text-white tabular-nums mt-1" id="svc-uptime">00:00:00</div>
                            </div>
                            <div class="icon-box text-orange-400 bg-orange-500/10">
                                <svg class="icon"><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
                            </div>
                        </div>
                        <div class="mt-4 text-xs text-slate-500">Since run started</div>
                    </div>

                    <!-- Sessions (Restored Volume Display) -->
                    <div class="card p-5 relative overflow-hidden group hover:border-slate-600 transition-colors">
                        <div class="flex justify-between items-start">
                            <div>
                                <div class="text-slate-400 text-xs font-bold uppercase tracking-wider mb-1">Active Sessions</div>
                                <div class="text-3xl font-bold text-white tabular-nums mt-1" id="sess-count">0</div>
                            </div>
                            <div class="icon-box text-purple-400 bg-purple-500/10">
                                <svg class="icon"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path><circle cx="9" cy="7" r="4"></circle><path d="M23 21v-2a4 4 0 0 0-3-3.87"></path><path d="M16 3.13a4 4 0 0 1 0 7.75"></path></svg>
                            </div>
                        </div>
                         <div class="mt-3 grid grid-cols-2 gap-2 text-[10px] font-mono border-t border-slate-700/50 pt-2">
                             <div>
                                <span class="text-slate-500 block">Total Sent</span>
                                <span id="vol-sent" class="text-blue-400">0 B</span>
                             </div>
                             <div>
                                <span class="text-slate-500 block">Total Recv</span>
                                <span id="vol-recv" class="text-emerald-400">0 B</span>
                             </div>
                         </div>
                    </div>
                </div>

                <!-- Traffic Chart (Maintained v3.5.4 design) -->
                <div class="card p-6 mb-6">
                    <div class="flex flex-col md:flex-row justify-between items-start md:items-center mb-6">
                        <div>
                            <h3 class="text-lg font-bold text-white">Traffic Overview</h3>
                            <p class="text-slate-500 text-sm">Real-time throughput monitor</p>
                        </div>
                        <div class="flex gap-6 mt-4 md:mt-0 text-sm font-medium">
                            <div class="flex items-center text-slate-300">
                                <span class="legend-dot bg-blue-500"></span> Upload (<span id="lg-up" class="font-mono">0 B/s</span>)
                            </div>
                            <div class="flex items-center text-slate-300">
                                <span class="legend-dot bg-emerald-500"></span> Download (<span id="lg-down" class="font-mono">0 B/s</span>)
                            </div>
                        </div>
                    </div>
                    <div class="h-80 w-full">
                        <canvas id="trafficChart"></canvas>
                    </div>
                </div>
            </div>

             <!-- VIEW: LOGS & SETTINGS (Unchanged) -->
            <div id="view-logs" class="view">
                <div class="card flex flex-col h-[calc(100vh-160px)] border-slate-700/50">
                    <div class="p-4 border-b border-slate-700/50 flex justify-between bg-slate-800/30 rounded-t-xl items-center">
                        <span class="font-bold text-sm uppercase text-slate-300 tracking-wide">System Logs</span>
                        <div class="flex bg-slate-800 rounded-lg p-1 border border-slate-700">
                            <button onclick="setLogFilter('all')" class="px-3 py-1 rounded text-xs font-medium text-slate-300 hover:bg-slate-700 hover:text-white transition-colors" id="btn-log-all">All</button>
                            <button onclick="setLogFilter('warn')" class="px-3 py-1 rounded text-xs font-medium text-yellow-500 hover:bg-slate-700 transition-colors" id="btn-log-warn">Warn</button>
                            <button onclick="setLogFilter('error')" class="px-3 py-1 rounded text-xs font-medium text-red-500 hover:bg-slate-700 transition-colors" id="btn-log-error">Error</button>
                        </div>
                    </div>
                    <div id="logs-container" class="flex-1 overflow-y-auto p-4 font-mono text-xs text-slate-300 space-y-1.5 bg-[#0d1117]/50">
                        <div class="text-center text-slate-500 mt-20 flex flex-col items-center gap-2">
                            <div class="loader"></div>
                            <span>Connecting to log stream...</span>
                        </div>
                    </div>
                </div>
            </div>

            <div id="view-settings" class="view">
                <div class="flex justify-between items-center mb-8">
                    <div>
                        <h3 class="text-2xl font-bold text-white">Configuration</h3>
                        <p class="text-slate-500 text-sm mt-1">Manage global tunnel settings</p>
                    </div>
                    <button onclick="saveConfig()" class="bg-blue-600 hover:bg-blue-500 text-white px-6 py-2.5 rounded-lg text-sm font-bold shadow-lg shadow-blue-500/20 transition-all flex items-center gap-2">
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7H5a2 2 0 00-2 2v9a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-3m-1 4l-3 3m0 0l-3-3m3 3V4"></path></svg>
                        Save & Restart
                    </button>
                </div>

                <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
                    <!-- General -->
                    <div class="card p-6 space-y-6">
                        <h4 class="text-xs font-bold text-blue-400 uppercase tracking-widest border-b border-slate-700/50 pb-3">General Settings</h4>
                        <div class="grid grid-cols-2 gap-5">
                            <div><label class="label">Mode</label><input disabled id="f-mode" class="input disabled"></div>
                            <div><label class="label">Transport</label><select id="f-transport" class="input">
                                <option value="httpmux">httpmux</option><option value="httpsmux">httpsmux</option>
                                <option value="tcpmux">tcpmux</option><option value="wsmux">wsmux</option><option value="wssmux">wssmux</option>
                            </select></div>
                            <div class="col-span-2"><label class="label">Listen Address</label><input id="f-listen" class="input font-mono"></div>
                            <div class="col-span-2"><label class="label">PSK (Secret Key)</label><input type="password" id="f-psk" class="input font-mono"></div>
                        </div>
                    </div>

                    <!-- TLS & Mimic -->
                    <div class="card p-6 space-y-6">
                        <h4 class="text-xs font-bold text-blue-400 uppercase tracking-widest border-b border-slate-700/50 pb-3">TLS & Mimicry</h4>
                        <div class="grid grid-cols-1 gap-5">
                            <div class="grid grid-cols-2 gap-5">
                                <div><label class="label">Cert File</label><input id="f-cert" class="input"></div>
                                <div><label class="label">Key File</label><input id="f-key" class="input"></div>
                            </div>
                            <div><label class="label">Fake Domain (SNI)</label><input id="f-domain" class="input" placeholder="www.google.com"></div>
                            <div><label class="label">User Agent</label><input id="f-ua" class="input text-xs" placeholder="Mozilla/5.0..."></div>
                        </div>
                    </div>

                    <!-- Smux & Obfuscation -->
                    <div class="card p-6 space-y-6">
                        <h4 class="text-xs font-bold text-blue-400 uppercase tracking-widest border-b border-slate-700/50 pb-3">Smux & Obfuscation</h4>
                        <div class="grid grid-cols-2 gap-5">
                            <div><label class="label">Version</label><input type="number" id="f-smux-ver" class="input"></div>
                            <div><label class="label">KeepAlive (s)</label><input type="number" id="f-smux-ka" class="input"></div>
                            <div><label class="label">Max Stream</label><input type="number" id="f-smux-stream" class="input"></div>
                            <div><label class="label">Max Recv</label><input type="number" id="f-smux-recv" class="input"></div>
                            
                            <div class="col-span-2 bg-slate-800/50 p-4 rounded-lg border border-slate-700/50">
                                <label class="flex items-center gap-3 text-sm text-white font-medium mb-3 cursor-pointer">
                                    <input type="checkbox" id="f-obfs-en" class="rounded bg-slate-700 border-slate-600 text-blue-500 focus:ring-blue-500">
                                    Enable Obfuscation (Padding)
                                </label>
                                <div class="flex gap-4">
                                    <div class="flex-1"><label class="label text-xs">Min Pad</label><input type="number" id="f-obfs-min" class="input text-center"></div>
                                    <div class="flex-1"><label class="label text-xs">Max Pad</label><input type="number" id="f-obfs-max" class="input text-center"></div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Advanced -->
                    <div class="card p-6 space-y-6">
                        <h4 class="text-xs font-bold text-blue-400 uppercase tracking-widest border-b border-slate-700/50 pb-3">Advanced TCP</h4>
                        <div class="grid grid-cols-2 gap-5">
                            <div><label class="label">TCP Buffer</label><input type="number" id="f-tcp-buf" class="input"></div>
                            <div><label class="label">TCP KeepAlive</label><input type="number" id="f-tcp-ka" class="input"></div>
                            <div class="col-span-2 pt-2">
                                <label class="flex items-center gap-2 text-sm text-slate-300"><input type="checkbox" id="f-nodelay" class="rounded bg-slate-700 border-slate-600 text-blue-500 focus:ring-blue-500"> Enable TCP NoDelay</label>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

        </div>
    </main>

    <script>
        const $ = s => document.querySelector(s);
        let chart = null;
        let config = {};
        
        function setView(id) {
            document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
            document.querySelectorAll('.nav-item').forEach(n => {
                n.classList.remove('bg-blue-600', 'text-white', 'shadow-lg');
                n.classList.add('text-slate-400', 'hover:bg-slate-800');
            });
            $(`#view-${id}`).classList.add('active');
            const nav = $(`#nav-${id}`);
            nav.classList.remove('text-slate-400', 'hover:bg-slate-800');
            nav.classList.add('bg-blue-600', 'text-white', 'shadow-lg');
            $('#page-title').innerText = nav.innerText.trim();
            if(id === 'logs') initLogs();
            if(id === 'settings') loadConfig();
        }

        setInterval(async () => {
            try {
                const res = await fetch('/api/stats');
                const data = await res.json();
                
                $('#cpu-val').innerText = data.cpu.toFixed(1);
                $('#cpu-bar').style.width = Math.min(data.cpu, 100) + '%';
                
                // RAM
                const usedBytes = data.ram_used || 0;
                const totalBytes = data.ram_total || 1; 
                const usedGB = (usedBytes / 1024 / 1024 / 1024).toFixed(1);
                const totalGB = (totalBytes / 1024 / 1024 / 1024).toFixed(1);
                
                if (totalBytes > 1024*1024) {
                     $('#ram-used').innerText = usedGB;
                     $('#ram-total').innerText = totalGB + 'GB';
                     const ramPct = (usedBytes / totalBytes) * 100;
                     $('#ram-bar').style.width = Math.min(ramPct, 100) + '%';
                } else {
                    $('#ram-used').innerText = humanBytes(data.ram_val);
                    $('#ram-total').innerText = 'System';
                }
                
                $('#sess-count').innerText = data.stats.total_conns;
                
                // Service Uptime
                if (data.uptime_s) {
                     $('#svc-uptime').innerText = formatUptime(data.uptime_s);
                } else {
                     $('#svc-uptime').innerText = "00:00:00";
                }

                // Volume (Restored in Sessions Card)
                $('#vol-sent').innerText = data.stats.sent_human;
                $('#vol-recv').innerText = data.stats.recv_human;

                // Update Legend
                const up = humanBytes(data.stats.speed_up || 0);
                const down = humanBytes(data.stats.speed_down || 0);
                $('#lg-up').innerText = up + '/s';
                $('#lg-down').innerText = down + '/s';

                updateChart(data.stats.speed_down || 0, data.stats.speed_up || 0);

            } catch(e) {/* quiet */}
        }, 1000);

        function formatUptime(s) {
            const days = Math.floor(s / 86400);
            s %= 86400;
            const hours = Math.floor(s / 3600);
            s %= 3600;
            const minutes = Math.floor(s / 60);
            s = Math.floor(s % 60);
            
            let res = "";
            if(days > 0) res += `${days}d `;
            res += `${String(hours).padStart(2, '0')}:`;
            res += `${String(minutes).padStart(2, '0')}:`;
            res += `${String(s).padStart(2, '0')}`;
            return res;
        }

        function updateChart(rx, tx) {
            const now = new Date();
            const timeLabel = now.getHours().toString().padStart(2,'0') + ':' + now.getMinutes().toString().padStart(2,'0');

            if(!chart) {
                const ctx = $('#trafficChart').getContext('2d');
                chart = new Chart(ctx, {
                    type: 'line',
                    data: {
                        labels: Array(30).fill(''),
                        datasets: [
                            { label: 'Download', data: Array(30).fill(0), borderColor: '#10b981', backgroundColor: (ctx) => {
                                const bg = ctx.chart.ctx.createLinearGradient(0,0,0,300);
                                bg.addColorStop(0, 'rgba(16, 185, 129, 0.4)');
                                bg.addColorStop(1, 'rgba(16, 185, 129, 0)');
                                return bg;
                            }, fill:true, borderWidth: 2, pointRadius:0, tension: 0.4 },
                            { label: 'Upload', data: Array(30).fill(0), borderColor: '#3b82f6', backgroundColor: (ctx) => {
                                const bg = ctx.chart.ctx.createLinearGradient(0,0,0,300);
                                bg.addColorStop(0, 'rgba(59, 130, 246, 0.4)');
                                bg.addColorStop(1, 'rgba(59, 130, 246, 0)');
                                return bg;
                            }, fill:true, borderWidth: 2, pointRadius:0, tension: 0.4 }
                        ]
                    },
                    options: { 
                        responsive: true, 
                        maintainAspectRatio: false, 
                        scales: { 
                            x:{display:true, grid:{display:false}, ticks:{color:'#64748b', maxTicksLimit: 6} }, 
                            y:{display:true, position:'right', grid:{color:'#1e293b'}, ticks:{color:'#64748b', callback: function(val){ return humanBytes(val) }} } 
                        }, 
                        plugins: { legend:{display:false} }, 
                        animation: false, 
                        interaction: {intersect: false} 
                    }
                });
            }
            
            chart.data.labels.push(timeLabel);
            chart.data.labels.shift();

            chart.data.datasets[0].data.push(rx);
            chart.data.datasets[1].data.push(tx);
            chart.data.datasets[0].data.shift();
            chart.data.datasets[1].data.shift();
            chart.update();
        }

        function humanBytes(b) {
            if(b==0) return '0 B';
            const u = ['B', 'KB', 'MB', 'GB'];
            let i=0;
            while(b >= 1024 && i < u.length-1) { b/=1024; i++; }
            return b.toFixed(1) + ' ' + u[i];
        }

        // --- CONFIG LOADER & LOGS (Re-inject for safety) ---
        async function loadConfig() {
            const t = await (await fetch('/api/config')).text();
            config = jsyaml.load(t);
            if(!config) return;
            setVal('mode', config.mode);
            setVal('transport', config.transport);
            setVal('listen', config.listen);
            setVal('psk', config.psk);
            setVal('cert', config.cert_file);
            setVal('key', config.key_file);
            const http = config.http_mimic || {};
            setVal('domain', http.fake_domain);
            setVal('ua', http.user_agent);
            const smux = config.smux || {};
            setVal('smux-ver', smux.version);
            setVal('smux-ka', smux.keepalive);
            setVal('smux-stream', smux.max_stream);
            setVal('smux-recv', smux.max_recv);
            const obfs = config.obfuscation || {};
            $('#f-obfs-en').checked = obfs.enabled;
            setVal('obfs-min', obfs.min_padding);
            setVal('obfs-max', obfs.max_padding);
            const adv = config.advanced || {};
            setVal('tcp-buf', adv.tcp_read_buffer);
            setVal('tcp-ka', adv.tcp_keepalive);
            $('#f-nodelay').checked = adv.tcp_nodelay;
        }
        function setVal(id, val) { const el = $(`#f-${id}`); if(el) el.value = (val !== undefined && val !== null) ? val : ''; }
        async function saveConfig() {
            if(!confirm('Apply changes and restart?')) return;
            config.listen = $('#f-listen').value;
            config.psk = $('#f-psk').value;
            config.transport = $('#f-transport').value;
            config.cert_file = $('#f-cert').value;
            config.key_file = $('#f-key').value;
            if(!config.http_mimic) config.http_mimic = {};
            config.http_mimic.fake_domain = $('#f-domain').value;
            config.http_mimic.user_agent = $('#f-ua').value;
            if(!config.smux) config.smux = {};
            config.smux.version = parseInt($('#f-smux-ver').value);
            config.smux.keepalive = parseInt($('#f-smux-ka').value);
            config.smux.max_stream = parseInt($('#f-smux-stream').value);
            config.smux.max_recv = parseInt($('#f-smux-recv').value);
            if(!config.obfuscation) config.obfuscation = {};
            config.obfuscation.enabled = $('#f-obfs-en').checked;
            config.obfuscation.min_padding = parseInt($('#f-obfs-min').value);
            config.obfuscation.max_padding = parseInt($('#f-obfs-max').value);
            if(!config.advanced) config.advanced = {};
            config.advanced.tcp_read_buffer = parseInt($('#f-tcp-buf').value);
            config.advanced.tcp_write_buffer = parseInt($('#f-tcp-buf').value); 
            config.advanced.tcp_keepalive = parseInt($('#f-tcp-ka').value);
            config.advanced.tcp_nodelay = $('#f-nodelay').checked;
            const yaml = jsyaml.dump(config);
            try {
                const r = await fetch('/api/config', { method:'POST', body: yaml });
                if(r.ok) { await fetch('/api/restart', { method:'POST' }); alert('Restarting...'); setTimeout(()=>location.reload(), 3000); } 
                else { const txt = await r.text(); alert('Error: '+txt); }
            } catch(e) { alert(e); }
        }
        let logSrc;
        function initLogs() {
            if(logSrc) return;
            $('#logs-container').innerHTML = '';
            logSrc = new EventSource('/api/logs/stream');
            logSrc.onmessage = e => {
                const d = document.createElement('div');
                const t = e.data;
                d.textContent = t;
                if(t.includes('ERR') || t.includes('fail')) d.className = 'text-red-400 border-l-2 border-red-500 pl-2 bg-red-400/10 rounded-r';
                else if(t.includes('WARN')) d.className = 'text-yellow-400 border-l-2 border-yellow-500 pl-2 bg-yellow-400/10 rounded-r';
                else d.className = 'text-slate-300 border-l-2 border-transparent pl-2 hover:bg-slate-800/50 rounded-r transition-colors';
                d.classList.add(t.includes('ERR')||t.includes('fail') ? 'log-error' : (t.includes('WARN')?'log-warn':'log-info'));
                const c = $('#logs-container');
                c.appendChild(d);
                if(c.children.length > 200) c.removeChild(c.firstChild);
                c.scrollTop = c.scrollHeight;
                if(window.logFilter) applyFilter(d);
            };
        }
        window.logFilter = 'all';
        function setLogFilter(f) { 
            window.logFilter = f; 
            document.querySelectorAll('#logs-container div').forEach(applyFilter); 
            ['all','warn','error'].forEach(id => { $(`#btn-log-${id}`).classList.remove('bg-slate-700', 'text-white'); if(id === 'all') $(`#btn-log-${id}`).classList.add('text-slate-300'); });
            $(`#btn-log-${f}`).classList.add('bg-slate-700', 'text-white');
        }
        function applyFilter(d) {
            if(window.logFilter === 'all') d.style.display = 'block';
            else d.style.display = d.classList.contains('log-'+window.logFilter) ? 'block' : 'none';
        }
    </script>
    <style>.label { display: block; font-size: 11px; font-weight: 700; color: #94a3b8; text-transform: uppercase; margin-bottom: 6px; letter-spacing: 0.05em; } .input { width: 100%; background: #0f172a; border: 1px solid #334155; color: white; padding: 8px 12px; border-radius: 8px; font-size: 13px; transition: border-color 0.15s ease-in-out; } .input:focus { border-color: #3b82f6; ring: 2px solid #3b82f630; outline: none; } .input.disabled { opacity: 0.5; cursor: not-allowed; background-color: #1e293b; }</style>
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

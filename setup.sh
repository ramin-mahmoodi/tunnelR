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
    
    echo "Creating Lite Dashboard Assets (v3.5.0)..."

    cat <<'EOF' > "$DASH_DIR/index.html"
<!DOCTYPE html>
<html class="dark" lang="en">
<head>
    <meta charset="utf-8"/>
    <meta content="width=device-width, initial-scale=1.0" name="viewport"/>
    <title>TunnelR Lite</title>
    <script src="https://cdn.tailwindcss.com?plugins=forms"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/js-yaml@4.1.0/dist/js-yaml.min.js"></script>
    <style>
        /* Lite Theme: Solid Colors, High Contrast, Performance Focused */
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
        .card { background-color: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; box-shadow: 0 1px 2px 0 rgba(0,0,0,0.05); }
        .view { display: none; }
        .view.active { display: block; }
        
        /* Custom Scrollbar */
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-body); }
        ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: #475569; }

        /* Icon sizing */
        .icon { width: 20px; height: 20px; fill: currentColor; }
        
        /* Spinner */
        .loader { border: 2px solid #334155; border-top: 2px solid var(--accent); border-radius: 50%; width: 16px; height: 16px; animation: spin 1s linear infinite; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body class="h-screen flex overflow-hidden">

    <!-- Sidebar -->
    <aside class="w-64 bg-nav border-r border-slate-700 flex flex-col z-20 hidden md:flex" style="background-color: var(--bg-nav);">
        <div class="p-4 flex items-center gap-3 border-b border-slate-700">
            <div class="w-8 h-8 bg-blue-500 rounded flex items-center justify-center text-white font-bold">T</div>
            <h1 class="font-bold text-lg tracking-tight text-white">TunnelR <span class="text-xs font-normal text-blue-400 bg-blue-900/30 px-1 py-0.5 rounded">Lite</span></h1>
        </div>

        <nav class="flex-1 px-2 space-y-1 mt-4">
            <button onclick="setView('dash')" id="nav-dash" class="nav-item w-full flex items-center gap-3 px-3 py-2 rounded text-sm font-medium transition-colors text-white bg-blue-600">
                <!-- Dashboard Icon -->
                <svg class="icon" viewBox="0 0 24 24"><path d="M3 13h8V3H3v10zm0 8h8v-6H3v6zm10 0h8V11h-8v10zm0-18v6h8V3h-8z"/></svg>
                Overview
            </button>
            <button onclick="setView('logs')" id="nav-logs" class="nav-item w-full flex items-center gap-3 px-3 py-2 rounded text-sm font-medium text-slate-400 hover:bg-slate-700 hover:text-white transition-colors">
                <!-- Logs Icon -->
                <svg class="icon" viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                Real-time Logs
            </button>
            <button onclick="setView('settings')" id="nav-settings" class="nav-item w-full flex items-center gap-3 px-3 py-2 rounded text-sm font-medium text-slate-400 hover:bg-slate-700 hover:text-white transition-colors">
                <!-- Settings Icon -->
                <svg class="icon" viewBox="0 0 24 24"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.488.488 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.04.17 0 .34.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.58 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.04-.17 0-.34-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>
                Configuration
            </button>
        </nav>
        
        <div class="p-4 text-xs text-slate-500 border-t border-slate-700">
            v<span id="version-disp">3.5.0</span>
        </div>
    </aside>

    <!-- Main Content -->
    <main class="flex-1 flex flex-col min-w-0 overflow-hidden bg-slate-900">
        <!-- Top Bar -->
        <header class="h-14 border-b border-slate-700 flex items-center justify-between px-6 bg-slate-800">
            <h2 class="text-lg font-semibold text-white" id="page-title">Overview</h2>
            <div class="flex items-center gap-4">
                <span class="text-xs font-mono text-slate-400">UPTIME: <span id="uptime-val" class="text-white">00:00:00</span></span>
            </div>
        </header>

        <div class="flex-1 overflow-y-auto p-6 space-y-6">
            
            <!-- VIEW: DASHBOARD -->
            <div id="view-dash" class="view active">
                <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-6">
                    <!-- Stat Cards -->
                    <div class="card p-4">
                        <div class="text-slate-400 text-xs font-bold uppercase">CPU Usage</div>
                        <div class="text-2xl font-bold text-white mt-1"><span id="cpu-val">0</span>%</div>
                        <div class="w-full bg-slate-700 h-1 mt-2 rounded overflow-hidden"><div id="cpu-bar" class="bg-blue-500 h-full" style="width:0%"></div></div>
                    </div>
                    <div class="card p-4">
                        <div class="text-slate-400 text-xs font-bold uppercase">RAM Usage</div>
                        <div class="text-2xl font-bold text-white mt-1"><span id="ram-val">0</span></div>
                        <div class="text-xs text-slate-500 mt-1">System Memory</div>
                    </div>
                    <div class="card p-4">
                        <div class="text-slate-400 text-xs font-bold uppercase">Load Avg</div>
                        <div class="text-2xl font-bold text-white mt-1" id="load-val">0.00</div>
                        <div class="text-xs text-slate-500 mt-1 font-mono" id="load-full">1m 5m 15m</div>
                    </div>
                    <div class="card p-4">
                        <div class="text-slate-400 text-xs font-bold uppercase">Sessions</div>
                        <div class="text-2xl font-bold text-white mt-1" id="sess-count">0</div>
                        <div class="text-xs text-slate-500 mt-1">Active Connections</div>
                    </div>
                </div>

                <!-- Traffic Chart -->
                <div class="card p-4 mb-6">
                    <div class="flex justify-between items-center mb-4">
                        <h3 class="text-sm font-bold text-white uppercase">Traffic</h3>
                        <div class="flex gap-4 text-xs font-mono">
                            <span class="text-blue-400">â†‘ <span id="speed-up">0 B/s</span></span>
                            <span class="text-emerald-400">â†“ <span id="speed-down">0 B/s</span></span>
                        </div>
                    </div>
                    <div class="h-64 w-full">
                        <canvas id="trafficChart"></canvas>
                    </div>
                </div>
            </div>

            <!-- VIEW: LOGS -->
            <div id="view-logs" class="view">
                <div class="card flex flex-col h-[calc(100vh-140px)]">
                    <div class="p-3 border-b border-slate-700 flex justify-between bg-slate-800 rounded-t">
                        <span class="font-bold text-xs uppercase text-slate-400">System Logs</span>
                        <div class="flex gap-2">
                            <button onclick="setLogFilter('all')" class="text-xs text-white hover:text-blue-400">All</button>
                            <button onclick="setLogFilter('warn')" class="text-xs text-yellow-400 hover:text-white">Warn</button>
                            <button onclick="setLogFilter('error')" class="text-xs text-red-400 hover:text-white">Error</button>
                        </div>
                    </div>
                    <div id="logs-container" class="flex-1 overflow-y-auto p-4 font-mono text-xs text-slate-300 space-y-1 bg-[#0d1117]">
                        <div class="text-center text-slate-500 mt-10">Waiting for logs...</div>
                    </div>
                </div>
            </div>

            <!-- VIEW: SETTINGS -->
            <div id="view-settings" class="view">
                <div class="flex justify-between items-center mb-6">
                    <h3 class="text-xl font-bold text-white">Full Configuration</h3>
                    <button onclick="saveConfig()" class="bg-blue-600 hover:bg-blue-500 text-white px-4 py-2 rounded text-sm font-bold shadow">Save & Restart</button>
                </div>

                <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
                    <!-- General -->
                    <div class="card p-5 space-y-4">
                        <h4 class="text-xs font-bold text-blue-400 uppercase border-b border-slate-700 pb-2">General</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><label class="label">Mode</label><input disabled id="f-mode" class="input disabled"></div>
                            <div><label class="label">Transport</label><select id="f-transport" class="input">
                                <option value="httpmux">httpmux</option><option value="httpsmux">httpsmux</option>
                                <option value="tcpmux">tcpmux</option><option value="wsmux">wsmux</option><option value="wssmux">wssmux</option>
                            </select></div>
                            <div><label class="label">Listen Addr</label><input id="f-listen" class="input"></div>
                            <div><label class="label">PSK (Secret)</label><input type="password" id="f-psk" class="input"></div>
                        </div>
                    </div>

                    <!-- TLS & Mimic -->
                    <div class="card p-5 space-y-4">
                        <h4 class="text-xs font-bold text-blue-400 uppercase border-b border-slate-700 pb-2">TLS / Mimicry</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><label class="label">Cert File</label><input id="f-cert" class="input"></div>
                            <div><label class="label">Key File</label><input id="f-key" class="input"></div>
                            <div><label class="label">Fake Domain</label><input id="f-domain" class="input"></div>
                            <div><label class="label">User Agent</label><input id="f-ua" class="input text-xs"></div>
                        </div>
                    </div>

                    <!-- Smux & Obfuscation -->
                    <div class="card p-5 space-y-4">
                        <h4 class="text-xs font-bold text-blue-400 uppercase border-b border-slate-700 pb-2">Smux & Obfuscation</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><label class="label">Smux Ver</label><input type="number" id="f-smux-ver" class="input"></div>
                            <div><label class="label">KeepAlive</label><input type="number" id="f-smux-ka" class="input"></div>
                            <div><label class="label">Max Stream</label><input type="number" id="f-smux-stream" class="input"></div>
                            <div><label class="label">Max Recv</label><input type="number" id="f-smux-recv" class="input"></div>
                            <div class="col-span-2 flex items-center gap-4 mt-2">
                                <label class="flex items-center gap-2 text-sm text-slate-300"><input type="checkbox" id="f-obfs-en" class="rounded bg-slate-800 border-slate-600"> Enable Obfs</label>
                                <input placeholder="Min Pad" type="number" id="f-obfs-min" class="input w-24">
                                <input placeholder="Max Pad" type="number" id="f-obfs-max" class="input w-24">
                            </div>
                        </div>
                    </div>

                    <!-- Advanced -->
                    <div class="card p-5 space-y-4">
                        <h4 class="text-xs font-bold text-blue-400 uppercase border-b border-slate-700 pb-2">Advanced Network</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><label class="label">TCP Buffer</label><input type="number" id="f-tcp-buf" class="input"></div>
                            <div><label class="label">TCP KeepAlive</label><input type="number" id="f-tcp-ka" class="input"></div>
                            <div class="col-span-2">
                                <label class="flex items-center gap-2 text-sm text-slate-300"><input type="checkbox" id="f-nodelay" class="rounded bg-slate-800 border-slate-600"> TCP NoDelay</label>
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
        
        // --- VIEW LOGIC ---
        function setView(id) {
            document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
            document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('bg-blue-600', 'text-white'));
            document.querySelectorAll('.nav-item').forEach(n => n.classList.add('text-slate-400'));
            
            $(`#view-${id}`).classList.add('active');
            const nav = $(`#nav-${id}`);
            nav.classList.remove('text-slate-400', 'hover:bg-slate-700');
            nav.classList.add('bg-blue-600', 'text-white');
            
            if(id === 'logs') initLogs();
            if(id === 'settings') loadConfig();
        }

        // --- STATS LOOP ---
        setInterval(async () => {
            try {
                const res = await fetch('/api/stats');
                const data = await res.json();
                
                $('#cpu-val').innerText = data.cpu.toFixed(1);
                $('#cpu-bar').style.width = Math.min(data.cpu, 100) + '%';
                $('#ram-val').innerText = data.ram;
                $('#uptime-val').innerText = data.uptime.split('.')[0];
                $('#version-disp').innerText = data.version;
                $('#sess-count').innerText = data.stats.total_conns;
                
                if(data.load_avg) {
                    $('#load-val').innerText = data.load_avg[0];
                    $('#load-full').innerText = data.load_avg.join('  ');
                }

                // Traffic (Server-calculated)
                const up = humanBytes(data.stats.speed_up || 0);
                const down = humanBytes(data.stats.speed_down || 0);
                $('#speed-up').innerText = up + '/s';
                $('#speed-down').innerText = down + '/s';

                updateChart(data.stats.speed_down || 0, data.stats.speed_up || 0);

            } catch(e) {/* quiet */}
        }, 1000);

        function updateChart(rx, tx) {
            if(!chart) {
                const ctx = $('#trafficChart').getContext('2d');
                chart = new Chart(ctx, {
                    type: 'line',
                    data: {
                        labels: Array(30).fill(''),
                        datasets: [
                            { label: 'DL', data: Array(30).fill(0), borderColor: '#10b981', borderWidth: 2, pointRadius:0, tension: 0.1 },
                            { label: 'UL', data: Array(30).fill(0), borderColor: '#3b82f6', borderWidth: 2, pointRadius:0, tension: 0.1 }
                        ]
                    },
                    options: { responsive: true, maintainAspectRatio: false, scales: { x:{display:false}, y:{display:false, min:0} }, plugins: { legend:{display:false} }, animation: false }
                });
            }
            // Add new data
            chart.data.datasets[0].data.push(rx);
            chart.data.datasets[1].data.push(tx);
            chart.data.datasets[0].data.shift();
            chart.data.datasets[1].data.shift();
            chart.update();
        }

        function humanBytes(b) {
            const u = ['B', 'KB', 'MB', 'GB'];
            let i=0;
            while(b >= 1024 && i < u.length-1) { b/=1024; i++; }
            return b.toFixed(1) + ' ' + u[i];
        }

        // --- CONFIG LOADER ---
        async function loadConfig() {
            const t = await (await fetch('/api/config')).text();
            config = jsyaml.load(t);
            if(!config) return;

            // Map fields (Flat + Nested)
            setVal('mode', config.mode);
            setVal('transport', config.transport);
            setVal('listen', config.listen);
            setVal('psk', config.psk);
            setVal('cert', config.cert_file);
            setVal('key', config.key_file);
            
            // Nested
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

        function setVal(id, val) {
            const el = $(`#f-${id}`);
            if(el) el.value = (val !== undefined && val !== null) ? val : '';
        }

        async function saveConfig() {
            if(!confirm('Apply changes and restart?')) return;
            
            // Read back
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
            config.advanced.tcp_write_buffer = parseInt($('#f-tcp-buf').value); // sync
            config.advanced.tcp_keepalive = parseInt($('#f-tcp-ka').value);
            config.advanced.tcp_nodelay = $('#f-nodelay').checked;

            const yaml = jsyaml.dump(config);
            try {
                const r = await fetch('/api/config', { method:'POST', body: yaml });
                if(r.ok) {
                    await fetch('/api/restart', { method:'POST' });
                    alert('Restarting...');
                    setTimeout(()=>location.reload(), 3000);
                } else {
                    const txt = await r.text();
                    alert('Error: '+txt);
                }
            } catch(e) { alert(e); }
        }

        // --- LOGS ---
        let logSrc;
        function initLogs() {
            if(logSrc) return;
            $('#logs-container').innerHTML = '';
            logSrc = new EventSource('/api/logs/stream');
            logSrc.onmessage = e => {
                const d = document.createElement('div');
                const t = e.data;
                d.textContent = t;
                if(t.includes('ERR') || t.includes('fail')) d.className = 'text-red-400';
                else if(t.includes('WARN')) d.className = 'text-yellow-400';
                
                // Add class for filtering
                d.classList.add(t.includes('ERR')||t.includes('fail') ? 'log-error' : (t.includes('WARN')?'log-warn':'log-info'));
                
                const c = $('#logs-container');
                c.appendChild(d);
                if(c.children.length > 200) c.removeChild(c.firstChild);
                c.scrollTop = c.scrollHeight;
                
                // Apply current filter
                if(window.logFilter) applyFilter(d);
            };
        }
        
        window.logFilter = 'all';
        function setLogFilter(f) { window.logFilter = f; document.querySelectorAll('#logs-container div').forEach(applyFilter); }
        function applyFilter(d) {
            if(window.logFilter === 'all') d.style.display = 'block';
            else d.style.display = d.classList.contains('log-'+window.logFilter) ? 'block' : 'none';
        }
    </script>
    <style>.label { display: block; font-size: 11px; font-weight: 700; color: #94a3b8; text-transform: uppercase; margin-bottom: 4px; } .input { width: 100%; background: #0f172a; border: 1px solid #334155; color: white; padding: 6px 10px; border-radius: 4px; font-size: 13px; } .input:focus { border-color: #3b82f6; outline: none; } .input.disabled { opacity: 0.5; cursor: not-allowed; }</style>
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
  listen: "0.0.0.0:8080"
  user: "${DASH_USER}"
  pass: "${DASH_PASS}"
  session_secret: "${SESSION_SECRET}"
EOF
        echo -e "${GREEN}[OK] Dashboard configured.${NC}"
        
        read -p "Restart service now? [Y/n]: " r
        if [[ ! "$r" =~ ^[Nn]$ ]]; then
            systemctl restart "$SVC"
            echo -e "${GREEN}[OK] Service restarted.${NC}"
            echo -e "Access at: http://YOUR_IP:8080"
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

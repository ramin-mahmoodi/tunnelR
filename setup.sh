#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# PicoTun — Dagger-Compatible Reverse Tunnel
# Setup Script (bash <(curl -s https://raw.githubusercontent.com/ramin-mahmoodi/tunnelR/main/setup.sh))
# ═══════════════════════════════════════════════════════════════

SCRIPT_VERSION="3.4.1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

BINARY_NAME="picotun"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/picotun"
SYSTEMD_DIR="/etc/systemd/system"

GITHUB_REPO="ramin-mahmoodi/tunnelR"
# Use 'latest' endpoint to rigidly respect the user's "Latest Release" on GitHub
LATEST_RELEASE_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

# ───────────── Banner & Checks ─────────────

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║           TunnelR (PicoTun)           ║"
    echo "  ║          Script v${SCRIPT_VERSION}          ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${PURPLE}GitHub: github.com/${GITHUB_REPO}${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ This script must be run as root${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${YELLOW}📦 Installing dependencies...${NC}"
    if command -v apt &>/dev/null; then
        apt update -qq 2>/dev/null
        apt install -y wget curl tar openssl iproute2 > /dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y wget curl tar openssl iproute > /dev/null 2>&1
    fi
    echo -e "${GREEN}✓ Dependencies ready${NC}"
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo -e "${RED}❌ Unsupported architecture: $ARCH${NC}"; exit 1 ;;
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

# ───────────── Download Binary ─────────────

download_binary() {
    echo -e "${YELLOW}⬇️  Downloading PicoTun...${NC}"
    mkdir -p "$INSTALL_DIR"
    detect_arch

    echo -e "${CYAN}🔍 Fetching latest release...${NC}"
    # Parse tag_name from the specific 'latest' release object
    LATEST_VERSION=$(curl -s "$LATEST_RELEASE_API" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}⚠️  Could not fetch version, trying v1.8.8${NC}"
        LATEST_VERSION="v1.8.8"
    fi

    TAR_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_VERSION}/picotun-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
    echo -e "${CYAN}📦 Version: ${GREEN}${LATEST_VERSION}${CYAN} (${ARCH})${NC}"

    # Backup
    [ -f "$INSTALL_DIR/$BINARY_NAME" ] && cp "$INSTALL_DIR/$BINARY_NAME" "$INSTALL_DIR/${BINARY_NAME}.bak"

    TMP_DIR=$(mktemp -d)
    if wget -q --show-progress "$TAR_URL" -O "$TMP_DIR/picotun.tar.gz"; then
        tar -xzf "$TMP_DIR/picotun.tar.gz" -C "$TMP_DIR"
        mv "$TMP_DIR/picotun" "$INSTALL_DIR/$BINARY_NAME"
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        rm -rf "$TMP_DIR"
        rm -f "$INSTALL_DIR/${BINARY_NAME}.bak"
        echo -e "${GREEN}✓ PicoTun ${LATEST_VERSION} installed${NC}"
    else
        rm -rf "$TMP_DIR"
        # Restore backup
        [ -f "$INSTALL_DIR/${BINARY_NAME}.bak" ] && mv "$INSTALL_DIR/${BINARY_NAME}.bak" "$INSTALL_DIR/$BINARY_NAME"
        echo -e "${RED}✖ Download failed${NC}"
        exit 1
    fi
}

# ───────────── SSL Certificate ─────────────

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
    echo -e "${GREEN}✓ SSL certificate generated${NC}"
}

# ───────────── Systemd Service ─────────────

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
    echo -e "${GREEN}✓ Service ${SERVICE_NAME} created${NC}"
}

# ───────────── System Optimizer ─────────────

optimize_system() {
    echo -e "${YELLOW}⚙️  Optimizing system...${NC}"

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
    echo -e "${GREEN}✓ System optimized (BBR + buffer tuning)${NC}"
}

# ───────────── Port Mapping Parser ─────────────

parse_port_mappings() {
    MAPPINGS=""
    COUNT=0

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}         PORT MAPPINGS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Format:${NC}"
    echo -e "  ${GREEN}Single${NC}:    8443              → 8443→8443"
    echo -e "  ${GREEN}Range${NC}:     1000/2000         → 1000→1000 ... 2000→2000"
    echo -e "  ${GREEN}Custom${NC}:    5000=8443         → 5000→8443"
    echo -e "  ${GREEN}Range Map${NC}: 1000/1010=2000/2010"
    echo ""

    BIND_IP="0.0.0.0"
    TARGET_IP="127.0.0.1"

    while true; do
        echo ""
        echo -e "${YELLOW}━━━ Port Mapping #$((COUNT+1)) ━━━${NC}"

        echo -e "${CYAN}Protocol:${NC}  1) tcp  2) udp  3) both"
        read -p "Choice [1-3]: " proto_choice
        case $proto_choice in
            1) PROTO="tcp" ;; 2) PROTO="udp" ;; 3) PROTO="both" ;; *) PROTO="tcp" ;;
        esac

        echo -e "${YELLOW}Examples: 8443 | 1000/2000 | 5000=8443${NC}"
        read -p "Port(s): " PORT_INPUT

        [ -z "$PORT_INPUT" ] && { echo -e "${RED}⚠ Empty!${NC}"; continue; }
        PORT_INPUT=$(echo "$PORT_INPUT" | tr -d ' ')

        # Range Map: 1000/1010=2000/2010
        if [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)=([0-9]+)/([0-9]+)$ ]]; then
            BS=${BASH_REMATCH[1]}; BE=${BASH_REMATCH[2]}; TS=${BASH_REMATCH[3]}; TE=${BASH_REMATCH[4]}
            BR=$((BE-BS+1)); TR=$((TE-TS+1))
            [ "$BR" -ne "$TR" ] && { echo -e "${RED}Range mismatch!${NC}"; continue; }
            for ((i=0; i<BR; i++)); do
                add_mapping "$PROTO" "${BIND_IP}:$((BS+i))" "${TARGET_IP}:$((TS+i))"
            done
            echo -e "${GREEN}✓ Added $BR mappings ($PROTO)${NC}"

        # Range: 1000/2000
        elif [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            SP=${BASH_REMATCH[1]}; EP=${BASH_REMATCH[2]}
            for ((p=SP; p<=EP; p++)); do
                add_mapping "$PROTO" "${BIND_IP}:${p}" "${TARGET_IP}:${p}"
            done
            echo -e "${GREEN}✓ Added $((EP-SP+1)) mappings ($PROTO)${NC}"

        # Custom: 5000=8443
        elif [[ "$PORT_INPUT" =~ ^([0-9]+)=([0-9]+)$ ]]; then
            add_mapping "$PROTO" "${BIND_IP}:${BASH_REMATCH[1]}" "${TARGET_IP}:${BASH_REMATCH[2]}"
            echo -e "${GREEN}✓ ${BASH_REMATCH[1]} → ${BASH_REMATCH[2]} ($PROTO)${NC}"

        # Single: 8443
        elif [[ "$PORT_INPUT" =~ ^[0-9]+$ ]]; then
            add_mapping "$PROTO" "${BIND_IP}:${PORT_INPUT}" "${TARGET_IP}:${PORT_INPUT}"
            echo -e "${GREEN}✓ ${PORT_INPUT} → ${PORT_INPUT} ($PROTO)${NC}"

        else
            echo -e "${RED}⚠ Invalid format!${NC}"; continue
        fi

        read -p "Add another? [y/N]: " more
        [[ ! "$more" =~ ^[Yy]$ ]] && break
    done

    [ "$COUNT" -eq 0 ] && {
        echo -e "${YELLOW}⚠ No ports! Adding 8080→8080 default${NC}"
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

# ───────────── System Optimization ─────────────

optimize_system() {
    echo -e "${CYAN}🚀 Optimizing System Network Stack...${NC}"
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
    echo -e "${GREEN}✓ System optimized for high throughput${NC}"
}

# ───────────── Install Server (Automatic) ─────────────

install_server_auto() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}   AUTOMATIC SERVER CONFIGURATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
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
    echo "  1) httpsmux  - HTTPS Mimicry ⭐ Recommended"
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
        ufw allow 8080/tcp >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=${LISTEN_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=8080/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ Server installed & running!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
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

# ───────────── Install Client (Automatic) ─────────────

install_client_auto() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}   AUTOMATIC CLIENT CONFIGURATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    while true; do
        read -sp "PSK (must match server): " PSK; echo
        [ -n "$PSK" ] && break
        echo -e "${RED}PSK cannot be empty!${NC}"
    done

    echo ""
    echo -e "${YELLOW}Transport (must match server):${NC}"
    echo "  1) httpsmux  - HTTPS Mimicry ⭐"
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
        ufw allow 8080/tcp >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=8080/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ Client installed & running!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
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

# ───────────── Install Server (Manual) ─────────────

install_server_manual() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}   MANUAL SERVER CONFIGURATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    echo -e "${YELLOW}Transport:${NC}"
    echo "  1) tcpmux    - TCP Multiplexing"
    echo "  2) wsmux     - WebSocket"
    echo "  3) wssmux    - WebSocket Secure (TLS)"
    echo "  4) httpmux   - HTTP Mimicry (DPI bypass)"
    echo "  5) httpsmux  - HTTPS Mimicry ⭐"
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
  listen: "0.0.0.0:8080"

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
        ufw allow 8080/tcp >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=${LISTEN_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=8080/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo ""
    echo -e "${GREEN}✓ Server installed! Port=${LISTEN_PORT} Transport=${TRANSPORT}${NC}"
    echo -e "  Logs: journalctl -u picotun-server -f"
    read -p "Press Enter..."
    main_menu
}

# ───────────── Install Server (Entry) ─────────────

install_server() {
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}        SERVER INSTALLATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Automatic - Optimized (Recommended)"
    echo "  2) Manual - Custom settings"
    echo ""
    read -p "Choice [1-2]: " cm
    [ "$cm" == "2" ] && install_server_manual || install_server_auto
}

# ───────────── Install Client (Entry) ─────────────

install_client() {
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}        CLIENT INSTALLATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    install_client_auto
}

# ───────────── Dashboard Config ─────────────


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
                        "primary": "#137fec",
                        "background-light": "#f6f7f8",
                        "background-dark": "#0f1115",
                        "surface-dark": "#161b22",
                        "accent-green": "#00ff9d",
                    },
                    fontFamily: { "display": ["Inter", "sans-serif"] },
                },
            },
        }
    </script>
    <style>
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: #334155; border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: #475569; }
        body { font-family: 'Inter', sans-serif; }
        .glass-card {
            background: rgba(22, 27, 34, 0.7);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.05);
        }
        .view { display: none; }
        .view.active { display: block; }
        #logs-out { background: #000; color: #4ade80; font-family: monospace; height: 500px; overflow-y: auto; padding: 1rem; border-radius: 0.5rem; font-size: 13px; }
        textarea { background: #0b0e14 !important; color: #e2e8f0; border: 1px solid #30363d; font-family: monospace; width: 100%; height: 500px; padding: 1rem; border-radius: 0.5rem; outline: none; }
    </style>
</head>
<body class="bg-background-light dark:bg-background-dark text-slate-900 dark:text-slate-100 font-display transition-colors duration-300">
    <div class="flex h-screen overflow-hidden">
        <!-- Sidebar -->
        <aside id="sidebar" class="fixed inset-y-0 left-0 z-50 w-64 bg-background-light dark:bg-[#0a0c10] border-r border-slate-200 dark:border-slate-800 flex flex-col transform -translate-x-full md:relative md:translate-x-0 transition-transform duration-300 ease-in-out md:flex">
            <div class="p-6 flex items-center justify-between">
                <div class="flex items-center gap-3">
                    <div class="w-10 h-10 bg-primary rounded-lg flex items-center justify-center text-white shadow-lg shadow-primary/20">
                        <span class="material-symbols-outlined">subway</span>
                    </div>
                    <div>
                        <h1 class="text-lg font-bold tracking-tight">TunnelR <span class="text-primary">Pro</span></h1>
                        <p class="text-xs text-slate-500 font-medium uppercase tracking-wider">v3.3.0</p>
                    </div>
                </div>
                <button class="md:hidden text-slate-500" onclick="toggleSidebar()">
                    <span class="material-symbols-outlined">close</span>
                </button>
            </div>
            <nav class="flex-1 px-4 space-y-1">
                <a onclick="setView('dash')" id="nav-dash" class="nav-item active flex items-center gap-3 px-3 py-2.5 bg-primary/10 text-primary rounded-lg font-medium transition-colors cursor-pointer">
                    <span class="material-symbols-outlined text-[22px]">dashboard</span>
                    <span>Dashboard</span>
                </a>
                <a onclick="setView('tunnels')" id="nav-tunnels" class="nav-item flex items-center gap-3 px-3 py-2.5 text-slate-500 hover:text-primary hover:bg-primary/5 rounded-lg font-medium transition-colors cursor-pointer">
                    <span class="material-symbols-outlined text-[22px]">hub</span>
                    <span>Tunnel Status</span>
                </a>
                <a onclick="setView('logs')" id="nav-logs" class="nav-item flex items-center gap-3 px-3 py-2.5 text-slate-500 hover:text-primary hover:bg-primary/5 rounded-lg font-medium transition-colors cursor-pointer">
                    <span class="material-symbols-outlined text-[22px]">terminal</span>
                    <span>Logs</span>
                </a>
                <a onclick="setView('settings')" id="nav-settings" class="nav-item flex items-center gap-3 px-3 py-2.5 text-slate-500 hover:text-primary hover:bg-primary/5 rounded-lg font-medium transition-colors cursor-pointer">
                    <span class="material-symbols-outlined text-[22px]">settings</span>
                    <span>Settings</span>
                </a>
            </nav>
        </aside>

        <!-- Overlay for mobile -->
        <div id="sidebar-overlay" onclick="toggleSidebar()" class="fixed inset-0 bg-black/50 z-40 hidden md:hidden"></div>

        <!-- Main Content -->
        <main class="flex-1 flex flex-col min-w-0 overflow-hidden">
            <header class="h-16 flex-shrink-0 flex items-center justify-between px-4 md:px-8 bg-background-light dark:bg-background-dark/50 border-b border-slate-200 dark:border-slate-800 backdrop-blur-md z-10">
                <div class="flex items-center gap-4">
                    <button class="md:hidden p-2 text-slate-500" onclick="toggleSidebar()">
                        <span class="material-symbols-outlined">menu</span>
                    </button>
                    <h2 class="text-lg md:text-xl font-bold tracking-tight" id="page-title">Dashboard Overview</h2>
                    <span id="health-badge" class="bg-accent-green/10 text-accent-green px-2.5 py-0.5 rounded-full text-[10px] md:text-xs font-bold border border-accent-green/20">System Online</span>
                </div>
                <div class="flex items-center gap-4">
                    <button class="p-2 text-slate-500 hover:text-primary transition-colors" onclick="location.reload()">
                        <span class="material-symbols-outlined">refresh</span>
                    </button>
                </div>
            </header>

            <div class="flex-1 overflow-y-auto p-4 md:p-8 space-y-6">
                <!-- DASHBOARD VIEW -->
                <div id="view-dash" class="view active">
                    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-6">
                        <div class="glass-card rounded-xl p-6">
                            <p class="text-sm font-medium text-slate-500 mb-1">Active Routines</p>
                            <h3 class="text-3xl font-bold tracking-tight" id="cpu-val">...</h3>
                        </div>
                        <div class="glass-card rounded-xl p-6">
                            <p class="text-sm font-medium text-slate-500 mb-1">RAM Usage</p>
                            <h3 class="text-3xl font-bold tracking-tight" id="ram-val">...</h3>
                        </div>
                        <div class="glass-card rounded-xl p-6">
                            <p class="text-sm font-medium text-slate-500 mb-1">Uptime</p>
                            <h3 class="text-3xl font-bold tracking-tight tabular-nums" id="uptime-val">...</h3>
                        </div>
                        <div class="glass-card rounded-xl p-6">
                            <p class="text-sm font-medium text-slate-500 mb-1">Latency</p>
                            <h3 class="text-3xl font-bold tracking-tight"><span id="ping-val">--</span><span class="text-lg text-slate-400 font-medium">ms</span></h3>
                        </div>
                    </div>
                    <div class="glass-card rounded-xl p-6">
                        <div class="h-64 w-full relative">
                            <canvas id="trafficChart"></canvas>
                        </div>
                    </div>
                </div>

                <!-- TUNNELS VIEW -->
                <div id="view-tunnels" class="view">
                    <div class="glass-card rounded-xl p-6 overflow-hidden">
                        <table class="w-full text-left border-collapse">
                            <thead>
                                <tr class="bg-slate-50/50 dark:bg-surface-dark/50 text-slate-500 uppercase text-[10px] tracking-widest font-bold">
                                    <th class="px-6 py-3">Peer/ID</th>
                                    <th class="px-6 py-3">Streams</th>
                                    <th class="px-6 py-3">Status</th>
                                    <th class="px-6 py-3">Age/Details</th>
                                </tr>
                            </thead>
                            <tbody id="sessions-table" class="divide-y divide-slate-800"></tbody>
                        </table>
                    </div>
                </div>

                <!-- LOGS VIEW -->
                <div id="view-logs" class="view">
                    <div class="glass-card rounded-xl p-6">
                        <div class="flex justify-between items-center mb-4">
                            <h3 class="text-lg font-bold">Live Logs</h3>
                            <select id="log-filter" onchange="runLogFilter()" class="bg-slate-900 border border-slate-700 rounded-lg px-3 py-1 text-sm text-slate-300">
                                <option value="all">All</option>
                                <option value="error">Errors</option>
                                <option value="warn">Warnings</option>
                            </select>
                        </div>
                        <div id="logs-out">Connecting...</div>
                    </div>
                </div>

                <!-- SETTINGS VIEW -->
                <div id="view-settings" class="view">
                    <div class="flex items-center justify-between mb-6">
                        <h3 class="text-lg font-bold">Configuration</h3>
                        <div class="flex gap-2">
                             <button onclick="toggleEditMode()" class="px-3 py-1.5 text-sm font-medium text-slate-600 bg-slate-100 dark:bg-slate-800 dark:text-slate-300 rounded-lg" id="toggle-btn">Advanced Editor</button>
                             <button onclick="saveConfig()" class="px-3 py-1.5 text-sm font-bold text-white bg-primary rounded-lg shadow-lg">Save & Restart</button>
                        </div>
                    </div>
                    <div id="cfg-form" class="space-y-4">
                        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                            <div><label class="text-xs font-bold text-slate-500">Listen</label><input type="text" id="f-listen" class="w-full mt-1 bg-slate-800 border-none rounded-lg text-white"></div>
                            <div><label class="text-xs font-bold text-slate-500">PSK</label><input type="password" id="f-psk" class="w-full mt-1 bg-slate-800 border-none rounded-lg text-white"></div>
                        </div>
                        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                            <div><label class="text-xs font-bold text-slate-500">Profile</label><select id="f-profile" class="w-full mt-1 bg-slate-800 border-none rounded-lg text-white"><option value="balanced">Balanced</option><option value="aggressive">Aggressive</option><option value="latency">Latency</option></select></div>
                            <div><label class="text-xs font-bold text-slate-500">Transport</label><input type="text" id="f-transport" class="w-full mt-1 bg-slate-800 border-none rounded-lg text-white"></div>
                        </div>
                    </div>
                    <textarea id="config-editor" class="hidden" spellcheck="false"></textarea>
                </div>
            </div>
        </main>
    </div>

<script>
    const $ = s => document.querySelector(s);
    let chartInstance = null;
    let lastStats = null;
    let currentConfig = null;
    let logEventSource = null;

    function setView(id) {
        document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
        document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('bg-primary/10', 'text-primary'));
        $(`#view-${id}`).classList.add('active');
        $(`#nav-${id}`).classList.add('bg-primary/10', 'text-primary');
        const titles = {dash:'Overview', tunnels:'Tunnels', logs:'Logs', settings:'Settings'};
        $('#page-title').innerText = titles[id];
        if(id === 'logs') initLogs();
        if(id === 'settings') loadConfig();
        if(window.innerWidth < 768) toggleSidebar(); 
    }

    function toggleSidebar() {
        const s = $('#sidebar');
        const o = $('#sidebar-overlay');
        const open = s.classList.contains('translate-x-0');
        if(open) {
            s.classList.remove('translate-x-0');
            s.classList.add('-translate-x-full');
            o.classList.add('hidden');
        } else {
            s.classList.add('translate-x-0');
            s.classList.remove('-translate-x-full');
            o.classList.remove('hidden');
        }
    }

    function initChart() {
        const ctx = $('#trafficChart').getContext('2d');
        chartInstance = new Chart(ctx, {
            type: 'line', data: { labels: Array(30).fill(''), datasets: [
                { label: 'Up', data: Array(30).fill(0), borderColor: '#137fec', tension:0.4, pointRadius:0, fill:true, backgroundColor:'rgba(19,127,236,0.1)' },
                { label: 'Down', data: Array(30).fill(0), borderColor: '#00ff9d', tension:0.4, pointRadius:0, fill:true, backgroundColor:'rgba(0,255,157,0.1)' }
            ]},
            options: { responsive:true, maintainAspectRatio:false, scales: { x:{display:false}, y:{display:false} }, plugins:{legend:{display:false}} }
        });
    }

    function updateUI(data) {
        if(!data) return;
        $('#cpu-val').innerText = data.cpu;
        $('#ram-val').innerText = data.ram;
        $('#uptime-val').innerText = data.uptime.split('.')[0]; 
        const p = data.ping_ms;
        const pEl = $('#ping-val');
        pEl.innerText = p > 0 ? p.toFixed(0) : '--';
        pEl.className = p < 100 ? 'text-accent-green' : (p < 300 ? 'text-yellow-400' : 'text-red-500');

        if(lastStats && chartInstance && data.stats) {
            let up = (data.stats.bytes_sent - lastStats.stats.bytes_sent) / 1024;
            let down = (data.stats.bytes_recv - lastStats.stats.bytes_recv) / 1024;
            if(up < 0) up = 0; if(down < 0) down = 0; 
            
            chartInstance.data.datasets[0].data.shift();
            chartInstance.data.datasets[0].data.push(up);
            chartInstance.data.datasets[1].data.shift();
            chartInstance.data.datasets[1].data.push(down);
            chartInstance.update('none');
        }
        lastStats = data;

        // Tunnel Table
        const sess = data.server ? data.server.sessions : (data.client ? data.client.sessions : []);
        let html = '';
        sess.forEach(s => {
            html += `<tr class="border-b border-slate-800 hover:bg-slate-800/50">
                <td class="px-6 py-4 text-xs font-mono">${s.addr || '#'+s.id}</td>
                <td class="px-6 py-4">${s.streams}</td>
                <td class="px-6 py-4"><span class="px-2 py-0.5 rounded text-[10px] font-bold ${s.closed?'bg-red-500/20 text-red-400':'bg-green-500/20 text-green-400'}">${s.closed?'CLOSED':'ACTIVE'}</span></td>
                <td class="px-6 py-4 text-xs text-slate-500">${s.age || 'Server Session'}</td>
            </tr>`;
        });
        
        if(data.client && data.client.paths) {
            html += `<tr class="bg-primary/5"><td colspan="4" class="px-6 py-2 text-[10px] uppercase font-bold text-primary">Multi-Path Health</td></tr>`;
            data.client.paths.forEach(p => {
                html += `<tr class="text-[11px] border-b border-slate-800 opacity-60">
                    <td class="px-6 py-2">${p.addr}</td>
                    <td class="px-6 py-2">--</td>
                    <td class="px-6 py-2"><span class="${p.rtt_ms < 200 ? 'text-accent-green' : 'text-yellow-400'}">ONLINE</span></td>
                    <td class="px-6 py-2">${p.rtt_ms.toFixed(1)}ms latency</td>
                </tr>`;
            });
        }
        $('#sessions-table').innerHTML = html || '<tr><td colspan="4" class="p-8 text-center text-slate-600">No peers connected</td></tr>';
    }

    function initLogs() {
        if(logEventSource) return;
        $('#logs-out').innerHTML = '';
        logEventSource = new EventSource('/api/logs/stream');
        logEventSource.onmessage = e => {
            const d = document.createElement('div');
            d.className = 'log-item py-0.5';
            d.innerText = e.data;
            const t = e.data.toLowerCase();
            if(t.includes('err') || t.includes('fail')) d.classList.add('text-red-400', 'is-error');
            else if(t.includes('warn')) d.classList.add('text-yellow-400', 'is-warn');
            $('#logs-out').appendChild(d);
            if($('#logs-out').children.length > 500) $('#logs-out').removeChild($('#logs-out').firstChild);
            $('#logs-out').scrollTop = $('#logs-out').scrollHeight;
            runLogFilter();
        };
    }

    function runLogFilter() {
        const val = $('#log-filter').value;
        document.querySelectorAll('.log-item').forEach(el => {
            if(val === 'all') el.style.display = 'block';
            else if(val === 'error') el.style.display = el.classList.contains('is-error') ? 'block' : 'none';
            else if(val === 'warn') el.style.display = (el.classList.contains('is-warn') || el.classList.contains('is-error')) ? 'block' : 'none';
        });
    }

    async function loadConfig() {
        try {
            const r = await fetch('/api/config');
            if(r.status === 401) { location.href = '/login'; return; }
            const txt = await r.text();
            $('#config-editor').value = txt;
            if(typeof jsyaml !== 'undefined') {
                currentConfig = jsyaml.load(txt);
                $('#f-listen').value = currentConfig.listen || '';
                $('#f-psk').value = currentConfig.psk || '';
                $('#f-profile').value = currentConfig.profile || 'balanced';
                $('#f-transport').value = currentConfig.transport || '';
            }
        } catch(e) { console.warn('Config load failed:', e); }
    }

    function toggleEditMode() {
        const adv = $('#config-editor').classList.contains('hidden');
        if(adv) {
            $('#config-editor').classList.remove('hidden');
            $('#cfg-form').classList.add('hidden');
            $('#toggle-btn').innerText = 'Form Editor';
        } else {
            $('#config-editor').classList.add('hidden');
            $('#cfg-form').classList.remove('hidden');
            $('#toggle-btn').innerText = 'Advanced Editor';
            loadConfig();
        }
    }

    async function saveConfig() {
        if(!confirm('Save and Restart?')) return;
        let yaml;
        try {
            if($('#config-editor').classList.contains('hidden')) {
                currentConfig.listen = $('#f-listen').value;
                currentConfig.psk = $('#f-psk').value;
                currentConfig.profile = $('#f-profile').value;
                currentConfig.transport = $('#f-transport').value;
                if(typeof jsyaml === 'undefined') throw new Error('js-yaml not loaded');
                yaml = jsyaml.dump(currentConfig);
            } else {
                yaml = $('#config-editor').value;
            }
            const r = await fetch('/api/config', {method:'POST', body:yaml});
            if(r.status === 401) return location.href = '/login';
            if(!r.ok) throw new Error('Save failed');
            await fetch('/api/restart', {method:'POST'});
            alert('Service restarting...');
            setTimeout(() => location.reload(), 3000);
        } catch(e) { alert('Error: ' + e.message); }
    }

    setInterval(() => {
        fetch('/api/stats').then(r => {
            if(r.status === 401) location.href = '/login'; 
            if(!r.ok) throw new Error(r.status);
            return r.json();
        }).then(data => {
            $('#health-badge').innerText = 'System Online';
            $('#health-badge').className = 'bg-accent-green/10 text-accent-green px-2.5 py-0.5 rounded-full text-xs font-bold border border-accent-green/20';
            updateUI(data);
        }).catch(e => {
            $('#health-badge').innerText = 'Offline';
            $('#health-badge').className = 'bg-red-500/10 text-red-500 px-2.5 py-0.5 rounded-full text-xs font-bold border border-red-500/20';
        });
    }, 1000);

    initChart();
</script>
</body>
</html>
EOF
    
    echo "Dashboard assets overhaul complete (v3.3.0)."
}

dashboard_menu() {
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}     DASHBOARD MANAGEMENT${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
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
        echo -e "${GREEN}✓ Dashboard configured.${NC}"
        
        read -p "Restart service now? [Y/n]: " r
        if [[ ! "$r" =~ ^[Nn]$ ]]; then
            systemctl restart "$SVC"
            echo -e "${GREEN}✓ Service restarted.${NC}"
            echo -e "Access at: http://YOUR_IP:8080"
        fi
        
    elif [ "$c" == "2" ]; then
        # Uninstall
        rm -rf /var/lib/picotun/dashboard
        sed -i '/# DASHBOARD-CONFIG-START/,$d' "$CFG"
        echo -e "${GREEN}✓ Dashboard uninstalled (files removed).${NC}"
        
        read -p "Restart service now? [Y/n]: " r
        if [[ ! "$r" =~ ^[Nn]$ ]]; then
            systemctl restart "$SVC"
            echo -e "${GREEN}✓ Service restarted.${NC}"
        fi
        
    elif [ "$c" == "0" ]; then
        main_menu
        return
    fi

    echo ""
    read -p "Press Enter..."
    dashboard_menu
}

# ───────────── Service Management ─────────────

service_management() {
    local MODE=$1
    local SVC="picotun-${MODE}"
    local CFG="$CONFIG_DIR/${MODE}.yaml"

    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      ${MODE^^} MANAGEMENT${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"

    # Status
    if systemctl is-active "$SVC" &>/dev/null; then
        echo -e "  Status: ${GREEN}● Running${NC}"
    else
        echo -e "  Status: ${RED}● Stopped${NC}"
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
        1) systemctl start "$SVC"; echo -e "${GREEN}✓ Started${NC}"; sleep 1; service_management "$MODE" ;;
        2) systemctl stop "$SVC"; echo -e "${GREEN}✓ Stopped${NC}"; sleep 1; service_management "$MODE" ;;
        3) systemctl restart "$SVC"; echo -e "${GREEN}✓ Restarted${NC}"; sleep 1; service_management "$MODE" ;;
        4) systemctl status "$SVC" --no-pager; read -p "Enter..."; service_management "$MODE" ;;
        5) journalctl -u "$SVC" -f ;;
        6) systemctl enable "$SVC" 2>/dev/null; echo -e "${GREEN}✓ Auto-start enabled${NC}"; sleep 1; service_management "$MODE" ;;
        7) systemctl disable "$SVC" 2>/dev/null; echo -e "${GREEN}✓ Auto-start disabled${NC}"; sleep 1; service_management "$MODE" ;;
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
                echo -e "${GREEN}✓ Deleted${NC}"; sleep 1
            fi
            settings_menu ;;
        0) settings_menu ;;
        *) service_management "$MODE" ;;
    esac
}

# ───────────── Settings Menu ─────────────

settings_menu() {
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}           SETTINGS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
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

# ───────────── Update ─────────────

update_binary() {
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}         UPDATE PICOTUN${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
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
        echo -e "${GREEN}✓ Dashboard updated${NC}"
    fi

    # Restart services if running
    for svc in picotun-server picotun-client; do
        if systemctl is-active "$svc" &>/dev/null; then
            systemctl restart "$svc"
            echo -e "${GREEN}✓ $svc restarted${NC}"
        fi
    done

    echo ""
    read -p "Press Enter..."
    main_menu
}

# ───────────── Uninstall ─────────────

uninstall() {
    show_banner
    echo -e "${RED}═══════════════════════════════════════${NC}"
    echo -e "${RED}         UNINSTALL PICOTUN${NC}"
    echo -e "${RED}═══════════════════════════════════════${NC}"
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

    echo -e "${GREEN}✓ PicoTun uninstalled${NC}"
    exit 0
}

# ───────────── Main Menu ─────────────

main_menu() {
    show_banner

    CUR=$(get_current_version)
    [ "$CUR" != "not-installed" ] && echo -e "  ${CYAN}Version: ${GREEN}${CUR}${NC}\n"

    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}           MAIN MENU${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Install Server (Iran)"
    echo "  2) Install Client (Kharej)"
    echo "  3) Dashboard Panel (Install/Uninstall)"
    echo "  4) Settings (Manage Services)"
    echo "  5) System Optimizer"
    echo "  6) Update PicoTun"
    echo "  7) Uninstall"
    echo ""
    echo "  0) Exit"
    echo ""
    read -p "Choice: " c

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

# ───────────── Entry Point ─────────────

check_root
show_banner
install_dependencies

if [ ! -f "$INSTALL_DIR/$BINARY_NAME" ]; then
    echo -e "${YELLOW}PicoTun not found. Installing...${NC}"
    download_binary
    echo ""
fi

main_menu

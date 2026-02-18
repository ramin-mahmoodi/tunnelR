#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# PicoTun — Dagger-Compatible Reverse Tunnel
# Setup Script (bash <(curl -s https://raw.githubusercontent.com/ramin-mahmoodi/tunnelR/main/setup.sh))
# ═══════════════════════════════════════════════════════════════

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
LATEST_RELEASE_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

# ───────────── Banner & Checks ─────────────

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║           TunnelR (PicoTun)           ║"
    echo "  ║   Dagger-Compatible Architecture      ║"
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
    LATEST_VERSION=$(curl -s "$LATEST_RELEASE_API" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

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
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PicoTun Pro</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root {
    --bg-dark: #0f172a;
    --sidebar-dark: #1e293b;
    --card-dark: #1e293b;
    --text-primary: #f1f5f9;
    --text-secondary: #94a3b8;
    --accent: #3b82f6;
    --success: #10b981;
    --danger: #ef4444;
    --border: #334155;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background-color: var(--bg-dark); color: var(--text-primary); font-family: 'Inter', sans-serif; height: 100vh; display: flex; overflow: hidden; }

/* Sidebar */
.sidebar { width: 260px; background-color: var(--sidebar-dark); border-right: 1px solid var(--border); display: flex; flex-direction: column; padding: 24px; flex-shrink: 0; }
.brand { font-size: 20px; font-weight: 700; color: var(--text-primary); margin-bottom: 40px; display: flex; align-items: center; gap: 12px; }
.brand span { color: var(--accent); }
.nav-item { padding: 12px 16px; border-radius: 8px; color: var(--text-secondary); cursor: pointer; transition: all 0.2s; font-weight: 500; display: flex; align-items: center; gap: 12px; margin-bottom: 4px; }
.nav-item:hover, .nav-item.active { background-color: rgba(59, 130, 246, 0.1); color: var(--accent); }
.nav-item svg { width: 20px; height: 20px; }
.user-profile { margin-top: auto; padding-top: 20px; border-top: 1px solid var(--border); display: flex; align-items: center; gap: 12px; }
.user-avatar { width: 40px; height: 40px; background: var(--accent); border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: bold; color: white; }
.user-info div:first-child { font-weight: 600; font-size: 14px; }
.user-info div:last-child { font-size: 12px; color: var(--text-secondary); }

/* Main Content */
.main { flex: 1; overflow-y: auto; padding: 32px; }
.header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 32px; }
.page-title { font-size: 24px; font-weight: 700; }
.badge { background: rgba(16, 185, 129, 0.1); color: var(--success); padding: 6px 12px; border-radius: 20px; font-size: 12px; font-weight: 600; display: flex; align-items: center; gap: 6px; }

/* Grid */
.stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 24px; margin-bottom: 32px; }
.card { background-color: var(--card-dark); border-radius: 16px; padding: 24px; border: 1px solid var(--border); }
.card-label { font-size: 14px; color: var(--text-secondary); margin-bottom: 8px; font-weight: 500; }
.card-value { font-size: 32px; font-weight: 700; color: var(--text-primary); }
.card-sub { font-size: 12px; color: var(--text-secondary); margin-top: 8px; display: flex; align-items: center; gap: 6px; }
.up { color: var(--success); }

/* Chart */
.chart-section { background: var(--card-dark); border-radius: 16px; padding: 24px; border: 1px solid var(--border); margin-bottom: 32px; }
.chart-header { display: flex; justify-content: space-between; margin-bottom: 20px; }
.chart-container { height: 350px; position: relative; }

/* Table */
.table-section { background: var(--card-dark); border-radius: 16px; border: 1px solid var(--border); overflow: hidden; }
.table-header { padding: 20px 24px; border-bottom: 1px solid var(--border); font-weight: 600; display: flex; justify-content: space-between; align-items: center; }
table { width: 100%; border-collapse: collapse; }
th { text-align: left; padding: 16px 24px; color: var(--text-secondary); font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; border-bottom: 1px solid var(--border); }
td { padding: 16px 24px; border-bottom: 1px solid var(--border); font-size: 14px; }
tr:last-child td { border-bottom: none; }
.status-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; margin-right: 6px; }
.online { background-color: var(--success); box-shadow: 0 0 8px rgba(16, 185, 129, 0.4); }

/* Views */
.view { display: none; }
.view.active { display: block; }
textarea { width: 100%; height: 500px; background: #0f172a; border: 1px solid var(--border); color: #f8fafc; padding: 16px; border-radius: 8px; font-family: monospace; resize: none; margin-top: 20px; outline: none; }
.btn-primary { background: var(--accent); color: white; border: none; padding: 10px 20px; border-radius: 8px; font-weight: 600; cursor: pointer; transition: 0.2s; }
.btn-primary:hover { filter: brightness(110%); }
#logs-container { height: 500px; background: #000; padding: 16px; border-radius: 8px; overflow-y: auto; font-family: monospace; font-size: 13px; color: #4ade80; line-height: 1.5; }
</style>
</head>
<body>

<div class="sidebar">
    <div class="brand">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#3b82f6" stroke-width="2"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
        PicoTun <span>Pro</span>
    </div>
    <div class="nav-item active" onclick="setView('dash')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg>
        Dashboard
    </div>
    <div class="nav-item" onclick="setView('tunnels')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
        Tunnels
    </div>
    <div class="nav-item" onclick="setView('logs')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg>
        System Logs
    </div>
    <div class="nav-item" onclick="setView('settings')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>
        Settings
    </div>
    
    <div class="user-profile">
        <div class="user-avatar">A</div>
        <div class="user-info">
            <div>Admin User</div>
            <div>Premium Plan</div>
        </div>
    </div>
</div>

<div class="main">
    <!-- DASHBOARD VIEW -->
    <div id="view-dash" class="view active">
        <div class="header">
            <div class="page-title">Dashboard Overview</div>
            <div class="badge"><span class="status-dot online"></span> System Healthy</div>
        </div>

        <div class="stats-grid">
            <div class="card">
                <div class="card-label">CPU Usage</div>
                <div class="card-value" id="cpu-val">...%</div>
                <div class="card-sub"><span class="up">Currently Active</span></div>
            </div>
            <div class="card">
                <div class="card-label">RAM Usage</div>
                <div class="card-value" id="ram-val">...</div>
                <div class="card-sub" id="ram-total">of 16GB Total</div>
            </div>
            <div class="card">
                <div class="card-label">System Uptime</div>
                <div class="card-value" id="uptime-val">...</div>
                <div class="card-sub">Since last reboot</div>
            </div>
        </div>

        <div class="chart-section">
            <div class="chart-header">
                <h3>Traffic Overview</h3>
                <div style="font-size:12px; color:var(--text-secondary)">Real-time throughput</div>
            </div>
            <div class="chart-container">
                <canvas id="trafficChart"></canvas>
            </div>
        </div>

        <div class="table-section">
            <div class="table-header">
                <div>Active Tunnels</div>
                <div style="font-size:12px; color:#3b82f6; cursor:pointer">Manage All</div>
            </div>
            <table id="tunnels-table">
                <thead>
                    <tr>
                        <th>Protocol</th>
                        <th>Endpoint</th>
                        <th>Connections</th>
                        <th>Status</th>
                        <th>Latency</th>
                    </tr>
                </thead>
                <tbody id="sessions-body">
                   <!-- Populated by JS -->
                </tbody>
            </table>
        </div>
    </div>

    <!-- TUNNELS VIEW -->
    <div id="view-tunnels" class="view">
        <div class="header"><div class="page-title">Tunnels</div></div>
        <div class="table-section">
            <table>
                 <thead><tr><th>ID</th><th>Type</th><th>Dest</th><th>Uptime</th><th>Status</th></tr></thead>
                 <tbody id="all-tunnels-body"></tbody>
            </table>
        </div>
    </div>

    <!-- LOGS VIEW -->
    <div id="view-logs" class="view">
        <div class="header"><div class="page-title">System Logs</div></div>
        <div id="logs-container">Connecting to stream...</div>
    </div>

    <!-- SETTINGS VIEW -->
    <div id="view-settings" class="view">
        <div class="header">
            <div class="page-title">Configuration</div>
            <button class="btn-primary" onclick="saveConfig()">Save & Restart</button>
        </div>
        <textarea id="config-editor"></textarea>
    </div>
</div>

<script>
const $ = s => document.querySelector(s);
let chartInstance = null;
let lastBytesSent = 0;
let lastBytesRecv = 0;

function setView(id) {
    document.querySelectorAll('.view').forEach(el => el.classList.remove('active'));
    document.getElementById('view-'+id).classList.add('active');
    document.querySelectorAll('.nav-item').forEach(el => el.classList.remove('active'));
    event.currentTarget.classList.add('active');
    
    if(id === 'logs') startLogStream();
    if(id === 'settings') loadConfig();
}

function initChart() {
    const ctx = document.getElementById('trafficChart').getContext('2d');
    const gradientTx = ctx.createLinearGradient(0, 0, 0, 300);
    gradientTx.addColorStop(0, 'rgba(59, 130, 246, 0.4)');
    gradientTx.addColorStop(1, 'rgba(59, 130, 246, 0.0)');
    
    const gradientRx = ctx.createLinearGradient(0, 0, 0, 300);
    gradientRx.addColorStop(0, 'rgba(16, 185, 129, 0.4)');
    gradientRx.addColorStop(1, 'rgba(16, 185, 129, 0.0)');

    chartInstance = new Chart(ctx, {
        type: 'line',
        data: {
            labels: Array(30).fill(''),
            datasets: [
                {
                    label: 'Upload',
                    data: Array(30).fill(0),
                    borderColor: '#3b82f6',
                    backgroundColor: gradientTx,
                    fill: true,
                    tension: 0.4,
                    borderWidth: 2,
                    pointRadius: 0
                },
                {
                    label: 'Download',
                    data: Array(30).fill(0),
                    borderColor: '#10b981',
                    backgroundColor: gradientRx,
                    fill: true,
                    tension: 0.4,
                    borderWidth: 2,
                    pointRadius: 0
                }
            ]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: { mode: 'index', intersect: false },
            scales: {
                x: { display: false },
                y: { 
                    border: { display: false }, 
                    grid: { color: '#334155' },
                    ticks: { color: '#94a3b8' }
                }
            },
            plugins: { legend: { labels: { color: '#f1f5f9' } } }
        }
    });
}

function updateStats(data) {
    if(!data) return;
    
    // CPU/RAM - Mock CPU since Go runtime doesn't expose easily
    $('#cpu-val').innerText = (Math.random() * 15 + 5).toFixed(1) + '%';
    $('#ram-val').innerText = data.ram;
    $('#uptime-val').innerText = data.uptime_s ? formatUptime(data.uptime_s) : data.uptime;
    
    // Traffic
    const currentSent = data.stats.bytes_sent || 0;
    const currentRecv = data.stats.bytes_recv || 0;
    
    if(lastBytesSent > 0) {
        const deltaSent = (currentSent - lastBytesSent) / 1024; // KB
        const deltaRecv = (currentRecv - lastBytesRecv) / 1024;
        
        chartInstance.data.datasets[0].data.shift();
        chartInstance.data.datasets[0].data.push(deltaSent);
        chartInstance.data.datasets[1].data.shift();
        chartInstance.data.datasets[1].data.push(deltaRecv);
        chartInstance.update('none');
    }
    lastBytesSent = currentSent;
    lastBytesRecv = currentRecv;

    // Table
    const tbody = $('#sessions-body');
    let html = '';
    
    // Server mode active connections
    if(data.stats.active_conns > 0) {
        html += `<tr>
            <td><span style="background:#3b82f6;padding:2px 6px;border-radius:4px;font-size:10px;color:#fff">TCP</span></td>
            <td>Client Pool</td>
            <td>${data.stats.active_conns} Active</td>
            <td><span class="status-dot online"></span>Online</td>
            <td style="color:#10b981">--</td>
        </tr>`;
    }

    // Client Sessions
    if(data.client && data.client.sessions) {
        data.client.sessions.forEach(s => {
            html += `<tr>
                <td><span style="background:#8b5cf6;padding:2px 6px;border-radius:4px;font-size:10px;color:#fff">MUX</span></td>
                <td>Session #${s.id}</td>
                <td>${s.streams} Streams</td>
                <td><span class="status-dot online"></span>Active</td>
                <td style="color:#10b981">${s.age}</td>
            </tr>`;
        });
    }
    
    if(html === '') html = '<tr><td colspan="5" style="text-align:center;color:#64748b;padding:20px">No active tunnels found</td></tr>';
    tbody.innerHTML = html;
}

function formatUptime(seconds) {
    const d = Math.floor(seconds / (3600*24));
    const h = Math.floor(seconds % (3600*24) / 3600);
    const m = Math.floor(seconds % 3600 / 60);
    return `${d}d ${h}h ${m}m`;
}

// Stats Poller
setInterval(() => {
    fetch('/api/stats').then(r => {
        if(r.status===401) location.reload();
        return r.json();
    }).then(updateStats).catch(console.error);
}, 1000);

// Logs
let es = null;
function startLogStream() {
    if(es) return;
    const el = $('#logs-container');
    el.innerText = '';
    es = new EventSource('/api/logs/stream');
    es.onmessage = e => {
        el.innerText += e.data + '\n';
        el.scrollTop = el.scrollHeight;
    }
}

// Config
async function loadConfig() {
    const r = await fetch('/api/config');
    $('#config-editor').value = await r.text();
}
async function saveConfig() {
   if(!confirm('Restart service?')) return;
   await fetch('/api/config', {method:'POST', body: $('#config-editor').value});
   await fetch('/api/restart', {method:'POST'});
   alert('Restarting...');
   setTimeout(()=>location.reload(), 3000);
}

// Init
initChart();
loadConfig(); // Preload config
</script>
</body>
</html>
EOF
    
    echo "Dashboard assets installed successfully."
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

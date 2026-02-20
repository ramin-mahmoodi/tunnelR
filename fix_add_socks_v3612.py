import os

# FILES
config_file = r"C:\GGNN\RsTunnel-main\config.go"
client_file = r"C:\GGNN\RsTunnel-main\client.go"
main_file = r"C:\GGNN\RsTunnel-main\cmd\picotun\main.go"

# 1. MODIFY CONFIG.GO
with open(config_file, 'r', encoding='utf-8') as f:
    config_code = f.read()

# Add SocksListen field
if 'SocksListen' not in config_code:
    config_code = config_code.replace(
        'Compression   string `yaml:"compression"`',
        'Compression   string `yaml:"compression"`\n\tSocksListen   string `yaml:"socks_listen"` // v3.6.12: Local SOCKS5 Listener'
    )

# Add default logic in applyBaseDefaults
if 'c.SocksListen = "127.0.0.1:1080"' not in config_code:
    injection = r'''	if c.Mode == "client" && c.SocksListen == "" {
		c.SocksListen = "127.0.0.1:1080"
	}
'''
    # Insert before applyProfile call
    config_code = config_code.replace('applyProfile(&c)', injection + '\tapplyProfile(&c)')

with open(config_file, 'w', encoding='utf-8') as f:
    f.write(config_code)
print("Updated config.go with SocksListen")


# 2. MODIFY CLIENT.GO
with open(client_file, 'r', encoding='utf-8') as f:
    client_code = f.read()

# Add imports
if '"encoding/binary"' not in client_code:
    client_code = client_code.replace(
        '"context"',
        '"context"\n\t"encoding/binary"\n\t"errors"'
    )

# Add StartSocks and handleSocks methods
socks_logic = r'''
// ───────────── SOCKS5 Server (v3.6.12) ─────────────

// StartSocks starts the SOCKS5 TCP listener.
func (c *Client) StartSocks(ctx context.Context) error {
	addr := c.cfg.SocksListen
	if addr == "" {
		addr = "127.0.0.1:1080"
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("socks listen %s: %w", addr, err)
	}
	log.Printf("[SOCKS5] Listening on %s", addr)

	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			continue
		}
		go c.handleSocks(conn)
	}
}

func (c *Client) handleSocks(conn net.Conn) {
	defer conn.Close()

	// Set handshake timeout
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))

	// 1. Version negotiation
	// Client sends: [VER, NMETHODS, METHODS...]
	buf := make([]byte, 258)
	if _, err := io.ReadAtLeast(conn, buf[:2], 2); err != nil {
		return
	}
	ver := buf[0]
	nmethods := int(buf[1])
	if ver != 5 {
		return // Only SOCKS5
	}
	if _, err := io.ReadFull(conn, buf[:nmethods]); err != nil {
		return
	}

	// Server reply: [VER, METHOD] -> [0x05, 0x00] (No Auth)
	// We assume No Auth for local proxy usage.
	conn.Write([]byte{0x05, 0x00})

	// 2. Request details
	// Client sends: [VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT]
	if _, err := io.ReadFull(conn, buf[:4]); err != nil {
		return
	}
	cmd := buf[1]
	atyp := buf[3]

	if cmd != 1 { // CONNECT only
		// Reply Command Not Supported
		conn.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	var host string
	switch atyp {
	case 1: // IPv4
		if _, err := io.ReadFull(conn, buf[:4]); err != nil {
			return
		}
		host = net.IP(buf[:4]).String()
	case 3: // Domain
		if _, err := io.ReadFull(conn, buf[:1]); err != nil {
			return
		}
		domainLen := int(buf[0])
		if _, err := io.ReadFull(conn, buf[:domainLen]); err != nil {
			return
		}
		host = string(buf[:domainLen])
	case 4: // IPv6
		if _, err := io.ReadFull(conn, buf[:16]); err != nil {
			return
		}
		host = "[" + net.IP(buf[:16]).String() + "]"
	default:
		return
	}

	// Port
	if _, err := io.ReadFull(conn, buf[:2]); err != nil {
		return
	}
	port := binary.BigEndian.Uint16(buf[:2])

	target := fmt.Sprintf("tcp://%s:%d", host, port)
	
	// Clear deadline
	conn.SetReadDeadline(time.Time{})

	// 3. Open Stream
	if c.verbose {
		log.Printf("[SOCKS] connecting to %s", target)
	}

	stream, err := c.OpenStream(target)
	if err != nil {
		log.Printf("[SOCKS] failed to connect %s: %v", target, err)
		// Reply Host Unreachable
		conn.Write([]byte{0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer stream.Close()

	// Reply Success
	// BIND.ADDR/PORT is 0.0.0.0:0 (we don't bind locally)
	conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})

	// 4. Relay
	relay(conn, stream)
}
'''
if 'StartSocks' not in client_code:
    client_code = client_code + '\n' + socks_logic

with open(client_file, 'w', encoding='utf-8') as f:
    f.write(client_code)
print("Updated client.go with SOCKS5 logic")


# 3. MODIFY MAIN.GO
with open(main_file, 'r', encoding='utf-8') as f:
    main_code = f.read()

# Add cl.StartSocks(ctx)
if 'cl.StartSocks' not in main_code:
    main_code = main_code.replace(
        'go func() { errCh <- cl.Start(ctx) }()',
        'go func() { errCh <- cl.Start(ctx) }()\n\t\tgo func() { errCh <- cl.StartSocks(ctx) }()'
    )

with open(main_file, 'w', encoding='utf-8') as f:
    f.write(main_code)
print("Updated main.go to start SOCKS listener")

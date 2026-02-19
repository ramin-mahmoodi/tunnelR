import os

# FILES
crypto_file = r"C:\GGNN\RsTunnel-main\encrypted_conn.go"

# 1. OPTIMIZE ENCRYPTED CONN (encrypted_conn.go)
# Rewrite Write() and addPadding() to use buffer pools
new_write_func = r'''func (c *EncryptedConn) Write(data []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	// 1. Get buffer for PADDED PLAINTEXT (Src)
	srcBufPtr := globalBufPool.Get().(*[]byte)
	defer globalBufPool.Put(srcBufPtr)
	
	var payload []byte
	
	// ① Padding BEFORE encryption (Zero-Alloc)
	if c.obfs != nil && c.obfs.Enabled {
		// Use srcBuf as scratch space for padding
		// Format: [2B len][data][padding]
		payload = addPaddingBuf(data, c.obfs, *srcBufPtr)
	} else {
		payload = data
	}

	// ② Encrypt
	if c.gcm != nil {
		nonce := make([]byte, c.gcm.NonceSize())
		if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
			return 0, fmt.Errorf("nonce: %w", err)
		}

		// 2. Get buffer for CIPHERTEXT (Dst)
		dstBufPtr := globalBufPool.Get().(*[]byte)
		defer globalBufPool.Put(dstBufPtr)
		buf := *dstBufPtr

		// Layout: [4B len][12B nonce][ciphertext+tag]
		copy(buf[4:], nonce)
		
		// Encrypt payload -> append to buf
		encrypted := c.gcm.Seal(buf[4+len(nonce):4+len(nonce)], nonce, payload, nil)
		pktLen := len(nonce) + len(encrypted)

		binary.BigEndian.PutUint32(buf[:4], uint32(pktLen))
		if _, err := c.conn.Write(buf[:4+pktLen]); err != nil {
			return 0, err
		}
	} else {
		// No encryption
		dstBufPtr := globalBufPool.Get().(*[]byte)
		defer globalBufPool.Put(dstBufPtr)
		buf := *dstBufPtr

		pktLen := len(payload)
		binary.BigEndian.PutUint32(buf[:4], uint32(pktLen))
		copy(buf[4:], payload)

		if _, err := c.conn.Write(buf[:4+pktLen]); err != nil {
			return 0, err
		}
	}

	// ③ Jitter
	if c.obfs != nil && c.obfs.Enabled && c.obfs.MaxDelayMS > 0 && len(data) > 128 {
		obfsDelay(c.obfs)
	}

	return len(data), nil
}'''

new_add_padding = r'''// addPaddingBuf writes padded data into the provided buffer to avoid allocation.
func addPaddingBuf(data []byte, obfs *ObfsConfig, buf []byte) []byte {
	padLen := obfs.MinPadding
	diff := obfs.MaxPadding - obfs.MinPadding
	if diff > 0 {
		padLen += secureRandInt(diff)
	}
	
	totalLen := 2 + len(data) + padLen
	if totalLen > len(buf) {
		// Fallback if pool buffer is too small (rare)
		out := make([]byte, totalLen)
		binary.BigEndian.PutUint16(out[:2], uint16(len(data)))
		copy(out[2:], data)
		return out // Padding is zeroed by make
	}

	out := buf[:totalLen]
	binary.BigEndian.PutUint16(out[:2], uint16(len(data)))
	copy(out[2:], data)
	
	if padLen > 0 {
		paddingArea := out[2+len(data):]
		rand.Read(paddingArea)
		// Decoy injection
		if padLen > 12 {
			decoyStr := decoyPatterns[secureRandInt(len(decoyPatterns))]
			if len(decoyStr) < padLen {
				maxOffset := padLen - len(decoyStr)
				offset := secureRandInt(maxOffset + 1)
				copy(paddingArea[offset:], []byte(decoyStr))
			}
		}
	}
	return out
}'''

with open(crypto_file, 'r', encoding='utf-8') as f:
    code = f.read()

# Replace Write
import re
code = re.sub(r'func \(c \*EncryptedConn\) Write.*?return len\(data\), nil\n}', new_write_func, code, flags=re.DOTALL)

# Replace addPadding
code = re.sub(r'func addPadding.*?return out\n}', new_add_padding, code, flags=re.DOTALL)

# OPTIMIZE READ (Remove make([]byte, 4))
# We can use the readBuf or a small scratch buffer, but local var array is stack allocated (fast).
# var header [4]byte is better than make
new_read_start = r'''func (c *EncryptedConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()

	if len(c.readBuf) > 0 {
		n := copy(p, c.readBuf)
		c.readBuf = c.readBuf[n:]
		return n, nil
	}

	var header [4]byte
	if _, err := io.ReadFull(c.conn, header[:]); err != nil {
		return 0, err
	}
	pktLen := binary.BigEndian.Uint32(header[:])'''

code = re.sub(r'func \(c \*EncryptedConn\) Read.*?pktLen := binary.BigEndian.Uint32\(header\)', new_read_start, code, flags=re.DOTALL)

with open(crypto_file, 'w', encoding='utf-8') as f:
    f.write(code)

print("Crypto pipeline optimized (v3.6.5).")

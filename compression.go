package httpmux

import (
	"io"
	"net"

	"github.com/golang/snappy"
)

// ═══════════════════════════════════════════════════════════════
// CompressedConn — transparent snappy compression wrapper
//
// Sits between EncryptedConn and smux in the pipeline:
//   TCP → Mimicry → Encrypt → Compress → smux
//
// Both sides must use the same compression setting.
// ═══════════════════════════════════════════════════════════════

// CompressedConn wraps a net.Conn with snappy stream compression.
type CompressedConn struct {
	net.Conn
	reader *snappy.Reader
	writer *snappy.Writer
}

// NewCompressedConn wraps conn with snappy compression.
// If algo is empty or "none", returns the original conn (passthrough).
func NewCompressedConn(conn net.Conn, algo string) net.Conn {
	switch algo {
	case "snappy":
		return &CompressedConn{
			Conn:   conn,
			reader: snappy.NewReader(conn),
			writer: snappy.NewBufferedWriter(conn),
		}
	default:
		return conn // passthrough
	}
}

func (c *CompressedConn) Read(b []byte) (int, error) {
	return c.reader.Read(b)
}

func (c *CompressedConn) Write(b []byte) (int, error) {
	n, err := c.writer.Write(b)
	if err != nil {
		return n, err
	}
	// Flush after every write to avoid buffering latency
	if err := c.writer.Flush(); err != nil {
		return n, err
	}
	return n, nil
}

func (c *CompressedConn) Close() error {
	c.writer.Close()
	return c.Conn.Close()
}

// Ensure CompressedConn implements io.ReadWriteCloser
var _ io.ReadWriteCloser = (*CompressedConn)(nil)

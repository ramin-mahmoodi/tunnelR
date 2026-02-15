package httpmux

import (
	"sync/atomic"
	"testing"
)

func TestStats_Snapshot(t *testing.T) {
	s := &Stats{}
	atomic.AddInt64(&s.ActiveConns, 5)
	atomic.AddInt64(&s.TotalConns, 100)
	atomic.AddInt64(&s.BytesSent, 1024*1024)
	atomic.AddInt64(&s.BytesRecv, 2048*1024)

	snap := s.Snapshot()
	if snap.ActiveConns != 5 {
		t.Errorf("ActiveConns: got %d, want 5", snap.ActiveConns)
	}
	if snap.TotalConns != 100 {
		t.Errorf("TotalConns: got %d, want 100", snap.TotalConns)
	}
	if snap.BytesSent != 1024*1024 {
		t.Errorf("BytesSent: got %d, want %d", snap.BytesSent, 1024*1024)
	}
	if snap.BytesRecv != 2048*1024 {
		t.Errorf("BytesRecv: got %d, want %d", snap.BytesRecv, 2048*1024)
	}
}

func TestStats_AtomicConcurrency(t *testing.T) {
	s := &Stats{}
	done := make(chan struct{})

	// Concurrent increments
	for i := 0; i < 100; i++ {
		go func() {
			atomic.AddInt64(&s.TotalConns, 1)
			atomic.AddInt64(&s.BytesSent, 100)
			done <- struct{}{}
		}()
	}
	for i := 0; i < 100; i++ {
		<-done
	}

	if atomic.LoadInt64(&s.TotalConns) != 100 {
		t.Errorf("TotalConns: got %d, want 100", s.TotalConns)
	}
	if atomic.LoadInt64(&s.BytesSent) != 10000 {
		t.Errorf("BytesSent: got %d, want 10000", s.BytesSent)
	}
}

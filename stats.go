package httpmux

import (
	"log"
	"sync/atomic"
	"time"
)

// Stats tracks runtime metrics for the tunnel.
// All fields are safe for concurrent access via atomic operations.
type Stats struct {
	ActiveConns    int64 // currently active relay connections
	TotalConns     int64 // total connections handled
	BytesSent      int64 // total bytes sent
	BytesRecv      int64 // total bytes received
	Reconnects     int64 // total reconnect attempts
	FailedDials    int64 // failed dial attempts
	ActiveSessions int64 // currently active smux sessions
	StartedAt      int64 // unix timestamp of start
}

// GlobalStats is the singleton stats instance.
var GlobalStats Stats

func init() {
	GlobalStats.StartedAt = time.Now().Unix()
}

// Snapshot returns a copy of the current stats.
func (s *Stats) Snapshot() Stats {
	return Stats{
		ActiveConns:    atomic.LoadInt64(&s.ActiveConns),
		TotalConns:     atomic.LoadInt64(&s.TotalConns),
		BytesSent:      atomic.LoadInt64(&s.BytesSent),
		BytesRecv:      atomic.LoadInt64(&s.BytesRecv),
		Reconnects:     atomic.LoadInt64(&s.Reconnects),
		FailedDials:    atomic.LoadInt64(&s.FailedDials),
		ActiveSessions: atomic.LoadInt64(&s.ActiveSessions),
		StartedAt:      s.StartedAt,
	}
}

// LogStats prints a summary of the current metrics.
func (s *Stats) LogStats() {
	snap := s.Snapshot()
	uptime := time.Since(time.Unix(snap.StartedAt, 0)).Round(time.Second)
	log.Printf("[STATS] uptime=%v conns=%d/%d sessions=%d sent=%dMB recv=%dMB reconnects=%d fails=%d",
		uptime,
		snap.ActiveConns, snap.TotalConns,
		snap.ActiveSessions,
		snap.BytesSent/(1024*1024), snap.BytesRecv/(1024*1024),
		snap.Reconnects, snap.FailedDials,
	)
}

// StartStatsLogger starts a background goroutine that logs stats periodically.
func StartStatsLogger(interval time.Duration) {
	if interval <= 0 {
		interval = 60 * time.Second
	}
	go func() {
		tick := time.NewTicker(interval)
		defer tick.Stop()
		for range tick.C {
			GlobalStats.LogStats()
		}
	}()
}

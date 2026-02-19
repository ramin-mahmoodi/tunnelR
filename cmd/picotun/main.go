package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	httpmux "github.com/amir6dev/rstunnel/PicoTun"
)

var version = "3.6.5"

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	configPath := flag.String("config", "/etc/picotun/config.yaml", "path to config file")
	configShort := flag.String("c", "", "alias for -config")
	flag.Parse()

	if *showVersion {
		log.Printf("PicoTun %s (Dagger-compatible architecture)", version)
		return
	}

	cfgPath := *configPath
	if *configShort != "" {
		cfgPath = *configShort
	}

	cfg, err := httpmux.LoadConfig(cfgPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// Start periodic stats logger (every 60s)
	httpmux.StartStatsLogger(60 * time.Second)

	// Graceful shutdown: handle SIGTERM/SIGINT
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Run in a goroutine so we can listen for shutdown signals
	errCh := make(chan error, 1)

	switch strings.ToLower(strings.TrimSpace(cfg.Mode)) {
	case "server":
		srv := httpmux.NewServer(cfg)
		httpmux.StartDashboard(cfg.Dashboard, "server", version, nil, srv)
		go func() { errCh <- srv.Start(ctx) }()

	case "client":
		cl := httpmux.NewClient(cfg)
		httpmux.StartDashboard(cfg.Dashboard, "client", version, cl, nil)
		go func() { errCh <- cl.Start(ctx) }()

	default:
		log.Fatalf("unknown mode: %q (expected server/client)", cfg.Mode)
	}

	select {
	case <-ctx.Done():
		log.Println("[MAIN] received shutdown signal, exiting gracefully...")
		httpmux.GlobalStats.LogStats()
	case err := <-errCh:
		log.Fatalf("[MAIN] fatal error: %v", err)
	}
}

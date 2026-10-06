// Command segue-hub runs the Segue hub next to a media server, configured by environment variables
// (see README.md, "Running").
package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/segue-music/segue/hub"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	fail := func(msg string, args ...any) {
		log.Error(msg, args...)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	upstream := os.Getenv("SEGUE_UPSTREAM")
	devAuth := os.Getenv("SEGUE_AUTH") == "none"
	if upstream == "" && !devAuth {
		fail("SEGUE_UPSTREAM is required (the media server's URL)")
	}
	kind := hub.KindNavidrome // SEGUE_AUTH=none with no media server: nothing to ask
	if upstream != "" {
		var err error
		kind, err = detectUpstream(ctx, log, upstream)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			fail("SEGUE_UPSTREAM is not a Navidrome, Subsonic or Jellyfin server", "upstream", upstream, "err", err)
		}
		log.Info("media server found", "upstream", upstream, "kind", kind)
	}

	var authenticate hub.Authenticator
	var report hub.Reporter
	if devAuth {
		log.Warn("SEGUE_AUTH=none: every device is accepted, as the user it claims. Never expose this.")
		authenticate = hub.DevAuthenticator
	} else {
		authenticate = hub.UpstreamAuthenticator(kind, upstream, 5*time.Minute)
		report = hub.UpstreamReporter(kind, upstream)
	}
	translate := hub.NoTranslation
	if kind == hub.KindNavidrome {
		translate = hub.NavidromeIDs
	}
	h := hub.New(hub.Options{
		Authenticate: authenticate, Translate: translate, Logger: log,
		StatePath: os.Getenv("SEGUE_STATE"), Report: report,
	})

	listener, err := net.Listen("tcp", env("SEGUE_LISTEN", "127.0.0.1:8480"))
	if err != nil {
		fail("can't listen", "err", err)
	}
	server := &http.Server{Handler: h.Handler(map[string]any{"server": kind}), ReadHeaderTimeout: 10 * time.Second}
	log.Info("hub listening", "url", "http://"+listener.Addr().String(), "upstream", upstream, "kind", kind)

	go func() {
		sweep := time.NewTicker(10 * time.Minute)
		defer sweep.Stop()
		for {
			select {
			case <-ctx.Done():
				shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				_ = server.Shutdown(shutdown)
				return
			case <-sweep.C:
				h.Sweep()
			}
		}
	}()
	if err := server.Serve(listener); !errors.Is(err, http.ErrServerClosed) {
		fail("server stopped", "err", err)
	}
	<-ctx.Done() // Serve returns as Shutdown starts; let it finish
	h.Close()
}

// detectUpstream asks the media server what it is until it answers, since it may be starting at
// the same time as the hub. A URL that answers as no media server is an error.
func detectUpstream(ctx context.Context, log *slog.Logger, upstream string) (hub.UpstreamKind, error) {
	wait := time.Second
	for {
		kind, err := hub.DetectUpstream(ctx, upstream)
		if err == nil || errors.Is(err, hub.ErrNotAMediaServer) {
			return kind, err
		}
		log.Warn("media server not answering yet", "upstream", upstream, "err", err, "retryIn", wait)
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(wait):
		}
		wait = min(2*wait, 30*time.Second)
	}
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

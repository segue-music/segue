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

	"github.com/mateusguilherme/segue/hub"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	fail := func(msg string, args ...any) {
		log.Error(msg, args...)
		os.Exit(1)
	}

	kind := hub.UpstreamKind(env("SEGUE_UPSTREAM_KIND", string(hub.KindNavidrome)))
	if kind != hub.KindNavidrome && kind != hub.KindSubsonic && kind != hub.KindJellyfin {
		fail("SEGUE_UPSTREAM_KIND must be navidrome, subsonic or jellyfin", "got", kind)
	}
	upstream := os.Getenv("SEGUE_UPSTREAM")

	var authenticate hub.Authenticator
	if os.Getenv("SEGUE_AUTH") == "none" {
		log.Warn("SEGUE_AUTH=none: every device is accepted, as the user it claims. Never expose this.")
		authenticate = hub.DevAuthenticator
	} else if upstream == "" {
		fail("SEGUE_UPSTREAM is required (the media server's URL)")
	} else {
		authenticate = hub.UpstreamAuthenticator(kind, upstream, 5*time.Minute)
	}
	translate := hub.NoTranslation
	if kind == hub.KindNavidrome {
		translate = hub.NavidromeIDs
	}
	h := hub.New(hub.Options{Authenticate: authenticate, Translate: translate, Logger: log})

	listener, err := net.Listen("tcp", env("SEGUE_LISTEN", "127.0.0.1:8480"))
	if err != nil {
		fail("can't listen", "err", err)
	}
	server := &http.Server{Handler: h.Handler(map[string]any{"server": kind}), ReadHeaderTimeout: 10 * time.Second}
	log.Info("hub listening", "url", "http://"+listener.Addr().String(), "upstream", upstream, "kind", kind)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
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
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

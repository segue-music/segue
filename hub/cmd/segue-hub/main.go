// Command segue-hub runs the Segue hub next to a media server, configured by environment variables
// (see README.md, "Configuration").
package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/url"
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

	mediaServerURL := os.Getenv("SEGUE_MEDIA_SERVER_URL")

	// SEGUE_UPSTREAM was its name until October 2026: a hub set up with it goes on working.
	if old := os.Getenv("SEGUE_UPSTREAM"); mediaServerURL == "" && old != "" {
		log.Warn("SEGUE_UPSTREAM is now called SEGUE_MEDIA_SERVER_URL; the old name will stop working")
		mediaServerURL = old
	}

	devAuth := os.Getenv("SEGUE_AUTH") == "none"
	if mediaServerURL == "" && !devAuth {
		fail("SEGUE_MEDIA_SERVER_URL is required (the media server's URL)")
	}

	kind := hub.KindNavidrome // SEGUE_AUTH=none with no media server: nothing to ask

	if mediaServerURL != "" {
		var err error

		kind, err = detectMediaServer(ctx, log, mediaServerURL)

		if ctx.Err() != nil {
			return
		}

		if err != nil {
			fail("SEGUE_MEDIA_SERVER_URL is not a Navidrome, Subsonic or Jellyfin server", "mediaServer", mediaServerURL, "err", err)
		}

		log.Info("media server found", "mediaServer", mediaServerURL, "kind", kind)
	}

	var authenticate hub.Authenticator
	var report hub.Reporter
	var allowOrigin func(string) bool // nil: any

	if devAuth {
		log.Warn("SEGUE_AUTH=none: every device is accepted, as the user it claims. Never expose this.")
		authenticate = hub.DevAuthenticator
		// Whoever connects is the user they claim, so a page from the web, which a browser would let
		// connect to a hub on the same machine, mustn't: only pages served from this one may, such as
		// an app's development server.
		allowOrigin = loopbackOrigin
	} else {
		authenticate = hub.MediaServerAuthenticator(kind, mediaServerURL, 5*time.Minute)
		report = hub.MediaServerReporter(kind, mediaServerURL)
	}

	translate := hub.NoTranslation

	if kind == hub.KindNavidrome {
		translate = hub.NavidromeIDs
	}

	h := hub.New(hub.Options{
		Authenticate: authenticate, Translate: translate, Logger: log,
		StatePath: os.Getenv("SEGUE_STATE"), Report: report, AllowOrigin: allowOrigin,
	})

	listener, err := net.Listen("tcp", env("SEGUE_LISTEN", "127.0.0.1:8480"))
	if err != nil {
		fail("can't listen", "err", err)
	}

	server := &http.Server{Handler: h.Handler(map[string]any{"server": kind}), ReadHeaderTimeout: 10 * time.Second}

	log.Info("hub listening", "url", "http://"+listener.Addr().String(), "mediaServer", mediaServerURL, "kind", kind)

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

// detectMediaServer asks the media server what it is until it answers, since it may be starting at
// the same time as the hub. A URL that answers as no media server is an error.
func detectMediaServer(ctx context.Context, log *slog.Logger, mediaServerURL string) (hub.MediaServerKind, error) {
	wait := time.Second

	for {
		kind, err := hub.DetectMediaServer(ctx, mediaServerURL)
		if err == nil || errors.Is(err, hub.ErrNotAMediaServer) {
			return kind, err
		}

		log.Warn("media server not answering yet", "mediaServer", mediaServerURL, "err", err, "retryIn", wait)

		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(wait):
		}

		wait = min(2*wait, 30*time.Second)
	}
}

// loopbackOrigin says whether origin, a page's, is served from this machine.
func loopbackOrigin(origin string) bool {
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}

	host := u.Hostname()
	ip := net.ParseIP(host)

	return host == "localhost" || (ip != nil && ip.IsLoopback())
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}

	return fallback
}

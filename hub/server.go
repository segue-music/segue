package hub

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	pingEvery   = 30 * time.Second
	pongWait    = 2 * pingEvery // a device that misses a ping is dropped at the next one
	writeWait   = 10 * time.Second
	closeGrace  = 5 * time.Second // how long to wait for the device's close frame after ours
	sendBuffer  = 64              // messages queued per connection before it counts as stuck
	maxFrameLen = 1 << 20
)

// probeWait is how long a device has to answer the ping of a Probe; a var, for the tests.
var probeWait = 5 * time.Second

// Handler serves the hub: GET /v1/info and the WebSocket at /v1/ws. Both also answer under
// /connect/, where the hub sits on the media server's origin (SPEC.md, "Discovery"), whether or not
// the reverse proxy strips that prefix. Pages in a browser use both from the origins that
// Options.AllowOrigin allows. info adds fields to /v1/info; Handler panics if they don't encode as
// JSON.
func (h *Hub) Handler(info map[string]any) http.Handler {
	fields := map[string]any{}

	for k, v := range info {
		fields[k] = v
	}

	fields["protocol"], fields["versions"] = "segue", []int{ProtocolVersion}
	infoJSON, err := json.Marshal(fields)
	if err != nil {
		panic("hub: the info for /v1/info doesn't encode as JSON: " + err.Error())
	}

	serveInfo := func(w http.ResponseWriter, r *http.Request) {
		h.allowCORS(w, r)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(infoJSON)
	}

	// A browser asks first (a preflight) before a GET with headers of its own, such as an
	// Authorization that its HTTP client adds to every request.
	preflightInfo := func(w http.ResponseWriter, r *http.Request) {
		h.allowCORS(w, r)

		if headers := r.Header.Get("Access-Control-Request-Headers"); headers != "" {
			w.Header().Set("Access-Control-Allow-Headers", headers)
		}

		w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD")
		w.Header().Set("Access-Control-Max-Age", "86400")
		w.Header().Add("Vary", "Access-Control-Request-Headers")
		w.WriteHeader(http.StatusNoContent)
	}

	upgrader := websocket.Upgrader{CheckOrigin: h.allowOrigin}

	serveWS := func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return // Upgrade has already answered with the error
		}

		h.serve(r, ws)
	}

	mux := http.NewServeMux()

	for _, prefix := range []string{"", "/connect"} {
		// GET also takes HEAD, and the mux answers other methods with a 405 and Allow. The
		// WebSocket has no method: Upgrade answers whatever isn't a handshake.
		mux.HandleFunc("GET "+prefix+"/v1/info", serveInfo)
		mux.HandleFunc("OPTIONS "+prefix+"/v1/info", preflightInfo)
		mux.HandleFunc(prefix+"/v1/ws", serveWS)
	}

	return mux
}

// allowOrigin says whether r comes from an app outside a browser, from the hub's own origin, or from
// one that Options.AllowOrigin allows.
func (h *Hub) allowOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" || h.opts.AllowOrigin == nil {
		return true
	}

	u, err := url.Parse(origin)

	return (err == nil && strings.EqualFold(u.Host, r.Host)) || h.opts.AllowOrigin(origin)
}

// allowCORS lets pages from the origins the hub allows read /v1/info, which is public (SPEC.md,
// section 1): any page, without Options.AllowOrigin.
func (h *Hub) allowCORS(w http.ResponseWriter, r *http.Request) {
	if h.opts.AllowOrigin == nil {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		return
	}

	w.Header().Add("Vary", "Origin")

	if origin := r.Header.Get("Origin"); origin != "" && h.allowOrigin(r) {
		w.Header().Set("Access-Control-Allow-Origin", origin)
	}
}

// serve runs one connection: a goroutine writes (messages and pings), this one reads.
func (h *Hub) serve(r *http.Request, ws *websocket.Conn) {
	c := &wsConn{ws: ws, out: make(chan frame, sendBuffer), done: make(chan struct{})}

	go c.writeLoop()

	session := h.Open(c)

	ws.SetReadLimit(maxFrameLen)
	_ = ws.SetReadDeadline(time.Now().Add(pongWait))
	ws.SetPongHandler(func(string) error { return ws.SetReadDeadline(time.Now().Add(pongWait)) })

	for {
		kind, data, err := ws.ReadMessage()
		if err != nil {
			// Before the close, which fails a write under way, whose error would only say that the
			// connection is closed.
			why := c.end(err)

			close(c.done)
			_ = ws.Close()
			session.Closed(why)
			return
		}

		_ = ws.SetReadDeadline(time.Now().Add(pongWait))

		if kind == websocket.TextMessage {
			session.Message(r.Context(), data)
		}
	}
}

// wsConn is the Conn the hub sees: a queue drained by writeLoop, so the hub never blocks on a
// slow device.
type wsConn struct {
	ws       *websocket.Conn
	out      chan frame
	done     chan struct{} // closed when the read side ends
	dropOnce sync.Once

	mu  sync.Mutex
	err error // why the connection ended, from the read, a write or the hub, whichever came first
}

type frame struct {
	data      []byte
	closeCode int // a close frame when not zero
	reason    string
	probe     bool // a ping that the device has probeWait to answer
}

func (c *wsConn) Send(msg any) {
	data, err := json.Marshal(msg)
	if err != nil {
		panic(err) // the hub only sends its own message types, which always marshal
	}

	c.enqueue(frame{data: data})
}

func (c *wsConn) Close(code int, reason string) {
	c.enqueue(frame{closeCode: code, reason: reason})
}

// Probe pings the device after what was sent before, and gives it probeWait to answer, rather than
// pongWait: a device that doesn't is dropped.
func (c *wsConn) Probe() {
	c.enqueue(frame{probe: true})
}

func (c *wsConn) enqueue(f frame) {
	select {
	case <-c.done:
	case c.out <- f:
	default:
		// The device isn't reading: drop it rather than hold up the hub.
		c.dropOnce.Do(func() { c.drop(errors.New("hub: the device isn't reading")) })
	}
}

// end keeps err as why the connection ended, unless it has a reason already, and returns the one
// it keeps: once one side fails, the other only fails with the connection closed.
func (c *wsConn) end(err error) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.err == nil {
		c.err = err
	}

	return c.err
}

// drop closes the connection from the hub's side, err saying why.
func (c *wsConn) drop(err error) {
	c.end(err)
	_ = c.ws.Close()
}

func (c *wsConn) writeLoop() {
	ping := time.NewTicker(pingEvery)
	defer ping.Stop()

	for {
		select {
		case <-c.done:
			return
		case f := <-c.out:
			if f.closeCode != 0 {
				msg := websocket.FormatCloseMessage(f.closeCode, f.reason)
				_ = c.ws.WriteControl(websocket.CloseMessage, msg, time.Now().Add(writeWait))
				// The device answers with its own close frame, which ends the read loop.
				time.AfterFunc(closeGrace, func() { c.drop(errors.New("hub: no close frame back from the device")) })
				return
			}

			if f.probe {
				// The deadline first: a pong that came before it would be undone by it. The pong
				// handler puts pongWait back, and so does any message.
				_ = c.ws.SetReadDeadline(time.Now().Add(probeWait))

				if err := c.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(writeWait)); err != nil {
					c.drop(err)
					return
				}

				continue
			}

			_ = c.ws.SetWriteDeadline(time.Now().Add(writeWait))

			if err := c.ws.WriteMessage(websocket.TextMessage, f.data); err != nil {
				c.drop(err)
				return
			}
		case <-ping.C:
			if err := c.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(writeWait)); err != nil {
				c.drop(err)
				return
			}
		}
	}
}

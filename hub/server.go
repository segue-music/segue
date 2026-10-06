package hub

import (
	"encoding/json"
	"net/http"
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

var upgrader = websocket.Upgrader{
	// Devices sign in inside the connection (hello), not with cookies, so a page from another origin
	// gains nothing by connecting. Accepting any origin lets web players on other origins work.
	CheckOrigin: func(*http.Request) bool { return true },
}

// Handler serves the hub: GET /v1/info and the WebSocket at /v1/ws. Both also answer under
// /connect/, where the hub sits on the media server's origin (SPEC.md, "Discovery"), whether or not
// the reverse proxy strips that prefix. info adds fields to /v1/info; Handler panics if they don't
// encode as JSON.
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

	serveInfo := func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(infoJSON)
	}
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
		mux.HandleFunc(prefix+"/v1/ws", serveWS)
	}
	return mux
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
			break
		}
		_ = ws.SetReadDeadline(time.Now().Add(pongWait))
		if kind == websocket.TextMessage {
			session.Message(r.Context(), data)
		}
	}
	close(c.done)
	_ = ws.Close()
	session.Closed()
}

// wsConn is the Conn the hub sees: a queue drained by writeLoop, so the hub never blocks on a
// slow device.
type wsConn struct {
	ws       *websocket.Conn
	out      chan frame
	done     chan struct{} // closed when the read side ends
	dropOnce sync.Once
}

type frame struct {
	data      []byte
	closeCode int // a close frame when not zero
	reason    string
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

func (c *wsConn) enqueue(f frame) {
	select {
	case <-c.done:
	case c.out <- f:
	default:
		// The device isn't reading: drop it rather than hold up the hub.
		c.dropOnce.Do(func() { _ = c.ws.Close() })
	}
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
				time.AfterFunc(closeGrace, func() { _ = c.ws.Close() })
				return
			}
			_ = c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if c.ws.WriteMessage(websocket.TextMessage, f.data) != nil {
				_ = c.ws.Close()
				return
			}
		case <-ping.C:
			if c.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(writeWait)) != nil {
				_ = c.ws.Close()
				return
			}
		}
	}
}

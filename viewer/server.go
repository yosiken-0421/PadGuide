package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

//go:embed web
var webFS embed.FS

const maxBody = 64 << 10

// Server は PC ビューアーのローカル Web サーバー。
//   - ブラウザ画面（/ と /api/events など）は、この PC 自身（127.0.0.1）からだけ開ける
//   - iPhone 用の API は同じ LAN（プライベートアドレス）からだけ受け付ける
type Server struct {
	auth   *Auth
	hub    *Hub
	lanIP  string
	port   int
	logger *log.Logger
}

func NewServer(auth *Auth, hub *Hub, lanIP string, port int, logger *log.Logger) *Server {
	return &Server{auth: auth, hub: hub, lanIP: lanIP, port: port, logger: logger}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	sub, _ := fs.Sub(webFS, "web")
	static := http.FileServer(http.FS(sub))

	// ---- PC のブラウザ用（ローカルのみ）----
	mux.Handle("/", s.localOnly(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, ".test.cjs") {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		static.ServeHTTP(w, r)
	})))
	mux.Handle("/qr.png", s.localOnly(http.HandlerFunc(s.handleQR)))
	mux.Handle("/api/events", s.localOnly(http.HandlerFunc(s.handleEvents)))
	mux.Handle("/api/disconnect", s.localOnly(s.postOnly(s.handleDisconnect)))
	mux.Handle("/api/rotate", s.localOnly(s.postOnly(func(w http.ResponseWriter, r *http.Request) {
		s.auth.Rotate()
		s.pushStatus()
		w.WriteHeader(http.StatusNoContent)
	})))

	// ---- iPhone 用（同一 LAN のみ）----
	mux.Handle("/api/pair", s.lanOnly(s.postOnly(s.handlePair)))
	mux.Handle("/api/push", s.lanOnly(s.postOnly(s.authed(s.handlePush))))
	mux.Handle("/api/share", s.lanOnly(s.postOnly(s.authed(s.handleShare))))
	mux.Handle("/api/bye", s.lanOnly(s.postOnly(s.authed(s.handleBye))))
	mux.Handle("/api/ping", s.lanOnly(s.authed(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})))
	return securityHeaders(mux)
}

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'")
		h.ServeHTTP(w, r)
	})
}

// ---- アクセス元の確認 ----

func remoteIP(r *http.Request) net.IP {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return nil
	}
	return net.ParseIP(host)
}

// isLANPeer: 同じ LAN（プライベートアドレス・リンクローカル）またはこの PC 自身
func isLANPeer(ip net.IP) bool {
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
}

func (s *Server) lanOnly(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !isLANPeer(remoteIP(r)) {
			http.Error(w, "同じネットワーク内からのみ接続できます", http.StatusForbidden)
			return
		}
		h.ServeHTTP(w, r)
	})
}

// localOnly: この PC 自身からのアクセスで、Host も localhost のものだけ（DNS リバインディング対策）
func (s *Server) localOnly(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := remoteIP(r)
		host := r.Host
		if hh, _, err := net.SplitHostPort(r.Host); err == nil {
			host = hh
		}
		host = strings.Trim(host, "[]")
		if ip == nil || !ip.IsLoopback() || (host != "localhost" && host != "127.0.0.1" && host != "::1") {
			http.Error(w, "この画面はビューアーを起動した PC でのみ開けます", http.StatusForbidden)
			return
		}
		h.ServeHTTP(w, r)
	})
}

func (s *Server) postOnly(f http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			http.Error(w, "POST のみ", http.StatusMethodNotAllowed)
			return
		}
		f(w, r)
	})
}

func (s *Server) authed(f http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !s.auth.Check(tok) {
			http.Error(w, "接続トークンが無効です。もう一度接続してください", http.StatusUnauthorized)
			return
		}
		f(w, r)
	}
}

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		http.Error(w, "データが大きすぎます", http.StatusRequestEntityTooLarge)
		return nil, false
	}
	return b, true
}

// ---- iPhone 用 API ----

type pairRequest struct {
	Token  string `json:"token,omitempty"`
	Code   string `json:"code,omitempty"`
	Device string `json:"device"`
}

func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	b, ok := readBody(w, r)
	if !ok {
		return
	}
	var req pairRequest
	if err := decodeStrict(bytes.NewReader(b), &req); err != nil {
		http.Error(w, "形式が正しくありません", http.StatusBadRequest)
		return
	}
	session, err := s.auth.Pair(req.Token, req.Code, req.Device)
	if err != nil {
		s.pushStatus() // コードを作り直した場合に画面を更新
		http.Error(w, err.Error(), http.StatusUnauthorized)
		return
	}
	s.hub.Discard() // 前の接続のデータは残さない
	s.logger.Printf("iPhone が接続しました（%s）", safeName(req.Device))
	s.pushStatus()
	writeJSON(w, map[string]any{"session": session, "expiresInSec": int(sessionTTL.Seconds())})
}

func (s *Server) handlePush(w http.ResponseWriter, r *http.Request) {
	b, ok := readBody(w, r)
	if !ok {
		return
	}
	m, err := ParseResult(b)
	if err != nil {
		http.Error(w, "解析結果の形式が正しくありません", http.StatusBadRequest)
		return
	}
	s.hub.SetResult(m)
	s.pushStatus()
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleShare(w http.ResponseWriter, r *http.Request) {
	b, ok := readBody(w, r)
	if !ok {
		return
	}
	var m ShareMessage
	if err := decodeStrict(bytes.NewReader(b), &m); err != nil || m.Type != "share" ||
		(m.State != "started" && m.State != "ended") {
		http.Error(w, "形式が正しくありません", http.StatusBadRequest)
		return
	}
	s.hub.SetSharing(m.State == "started")
	if m.State == "ended" {
		s.logger.Printf("画面共有が終了しました（データを破棄しました）")
	} else {
		s.logger.Printf("画面共有が始まりました")
	}
	s.pushStatus()
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleBye(w http.ResponseWriter, r *http.Request) {
	s.auth.Revoke()
	s.hub.Discard()
	s.logger.Printf("iPhone 側で切断されました")
	s.pushStatus()
	w.WriteHeader(http.StatusNoContent)
}

// ---- ブラウザ用 ----

func (s *Server) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	s.auth.Revoke()
	s.hub.Discard()
	s.logger.Printf("切断しました（データを破棄しました）")
	s.pushStatus()
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleQR(w http.ResponseWriter, r *http.Request) {
	p := s.auth.Pairing()
	img, err := QRPNG(s.PairURL(p.Token), 8)
	if err != nil {
		http.Error(w, "QR を作れませんでした", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(img)
}

func (s *Server) PairURL(token string) string {
	return fmt.Sprintf("puzzleroute://pair?h=%s&p=%d&t=%s", s.lanIP, s.port, token)
}

func (s *Server) statusEvent() map[string]any {
	p := s.auth.Pairing()
	connected, device, left := s.auth.SessionInfo()
	_, sharing := s.hub.Snapshot()
	return map[string]any{
		"kind":             "status",
		"connected":        connected,
		"device":           safeName(device),
		"sharing":          sharing && connected,
		"code":             p.Code,
		"codeExpiresIn":    int(p.ExpiresIn.Seconds()),
		"qrVersion":        p.Version,
		"lanIP":            s.lanIP,
		"port":             s.port,
		"sessionExpiresIn": int(left.Seconds()),
	}
}

func (s *Server) pushStatus() { s.hub.Broadcast(s.statusEvent()) }

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "未対応", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	ch := s.hub.Subscribe()
	defer s.hub.Unsubscribe(ch)

	send := func(b []byte) bool {
		if _, err := fmt.Fprintf(w, "data: %s\n\n", b); err != nil {
			return false
		}
		fl.Flush()
		return true
	}
	st, _ := json.Marshal(s.statusEvent())
	if !send(st) {
		return
	}
	if m, _ := s.hub.Snapshot(); m != nil {
		b, _ := json.Marshal(map[string]any{"kind": "result", "data": m})
		send(b)
	}
	tick := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case b, ok := <-ch:
			if !ok || !send(b) {
				return
			}
		case <-tick.C:
			st, _ := json.Marshal(s.statusEvent())
			if !send(st) {
				return
			}
		}
	}
}

// Maintain は期限切れの QR を作り直し、期限切れのセッションのデータを破棄する
func (s *Server) Maintain() {
	wasConnected := false
	for range time.Tick(5 * time.Second) {
		if s.auth.RotateIfExpired() {
			s.pushStatus()
		}
		connected, _, _ := s.auth.SessionInfo()
		if wasConnected && !connected {
			s.hub.Discard()
			s.logger.Printf("接続の有効期限が切れました（データを破棄しました）")
			s.pushStatus()
		}
		wasConnected = connected
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// safeName は表示用に端末名を整える（制御文字を除く）
func safeName(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 0x20 && r != 0x7f {
			b.WriteRune(r)
		}
	}
	out := b.String()
	if len([]rune(out)) > 40 {
		out = string([]rune(out)[:40])
	}
	return out
}

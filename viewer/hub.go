package main

import (
	"encoding/json"
	"sync"
)

// Hub は最新の解析結果と画面共有状態を持ち、ブラウザへ配信する。
// 画像は受け取らない・保存しない。共有終了や切断で破棄する。
type Hub struct {
	mu      sync.Mutex
	latest  *ResultMessage
	sharing bool
	subs    map[chan []byte]struct{}
}

func NewHub() *Hub { return &Hub{subs: map[chan []byte]struct{}{}} }

func (h *Hub) Subscribe() chan []byte {
	h.mu.Lock()
	defer h.mu.Unlock()
	ch := make(chan []byte, 16)
	h.subs[ch] = struct{}{}
	return ch
}

func (h *Hub) Unsubscribe(ch chan []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.subs[ch]; ok {
		delete(h.subs, ch)
		close(ch)
	}
}

func (h *Hub) broadcastLocked(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	for ch := range h.subs {
		select {
		case ch <- b:
		default: // 遅いブラウザは古い通知を捨てる
		}
	}
}

func (h *Hub) Broadcast(v any) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.broadcastLocked(v)
}

func (h *Hub) SetResult(m *ResultMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.latest = m
	h.sharing = true
	h.broadcastLocked(map[string]any{"kind": "result", "data": m})
}

func (h *Hub) SetSharing(on bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sharing = on
	if !on {
		h.latest = nil // 画面共有終了：データを破棄
		h.broadcastLocked(map[string]any{"kind": "cleared"})
	}
}

// Discard はすべてのデータを破棄する（切断・セッション期限切れ）
func (h *Hub) Discard() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.latest = nil
	h.sharing = false
	h.broadcastLocked(map[string]any{"kind": "cleared"})
}

func (h *Hub) Snapshot() (*ResultMessage, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.latest, h.sharing
}

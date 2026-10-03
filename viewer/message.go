package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// ResultMessage は iPhone から届く解析結果（ios/PuzzleCore の ResultMessage と同じ形）。
// 画像などの余計な項目が入っていたら受け付けない。
type ResultMessage struct {
	Type       string      `json:"type"`
	V          int         `json:"v"`
	TS         int64       `json:"ts"`
	Cols       int         `json:"cols"`
	Rows       int         `json:"rows"`
	Cells      []string    `json:"cells"`
	Confidence []float64   `json:"confidence"`
	Status     string      `json:"status"`
	Start      *int        `json:"start,omitempty"`
	End        *int        `json:"end,omitempty"`
	Moves      []string    `json:"moves"`
	Path       []int       `json:"path"`
	Arrows     [][]float64 `json:"arrows"`
	Combos     int         `json:"combos"`
	Cleared    int         `json:"cleared"`
	Steps      int         `json:"steps"`
	ElapsedMs  int         `json:"elapsedMs"`
	Achieved   []string    `json:"achieved"`
	Source     string      `json:"source"`
}

type ShareMessage struct {
	Type  string `json:"type"`
	State string `json:"state"`
	TS    int64  `json:"ts"`
}

var validCells = map[string]bool{
	"fire": true, "water": true, "wood": true, "light": true, "dark": true, "heart": true,
	"jammer": true, "poison": true, "mortal": true, "unknown": true,
}

var validStatus = map[string]bool{"ok": true, "nocombo": true, "unstable": true, "dark": true, "invalid": true}

var validSizes = map[[2]int]bool{{6, 5}: true, {7, 6}: true, {5, 4}: true}

// decodeStrict は未知の項目を拒否して JSON を読む
func decodeStrict(r io.Reader, v any) error {
	d := json.NewDecoder(r)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	if d.More() {
		return errors.New("余分なデータがあります")
	}
	return nil
}

func ParseResult(b []byte) (*ResultMessage, error) {
	var m ResultMessage
	if err := decodeStrict(bytes.NewReader(b), &m); err != nil {
		return nil, err
	}
	return &m, m.Validate()
}

func (m *ResultMessage) Validate() error {
	if m.Type != "result" || m.V != 1 {
		return errors.New("種類が違います")
	}
	if !validSizes[[2]int{m.Cols, m.Rows}] {
		return fmt.Errorf("未対応の盤面サイズ %dx%d", m.Cols, m.Rows)
	}
	n := m.Cols * m.Rows
	if len(m.Cells) != n {
		return errors.New("マス数が合いません")
	}
	for _, c := range m.Cells {
		if !validCells[c] {
			return errors.New("不明なドロップ種類")
		}
	}
	if len(m.Confidence) != 0 && len(m.Confidence) != n {
		return errors.New("信頼度の数が合いません")
	}
	for _, c := range m.Confidence {
		if c < 0 || c > 1 {
			return errors.New("信頼度が範囲外")
		}
	}
	if !validStatus[m.Status] {
		return errors.New("状態が不正")
	}
	if len(m.Moves) > 64 || len(m.Path) > 65 || len(m.Arrows) > 64 || len(m.Achieved) > 16 {
		return errors.New("ルートが長すぎます")
	}
	for _, p := range m.Path {
		if p < 0 || p >= n {
			return errors.New("ルートが盤面外")
		}
	}
	for _, mv := range m.Moves {
		if mv != "U" && mv != "D" && mv != "L" && mv != "R" {
			return errors.New("移動方向が不正")
		}
	}
	for _, a := range m.Arrows {
		if len(a) != 4 {
			return errors.New("矢印の形式が不正")
		}
	}
	if m.Start != nil && (*m.Start < 0 || *m.Start >= n) {
		return errors.New("開始位置が盤面外")
	}
	if m.Source != "iphone" && m.Source != "iphone-manual" {
		return errors.New("送信元が不正")
	}
	return nil
}

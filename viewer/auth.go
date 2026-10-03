package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"sync"
	"time"
)

const (
	pairTTL         = 10 * time.Minute // QR・接続コードの有効期限
	sessionTTL      = 12 * time.Hour   // 接続後のトークンの有効期限
	maxCodeAttempts = 5                // 接続コードの入力ミス上限（超えたら作り直す）
)

var (
	errBadPairing = errors.New("接続情報が正しくないか、有効期限切れです")
	errLocked     = errors.New("入力ミスが多いため接続コードを作り直しました")
)

// Auth は接続トークンを管理する。
// - QR 用のペアリングトークン（128bit）と 6 桁コードは一度使ったら作り直す
// - 接続（ペアリング）するたびに新しいセッショントークン（256bit）を発行し、古いものは無効
// - トークンは画面やログに出さない（QR 画像と接続コードの表示はローカルの PC 画面だけ）
type Auth struct {
	mu           sync.Mutex
	now          func() time.Time
	pairToken    string
	code         string
	pairExpires  time.Time
	codeAttempts int
	version      int // QR を作り直すたびに増える

	session        string
	sessionExpires time.Time
	device         string
}

func NewAuth(now func() time.Time) *Auth {
	a := &Auth{now: now}
	a.rotateLocked()
	return a
}

func randomHex(nBytes int) string {
	b := make([]byte, nBytes)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func randomCode() string {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		panic(err)
	}
	return fmt.Sprintf("%06d", n.Int64())
}

func (a *Auth) rotateLocked() {
	a.pairToken = randomHex(16)
	a.code = randomCode()
	a.pairExpires = a.now().Add(pairTTL)
	a.codeAttempts = 0
	a.version++
}

// Rotate は QR と接続コードを作り直す
func (a *Auth) Rotate() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.rotateLocked()
}

// RotateIfExpired は期限切れなら作り直す。作り直したら true
func (a *Auth) RotateIfExpired() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.now().After(a.pairExpires) {
		a.rotateLocked()
		return true
	}
	return false
}

// PairingSnapshot は PC 画面に表示する情報（ローカル表示専用）
type PairingSnapshot struct {
	Token     string
	Code      string
	ExpiresIn time.Duration
	Version   int
}

func (a *Auth) Pairing() PairingSnapshot {
	a.mu.Lock()
	defer a.mu.Unlock()
	return PairingSnapshot{a.pairToken, a.code, a.pairExpires.Sub(a.now()), a.version}
}

func eq(a, b string) bool {
	return len(a) == len(b) && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// Pair はトークンまたはコードを確認して、新しいセッショントークンを返す
func (a *Auth) Pair(token, code, device string) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.now().After(a.pairExpires) {
		a.rotateLocked()
		return "", errBadPairing
	}
	ok := false
	switch {
	case token != "":
		ok = eq(token, a.pairToken)
	case code != "":
		ok = eq(code, a.code)
		if !ok {
			a.codeAttempts++
			if a.codeAttempts >= maxCodeAttempts {
				a.rotateLocked()
				return "", errLocked
			}
		}
	}
	if !ok {
		return "", errBadPairing
	}
	// 成功：使ったトークン・コードは無効にして、新しいセッションを発行（古いセッションは失効）
	a.rotateLocked()
	a.session = randomHex(32)
	a.sessionExpires = a.now().Add(sessionTTL)
	if len(device) > 40 {
		device = device[:40]
	}
	a.device = device
	return a.session, nil
}

// Check はセッショントークンが有効か確認する
func (a *Auth) Check(token string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.session == "" || token == "" {
		return false
	}
	if a.now().After(a.sessionExpires) {
		a.session = ""
		return false
	}
	return eq(token, a.session)
}

// Revoke は接続を切る（切断ボタン・iPhone 側の切断）
func (a *Auth) Revoke() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.session = ""
	a.device = ""
	a.rotateLocked()
}

// SessionInfo は (接続中か, 端末名, 残り時間)
func (a *Auth) SessionInfo() (bool, string, time.Duration) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.session == "" || a.now().After(a.sessionExpires) {
		return false, "", 0
	}
	return true, a.device, a.sessionExpires.Sub(a.now())
}

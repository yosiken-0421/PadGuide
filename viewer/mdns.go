package main

// 同一 Wi-Fi 内の自動検出（Bonjour / mDNS）。外部ライブラリなしの最小実装。
// iPhone アプリは "_puzzleroute._tcp" を探し、見つかった PC に 6 桁の接続コードで接続する。
// 応答に含めるのは PC の LAN 内アドレスとポートだけで、トークンは含めない。

import (
	"encoding/binary"
	"errors"
	"log"
	"net"
	"strings"
	"time"
)

const (
	mdnsServiceType = "_puzzleroute._tcp.local."
	typePTR         = 12
	typeSRV         = 33
	typeTXT         = 16
	typeA           = 1
	typeANY         = 255
	classIN         = 1
)

var mdnsGroup = &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}

type MDNS struct {
	Instance string // 例 "PuzzleRoute-1a2b._puzzleroute._tcp.local."
	Host     string // 例 "puzzleroute-1a2b.local."
	IP       net.IP
	Port     int
}

func NewMDNS(ip net.IP, port int) *MDNS {
	id := randomHex(2)
	return &MDNS{
		Instance: "PuzzleRoute-" + id + "." + mdnsServiceType,
		Host:     "puzzleroute-" + id + ".local.",
		IP:       ip.To4(),
		Port:     port,
	}
}

type dnsRR struct {
	Name  string
	Type  uint16
	Class uint16
	TTL   uint32
	Data  []byte
}

func encodeName(name string) []byte {
	var b []byte
	for _, l := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		if l == "" {
			continue
		}
		b = append(b, byte(len(l)))
		b = append(b, l...)
	}
	return append(b, 0)
}

func (m *MDNS) records() (ptr, srv, txt, a dnsRR) {
	ptr = dnsRR{mdnsServiceType, typePTR, classIN, 120, encodeName(m.Instance)}
	sd := make([]byte, 6)
	binary.BigEndian.PutUint16(sd[4:], uint16(m.Port))
	srv = dnsRR{m.Instance, typeSRV, classIN | 0x8000, 120, append(sd, encodeName(m.Host)...)}
	t := "v=1"
	txt = dnsRR{m.Instance, typeTXT, classIN | 0x8000, 120, append([]byte{byte(len(t))}, t...)}
	a = dnsRR{m.Host, typeA, classIN | 0x8000, 120, []byte(m.IP)}
	return
}

func buildMessage(id uint16, answers, extra []dnsRR) []byte {
	b := make([]byte, 12)
	binary.BigEndian.PutUint16(b[0:], id)
	binary.BigEndian.PutUint16(b[2:], 0x8400) // 応答・権威あり
	binary.BigEndian.PutUint16(b[6:], uint16(len(answers)))
	binary.BigEndian.PutUint16(b[10:], uint16(len(extra)))
	for _, rr := range append(append([]dnsRR{}, answers...), extra...) {
		b = append(b, encodeName(rr.Name)...)
		f := make([]byte, 10)
		binary.BigEndian.PutUint16(f[0:], rr.Type)
		binary.BigEndian.PutUint16(f[2:], rr.Class)
		binary.BigEndian.PutUint32(f[4:], rr.TTL)
		binary.BigEndian.PutUint16(f[8:], uint16(len(rr.Data)))
		b = append(b, f...)
		b = append(b, rr.Data...)
	}
	return b
}

type dnsQuestion struct {
	Name    string
	Type    uint16
	Unicast bool
}

// readName は圧縮ポインタに対応した名前の読み取り
func readName(msg []byte, off int) (string, int, error) {
	var labels []string
	jumped := false
	next := 0
	for hops := 0; hops < 20; hops++ {
		if off >= len(msg) {
			return "", 0, errors.New("短すぎます")
		}
		l := int(msg[off])
		switch {
		case l == 0:
			if !jumped {
				next = off + 1
			}
			return strings.Join(labels, ".") + ".", next, nil
		case l&0xC0 == 0xC0:
			if off+1 >= len(msg) {
				return "", 0, errors.New("短すぎます")
			}
			if !jumped {
				next = off + 2
			}
			off = int(binary.BigEndian.Uint16(msg[off:]) & 0x3FFF)
			jumped = true
		default:
			if off+1+l > len(msg) {
				return "", 0, errors.New("短すぎます")
			}
			labels = append(labels, string(msg[off+1:off+1+l]))
			off += 1 + l
		}
	}
	return "", 0, errors.New("名前が長すぎます")
}

func parseQuestions(msg []byte) (id uint16, qs []dnsQuestion, err error) {
	if len(msg) < 12 {
		return 0, nil, errors.New("短すぎます")
	}
	id = binary.BigEndian.Uint16(msg[0:])
	if binary.BigEndian.Uint16(msg[2:])&0x8000 != 0 {
		return id, nil, nil // 応答は無視
	}
	n := int(binary.BigEndian.Uint16(msg[4:]))
	off := 12
	for i := 0; i < n && i < 32; i++ {
		name, o, e := readName(msg, off)
		if e != nil || o+4 > len(msg) {
			return id, qs, e
		}
		t := binary.BigEndian.Uint16(msg[o:])
		c := binary.BigEndian.Uint16(msg[o+2:])
		qs = append(qs, dnsQuestion{name, t, c&0x8000 != 0})
		off = o + 4
	}
	return id, qs, nil
}

// Answer は質問への応答を作る（該当しなければ nil）
func (m *MDNS) Answer(qs []dnsQuestion) (answers, extra []dnsRR) {
	ptr, srv, txt, a := m.records()
	match := func(x, y string) bool { return strings.EqualFold(x, y) }
	for _, q := range qs {
		switch {
		case match(q.Name, mdnsServiceType) && (q.Type == typePTR || q.Type == typeANY):
			answers = append(answers, ptr)
			extra = append(extra, srv, txt, a)
		case match(q.Name, "_services._dns-sd._udp.local.") && (q.Type == typePTR || q.Type == typeANY):
			answers = append(answers, dnsRR{q.Name, typePTR, classIN, 120, encodeName(mdnsServiceType)})
		case match(q.Name, m.Instance):
			if q.Type == typeSRV || q.Type == typeANY {
				answers = append(answers, srv)
				extra = append(extra, a)
			}
			if q.Type == typeTXT || q.Type == typeANY {
				answers = append(answers, txt)
			}
		case match(q.Name, m.Host) && (q.Type == typeA || q.Type == typeANY):
			answers = append(answers, a)
		}
	}
	return
}

// Run は指定インターフェースで応答を続ける（失敗しても QR・コード接続は使える）
func (m *MDNS) Run(ifi *net.Interface, logger *log.Logger) {
	conn, err := net.ListenMulticastUDP("udp4", ifi, mdnsGroup)
	if err != nil {
		logger.Printf("自動検出（Bonjour）を開始できませんでした。QR コードか接続コードで接続してください")
		return
	}
	defer conn.Close()
	// 起動時のお知らせ
	ptr, srv, txt, a := m.records()
	announce := buildMessage(0, []dnsRR{ptr, srv, txt, a}, nil)
	for i := 0; i < 2; i++ {
		_, _ = conn.WriteToUDP(announce, mdnsGroup)
		time.Sleep(time.Second)
	}
	buf := make([]byte, 9000)
	for {
		n, src, err := conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		id, qs, err := parseQuestions(buf[:n])
		if err != nil || len(qs) == 0 {
			continue
		}
		ans, extra := m.Answer(qs)
		if len(ans) == 0 {
			continue
		}
		unicast := src.Port != 5353
		for _, q := range qs {
			unicast = unicast || q.Unicast
		}
		if unicast {
			_, _ = conn.WriteToUDP(buildMessage(id, ans, extra), src)
		}
		_, _ = conn.WriteToUDP(buildMessage(0, ans, extra), mdnsGroup)
	}
}

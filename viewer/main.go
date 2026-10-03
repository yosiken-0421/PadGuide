package main

// パズルルート PC ビューアー
// 起動すると、この PC だけで開けるブラウザ画面と、同じ Wi-Fi の iPhone から解析結果を受け取る窓口を用意する。
// 画面画像は受け取らない・保存しない。外部のクラウドには何も送らない。

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"time"
)

// lanAddresses は LAN 内の IPv4 アドレス（192.168 を優先）とそのインターフェース
func lanAddresses() []struct {
	IP  net.IP
	Ifi net.Interface
} {
	var out []struct {
		IP  net.IP
		Ifi net.Interface
	}
	ifs, _ := net.Interfaces()
	for _, ifi := range ifs {
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifi.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok || ipn.IP.To4() == nil || !ipn.IP.IsPrivate() {
				continue
			}
			out = append(out, struct {
				IP  net.IP
				Ifi net.Interface
			}{ipn.IP.To4(), ifi})
		}
	}
	rank := func(ip net.IP) int {
		switch {
		case ip[0] == 192 && ip[1] == 168:
			return 0
		case ip[0] == 10:
			return 1
		default:
			return 2
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return rank(out[i].IP) < rank(out[j].IP) })
	return out
}

func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	_ = cmd.Start()
}

func main() {
	port := flag.Int("port", 48123, "待ち受けポート")
	noBrowser := flag.Bool("no-browser", false, "ブラウザを自動で開かない")
	flag.Parse()

	logger := log.New(os.Stdout, "", log.Ltime)
	addrs := lanAddresses()
	if len(addrs) == 0 {
		fmt.Println("※ Wi-Fi（LAN）に接続されていないようです。iPhone と同じ Wi-Fi に接続してから起動し直してください。")
		addrs = append(addrs, struct {
			IP  net.IP
			Ifi net.Interface
		}{net.IPv4(127, 0, 0, 1).To4(), net.Interface{}})
	}
	lanIP := addrs[0].IP.String()

	ln, err := net.Listen("tcp4", fmt.Sprintf(":%d", *port))
	if err != nil {
		fmt.Printf("ポート %d が使えません（ビューアーがすでに起動していませんか？）\n", *port)
		fmt.Println("Enter キーで終了します")
		fmt.Scanln()
		os.Exit(1)
	}

	auth := NewAuth(time.Now)
	hub := NewHub()
	srv := NewServer(auth, hub, lanIP, *port, logger)
	go srv.Maintain()

	if !strings.HasPrefix(lanIP, "127.") {
		md := NewMDNS(addrs[0].IP, *port)
		ifi := addrs[0].Ifi
		go md.Run(&ifi, logger)
	}

	url := fmt.Sprintf("http://127.0.0.1:%d/", *port)
	fmt.Println("==============================================")
	fmt.Println(" パズルルート PC ビューアー")
	fmt.Println("==============================================")
	fmt.Println(" ブラウザ画面: " + url)
	fmt.Println(" この PC の LAN アドレス: " + lanIP)
	fmt.Println(" iPhone アプリでブラウザに表示された QR コードを読み取ってください。")
	fmt.Println(" 終了するときはこのウィンドウを閉じてください。")
	fmt.Println("----------------------------------------------")

	if !*noBrowser {
		go func() {
			time.Sleep(500 * time.Millisecond)
			openBrowser(url)
		}()
	}
	hs := &http.Server{
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	if err := hs.Serve(ln); err != nil {
		logger.Println("終了しました:", err)
	}
}

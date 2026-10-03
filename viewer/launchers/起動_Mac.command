#!/bin/bash
# パズルルート PCビューアー（macOS）
cd "$(dirname "$0")"
if [ "$(uname -m)" = "arm64" ]; then BIN=./puzzleroute-viewer-mac-arm64; else BIN=./puzzleroute-viewer-mac-intel; fi
# ダウンロードしたファイルに付く「隔離」属性を外す（このフォルダの中だけ）
xattr -dr com.apple.quarantine . 2>/dev/null
chmod +x "$BIN"
echo "パズルルート PCビューアーを起動します。"
echo "「受信接続を許可しますか？」と出たら「許可」を押してください。"
echo
"$BIN"

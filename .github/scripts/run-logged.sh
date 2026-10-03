#!/bin/bash
# 使い方: run-logged.sh <ログ名> <コマンド...>
# コマンドの出力をログに保存し、失敗したらエラー行を GitHub の注釈（画面に出るメッセージ）にする。
# 秘密情報はコマンドライン引数に含めないこと（GitHub 側でもマスクされます）。
set -o pipefail
name="$1"; shift
log="${RUNNER_TEMP:-/tmp}/${name}.log"
"$@" 2>&1 | tee "$log"
code=${PIPESTATUS[0]}
if [ "$code" -ne 0 ]; then
  { grep -E ": error:|error:|\*\* .* FAILED \*\*|Testing failed|failed \(|XCTAssert" "$log" || tail -5 "$log"; } \
    | sed -E 's#/Users/runner/work/[^/]+/[^/]+/##g' | awk '!seen[$0]++' | head -12 \
    | while IFS= read -r l; do echo "::error title=${name}::${l:0:800}"; done
fi
exit "$code"

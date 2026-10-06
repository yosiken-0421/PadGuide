# まいにち家計簿 / LocalLedger

第三者のゲーム・商標・画像・外部サービスに依存しない、iPhone向けのローカル家計簿です。

## v1
- 収入・支出を金額 / カテゴリ / 日付 / メモで記録
- 月を切り替えて過去の収支を閲覧
- 月ごとの収入・支出・残高を自動集計
- 直近6か月の支出グラフ
- カテゴリ別支出の集計
- 記録検索・個別削除・全削除
- アプリ内プライバシーポリシー
- 端末内だけに保存
- アカウント不要
- 広告・解析SDK・トラッキングなし
- 外部API / クラウド送信なし
- 第三者の著作物・ブランド素材を使用しない

## ビルド
```sh
cd apps/LocalLedger
brew install xcodegen
xcodegen generate
swift test --package-path Core
xcodebuild build -project LocalLedger.xcodeproj -scheme LocalLedger -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

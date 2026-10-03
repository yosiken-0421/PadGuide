# パズドラ矢印ガイド（Android / iPhone）

パズドラのパズル画面をリアルタイムで読み取り、最大コンボになるなぞり方を矢印で表示します。
自動で操作はしません（表示だけ）。

| | Android | iPhone |
|---|---|---|
| 画面の読み取り | MediaProjection（画面キャプチャをリアルタイム取得） | ReplayKit 画面ブロードキャスト（同上） |
| 矢印の表示 | **盤面の上に直接矢印を重ねる** | ピクチャ・イン・ピクチャの小窓に「盤面＋矢印」を表示 |
| 理由 | Android は他アプリの上に描画できる | iOS は他アプリの上への描画が禁止されているため、浮かせられるのはPiP小窓だけ |

## 表示の見方
- 緑の輪 … 最初につかむドロップ
- 白い線と矢じり … なぞる経路
- 動く白い点 … なぞる順番
- 赤い四角 … 指を離す位置
- 上の文字 … 「○コンボ（最大○）/ ○手」

落ちコンは計算に入れていません。お邪魔・毒などは「?」扱い（動かせるが消えない）です。

---

## Android

### APK の入手（スマホだけでやる場合）
1. GitHub にこのフォルダ一式をアップロード（新規リポジトリ → Add file → Upload files に zip の中身を入れる）
2. 「Actions」タブで **Build** が自動で走る（数分）
3. 完了したら成果物 **PadGuide-android-apk** をダウンロード → 解凍 → APK をインストール
   （「提供元不明のアプリ」の許可が必要）

PC がある場合は `android` フォルダを Android Studio で開いて実行でもOK。

### 使い方
1. アプリを開き「① 他のアプリの上に表示を許可」
2. 「② ガイド開始」→ 確認画面で **「画面全体」** を選ぶ → パズドラが自動で開きます
3. 画面端の浮きボタン
   - **解析** … 今の盤面で矢印を表示
   - **自動** … ON にすると盤面が変わって落ち着くたびに自動更新
   - **消す** … 矢印を消す
   - **位置** … 枠を盤面に合わせる（認識結果が色付きの点で出るので、正しく読めているか確認できます）
   - **終了**
4. 初回は自動で盤面位置を探します。ずれていたら「位置」で調整してください。

---

## iPhone

### インストール方法（どちらか）
- **スマホだけ（有料 Apple Developer）**：下の「TestFlight で入れる」を参照
- **Mac がある**：`ios` フォルダで `brew install xcodegen && xcodegen generate` → `PadGuide.xcodeproj` を Xcode で開く → `PD_BUNDLE_PREFIX` を自分用に変更 → Signing で自分のチームを選んで iPhone に実行

### TestFlight で入れる（iPhone のブラウザだけで完結）
`○○` は自分用の文字列（例 `com.taro.padguide`）。世界で重複しない名前にしてください。

1. **Apple Developer Program に登録**（developer.apple.com → Account → 登録。承認に最大2日ほど）
2. **Team ID を控える**：developer.apple.com/account →「メンバーシップの詳細」
3. **ID を登録**：developer.apple.com/account/resources/identifiers
   - App Groups で `group.○○` を作成
   - App IDs で `○○.app` と `○○.app.broadcast` を作成し、どちらも「App Groups」にチェック → `group.○○` を割り当て
4. **アプリ枠を作成**：App Store Connect →「マイApp」→ ＋ → 新規App（バンドルIDは `○○.app`、名前は他と被らないもの、SKU は適当）
5. **API キー作成**：App Store Connect →「ユーザとアクセス」→「統合」→「App Store Connect API」→ チームキーを生成（アクセスは **Admin**）
   - Issuer ID と キーID を控える
   - .p8 ファイルをダウンロード（**1回しか落とせません**）→ ファイルアプリ等で中身のテキストをコピー
6. **GitHub の設定**（リポジトリの Settings → Secrets and variables → Actions）
   - Secrets：`ASC_KEY_ID`（キーID）、`ASC_ISSUER_ID`、`ASC_KEY_P8`（.p8 の中身まるごと）、`APPLE_TEAM_ID`
   - Variables：`BUNDLE_PREFIX` = `○○`
7. **実行**：Actions →「iOS TestFlight」→「Run workflow」（20分ほど）
8. **インストール**：App Store Connect → アプリ → TestFlight →「内部テスト」でグループを作り自分を追加 → iPhone に TestFlight アプリを入れて招待から入れる

TestFlight のビルドは90日で期限切れになるので、その前に 7 をもう一度実行してください。

### SideStore / AltStore で入れる場合
GitHub Actions の **Build** が作る **PadGuide-ios-unsigned-ipa** を署名してインストール（無料 Apple ID は7日ごとに再署名）。

### 使い方
1. アプリを開き、①のボタン →「パズドラ矢印ガイド」→「ブロードキャストを開始」
2. 「② 小窓を表示」→ ホームに戻ってパズドラを開く
3. 小窓をパズドラの盤面と重ならない位置（上のほう）に置く
4. 盤面が落ち着くたびに小窓の矢印が自動更新されます
5. ずれる時はアプリの「盤面の位置を調整」で枠を合わせる（ブロードキャスト中ならプレビューが出ます）

---

## 調整のヒント
- 色の誤認識がある場合は `BoardReader`（Android: `BoardReader.kt` / iOS: `Shared/Core.swift`）の `classify` の色相の境界値を調整してください
- 「最大手数」を増やすと高コンボになりやすいですが、なぞる時間（約4〜5秒）に注意
- 「探索精度」を上げるとより良い経路が出ますが計算が遅くなります

## 注意
外部ツールの利用はパズドラの利用規約で制限されている可能性があります。ランキングダンジョン等での使用は特に自己責任でお願いします。

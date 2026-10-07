import SwiftUI
import PuzzleCore

@main
struct PuzzleRouteApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var pip = PiPGuide()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(pip)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var pip: PiPGuide
    @State private var picker = BroadcastPickerHolder()
    @State private var showQR = false
    @State private var showDiscovery = false
    @State private var editingCell: Int?
    @State private var showPicker = false

    static let disclaimer = "画面共有はユーザーが開始した場合だけ動作します。画面は端末内または同一ネットワーク内で処理されます。本アプリは操作を自動実行しません。利用するサービスの規約を確認したうえで使用してください。"

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                shareSection
                pcSection
                boardSection
                constraintSection
                settingsSection
                pipSection
                learnedSection
                Section {
                    Text(Self.disclaimer)
                        .font(.footnote)
                        .accessibilityIdentifier("disclaimer")
                }
            }
            .navigationTitle("パズルルート")
            // 小窓の表示レイヤーは常に画面に置いておく（画面に入っていないと小窓を開始できない）
            .safeAreaInset(edge: .bottom, spacing: 0) { PiPBar(pip: pip) }
            .onAppear {
                pip.prepare(autoStart: !model.isUITest) { [weak m = model] in
                    PiPContent(board: m?.board, result: m?.result, progress: m?.progress, offRoute: m?.offRoute ?? false)
                }
            }
            .sheet(isPresented: $showQR) { QRScannerSheet().environmentObject(model) }
            .sheet(isPresented: $showDiscovery) { DiscoverySheet().environmentObject(model) }
            // 編集するマスの番号はダイアログに渡して保持する（閉じる処理と競合して修正が失われないように）
            .confirmationDialog("正しいドロップを選んでください", isPresented: $showPicker,
                                titleVisibility: .visible, presenting: editingCell) { index in
                ForEach(OrbKind.allCases, id: \.self) { k in
                    Button(k.label) { model.correct(index: index, to: k) }
                }
            }
        }
    }

    // MARK: 状態

    private var statusSection: some View {
        Section {
            HStack {
                Circle().fill(model.sharing ? Color.red : Color.gray).frame(width: 10, height: 10)
                Text(model.sharing ? "画面共有中（この iPhone の画面を解析しています）" : "画面共有していません")
                    .accessibilityIdentifier("shareStatus")
            }
            HStack {
                Circle().fill(model.connection != nil ? Color.green : Color.gray).frame(width: 10, height: 10)
                if let c = model.connection {
                    Text("PC と接続中（\(c.host)）")
                } else {
                    Text("PC と未接続")
                }
            }
            .accessibilityIdentifier("pcStatus")
        }
    }

    private var shareSection: some View {
        Section {
            Button {
                picker.open()
            } label: {
                Label(model.sharing ? "画面共有を確認・終了" : "画面共有を開始", systemImage: "record.circle")
                    .font(.headline)
            }
            .accessibilityIdentifier("startShareButton")
            .background(BroadcastPickerHost(holder: picker).frame(width: 1, height: 1).opacity(0.02))
        } header: {
            Text("画面共有")
        } footer: {
            Text("押すと iOS の確認画面が出ます。「パズルルート」を選んで「ブロードキャストを開始」を押すと始まります。終了は画面上部の赤い表示（またはコントロールセンター）から行えます。")
        }
    }

    private var pcSection: some View {
        Section {
            if model.connection == nil {
                Button { showQR = true } label: { Label("QR コードで接続", systemImage: "qrcode.viewfinder") }
                    .accessibilityIdentifier("qrConnectButton")
                Button { showDiscovery = true } label: { Label("同じ Wi-Fi の PC を探す", systemImage: "wifi") }
                    .accessibilityIdentifier("discoverButton")
            } else {
                Button(role: .destructive) { Task { await model.disconnect() } } label: {
                    Label("PC との接続を切る", systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("disconnectButton")
            }
            if let m = model.connectionMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("PC ビューアーに表示")
        } footer: {
            Text("PC へ送るのは盤面の認識結果とルートだけです。画面の画像は送りません。通信は同じネットワーク内に限られます。")
        }
    }

    @ViewBuilder private var boardSection: some View {
        Section {
            if let b = model.board {
                BoardView(board: b, confidence: model.confidence, result: model.result, progress: model.progress,
                          constraints: model.activeConstraints) { i in
                    if model.tapCell(i) {
                        editingCell = i
                        showPicker = true
                    }
                }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                toolPicker
                if let r = model.result {
                    if r.status == "ok" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("見つかった候補：\(r.combos)コンボ・\(r.steps)手").font(.headline)
                                .accessibilityIdentifier("routeSummary")
                            if r.reachedMaxCombos {
                                Text("この盤面の最大\(r.maxCombos)コンボに到達").font(.subheadline.bold()).foregroundStyle(.green)
                                    .accessibilityIdentifier("maxComboStatus")
                            } else {
                                Text("この盤面の最大は\(r.maxCombos)コンボ（時間内に届くルートは見つかりませんでした）")
                                    .font(.footnote).foregroundStyle(.orange)
                                    .accessibilityIdentifier("maxComboStatus")
                            }
                            if let s = RouteText.start(r) { Text("開始：\(s)").accessibilityIdentifier("routeStart") }
                            if let c = r.constraints { Text("縛り：\(c.summary)").font(.footnote).accessibilityIdentifier("routeConstraints") }
                            Text(RouteText.firstMoves(r)).font(.title2.bold())
                            if !r.achieved.isEmpty { Text("達成：" + r.achieved.joined(separator: "、")).font(.footnote) }
                        }
                    } else {
                        Text(RouteText.status(r.status)).accessibilityIdentifier("routeSummary")
                    }
                }
                if model.solving { HStack { ProgressView(); Text("探しています…") } }
                if model.unknownCount > 0 {
                    Label("不明なマスが \(model.unknownCount) 個あります。マスをタップして色を直してください。", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("unknownWarning")
                }
                HStack {
                    Button("再探索") { model.resolve() }
                        .buttonStyle(.borderless)
                    Spacer()
                    if model.edited {
                        Button("自動の結果に戻す") { model.revertToAuto() }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                Text("まだ盤面がありません。画面共有を開始して、パズル画面を表示してください。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("emptyBoard")
            }
            if model.sharing {
                Button("今の画面で計算し直す") { model.recalcFromScreen() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("recalcButton")
            }
        } header: {
            Text("認識した盤面")
        } footer: {
            Text("ルートを表示した後は、ドロップを動かしている間もルートを変えずに表示し続けます。コンボで消えて次の盤面になると、自動で計算し直します。黄色い枠は認識に自信がないマスです。タップすると正しい色に直せます。直した色の傾向はこの iPhone の中だけに保存されます。")
        }
    }

    /// マスを押したときの動作（色を直す／縛りを付ける）
    private var toolPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("マスを押したとき").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(CellTool.allCases) { t in
                    Button {
                        model.tapTool = t
                    } label: {
                        Text(t.label).font(.footnote.bold()).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.tapTool == t ? .accentColor : .gray)
                    .accessibilityIdentifier("tool-\(t.rawValue)")
                    .accessibilityAddTraits(model.tapTool == t ? .isSelected : [])
                }
            }
        }
    }

    /// 敵の妨害（縛り）
    private var constraintSection: some View {
        Section {
            Text("設定中：\(model.constraintSummary)")
                .font(.footnote)
                .accessibilityIdentifier("constraintSummary")
            DisclosureGroup("消せない状態のドロップ") {
                ForEach([OrbKind.fire, .water, .wood, .light, .dark, .heart, .jammer, .poison, .mortalPoison], id: \.self) { k in
                    Toggle(k.label, isOn: Binding(get: { model.isUnclearable(k) }, set: { model.setUnclearable(k, $0) }))
                        .accessibilityIdentifier("unclearable-\(k.key)")
                }
            }
            .accessibilityIdentifier("unclearableGroup")
            Button("縛りをすべて解除", role: .destructive) { model.clearConstraints() }
                .disabled(model.settings.constraints == nil)
                .accessibilityIdentifier("clearConstraints")
        } header: {
            Text("敵の妨害（縛り）")
        } footer: {
            Text(Self.constraintHelp)
        }
    }

    static let constraintHelp = "敵のスキルでパズルが縛られたときに設定します。盤面の上の「開始位置」「操作不可」「棘」「雲・ルーレット」を選んでから、盤面のマスを押してください（もう一度押すと外れます）。\n・開始位置：盤面にカーソルが出て、そこから動かし始めるよう指定されたとき\n・操作不可：テープ・お札が貼られたマス（動かせず、指で通れません）\n・棘：動かすとダメージを受けるドロップ（通らないルートにします）\n・雲・ルーレット：色が見えない／変わり続けるマス（消えないものとして計算します）\n・消せない状態：×印が付いた種類のドロップ（消えないものとして計算します）\n縛りは解除するまで続きます。効果が切れたら「縛りをすべて解除」を押してください。"

    private var settingsSection: some View {
        Section("探索の設定") {
            Picker("盤面サイズ", selection: $model.settings.sizeMode) {
                Text("自動判定").tag("auto")
                Text("6×5").tag("6x5")
                Text("7×6").tag("7x6")
                Text("5×4").tag("5x4")
            }
            .accessibilityIdentifier("sizePicker")
            Picker("手数の上限", selection: $model.settings.maxSteps) {
                ForEach(SolverOptions.stepChoices, id: \.self) { Text("\($0)手").tag($0) }
            }
            Picker("探索時間", selection: $model.settings.timeLimit) {
                ForEach(SolverOptions.timeChoices, id: \.self) { Text("約\(Int($0))秒").tag($0) }
            }
            Picker("優先する色", selection: $model.settings.goals.priorityColor) {
                Text("指定なし").tag(OrbKind?.none)
                ForEach([OrbKind.fire, .water, .wood, .light, .dark, .heart], id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            Toggle("回復を消す", isOn: $model.settings.goals.heal)
            Toggle("5色同時消し", isOn: $model.settings.goals.fiveColors)
            Toggle("L字", isOn: $model.settings.goals.lShape)
            Toggle("十字", isOn: $model.settings.goals.cross)
            Toggle("横1列", isOn: $model.settings.goals.row)
            Toggle("3×3正方形", isOn: $model.settings.goals.square)
        }
    }

    /// スマホだけで使うときの説明（小窓の操作は画面下部のバー）
    private var pipSection: some View {
        Section {
            Text(Self.pipNotice)
                .font(.footnote)
                .accessibilityIdentifier("pipNotice")
        } header: {
            Text("スマホだけで使う（小窓表示）")
        }
    }

    static let pipNotice = "画面下の「小窓で表示」を押すか、画面共有中にゲームへ切り替えると、盤面とルートの図が小窓（ピクチャ・イン・ピクチャ）で表示されます。iOS ではゲーム画面に直接ルートを重ねることはできないため、小窓をパズルの盤面に重ならない位置（画面の上のほう）へ動かして使ってください。PC ビューアーでも同じルートを見られます。"

    private var learnedSection: some View {
        Section {
            HStack {
                Text("覚えた色の修正")
                Spacer()
                Text("\(model.learnedCount) 件").foregroundStyle(.secondary)
            }
            Button("修正の記録を消す", role: .destructive) { model.resetLearned() }
                .disabled(model.learnedCount == 0)
        } footer: {
            Text("この記録は iPhone の中だけに保存され、外部へ送られません。")
        }
    }
}

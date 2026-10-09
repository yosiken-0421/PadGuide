import SwiftUI
import PhotosUI
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
    @State private var photoItem: PhotosPickerItem?

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
                leaderSection
                pipSection
                learnedSection
                privacySection
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
                pip.prepare(autoStart: false) { [weak m = model] in
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
                if model.showingSample {
                    Label("見本盤面（実際のゲーム画面は使っていません）", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sampleBoardNotice")
                }
                toolPicker
                BoardView(board: b, confidence: model.confidence, result: model.result, progress: model.progress,
                          constraints: model.boardConstraints, covered: model.coveredCells, clouds: model.cloudCells,
                          autoRoulette: model.autoRouletteCells) { i in
                    if model.tapCell(i) {
                        editingCell = i
                        showPicker = true
                    }
                }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
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
                            if let m = r.missed, !m.isEmpty {
                                Text("満たせなかった条件：" + m.joined(separator: "、")).font(.footnote).foregroundStyle(.orange)
                                    .accessibilityIdentifier("missedConditions")
                            }
                        }
                    } else {
                        Text(RouteText.status(r.status)).accessibilityIdentifier("routeSummary")
                    }
                }
                if let note = model.correctionNote {
                    Text(note).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("correctionNote")
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
                    if model.showingSample {
                        Button("見本盤面を閉じる") { model.clearSampleBoard() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("closeSampleBoardButton")
                    } else if model.edited {
                        Button("自動の結果に戻す") { model.revertToAuto() }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                Text("まだ盤面がありません。画面共有を開始して、パズル画面を表示してください。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("emptyBoard")
                Button {
                    model.loadSampleBoard()
                } label: {
                    Label("見本盤面で試す", systemImage: "play.rectangle")
                }
                .accessibilityIdentifier("sampleBoardButton")
            }
            screenshotRow
            if model.sharing {
                Button("今の画面で計算し直す") { model.recalcFromScreen() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("recalcButton")
            }
        } header: {
            Text("盤面とルート")
        } footer: {
            Text("ルートを表示した後は、ドロップを動かしている間もルートを変えずに表示し続けます。コンボで消えて次の盤面になると、自動で計算し直します。黄色い枠は認識に自信がないマスです。タップすると正しい色に直せます（見た目が近いマスもまとめて直します）。直した色の傾向はこの iPhone の中だけに保存され、次の盤面からは同じ見た目のドロップを正しく読みます。")
        }
    }

    /// スクリーンショットから読み取る・診断情報をコピー
    @ViewBuilder private var screenshotRow: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Label(model.readingScreenshot ? "読み取っています…" : "スクショから読み取る", systemImage: "photo")
        }
        .disabled(model.readingScreenshot)
        .accessibilityIdentifier("screenshotButton")
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { model.importScreenshot(data) }
                photoItem = nil
            }
        }
        if model.diagnosticsText != nil {
            Button { model.copyDiagnostics() } label: { Label("診断情報をコピー", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("copyDiagnostics")
        }
        if let m = model.boardMessage {
            Text(m).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("screenshotMessage")
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
            Toggle("ルーレットを自動で見つける", isOn: Binding(
                get: { model.settings.autoRouletteOn },
                set: { model.settings.autoRoulette = $0 }))
                .accessibilityIdentifier("autoRouletteToggle")
            if !model.autoRouletteCells.isEmpty {
                Text("自動で見つけたルーレット：\(model.autoRouletteCells.count)マス（盤面に「ル」と表示）")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("autoRouletteSummary")
            }
            if !model.autoTapedCells.isEmpty {
                Text("自動で見つけた操作不可（テープ）：\(model.autoTapedCells.count)マス（盤面に「不可」と表示。ここは通らないルートにします）")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("autoTapedSummary")
            }
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

    static let constraintHelp = "敵のスキルでパズルが縛られたときに設定します。盤面の上の「開始位置」「操作不可」「棘」「雲・ルーレット」を選んでから、盤面のマスを押してください（もう一度押すと外れます）。\n・開始位置：盤面にカーソルが出て、そこから動かし始めるよう指定されたとき\n・操作不可：テープ・お札が貼られたマス（動かせず、指で通れません）\n・棘：動かすとダメージを受けるドロップ（通らないルートにします）\n・雲・ルーレット：色が見えない／変わり続けるマス（消えないものとして計算します）\n・ルーレットは「ルーレットを自動で見つける」がオンなら、画面共有中に自動で見つけます（盤面が止まっている間に、同じマスの色が変わり続けるのを見て判断。見つけるまで約3秒）。\n・消せない状態：×印が付いた種類のドロップ（消えないものとして計算します）\n縛りは解除するまで続きます。効果が切れたら「縛りをすべて解除」を押してください。"

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
        }
    }

    static let attackColors: [OrbKind] = [.fire, .water, .wood, .light, .dark, .heart]

    /// 「なし」を含む数の選択
    private func numberPicker(_ title: String, _ value: Binding<Int?>, _ range: ClosedRange<Int>, unit: String,
                              id: String) -> some View {
        Picker(title, selection: value) {
            Text("なし").tag(Int?.none)
            ForEach(Array(range), id: \.self) { Text("\($0)\(unit)").tag(Optional($0)) }
        }
        .accessibilityIdentifier(id)
    }

    private func colorPicker(_ title: String, _ value: Binding<OrbKind?>, any: String, id: String) -> some View {
        Picker(title, selection: value) {
            Text(any).tag(OrbKind?.none)
            ForEach(Self.attackColors, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        .accessibilityIdentifier(id)
    }

    private func shapeRow(_ shape: ClearShape, _ on: Binding<Bool>) -> some View {
        Group {
            Toggle(shape == .row ? "横1列消し" : "5個\(shape.rawValue)消し".replacingOccurrences(of: "5個3×3正方形消し", with: "3×3正方形消し"),
                   isOn: on)
                .accessibilityIdentifier("shape-\(shape.rawValue)")
            if on.wrappedValue {
                colorPicker("　\(shape.rawValue)の色", Binding(get: { model.settings.goals.shapeColors[shape] },
                                                             set: { model.settings.goals.shapeColors[shape] = $0 }),
                            any: "どの色でも", id: "shapeColor-\(shape.rawValue)")
            }
        }
    }

    /// リーダースキルの発動条件（盤面の消し方に関わるもの）
    private var leaderSection: some View {
        Section {
            numberPicker("コンボ数（以上）", $model.settings.goals.minCombos, 3...12, unit: "コンボ以上", id: "lsMinCombos")
            numberPicker("コンボ数（ちょうど）", $model.settings.goals.exactCombos, 3...10, unit: "コンボちょうど", id: "lsExactCombos")
            numberPicker("同時攻撃の色数", $model.settings.goals.minColors, 2...6, unit: "色以上", id: "lsMinColors")
            DisclosureGroup("同時に消す色（例：火水の同時攻撃）") {
                ForEach(Self.attackColors, id: \.self) { k in
                    Toggle(k.label, isOn: Binding(
                        get: { model.settings.goals.requiredColors.contains(k) },
                        set: { on in
                            model.settings.goals.requiredColors.removeAll { $0 == k }
                            if on { model.settings.goals.requiredColors.append(k) }
                        }))
                    .accessibilityIdentifier("lsRequired-\(k.key)")
                }
            }
            colorPicker("つなげて消す色", $model.settings.goals.connectColor, any: "どの色でも", id: "lsConnectColor")
            numberPicker("つなげて消す個数", $model.settings.goals.connectCount, 4...10, unit: "個以上", id: "lsConnectCount")
            colorPicker("色のコンボ（例：闇の2コンボ）", Binding(
                get: { model.settings.goals.colorComboKind },
                set: { k in
                    model.settings.goals.colorComboKind = k
                    if k != nil && model.settings.goals.colorComboCount == nil { model.settings.goals.colorComboCount = 2 }
                }), any: "なし", id: "lsColorComboKind")
            if model.settings.goals.colorComboKind != nil {
                Picker("　その色のコンボ数", selection: Binding(
                    get: { model.settings.goals.colorComboCount ?? 2 },
                    set: { model.settings.goals.colorComboCount = $0 })) {
                    ForEach(2...5, id: \.self) { Text("\($0)コンボ以上").tag($0) }
                }
            }
            shapeRow(.lShape, $model.settings.goals.lShape)
            shapeRow(.cross, $model.settings.goals.cross)
            shapeRow(.tShape, $model.settings.goals.tShape)
            shapeRow(.row, $model.settings.goals.row)
            shapeRow(.square, $model.settings.goals.square)
            numberPicker("パズル後の残りドロップ数", $model.settings.goals.maxRemaining, 0...10, unit: "個以下", id: "lsMaxRemaining")
        } header: {
            Text("リーダースキルの条件")
        } footer: {
            Text(Self.leaderHelp)
        }
    }

    static let leaderHelp = "使っているリーダースキルの発動条件を設定すると、その条件を満たすルートを優先して探し、そのうえでコンボ数を増やします。例：「木を4個つなげて消すと攻撃力が8倍」→ つなげて消す色＝木、個数＝4個以上。「4コンボ以上で攻撃力が上昇」→ コンボ数（以上）＝4。\n・公式の説明どおり「Nコンボ」「N色同時攻撃」「○のNコンボ」「○をN個つなげて消す」はN以上で数えます。\n・同時攻撃の色数は、火・水・木・光・闇・回復を1色ずつ数えます（「3色(2色+回復)」のように回復も1色）。\n・ダメージや倍率の計算はしません。満たせなかった条件はルートの下に表示します。"


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

    static let pipNotice = "画面下の「小窓で表示」を押すと、盤面とルートの図が小窓（ピクチャ・イン・ピクチャ）で表示されます。小窓を開始してからゲームへ切り替えてください。iOS ではゲーム画面に直接ルートを重ねることはできないため、小窓をパズルの盤面に重ならない位置（画面の上のほう）へ動かして使ってください。PC ビューアーでも同じルートを見られます。"

    private var privacySection: some View {
        Section {
            Link(destination: URL(string: "https://github.com/yosiken-0421/PadGuide/blob/main/PRIVACY.md")!) {
                Label("プライバシーポリシー", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("privacyPolicyLink")
        } footer: {
            Text("画面共有・カメラ・ローカルネットワークの利用目的、保存する情報、削除方法を確認できます。")
        }
    }

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

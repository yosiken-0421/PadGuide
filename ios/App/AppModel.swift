import Foundation
import SwiftUI
import UIKit
import Network
import PuzzleCore

/// アプリ全体の状態
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings { didSet { SharedStore.saveSettings(settings) } }
    @Published private(set) var sharing = false
    @Published private(set) var connection: PCConnection?
    @Published var connectionMessage: String?
    @Published private(set) var busyConnecting = false

    /// 表示中の盤面（手動修正するとここが変わる）
    @Published private(set) var board: Board?
    @Published private(set) var confidence: [Double] = []
    /// 表示中の結果（自動解析 or 手動修正後の再探索）
    @Published private(set) var result: ResultMessage?
    /// ルートのうち何手目まで操作が進んだか（画面共有中に推定。nil = 不明）
    @Published private(set) var progress: Int?
    /// 操作がルートから外れた
    @Published private(set) var offRoute = false
    @Published private(set) var edited = false
    @Published private(set) var solving = false
    @Published private(set) var learnedCount = 0
    /// 盤面のマスを押したときの動作（色を直す／縛りを付ける）
    @Published var tapTool: CellTool = .color
    /// 手動修正で、似た見た目のマスもまとめて直したときのお知らせ
    @Published private(set) var correctionNote: String?
    /// 画面共有なしでも動作を確認できる、アプリ独自配色の見本盤面
    @Published private(set) var showingSample = false
    /// スクリーンショットを読み取っている最中
    @Published private(set) var readingScreenshot = false
    /// 盤面まわりのお知らせ（スクショの読み取り・診断情報のコピー）
    @Published private(set) var boardMessage: String?
    /// 診断用：最後に読み取った盤面（画像は持たない）と、その入力元
    private var screenshotReading: BoardReading?
    private var screenshotSize: (Int, Int)?

    private var colors: [RGB] = []
    /// 黒く覆われて色が見えないマス（暗闇など）
    @Published private(set) var coveredCells: Set<Int> = []
    /// UI テスト用：見本盤面で「何手目まで進んだか」を指定する（-demoProgress N）
    private var demoProgress: Int?
    private var latest: LatestState?
    private var lastSeq = -1
    private var timer: Timer?
    private var pingCounter = 0
    private var cancelFlag: CancellationFlag?
    let isUITest = ProcessInfo.processInfo.arguments.contains("-uitest")

    init() {
        settings = SharedStore.loadSettings()
        if ProcessInfo.processInfo.arguments.contains("-uitest") { settings.constraints = nil }   // テストは縛りなしで始める
        connection = SharedStore.connection
        learnedCount = SharedStore.loadLearned().count
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demoProgress"), i + 1 < args.count { demoProgress = Int(args[i + 1]) }
        if args.contains("-demoBoard") { loadTestDemo() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: 拡張からの結果を読む

    private func poll() {
        sharing = SharedStore.isSharing
        if let l = SharedStore.readLatest() {
            if l.seq != lastSeq {
                lastSeq = l.seq
                latest = l
                showingSample = false
                if !edited { apply(l) }
            }
        } else if latest != nil {
            // 画面共有が終わってデータが消された。見本盤面を表示中なら、その見本は残す。
            latest = nil
            lastSeq = -1
            if !edited && !showingSample {
                board = nil; result = nil; confidence = []; colors = []; coveredCells = []; progress = nil; offRoute = false
            }
        }
        // 接続状態の確認（約 10 秒ごと）
        pingCounter += 1
        if pingCounter % 40 == 0, !isUITest, SharedStore.connection != nil {
            Task {
                let code = await PCLink.ping()
                if code == 401 {
                    SharedStore.connection = nil
                    self.connectionMessage = "PC 側で切断されたため、接続を解除しました"
                }
                self.connection = SharedStore.connection
            }
        } else {
            connection = SharedStore.connection
        }
    }

    private func apply(_ l: LatestState) {
        let r = l.result
        if r != result {
            let size = BoardSize(cols: r.cols, rows: r.rows)
            board = Board(size: size, cells: r.cells.map { OrbKind(key: $0) ?? .unknown })
            confidence = r.confidence.count == size.count ? r.confidence : Array(repeating: 1, count: size.count)
            colors = l.reading?.cells.map { $0.color } ?? []
            coveredCells = Set((l.reading?.cells ?? []).indices.filter { l.reading!.cells[$0].covered == true })
            result = r
        }
        progress = l.progress
        offRoute = l.offRoute ?? false
    }

    // MARK: 手動修正

    func correct(index: Int, to kind: OrbKind) {
        guard var b = board, index < b.cells.count else { return }
        // 修正した色の傾向を端末内に保存（外部へは送らない）
        if index < colors.count {
            var cls = ColorClassifier(learned: SharedStore.loadLearned())
            cls.learn(colors[index], as: kind)
            SharedStore.saveLearned(cls.learned)
            learnedCount = cls.learned.count
        }
        // 同じように読み違えていた、見た目の近いマスもまとめて直す（お邪魔・毒などは盤面に複数あることが多い）
        let old = b.cells[index]
        var also = 0
        if index < colors.count && old != kind {
            let ref = colors[index]
            for j in b.cells.indices where j != index && j < colors.count && b.cells[j] == old
                && Self.colorDistance(colors[j], ref) < Self.sameLookDistance {
                b.cells[j] = kind
                if j < confidence.count { confidence[j] = 1 }
                also += 1
            }
        }
        correctionNote = also > 0 ? "見た目が近い \(also) マスも「\(kind.label)」に直しました" : nil
        b.cells[index] = kind
        coveredCells.remove(index)
        board = b
        progress = nil
        offRoute = false
        if index < confidence.count { confidence[index] = 1 }
        edited = true
        resolve()
    }

    /// 同じ見た目とみなす色の差（RGB の距離）
    static let sameLookDistance = 30.0

    static func colorDistance(_ a: RGB, _ b: RGB) -> Double {
        let dr = Double(a.r) - Double(b.r), dg = Double(a.g) - Double(b.g), db = Double(a.b) - Double(b.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// 表示中の盤面で探し直す（バックグラウンド・前の計算はキャンセル）
    func resolve() {
        guard let b = board else { return }
        cancelFlag?.cancel()
        let flag = CancellationFlag()
        cancelFlag = flag
        solving = true
        let opts = settings.solverOptions
        let goals = settings.goals
        let cons = settings.constraints
        let conf = confidence
        let source = edited ? "iphone-manual" : "iphone"
        Task.detached(priority: .userInitiated) {
            let route = Solver.solve(b, options: opts, cancel: flag)
            let msg = ResultMessage.make(board: b, confidence: conf, route: route, goals: goals,
                                         status: route.result.combos > 0 ? "ok" : "nocombo", source: source,
                                         constraints: cons)
            await MainActor.run {
                guard !flag.isCancelled else { return }
                self.result = msg
                self.solving = false
                if let dp = self.demoProgress, msg.status == "ok" { self.progress = min(dp, msg.steps) }
            }
            if !flag.isCancelled { PCLink.push(msg) }
        }
    }

    /// 画面共有中：表示中のルートを手放し、今の画面の盤面で計算し直す
    func recalcFromScreen() {
        edited = false
        SharedStore.requestForceSolve()
        connectionMessage = nil
    }

    func revertToAuto() {
        edited = false
        screenshotReading = nil
        correctionNote = nil
        if let l = latest { apply(l) } else { board = nil; result = nil }
    }

    func resetLearned() {
        SharedStore.saveLearned([])
        learnedCount = 0
    }

    // MARK: 敵の妨害（縛り）

    /// 今の盤面に使われる縛り
    var activeConstraints: BoardConstraints? {
        guard let c = settings.constraints else { return nil }
        return board.map { c.effective(for: $0.size) } ?? c
    }

    var constraintSummary: String { activeConstraints?.summary ?? "なし" }

    /// 盤面のマスを押した。色を直すモードなら true を返す（色の選択肢を出す）
    func tapCell(_ i: Int) -> Bool {
        guard let mark = tapTool.mark else { return true }
        guard let b = board else { return false }
        var c = settings.constraints?.effective(for: b.size) ?? BoardConstraints(size: b.size)
        if !c.applies(to: b.size) { c = BoardConstraints(size: b.size, unclearable: c.unclearable) }
        c.toggle(mark, at: i)
        setConstraints(c)
        return false
    }

    func isUnclearable(_ k: OrbKind) -> Bool { settings.constraints?.unclearable.contains(k) ?? false }

    func setUnclearable(_ k: OrbKind, _ on: Bool) {
        let size = board?.size ?? settings.constraints?.size ?? .sixByFive
        var c = settings.constraints ?? BoardConstraints(size: size)
        c.unclearable.removeAll { $0 == k }
        if on { c.unclearable.append(k) }
        setConstraints(c)
    }

    func clearConstraints() { setConstraints(nil) }

    /// 縛りを保存し、表示中の盤面と画面共有中の盤面で計算し直す
    private func setConstraints(_ c: BoardConstraints?) {
        settings.constraints = (c?.isEmpty ?? true) ? nil : c
        progress = nil
        offRoute = false
        if sharing && !edited && !showingSample {
            // 画面共有中は、画面共有側だけで計算し直す（アプリ側でも別に計算すると、
            // 2つのルートが交互に表示されて操作の順番が変わってしまう）
            SharedStore.requestForceSolve()
        } else if board != nil {
            resolve()
        }
    }

    var lowConfidenceCount: Int { confidence.filter { $0 < BoardReading.lowConfidence }.count }
    /// 不明なマスの数（雲・ルーレットに指定したマスは数えない）
    var unknownCount: Int {
        guard let b = board else { return 0 }
        let hidden = Set(activeConstraints?.hidden ?? [])
        return b.cells.indices.filter { b.cells[$0] == .unknown && !hidden.contains($0) && !coveredCells.contains($0) }.count
    }

    // MARK: PC との接続

    func pair(with info: PairingInfo) async {
        await connect { try await PCLink.pair(.hostPort(info.host, info.port), token: info.token, code: nil) }
    }

    func pair(endpoint: NWEndpoint, code: String) async {
        guard Token.isValidCode(code) else {
            connectionMessage = "接続コードは 6 桁の数字です"
            return
        }
        await connect { try await PCLink.pair(.endpoint(endpoint), token: nil, code: code) }
    }

    private func connect(_ op: () async throws -> PCConnection) async {
        busyConnecting = true
        defer { busyConnecting = false }
        do {
            connection = try await op()
            connectionMessage = "PC と接続しました"
            if sharing { PCLink.share("started") }
            if let r = result { PCLink.push(r) }
        } catch {
            connectionMessage = "接続できませんでした：" + error.localizedDescription
        }
    }

    func disconnect() async {
        await PCLink.bye()
        connection = nil
        connectionMessage = "切断しました"
    }

    // MARK: スクリーンショットから読み取る（端末内だけで解析し、画像は保存も送信もしない）

    func importScreenshot(_ data: Data) {
        readingScreenshot = true
        boardMessage = nil
        let size = settings.fixedSize
        let cls = ColorClassifier(learned: SharedStore.loadLearned())
        Task.detached(priority: .userInitiated) {
            let decoded = AppModel.decode(data)
            let imageSize = decoded.map { ($0.width, $0.height) }
            let reading = decoded.flatMap { BoardDetector.detect($0, fixedSize: size, classifier: cls) }
            await MainActor.run {
                self.readingScreenshot = false
                guard let imageSize else {
                    self.boardMessage = "画像を読み込めませんでした"
                    return
                }
                guard let rd = reading else {
                    self.boardMessage = "スクリーンショットから盤面が見つかりませんでした。パズル画面のスクリーンショットを選んでください（盤面サイズを手動で選ぶと見つかることがあります）"
                    return
                }
                self.cancelFlag?.cancel()
                self.showingSample = false
                self.screenshotReading = rd
                self.screenshotSize = imageSize
                self.board = rd.board
                self.confidence = rd.cells.map { $0.confidence }
                self.colors = rd.cells.map { $0.color }
                self.coveredCells = Set(rd.cells.indices.filter { rd.cells[$0].covered == true })
                self.progress = nil
                self.offRoute = false
                self.correctionNote = nil
                self.edited = true    // 画面共有の結果で上書きしない
                self.boardMessage = "スクリーンショットの盤面を読み取りました（画像は保存していません）"
                self.resolve()
            }
        }
    }

    /// 画像を RGBA の画素に直す（sRGB）
    nonisolated static func decode(_ data: Data) -> RGBAImageSource? {
        guard let img = UIImage(data: data)?.cgImage else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0, w * h <= 40_000_000 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return RGBAImageSource(width: w, height: h, rowBytes: w * 4, bytes: px)
    }

    /// 診断情報（各マスの判定と代表色の数値だけ。画像は含まない）
    var diagnosticsText: String? {
        if let r = screenshotReading {
            return RecognitionDiagnostics.text(r, source: "スクリーンショット", imageSize: screenshotSize)
        }
        guard let l = latest, let r = l.reading else { return nil }
        let size = l.frameSize.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        return RecognitionDiagnostics.text(r, source: "画面共有 " + (l.videoFormat ?? ""), imageSize: size)
    }

    func copyDiagnostics() {
        guard let t = diagnosticsText else {
            boardMessage = "まだ読み取った盤面がありません"
            return
        }
        UIPasteboard.general.string = t
        boardMessage = "診断情報をコピーしました。チャットに貼り付けて送ってください（画像は含まれていません）"
    }

    // MARK: 見本盤面

    /// 画面共有なしでも、アプリ単体で盤面認識後の表示・探索・ルート表示を試せる。
    /// 第三者のゲーム画像や素材は使わず、アプリ独自の色と記号だけで構成する。
    func loadSampleBoard() {
        cancelFlag?.cancel()
        // App Group に前回の画面共有結果が残っていても、見本を開いた直後に
        // poll() が古い結果で上書きしないよう、現在の seq を既読にする。
        let current = SharedStore.readLatest()
        latest = current
        lastSeq = current?.seq ?? -1
        edited = false
        correctionNote = nil
        showingSample = true
        result = nil
        progress = nil
        offRoute = false
        let b = Board(size: .sixByFive, string: """
            RBGLDH
            HRBLGD
            DHRBGL
            LDHRBG
            GLDHRB
            """)
        board = b
        confidence = Array(repeating: 0.98, count: b.size.count)
        colors = []
        coveredCells = []
        resolve()
    }

    func clearSampleBoard() {
        guard showingSample else { return }
        cancelFlag?.cancel()
        showingSample = false
        board = nil
        result = nil
        confidence = []
        colors = []
        coveredCells = []
        progress = nil
        offRoute = false
        solving = false
    }

    /// UI テスト用。手動修正テストのため 1 マスだけ不明を含める。
    private func loadTestDemo() {
        let b = Board(size: .sixByFive, string: """
            RBGLDH
            HRB?GL
            DHRBGL
            LDHRBG
            GLDHRB
            """)
        board = b
        confidence = b.cells.map { $0 == .unknown ? 0.2 : 0.9 }
        colors = []
        coveredCells = []
        resolve()
    }
}

/// 盤面のマスを押したときの動作
enum CellTool: String, CaseIterable, Identifiable {
    case color, start, blocked, thorn, hidden
    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: return "色を直す"
        case .start: return "開始位置"
        case .blocked: return "操作不可"
        case .thorn: return "棘"
        case .hidden: return "雲・ルーレット"
        }
    }

    var mark: BoardConstraints.CellMark? {
        switch self {
        case .color: return nil
        case .start: return .start
        case .blocked: return .blocked
        case .thorn: return .thorn
        case .hidden: return .hidden
        }
    }
}

import Foundation
import SwiftUI
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
    @Published private(set) var edited = false
    @Published private(set) var solving = false
    @Published private(set) var learnedCount = 0

    private var colors: [RGB] = []
    private var latest: LatestState?
    private var lastSeq = -1
    private var timer: Timer?
    private var pingCounter = 0
    private var cancelFlag: CancellationFlag?
    let isUITest = ProcessInfo.processInfo.arguments.contains("-uitest")

    init() {
        settings = SharedStore.loadSettings()
        connection = SharedStore.connection
        learnedCount = SharedStore.loadLearned().count
        if ProcessInfo.processInfo.arguments.contains("-demoBoard") { loadDemo() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
                if !edited { apply(l) }
            }
        } else if latest != nil {
            // 画面共有が終わってデータが消された
            latest = nil
            lastSeq = -1
            if !edited { board = nil; result = nil; confidence = []; colors = [] }
        }
        // 接続状態の確認（約 10 秒ごと）
        pingCounter += 1
        if pingCounter % 20 == 0, !isUITest, SharedStore.connection != nil {
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
        let size = BoardSize(cols: r.cols, rows: r.rows)
        board = Board(size: size, cells: r.cells.map { OrbKind(key: $0) ?? .unknown })
        confidence = r.confidence.count == size.count ? r.confidence : Array(repeating: 1, count: size.count)
        colors = l.reading?.cells.map { $0.color } ?? []
        result = r
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
        b.cells[index] = kind
        board = b
        if index < confidence.count { confidence[index] = 1 }
        edited = true
        resolve()
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
        let conf = confidence
        let source = edited ? "iphone-manual" : "iphone"
        Task.detached(priority: .userInitiated) {
            let route = Solver.solve(b, options: opts, cancel: flag)
            let msg = ResultMessage.make(board: b, confidence: conf, route: route, goals: goals,
                                         status: route.result.combos > 0 ? "ok" : "nocombo", source: source)
            await MainActor.run {
                guard !flag.isCancelled else { return }
                self.result = msg
                self.solving = false
            }
            if !flag.isCancelled { PCLink.push(msg) }
        }
    }

    func revertToAuto() {
        edited = false
        if let l = latest { apply(l) } else { board = nil; result = nil }
    }

    func resetLearned() {
        SharedStore.saveLearned([])
        learnedCount = 0
    }

    var lowConfidenceCount: Int { confidence.filter { $0 < BoardReading.lowConfidence }.count }
    var unknownCount: Int { board?.unknownCount ?? 0 }

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

    // MARK: UI テスト用の見本盤面（独自の配色。実際の画面は使わない）

    private func loadDemo() {
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
        resolve()
    }
}

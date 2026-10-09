import ReplayKit
import PuzzleCore

/// 画面共有（Broadcast Upload Extension）
/// - ユーザーが iOS 標準の画面で共有を開始したときだけ動く
/// - フレームは端末内で解析し、画像は保存・送信しない
/// - 盤面が確定して変化したときだけルートを計算し、結果（盤面・信頼度・ルート）だけを PC へ送る
/// - 共有終了でデータを破棄する
final class SampleHandler: RPBroadcastSampleHandler {

    private let session = LiveSession()
    private let solveQueue = DispatchQueue(label: "puzzleroute.solve", qos: .userInitiated)
    private let lock = NSLock()

    private var lastFrame = 0.0
    private var lastHeartbeat = 0.0
    private var lastReload = 0.0
    private var lastDetect = 0.0
    private var lastStatusSent = 0.0
    private var settings = AppSettings()
    private var classifier = ColorClassifier()
    private var rect: BoardRect?
    private var badFrames = 0
    private var lastGoodFrame = 0.0
    // 表示中のルートと、操作の進み具合
    private var tracker: RouteTracker?
    private var shownResult: ResultMessage?
    private var shownReading: BoardReading?
    private var hasResult = false
    private var seq = 0
    private var cancelFlag: CancellationFlag?
    private var videoFormat = ""
    /// ルーレットの自動判定（画面の変化だけで判断する。見つけたマスは「見ないマス」に足すだけで、手動の設定は変えない）
    private var roulette = RouletteDetector()
    /// 小窓・アプリへ知らせる、自動で見つけたルーレットのマス（別スレッドから読むので lock で守る）
    private var autoHiddenSnapshot: [Int] = []
    private var rouletteInfo = ""
    private var rouletteRect: BoardRect?
    /// 画面から自動で見つけた操作不可（テープ）のマス（ちらつかないように数フレーム続けて見えたものだけ使う）
    private var tape = TapeTracker()
    private var autoTapedSnapshot: [Int] = []
    private var frameSize: [Int] = []

    private func now() -> Double { Date().timeIntervalSince1970 }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        session.begin()
        roulette.reset()
        tape.reset()
        reloadSettings()
        SharedStore.heartbeat()
        SharedStore.clearLatest()
        PCLink.share("started")
    }

    override func broadcastFinished() {
        cancelFlag?.cancel()
        session.end()                       // 保持しているデータを破棄
        roulette.reset()
        tape.reset()
        lock.lock(); tracker = nil; shownResult = nil; shownReading = nil; lock.unlock()
        SharedStore.clearLatest()
        SharedStore.clearHeartbeat()
        let done = DispatchSemaphore(value: 0)
        PCLink.share("ended") { done.signal() }   // PC 側でもデータを破棄
        _ = done.wait(timeout: .now() + 1.5)
    }

    override func broadcastPaused() { SharedStore.clearHeartbeat() }
    override func broadcastResumed() { SharedStore.heartbeat() }

    private func reloadSettings() {
        settings = SharedStore.loadSettings()
        classifier = ColorClassifier(learned: SharedStore.loadLearned())
        lastReload = now()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        let t = now()
        if t - lastHeartbeat > 1 { SharedStore.heartbeat(); lastHeartbeat = t }
        if t - lastFrame < 0.25 { return }          // 1 秒に約 4 回だけ解析
        lastFrame = t
        if t - lastReload > 2 { reloadSettings() }
        if SharedStore.takeForceSolve() {   // アプリで「今の画面で計算し直す」・縛りの変更
            reloadSettings()
            session.forceNextSolve()
        }

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let src = FrameSource(pb), src.height > src.width else { return }   // 縦画面のみ
        let fmt = src.formatDescription
        lock.lock(); videoFormat = fmt; frameSize = [src.width, src.height]; lock.unlock()

        // 盤面の位置：見失ったときだけ探し直す（1 秒に 1 回まで）
        if rect == nil || (rect?.size != settings.fixedSize && settings.fixedSize != nil) {
            guard t - lastDetect > 1 else { return }
            lastDetect = t
            rect = BoardDetector.detect(src, fixedSize: settings.fixedSize, classifier: classifier)?.rect
            guard rect != nil else { reportStatus("invalid", t); return }
        }
        guard let r = rect else { return }
        // 小窓（アプリ自身の盤面の図）を読んでいたら、位置を探し直す
        if BoardDetector.looksLikeOwnDrawing(src, r) {
            rect = nil
            session.invalidate()
            return
        }
        let reading = BoardReader.read(src, rect: r, classifier: classifier)

        guard reading.isUsable else {
            badFrames += 1
            if badFrames >= 3 {        // しばらく読めなければ盤面を探し直す
                rect = nil
                session.invalidate()
            }
            reportStatus(reading.isDark || reading.dimmed == true ? "dark" : "invalid", t)
            return
        }
        badFrames = 0
        lastGoodFrame = t

        // 盤面の位置の見直し（約3秒ごと）：もっとはっきり読める位置があれば切り替える
        // （最初に盤面の上の表示を盤面と間違えて、数段ずれたまま読み続けることを防ぐ）
        if t - lastDetect > 3 {
            lastDetect = t
            if let better = BoardDetector.detect(src, fixedSize: settings.fixedSize, classifier: classifier),
               Self.differs(better.rect, r),
               BoardDetector.placementScore(better, screenHeight: Double(src.height))
                > BoardDetector.placementScore(reading, screenHeight: Double(src.height)) + 0.03 {
                rect = better.rect
                session.forceNextSolve()
                return
            }
        }

        // ルーレットの自動判定：見つけたマスが変わったら、そのマスを見ないで計算し直す
        // （盤面の位置が変わったときだけやり直す。演出中などに一時的に読めなくなっても、見つけたマスは保つ）
        if let old = rouletteRect, Self.differs(old, r) { roulette.reset(); tape.reset() }
        rouletteRect = r

        // 操作不可（テープ）の自動判定：貼られた・はがれたら計算し直す（ドロップを動かしている最中は計算し直さない）
        let tapeChanged = tape.feed(Set(reading.taped ?? []))
        lock.lock(); let moving = (tracker?.progress ?? 0) > 0; autoTapedSnapshot = tape.cells.sorted(); lock.unlock()
        if tapeChanged && !moving { session.forceNextSolve() }

        if settings.autoRouletteOn {
            // テープのマスはルーレットではない（帯の下のドロップの色の読み違いを、ルーレットと間違えないように見ない）
            var kinds = reading.cells.map { $0.kind }
            for i in tape.cells where i < kinds.count { kinds[i] = .unknown }
            if roulette.feed(kinds) { session.forceNextSolve() }
        } else if !roulette.cells.isEmpty {
            roulette.reset()
            session.forceNextSolve()
        }

        // 雲・ルーレットに指定したマス（手動）と、自動で見つけたルーレットのマスは見ない
        // （色が変わり続けても、盤面が変わったとみなさない）
        let ignored = Array(Set(settings.constraints?.effective(for: r.size)?.hidden ?? []).union(roulette.cells)).sorted()
        session.setIgnored(ignored)
        let rInfo = settings.autoRouletteOn ? roulette.diagnostics(cols: r.size.cols) : "ルーレット判定：オフ"
        lock.lock(); autoHiddenSnapshot = roulette.cells.sorted(); rouletteInfo = rInfo; lock.unlock()

        // ルート表示中：今の盤面からどこまで操作が進んだかを推定して知らせる
        lock.lock()
        tracker?.ignored = Set(ignored)
        var tr = tracker
        let changed = tr?.update(reading.cells.map { $0.kind }) ?? false
        if changed { tracker = tr }
        let res = shownResult, rd = shownReading
        lock.unlock()
        if changed, let res, let tr {
            publish(res, reading: rd, progress: tr.progress, offRoute: tr.offRoute, sendToPC: false)
        }

        // 同じ盤面が続いて確定し、前回と違うときだけ再計算
        guard session.feed(reading) else {
            if !hasResult { reportStatus("unstable", t) }
            return
        }
        solve(reading)
    }

    private func solve(_ reading: BoardReading) {
        cancelFlag?.cancel()                 // 前の計算は中断
        let flag = CancellationFlag()
        cancelFlag = flag
        var options = settings.solverOptions
        // 自動で見つけた操作不可（テープ）のマスは、動かせず指で通れないマスとして計算する
        options.constraints = BoardConstraints.merging(options.constraints, autoBlocked: Array(tape.cells), size: reading.size)
        let autoHidden = roulette.cells
        let goals = settings.goals
        // 直近のフレームの多数決で確定した盤面を使う（1フレームだけの読み違いを入れない）
        let stable = session.stableCells
        solveQueue.async { [weak self] in
            guard let self, !flag.isCancelled else { return }
            var board = reading.board
            if let st = stable, st.count == board.cells.count { board = Board(size: board.size, cells: st) }
            let route = Solver.solve(board, options: options, cancel: flag)
            guard !flag.isCancelled else { return }
            let msg = ResultMessage.make(board: board, confidence: reading.cells.map { $0.confidence }, route: route,
                                         goals: goals, status: route.result.combos > 0 ? "ok" : "nocombo", source: "iphone",
                                         constraints: options.constraints)
            self.session.store(result: msg)
            var newTracker = msg.status == "ok" ? RouteTracker(board: board, path: msg.path) : nil
            newTracker?.ignored = Set(options.constraints?.effective(for: board.size)?.hidden ?? []).union(autoHidden)
            // このルートで起こりうる盤面を登録（これと違う盤面になったら自動で読み直す）
            self.session.setRoute(boards: newTracker?.boards ?? [board.cells])
            self.lock.lock()
            self.tracker = newTracker
            self.shownResult = msg
            self.shownReading = reading
            self.lock.unlock()
            self.publish(msg, reading: reading, progress: msg.status == "ok" ? 0 : nil)
            self.hasResult = true
        }
    }

    /// 盤面の位置が意味のある大きさで違うか
    static func differs(_ a: BoardRect, _ b: BoardRect) -> Bool {
        a.size != b.size || abs(a.x - b.x) > a.cell * 0.2 || abs(a.y - b.y) > a.cell * 0.2 || abs(a.cell - b.cell) > a.cell * 0.03
    }

    /// 結果がまだないときだけ、状態（読めない・暗い・変化中）を 1 秒に 1 回まで知らせる
    private func reportStatus(_ status: String, _ t: Double) {
        if hasResult && status == "unstable" { return }
        // ルート表示中は、操作中に指で隠れたりコンボ演出で読めなくなったりするので、すぐには消さない
        if hasResult && t - lastGoodFrame < 10 { return }
        guard t - lastStatusSent > 1 else { return }
        lastStatusSent = t
        if hasResult {
            hasResult = false
            lock.lock(); tracker = nil; shownResult = nil; shownReading = nil; lock.unlock()
        }
        let size = rect?.size ?? .sixByFive
        let empty = Board(size: size, cells: Array(repeating: .unknown, count: size.count))
        let msg = ResultMessage.make(board: session.lastReading?.board ?? empty, confidence: [], route: nil,
                                     goals: settings.goals, status: status, source: "iphone")
        publish(msg, reading: session.lastReading)
    }

    private func publish(_ msg: ResultMessage, reading: BoardReading?, progress: Int? = nil, offRoute: Bool = false,
                         sendToPC: Bool = true) {
        lock.lock(); seq += 1; let s = seq; let vf = videoFormat; let fs = frameSize; let ah = autoHiddenSnapshot; let ri = rouletteInfo; let at = autoTapedSnapshot; lock.unlock()
        SharedStore.writeLatest(LatestState(seq: s, reading: reading, result: msg, progress: progress, offRoute: offRoute,
                                            videoFormat: vf, frameSize: fs, autoHidden: ah.isEmpty ? nil : ah,
                                            rouletteInfo: ri.isEmpty ? nil : ri, autoTaped: at.isEmpty ? nil : at))
        if sendToPC { PCLink.push(msg) }
    }
}

/// CVPixelBuffer（BGRA または YUV420）から必要な画素だけ読む（コピーしないのでメモリを使わない）
/// YUV の映像は、映像に付いている変換式（BT.601 / 709 / 2020）と範囲（フル／ビデオ）に合わせて RGB に直す
struct FrameSource: PixelSource {
    let width: Int, height: Int
    private let bgra: Bool
    private let p0: UnsafePointer<UInt8>, s0: Int
    private let p1: UnsafePointer<UInt8>?, s1: Int
    let converter: YCbCrConverter?

    init?(_ pb: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(pb)
        height = CVPixelBufferGetHeight(pb)
        let format = CVPixelBufferGetPixelFormatType(pb)
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let b = CVPixelBufferGetBaseAddress(pb) else { return nil }
            bgra = true
            p0 = UnsafePointer(b.assumingMemoryBound(to: UInt8.self)); s0 = CVPixelBufferGetBytesPerRow(pb)
            p1 = nil; s1 = 0
            converter = nil
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
            bgra = false
            p0 = UnsafePointer(y.assumingMemoryBound(to: UInt8.self)); s0 = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            p1 = UnsafePointer(uv.assumingMemoryBound(to: UInt8.self)); s1 = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            converter = YCbCrConverter(matrix: Self.matrix(of: pb, height: height),
                                       fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        default:
            return nil
        }
    }

    /// 映像に付いている変換式を読む（なければ映像の大きさから決める）
    static func matrix(of pb: CVPixelBuffer, height: Int) -> YCbCrConverter.Matrix {
        if let v = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil), let s = v as? String {
            if s == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { return .bt709 }
            if s == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) { return .bt601 }
            if s == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return .bt2020 }
        }
        return YCbCrConverter.defaultMatrix(height: height)
    }

    /// 診断用：映像の形式（例 "YUV フルレンジ / bt709"）
    var formatDescription: String {
        guard let c = converter else { return "BGRA" }
        return "YUV \(c.fullRange ? "フルレンジ" : "ビデオレンジ") / \(c.matrix.rawValue)"
    }

    func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        if bgra {
            let i = y * s0 + x * 4
            return (p0[i + 2], p0[i + 1], p0[i])
        }
        let Y = p0[y * s0 + x]
        let j = (y / 2) * s1 + (x / 2) * 2
        return converter!.rgb(Y, p1![j], p1![j + 1])
    }
}

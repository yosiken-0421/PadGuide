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

    private func now() -> Double { Date().timeIntervalSince1970 }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        session.begin()
        reloadSettings()
        SharedStore.heartbeat()
        SharedStore.clearLatest()
        PCLink.share("started")
    }

    override func broadcastFinished() {
        cancelFlag?.cancel()
        session.end()                       // 保持しているデータを破棄
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
        if SharedStore.takeForceSolve() { session.forceNextSolve() }   // アプリで「今の画面で計算し直す」

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let src = FrameSource(pb), src.height > src.width else { return }   // 縦画面のみ

        // 盤面の位置：見失ったときだけ探し直す（1 秒に 1 回まで）
        if rect == nil || (rect?.size != settings.fixedSize && settings.fixedSize != nil) {
            guard t - lastDetect > 1 else { return }
            lastDetect = t
            rect = BoardDetector.detect(src, fixedSize: settings.fixedSize, classifier: classifier)?.rect
            guard rect != nil else { reportStatus("invalid", t); return }
        }
        guard let r = rect else { return }
        let reading = BoardReader.read(src, rect: r, classifier: classifier)

        guard reading.isUsable else {
            badFrames += 1
            if badFrames >= 3 {        // しばらく読めなければ盤面を探し直す
                rect = nil
                session.invalidate()
            }
            reportStatus(reading.isDark ? "dark" : "invalid", t)
            return
        }
        badFrames = 0
        lastGoodFrame = t

        // ルート表示中：今の盤面からどこまで操作が進んだかを推定して知らせる
        lock.lock()
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
        let options = settings.solverOptions
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
                                         goals: goals, status: route.result.combos > 0 ? "ok" : "nocombo", source: "iphone")
            self.session.store(result: msg)
            let newTracker = msg.status == "ok" ? RouteTracker(board: board, path: msg.path) : nil
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
        lock.lock(); seq += 1; let s = seq; lock.unlock()
        SharedStore.writeLatest(LatestState(seq: s, reading: reading, result: msg, progress: progress, offRoute: offRoute))
        if sendToPC { PCLink.push(msg) }
    }
}

/// CVPixelBuffer（BGRA または YUV420）から必要な画素だけ読む（コピーしないのでメモリを使わない）
struct FrameSource: PixelSource {
    let width: Int, height: Int
    private let bgra: Bool
    private let p0: UnsafePointer<UInt8>, s0: Int
    private let p1: UnsafePointer<UInt8>?, s1: Int

    init?(_ pb: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(pb)
        height = CVPixelBufferGetHeight(pb)
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_32BGRA:
            guard let b = CVPixelBufferGetBaseAddress(pb) else { return nil }
            bgra = true
            p0 = UnsafePointer(b.assumingMemoryBound(to: UInt8.self)); s0 = CVPixelBufferGetBytesPerRow(pb)
            p1 = nil; s1 = 0
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
            bgra = false
            p0 = UnsafePointer(y.assumingMemoryBound(to: UInt8.self)); s0 = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            p1 = UnsafePointer(uv.assumingMemoryBound(to: UInt8.self)); s1 = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        default:
            return nil
        }
    }

    func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        if bgra {
            let i = y * s0 + x * 4
            return (p0[i + 2], p0[i + 1], p0[i])
        }
        let Y = Double(p0[y * s0 + x])
        let j = (y / 2) * s1 + (x / 2) * 2
        let cb = Double(p1![j]) - 128, cr = Double(p1![j + 1]) - 128
        func c(_ v: Double) -> UInt8 { UInt8(min(max(v, 0), 255)) }
        return (c(Y + 1.402 * cr), c(Y - 0.344136 * cb - 0.714136 * cr), c(Y + 1.772 * cb))
    }
}

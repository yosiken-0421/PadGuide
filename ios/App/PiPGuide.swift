import UIKit
import SwiftUI
import AVKit
import AVFoundation
import CoreMedia
import PuzzleCore

/// iPhone だけで使うときの小窓表示（ピクチャ・イン・ピクチャ）。
/// iOS では他アプリの上に自由に描けないため、盤面とルートの図を小窓に表示する。
///
/// 前回（ビルド 1006）は表示レイヤーが画面に入っておらず、iOS が「開始できない」と判断して
/// 何も起きなかった。今回は：
/// - 表示レイヤーを常に画面下部のバーに置く（有効なサイズで表示中）
/// - 再生用の時刻（タイムベース）を設定し、開始前から有効なフレームを送り続ける
/// - 開始可能かを監視し、できないときはボタンを無効にして理由を表示する
/// - 開始・停止・失敗を画面の状態に反映し、連打による二重起動を防ぐ
@MainActor
final class PiPGuide: NSObject, ObservableObject {
    @Published private(set) var state: PiPState
    var supported: Bool { state.supported }
    var possible: Bool { state.possible }
    var active: Bool { state.active }
    var starting: Bool { state.starting }
    var lastError: String? { state.lastError }

    /// UI テスト用：開始の失敗を再現する（-pipSimulateFailure）
    private let simulateFailure = ProcessInfo.processInfo.arguments.contains("-pipSimulateFailure")

    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var timer: Timer?
    private var timebase: CMTimebase?
    private var provider: @MainActor () -> PiPContent = { PiPContent() }
    private var lastKey = ""
    private var lastImage: CGImage?
    private var framesSent = 0
    static let renderSize = CGSize(width: 600, height: 650)

    override init() {
        let forced = ProcessInfo.processInfo.arguments.contains("-pipSimulateFailure")
        state = PiPState(supported: forced || AVPictureInPictureController.isPictureInPictureSupported())
        super.init()
        displayLayer.videoGravity = .resizeAspect
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1.0)
            displayLayer.controlTimebase = tb
            timebase = tb
        }
    }

    /// 画面に表示されたら一度だけ呼ぶ
    func prepare(autoStart _: Bool, provider: @escaping @MainActor () -> PiPContent) {
        self.provider = provider
        guard controller == nil else { return }
        // 小窓には「再生」用の音声設定が必要（音は鳴らさない。ゲームの音を止めないよう他の音と混ぜる設定）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        // 小窓は必ずユーザーが「小窓で表示」を押したときだけ開始する。
        try? AVAudioSession.sharedInstance().setActive(true)
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: false) }
        }
        if simulateFailure {
            state.setPrepared()
            state.setPossible(true)
            return
        }
        guard supported else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.requiresLinearPlayback = true
        // App Store の要件に合わせ、バックグラウンド遷移だけで自動開始しない。
        c.canStartPictureInPictureAutomaticallyFromInline = false
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctl, _ in
            let p = ctl.isPictureInPicturePossible
            Task { @MainActor in self?.state.setPossible(p) }
        }
        controller = c
        state.setPrepared()
    }

    var unavailableReason: String? { state.unavailableReason }
    var canToggle: Bool { state.buttonEnabled }

    func toggle() {
        switch state.pressButton() {
        case .none:
            return                                         // 開始中の連打・開始できない状態（理由は state に入る）
        case .stop:
            controller?.stopPictureInPicture()
        case .start:
            if simulateFailure {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.state.failedToStart("テスト用に失敗を再現しました")
                }
                return
            }
            guard let c = controller else { state.failedToStart("小窓の準備ができていません"); return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                state.failedToStart("音声の設定に失敗しました（\(error.localizedDescription)）")
                return
            }
            refresh(force: true)
            c.startPictureInPicture()
            // 開始も失敗も通知されない場合も、「押しても何も起きない」状態にしない
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.state.startTimedOut()
            }
        }
    }

    // MARK: フレームの作成と送信

    private func refresh(force: Bool) {
        let content = provider()
        let animating = content.result?.status == "ok"
        // ルート表示中は光る点を動かすため毎回描き直す（約7回/秒）。それ以外は内容が変わったときだけ
        let key = content.key
        if force || animating || key != lastKey || lastImage == nil {
            lastKey = key
            let phase: CGFloat? = animating ? CGFloat(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1.6) / 1.6) : nil
            lastImage = Self.render(content, phase: phase)
        }
        // 内容が同じでも送り続ける（小窓が黒くならないように）
        if let img = lastImage { enqueue(img) }
        framesSent += 1
    }

    private func enqueue(_ image: CGImage) {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        let now = timebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 4), presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary], let a = arr.first {
            a[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        // 画面ロックなどで描画が止まったら、黒くなる前にやり直す
        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sb)
    }

    // MARK: 小窓に出す図（盤面・ルート・手順番号・つかむ位置）

    static func render(_ content: PiPContent, phase: CGFloat?) -> CGImage? {
        let size = renderSize
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rc in
            let g = rc.cgContext
            UIColor(red: 0.12, green: 0.15, blue: 0.24, alpha: 1).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            let board = content.board, res = content.result
            let header: CGFloat = 150

            // 1行目：状況
            var title = "画面共有を開始すると、ここにルートが出ます"
            var titleColor = UIColor.white
            if let r = res {
                if r.status == "ok" {
                    let n = r.steps
                    let p = RouteDrawing.nextStep(progress: content.progress, steps: n)
                    if content.offRoute {
                        title = "ルートから外れました（指を離すと次の盤面で計算）"
                        titleColor = UIColor(red: 1, green: 0.55, blue: 0.5, alpha: 1)
                    } else if p >= n {
                        title = "最後まで動かしました。指を離してください"
                        titleColor = UIColor(red: 0.6, green: 1, blue: 0.75, alpha: 1)
                    } else if p > 0 {
                        title = "\(p)/\(n)手　あと\(n - p)手（\(r.combos)コンボ）"
                    } else if let s = RouteText.start(r) {
                        let maxMark = r.reachedMaxCombos ? "(最大)" : "/" + String(r.maxCombos)
                        title = "\(r.combos)\(maxMark)コンボ・\(n)手　START：\(s)"
                    }
                } else {
                    title = RouteText.status(r.status)
                }
            } else if board != nil {
                title = "ルートを計算しています…"
            }
            (title as NSString).draw(in: CGRect(x: 14, y: 8, width: size.width - 28, height: 34),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: titleColor])
            // 2行目：次の手順（大きな矢印）
            if let r = res, r.status == "ok" {
                RouteDrawing.drawNextStrip(g, result: r, progress: content.progress,
                                           in: CGRect(x: 12, y: 50, width: size.width - 24, height: 92))
            }

            guard let b = board else { return }
            let cols = b.size.cols, rows = b.size.rows
            let cell = min(size.width / CGFloat(cols), (size.height - header) / CGFloat(rows))
            let origin = CGPoint(x: (size.width - cell * CGFloat(cols)) / 2, y: header)
            RouteDrawing.drawBoard(g, board: b, origin: origin, cell: cell, drawOrbs: true)
            if let r = res {
                RouteDrawing.drawRoute(g, result: r, origin: origin, cell: cell, progress: content.progress, phase: phase)
            }
        }
        return img.cgImage
    }
}

// MARK: - デリゲート（開始・停止・失敗を画面に反映）

extension PiPGuide: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.state.didStart() }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.state.failedToStart(msg) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.state.didStop() }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension PiPGuide: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)   // 終わりのない表示
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - 表示レイヤーを画面に置く

/// AVSampleBufferDisplayLayer を SwiftUI の画面に組み込む（これがないと小窓を開始できない）
struct PiPLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    final class HostView: UIView {
        var hosted: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.backgroundColor = .black
        v.layer.addSublayer(layer)
        v.hosted = layer
        v.isAccessibilityElement = true
        v.accessibilityLabel = "小窓のプレビュー"
        v.accessibilityIdentifier = "pipPreview"
        return v
    }

    func updateUIView(_ v: HostView, context: Context) {}
}

/// 画面下部に常に表示する小窓のバー（プレビュー・状態・ボタン・診断）
struct PiPBar: View {
    /// UI テスト用：小窓の中身を大きく表示して確認する（-pipPreviewLarge）
    static let large = ProcessInfo.processInfo.arguments.contains("-pipPreviewLarge")
    @ObservedObject var pip: PiPGuide
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                PiPLayerView(layer: pip.displayLayer)
                    .frame(width: Self.large ? 230 : 96, height: Self.large ? 249 : 104)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        pip.toggle()
                    } label: {
                        Label(pip.active ? "小窓を閉じる" : (pip.starting ? "開始しています…" : "小窓で表示"),
                              systemImage: "pip")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!pip.canToggle)
                    .accessibilityIdentifier("pipButton")
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(pip.lastError == nil ? Color.secondary : Color.red)
                        .accessibilityIdentifier("pipStatus")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    showDiagnostics.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("小窓の診断")
                .accessibilityIdentifier("pipInfoButton")
            }
            if showDiagnostics {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(pip.state.diagnostics.enumerated()), id: \.offset) { i, line in
                        Text(line).accessibilityIdentifier(["pipSupported", "pipPossible", "pipActive", "pipLastError", "pipReason"][min(i, 4)])
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusText: String { pip.state.statusText }
}

/// 小窓に表示する内容
struct PiPContent {
    var board: Board?
    var result: ResultMessage?
    var progress: Int?
    var offRoute = false

    var key: String {
        "\(board?.raw.map(String.init).joined() ?? "-")|\(result?.status ?? "-")|\(result?.path.map(String.init).joined(separator: ",") ?? "")|\(progress ?? -1)|\(offRoute)"
    }
}

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
    private var provider: @MainActor () -> (Board?, ResultMessage?) = { (nil, nil) }
    private var lastKey = ""
    private var lastImage: CGImage?
    private var framesSent = 0
    static let renderSize = CGSize(width: 600, height: 560)

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
    func prepare(autoStart: Bool, provider: @escaping @MainActor () -> (Board?, ResultMessage?)) {
        self.provider = provider
        guard controller == nil else { return }
        // 小窓には「再生」用の音声設定が必要（音は鳴らさない。ゲームの音を止めないよう他の音と混ぜる設定）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        // ゲームへ切り替えたときの自動開始にも必要なので、最初から有効にしておく（他の音は止めない）
        try? AVAudioSession.sharedInstance().setActive(true)
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
        // ゲームへ切り替えたとき自動で小窓にする
        c.canStartPictureInPictureAutomaticallyFromInline = autoStart
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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
        let (board, res) = provider()
        let key = Self.contentKey(board: board, res: res)
        let changed = force || key != lastKey || lastImage == nil
        if changed {
            lastKey = key
            lastImage = Self.render(board: board, res: res)
        }
        // 内容が同じでも送り続ける（小窓が黒くならないように）
        if let img = lastImage { enqueue(img) }
        framesSent += 1
    }

    private static func contentKey(board: Board?, res: ResultMessage?) -> String {
        "\(board?.raw.map(String.init).joined() ?? "-")|\(res?.status ?? "-")|\(res?.path.map(String.init).joined(separator: ",") ?? "")"
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

    static func render(board: Board?, res: ResultMessage?) -> CGImage? {
        let size = renderSize
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rc in
            let g = rc.cgContext
            UIColor(red: 0.15, green: 0.19, blue: 0.29, alpha: 1).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            let header: CGFloat = 72
            var title = "画面共有を開始すると、ここにルートが出ます"
            var sub = ""
            if let r = res {
                if r.status == "ok" {
                    title = "\(r.combos)コンボ・\(r.steps)手"
                    if let s = RouteText.start(r) { sub = "つかむ：" + s }
                } else {
                    title = RouteText.status(r.status)
                }
            } else if board != nil {
                title = "ルートを計算しています…"
            }
            (title as NSString).draw(in: CGRect(x: 16, y: 8, width: size.width - 32, height: 36),
                                     withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28), .foregroundColor: UIColor.white])
            (sub as NSString).draw(in: CGRect(x: 16, y: 42, width: size.width - 32, height: 28),
                                   withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                                                    .foregroundColor: UIColor(red: 0.72, green: 0.95, blue: 0.82, alpha: 1)])
            guard let b = board else { return }
            let cols = b.size.cols, rows = b.size.rows
            let cell = min(size.width / CGFloat(cols), (size.height - header) / CGFloat(rows))
            let ox = (size.width - cell * CGFloat(cols)) / 2
            let oy = header
            for i in 0..<b.size.count {
                let x = ox + CGFloat(i % cols) * cell
                let y = oy + CGFloat(i / cols) * cell
                let even = (i / cols + i % cols) % 2 == 0
                (even ? UIColor(red: 0.18, green: 0.22, blue: 0.33, alpha: 1) : UIColor(red: 0.21, green: 0.26, blue: 0.37, alpha: 1)).setFill()
                g.fill(CGRect(x: x, y: y, width: cell, height: cell))
                UIColor(OrbStyle.color(b.cells[i])).setFill()
                g.fillEllipse(in: CGRect(x: x + cell * 0.1, y: y + cell * 0.1, width: cell * 0.8, height: cell * 0.8))
            }
            guard let r = res, r.status == "ok", let start = r.start, !r.arrows.isEmpty else { return }
            let n = r.arrows.count
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell)
            }
            g.setLineCap(.round)
            g.setLineJoin(.round)
            for (i, a) in r.arrows.enumerated() {
                let p1 = pt(a[0], a[1]), p2 = pt(a[2], a[3])
                let frac = n > 1 ? CGFloat(i) / CGFloat(n - 1) : 0
                let color = UIColor(hue: (350 - 92 * frac) / 360, saturation: 0.75, brightness: 1, alpha: 1)
                g.setStrokeColor(UIColor.black.withAlphaComponent(0.75).cgColor)
                g.setLineWidth(cell * 0.13 + 4)
                g.move(to: p1); g.addLine(to: p2); g.strokePath()
                g.setStrokeColor(color.cgColor)
                g.setLineWidth(cell * 0.13)
                g.move(to: p1); g.addLine(to: p2); g.strokePath()
                // 矢じり
                let ang = atan2(p2.y - p1.y, p2.x - p1.x), s = cell * 0.22
                let t = CGPoint(x: p1.x + (p2.x - p1.x) * 0.72, y: p1.y + (p2.y - p1.y) * 0.72)
                g.beginPath()
                g.move(to: CGPoint(x: t.x + s * cos(ang), y: t.y + s * sin(ang)))
                g.addLine(to: CGPoint(x: t.x + s * 0.8 * cos(ang + 2.45), y: t.y + s * 0.8 * sin(ang + 2.45)))
                g.addLine(to: CGPoint(x: t.x + s * 0.8 * cos(ang - 2.45), y: t.y + s * 0.8 * sin(ang - 2.45)))
                g.closePath()
                g.setFillColor(color.cgColor)
                g.fillPath()
            }
            // 手順番号（交差しても順番が分かるように）
            let every = n > 24 ? 2 : 1
            let rr = max(11, cell * 0.15)
            for i in stride(from: 0, to: n, by: every) {
                let a = r.arrows[i]
                let m = CGPoint(x: (pt(a[0], a[1]).x + pt(a[2], a[3]).x) / 2, y: (pt(a[0], a[1]).y + pt(a[2], a[3]).y) / 2)
                UIColor.white.setFill()
                g.fillEllipse(in: CGRect(x: m.x - rr, y: m.y - rr, width: rr * 2, height: rr * 2))
                let label = "\(i + 1)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: rr * 1.1),
                                                            .foregroundColor: UIColor(red: 0.1, green: 0.13, blue: 0.22, alpha: 1)]
                let ls = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: m.x - ls.width / 2, y: m.y - ls.height / 2), withAttributes: attrs)
            }
            // つかむドロップ（緑の輪）と離す位置（白い四角）
            let sp = pt(Double(start % cols) + 0.5, Double(start / cols) + 0.5)
            g.setStrokeColor(UIColor(red: 0.17, green: 0.83, blue: 0.56, alpha: 1).cgColor)
            g.setLineWidth(max(5, cell * 0.09))
            g.strokeEllipse(in: CGRect(x: sp.x - cell * 0.46, y: sp.y - cell * 0.46, width: cell * 0.92, height: cell * 0.92))
            if let last = r.arrows.last {
                let e = pt(last[2], last[3]), es = cell * 0.15
                UIColor.white.setFill()
                g.fill(CGRect(x: e.x - es, y: e.y - es, width: es * 2, height: es * 2))
                g.setStrokeColor(UIColor.black.cgColor)
                g.setLineWidth(3)
                g.stroke(CGRect(x: e.x - es, y: e.y - es, width: es * 2, height: es * 2))
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
    @ObservedObject var pip: PiPGuide
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                PiPLayerView(layer: pip.displayLayer)
                    .frame(width: 96, height: 90)
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

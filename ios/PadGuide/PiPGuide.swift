import UIKit
import AVKit
import AVFoundation
import CoreMedia

/**
 * ピクチャ・イン・ピクチャの小窓に「盤面＋矢印」を描画し続ける。
 * iOS は他アプリの上に自由に描画できないため、この小窓をパズドラの上に浮かべて使う。
 */
final class PiPGuide: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {

    @Published var pipActive = false
    @Published var statusText = "画面ブロードキャスト待ち"

    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var result: GuideResult?
    private var lastMod: Date?
    private var phase: Double = 0
    private let size = CGSize(width: 600, height: 560)

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let src = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            let c = AVPictureInPictureController(contentSource: src)
            c.delegate = self
            c.canStartPictureInPictureAutomaticallyFromInline = true // ホームに戻ると自動で小窓に
            c.requiresLinearPlayback = true
            controller = c
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    func togglePiP() {
        guard let c = controller else { statusText = "この端末は小窓表示に未対応です"; return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    private func tick() {
        // 拡張が書いた結果ファイルが更新されていたら読み込む
        if let attr = try? FileManager.default.attributesOfItem(atPath: Shared.resultURL.path),
           let mod = attr[.modificationDate] as? Date, mod != lastMod {
            lastMod = mod
            if let d = try? Data(contentsOf: Shared.resultURL), let r = try? JSONDecoder().decode(GuideResult.self, from: d) {
                result = r
                phase = 0
                switch r.status {
                case "ok": statusText = "\(r.combos)コンボ（最大\(r.maxCombos)）/ \(r.path.count - 1)手"
                case "nocombo": statusText = "コンボが見つかりませんでした"
                default: statusText = "盤面を探しています…"
                }
            }
        } else if lastMod == nil {
            statusText = "画面ブロードキャスト待ち"
        }
        phase += 1.0 / 15 / max(1.0, 0.6 + Double(result?.path.count ?? 1) * 0.22)
        if phase > 1 { phase -= 1 }
        enqueue(render())
    }

    // MARK: 描画

    private func render() -> CGImage? {
        let r = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let img = r.image { ctx in
            let g = ctx.cgContext
            UIColor(white: 0.08, alpha: 1).setFill(); g.fill(CGRect(origin: .zero, size: size))
            let header: CGFloat = 60
            let cell = size.width / 6
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.white]
            (statusText as NSString).draw(at: CGPoint(x: 16, y: 12), withAttributes: attrs)

            guard let res = result, res.board.count == Orb.cells else { return }
            let colors: [UIColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow, .systemPurple, .systemPink, .gray]
            for i in 0..<Orb.cells {
                let x = CGFloat(i % 6) * cell, y = header + CGFloat(i / 6) * cell
                (((i % 6) + (i / 6)) % 2 == 0 ? UIColor(white: 0.18, alpha: 1) : UIColor(white: 0.24, alpha: 1)).setFill()
                g.fill(CGRect(x: x, y: y, width: cell, height: cell))
                let v = Int(res.board[i])
                colors[max(0, min(6, v))].setFill()
                g.fillEllipse(in: CGRect(x: x + cell * 0.1, y: y + cell * 0.1, width: cell * 0.8, height: cell * 0.8))
                let l = Orb.labels[max(0, min(6, v))] as NSString
                l.draw(at: CGPoint(x: x + cell * 0.32, y: y + cell * 0.28),
                       withAttributes: [.font: UIFont.boldSystemFont(ofSize: cell * 0.32), .foregroundColor: UIColor.white.withAlphaComponent(0.85)])
            }
            guard res.status == "ok", res.path.count >= 2 else { return }
            var visits: [Int: Int] = [:]
            let pts: [CGPoint] = res.path.enumerated().map { (k, idx) in
                let n = visits[idx, default: 0]; visits[idx] = n + 1
                let off = k == 0 ? 0 : CGFloat(n) * cell * 0.09
                return CGPoint(x: (CGFloat(idx % 6) + 0.5) * cell + off, y: header + (CGFloat(idx / 6) + 0.5) * cell + off)
            }
            g.setLineCap(.round); g.setLineJoin(.round)
            for (color, width) in [(UIColor.black, cell * 0.17), (UIColor.white, cell * 0.10)] {
                g.setStrokeColor(color.cgColor); g.setLineWidth(width)
                g.beginPath(); g.addLines(between: pts); g.strokePath()
            }
            for i in 1..<pts.count { drawHead(g, pts[i - 1], pts[i], cell * 0.22) }
            g.setStrokeColor(UIColor.systemGreen.cgColor); g.setLineWidth(cell * 0.08)
            g.strokeEllipse(in: CGRect(x: pts[0].x - cell * 0.2, y: pts[0].y - cell * 0.2, width: cell * 0.4, height: cell * 0.4))
            UIColor.systemRed.setFill()
            g.fill(CGRect(x: pts.last!.x - cell * 0.1, y: pts.last!.y - cell * 0.1, width: cell * 0.2, height: cell * 0.2))
            let d = pointAt(pts, phase)
            UIColor.black.setFill(); g.fillEllipse(in: CGRect(x: d.x - cell * 0.12, y: d.y - cell * 0.12, width: cell * 0.24, height: cell * 0.24))
            UIColor.white.setFill(); g.fillEllipse(in: CGRect(x: d.x - cell * 0.09, y: d.y - cell * 0.09, width: cell * 0.18, height: cell * 0.18))
        }
        return img.cgImage
    }

    private func drawHead(_ g: CGContext, _ a: CGPoint, _ b: CGPoint, _ s: CGFloat) {
        let ang = atan2(b.y - a.y, b.x - a.x)
        let t = CGPoint(x: a.x + (b.x - a.x) * 0.7, y: a.y + (b.y - a.y) * 0.7)
        g.beginPath()
        g.move(to: CGPoint(x: t.x + s * cos(ang), y: t.y + s * sin(ang)))
        g.addLine(to: CGPoint(x: t.x + s * 0.8 * cos(ang + 2.4), y: t.y + s * 0.8 * sin(ang + 2.4)))
        g.addLine(to: CGPoint(x: t.x + s * 0.8 * cos(ang - 2.4), y: t.y + s * 0.8 * sin(ang - 2.4)))
        g.closePath()
        g.setFillColor(UIColor.white.cgColor); g.setStrokeColor(UIColor.black.cgColor); g.setLineWidth(s * 0.25)
        g.drawPath(using: .fillStroke)
    }

    private func pointAt(_ p: [CGPoint], _ t: Double) -> CGPoint {
        let lens = (0..<(p.count - 1)).map { hypot(p[$0 + 1].x - p[$0].x, p[$0 + 1].y - p[$0].y) }
        var target = lens.reduce(0, +) * CGFloat(t)
        for i in lens.indices {
            if target <= lens[i] || i == lens.count - 1 {
                let k = lens[i] == 0 ? 0 : min(1, max(0, target / lens[i]))
                return CGPoint(x: p[i].x + (p[i + 1].x - p[i].x) * k, y: p[i].y + (p[i + 1].y - p[i].y) * k)
            }
            target -= lens[i]
        }
        return p.last!
    }

    // MARK: CGImage → CMSampleBuffer → 表示レイヤー

    private func enqueue(_ image: CGImage?) {
        guard let image else { return }
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
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary], let a = arr.first {
            a[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sb)
    }

    // MARK: PiP delegates

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { pipActive = true }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { pipActive = false }

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

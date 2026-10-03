import UIKit
import AVKit
import AVFoundation
import CoreMedia
import PuzzleCore

/// iPhone 単体で使うときの小窓表示（ピクチャ・イン・ピクチャ）。
/// iOS では他アプリの上に自由に描けないため、盤面とルートの図をこの小窓に表示する。
@MainActor
final class PiPGuide: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published var active = false
    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var provider: @MainActor () -> (Board?, ResultMessage?) = { (nil, nil) }
    private let size = CGSize(width: 600, height: 560)

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    func attach(_ provider: @escaping @MainActor () -> (Board?, ResultMessage?)) {
        self.provider = provider
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        let src = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: src)
        c.delegate = self
        c.requiresLinearPlayback = true
        controller = c
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() }
        else {
            try? AVAudioSession.sharedInstance().setActive(true)
            c.startPictureInPicture()
        }
    }

    private func refresh() {
        let (board, res) = provider()
        guard let img = render(board: board, res: res) else { return }
        enqueue(img)
    }

    private func render(board: Board?, res: ResultMessage?) -> CGImage? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rc in
            let g = rc.cgContext
            UIColor(red: 0.15, green: 0.19, blue: 0.29, alpha: 1).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            var title = "盤面を待っています"
            if let r = res {
                if r.status == "ok" { title = "\(r.combos)コンボ・\(r.steps)手（見つかった候補）" }
                else { title = RouteText.status(r.status) }
            }
            (title as NSString).draw(in: CGRect(x: 14, y: 10, width: size.width - 28, height: 44),
                                     withAttributes: [.font: UIFont.boldSystemFont(ofSize: 26), .foregroundColor: UIColor.white])
            guard let b = board else { return }
            let top: CGFloat = 60
            let cell = min(size.width / CGFloat(b.size.cols), (size.height - top) / CGFloat(b.size.rows))
            let ox = (size.width - cell * CGFloat(b.size.cols)) / 2
            for i in 0..<b.size.count {
                let x = ox + CGFloat(i % b.size.cols) * cell
                let y = top + CGFloat(i / b.size.cols) * cell
                UIColor(OrbStyle.color(b.cells[i])).setFill()
                g.fillEllipse(in: CGRect(x: x + cell * 0.1, y: y + cell * 0.1, width: cell * 0.8, height: cell * 0.8))
            }
            guard let r = res, r.status == "ok", let start = r.start else { return }
            g.setLineCap(.round)
            for (i, a) in r.arrows.enumerated() {
                let p1 = CGPoint(x: ox + CGFloat(a[0]) * cell, y: top + CGFloat(a[1]) * cell)
                let p2 = CGPoint(x: ox + CGFloat(a[2]) * cell, y: top + CGFloat(a[3]) * cell)
                let n = max(1, r.arrows.count - 1)
                let frac = CGFloat(i) / CGFloat(n)
                let hue: CGFloat = (350 - 92 * frac) / 360
                g.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor)
                g.setLineWidth(cell * 0.12 + 3)
                g.move(to: p1); g.addLine(to: p2); g.strokePath()
                g.setStrokeColor(UIColor(hue: hue, saturation: 0.75, brightness: 1, alpha: 1).cgColor)
                g.setLineWidth(cell * 0.12)
                g.move(to: p1); g.addLine(to: p2); g.strokePath()
            }
            let sx = ox + (CGFloat(start % b.size.cols) + 0.5) * cell
            let sy = top + (CGFloat(start / b.size.cols) + 0.5) * cell
            g.setStrokeColor(UIColor.systemGreen.cgColor)
            g.setLineWidth(cell * 0.09)
            g.strokeEllipse(in: CGRect(x: sx - cell * 0.46, y: sy - cell * 0.46, width: cell * 0.92, height: cell * 0.92))
        }
        return img.cgImage
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

    // MARK: デリゲート
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.active = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.active = false }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

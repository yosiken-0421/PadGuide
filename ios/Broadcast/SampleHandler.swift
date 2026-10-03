import ReplayKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/**
 * 画面ブロードキャスト拡張。端末の画面をリアルタイムに受け取り、盤面を読み取って解いた結果を
 * App Group 経由でアプリ本体（ピクチャ・イン・ピクチャ表示）へ渡す。
 * 拡張のメモリ上限は約50MBなので、フレームはコピーせず必要な画素だけ直接読む。
 */
final class SampleHandler: RPBroadcastSampleHandler {

    private let queue = DispatchQueue(label: "pdguide.solve")
    private var busy = false
    private var lastProcessed = 0.0
    private var lastPreview = 0.0
    private var shownBoard: [Int8]?
    private var pendingBoard: [Int8]?
    private var lastStatus = ""

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        shownBoard = nil; pendingBoard = nil
        write(GuideResult(status: "invalid", board: [], path: [], combos: 0, maxCombos: 0, timestamp: Date().timeIntervalSince1970))
    }

    override func broadcastFinished() {
        try? FileManager.default.removeItem(at: Shared.resultURL)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        let now = CACurrentMediaTime()
        if busy || now - lastProcessed < 0.35 { return }
        lastProcessed = now
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let src = BufferSource(pb) else { return }

        // 位置調整用のプレビュー画像（アプリ側で調整画面を開いている時だけ）
        if Shared.wantPreview && now - lastPreview > 1.0 {
            lastPreview = now
            writePreview(src)
        }
        // 自動検出（未調整 or アプリから要求があった時）
        if !Shared.calibrated || Shared.requestAutoDetect {
            Shared.requestAutoDetect = false
            if let r = BoardReader.autoDetect(src) {
                Shared.boardLeft = r.x / Double(src.width)
                Shared.boardTop = r.y / Double(src.height)
                Shared.boardWidth = r.w / Double(src.width)
                Shared.calibrated = true
            }
        }

        let rect = BoardRect(x: Shared.boardLeft * Double(src.width),
                             y: Shared.boardTop * Double(src.height),
                             w: Shared.boardWidth * Double(src.width))
        let rd = BoardReader.read(src, rect)
        guard rd.looksValid else {
            pendingBoard = nil
            if shownBoard != nil || lastStatus != "invalid" {
                shownBoard = nil
                write(GuideResult(status: "invalid", board: rd.board, path: [], combos: 0, maxCombos: 0, timestamp: Date().timeIntervalSince1970))
            }
            return
        }
        if rd.board == shownBoard { return }
        // 2回連続で同じ盤面＝操作が落ち着いた → 解く
        guard rd.board == pendingBoard else { pendingBoard = rd.board; return }
        pendingBoard = nil
        busy = true
        let board = rd.board
        let steps = Shared.maxSteps, diag = Shared.diagonal, beam = Shared.beamWidth
        queue.async { [weak self] in
            let res = Solver(maxSteps: steps, diagonal: diag, beamWidth: beam).solve(board)
            self?.shownBoard = board
            self?.write(GuideResult(status: res.combos > 0 ? "ok" : "nocombo", board: board, path: res.path,
                                    combos: res.combos, maxCombos: res.maxCombos,
                                    timestamp: Date().timeIntervalSince1970))
            self?.busy = false
        }
    }

    private func write(_ r: GuideResult) {
        lastStatus = r.status
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: Shared.resultURL, options: .atomic) }
    }

    /** 縮小プレビュー（幅270px）を JPEG で保存 */
    private func writePreview(_ src: BufferSource) {
        let w = 270
        let h = Int(Double(src.height) * Double(w) / Double(src.width))
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let c = src.rgb(x * src.width / w, y * src.height / h)
            let i = (y * w + x) * 4
            px[i] = UInt8(c.0); px[i + 1] = UInt8(c.1); px[i + 2] = UInt8(c.2)
        }}
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(Shared.previewURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

/** CVPixelBuffer（BGRA または YUV420 NV12）から直接RGBを読む */
struct BufferSource: PixelSource {
    let width: Int, height: Int
    private let bgra: Bool
    private let p0: UnsafePointer<UInt8>, s0: Int
    private let p1: UnsafePointer<UInt8>?, s1: Int

    init?(_ pb: CVPixelBuffer) {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        width = CVPixelBufferGetWidth(pb); height = CVPixelBufferGetHeight(pb)
        switch fmt {
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

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        if bgra {
            let i = y * s0 + x * 4
            return (Int(p0[i + 2]), Int(p0[i + 1]), Int(p0[i]))
        }
        let Y = Double(p0[y * s0 + x])
        let j = (y / 2) * s1 + (x / 2) * 2
        let cb = Double(p1![j]) - 128, cr = Double(p1![j + 1]) - 128
        func clamp(_ v: Double) -> Int { Int(min(max(v, 0), 255)) }
        return (clamp(Y + 1.402 * cr), clamp(Y - 0.344136 * cb - 0.714136 * cr), clamp(Y + 1.772 * cb))
    }
}

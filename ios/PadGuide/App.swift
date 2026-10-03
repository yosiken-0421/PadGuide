import SwiftUI
import ReplayKit

@main
struct PadGuideApp: App {
    @StateObject private var guide = PiPGuide()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(guide) }
    }
}

struct ContentView: View {
    @EnvironmentObject var guide: PiPGuide
    @State private var steps = Double(Shared.maxSteps)
    @State private var diagonal = Shared.diagonal
    @State private var beam = Double([300, 800, 1500, 3000].firstIndex(of: Shared.beamWidth) ?? 1)
    @State private var showCalib = false
    private let beamLevels = [300, 800, 1500, 3000]
    private let beamNames = ["速い", "標準", "高精度", "最高精度（重い）"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // PiP の元になる表示レイヤー（ここに映っている内容が小窓になる）
                    LayerView(layer: guide.displayLayer)
                        .aspectRatio(600.0 / 560.0, contentMode: .fit)
                        .listRowInsets(EdgeInsets())
                    Text(guide.statusText).font(.headline)
                }
                Section("① 画面の読み取りを開始") {
                    HStack {
                        BroadcastButton().frame(width: 50, height: 50)
                        Text("左のボタン →「パズドラ矢印ガイド」を選んで「ブロードキャストを開始」")
                            .font(.footnote)
                    }
                }
                Section("② 小窓を表示してパズドラへ") {
                    Button(guide.pipActive ? "小窓を閉じる" : "小窓（ピクチャ・イン・ピクチャ）を表示") { guide.togglePiP() }
                    Text("小窓をパズドラの盤面の上あたりに置いて使います。ホームに戻ると自動で小窓になります。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("設定") {
                    VStack(alignment: .leading) {
                        Text("最大手数：\(Int(steps))手")
                        Slider(value: $steps, in: 8...40, step: 1) { _ in Shared.maxSteps = Int(steps) }
                    }
                    Toggle("斜め移動を使う", isOn: $diagonal).onChange(of: diagonal) { _, v in Shared.diagonal = v }
                    VStack(alignment: .leading) {
                        Text("探索精度：\(beamNames[Int(beam)])")
                        Slider(value: $beam, in: 0...3, step: 1) { _ in Shared.beamWidth = beamLevels[Int(beam)] }
                    }
                    Button("盤面の位置を調整") { showCalib = true }
                }
                Section("見方") {
                    Text("緑の輪＝つかむドロップ／赤い四角＝離す位置／動く白い点＝なぞる順番。盤面が変わって落ち着くと自動で更新されます。")
                        .font(.footnote)
                }
            }
            .navigationTitle("パズドラ矢印ガイド")
            .sheet(isPresented: $showCalib) { CalibrationView() }
        }
    }
}

/** AVSampleBufferDisplayLayer を SwiftUI に載せる */
struct LayerView: UIViewRepresentable {
    let layer: CALayer
    final class HostView: UIView {
        var hosted: CALayer?
        override func layoutSubviews() { super.layoutSubviews(); hosted?.frame = bounds }
    }
    func makeUIView(context: Context) -> HostView {
        let v = HostView(); v.backgroundColor = .black
        v.layer.addSublayer(layer); v.hosted = layer
        return v
    }
    func updateUIView(_ v: HostView, context: Context) {}
}

/** システムの画面ブロードキャスト開始ボタン（この拡張を指定） */
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        v.preferredExtension = (Bundle.main.bundleIdentifier ?? "com.pdguide.app") + ".broadcast"
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {}
}

/** 盤面位置の調整。ブロードキャスト中に拡張が保存したプレビュー画像に枠を重ねて合わせる */
struct CalibrationView: View {
    @Environment(\.dismiss) var dismiss
    @State private var left = Shared.boardLeft
    @State private var top = Shared.boardTop
    @State private var width = Shared.boardWidth
    @State private var preview: UIImage?
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let img = preview {
                    GeometryReader { geo in
                        let s = min(geo.size.width / img.size.width, geo.size.height / img.size.height)
                        let w = img.size.width * s, h = img.size.height * s
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: img).resizable().frame(width: w, height: h)
                            let bw = width * w
                            GridShape().stroke(Color.cyan, lineWidth: 2)
                                .frame(width: bw, height: bw * 5 / 6)
                                .offset(x: left * w, y: top * h)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    Text("画面ブロードキャストを開始してパズドラのパズル画面を表示すると、ここにプレビューが出ます。")
                        .foregroundStyle(.secondary).padding()
                    Spacer()
                }
                Group {
                    LabeledSlider(title: "上下", value: $top, range: 0...0.95)
                    LabeledSlider(title: "左右", value: $left, range: 0...0.5)
                    LabeledSlider(title: "大きさ", value: $width, range: 0.4...1)
                }.padding(.horizontal)
                HStack {
                    Button("自動検出") { Shared.requestAutoDetect = true }
                    Spacer()
                    Button("保存") {
                        Shared.boardLeft = left; Shared.boardTop = top; Shared.boardWidth = width
                        Shared.calibrated = true
                        dismiss()
                    }.bold()
                }.padding()
            }
            .navigationTitle("盤面の位置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { Shared.wantPreview = true; load() }
            .onDisappear { Shared.wantPreview = false }
            .onReceive(timer) { _ in
                load()
                if !Shared.requestAutoDetect && Shared.calibrated {
                    // 自動検出が終わったら値を反映
                    if abs(Shared.boardTop - top) > 0.0001 && autoPending { top = Shared.boardTop; left = Shared.boardLeft; width = Shared.boardWidth; autoPending = false }
                }
            }
        }
    }
    @State private var autoPending = false

    private func load() {
        if let d = try? Data(contentsOf: Shared.previewURL) { preview = UIImage(data: d) }
        if Shared.requestAutoDetect { autoPending = true }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        HStack { Text(title).frame(width: 56, alignment: .leading); Slider(value: $value, in: range) }
    }
}

struct GridShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRect(r)
        for i in 1..<6 { let x = r.minX + r.width * CGFloat(i) / 6; p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY)) }
        for i in 1..<5 { let y = r.minY + r.height * CGFloat(i) / 5; p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y)) }
        return p
    }
}

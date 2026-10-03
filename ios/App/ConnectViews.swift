import SwiftUI
import AVFoundation
import Vision
import Network
import ReplayKit
import PuzzleCore

// MARK: - 画面共有の開始ボタン（iOS 標準の確認画面を出すだけ。勝手には始まらない）

final class BroadcastPickerHolder {
    let view: RPSystemBroadcastPickerView = {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".broadcast"
        v.showsMicrophoneButton = false
        return v
    }()

    /// iOS 標準の「画面収録/ブロードキャスト」確認画面を開く
    func open() {
        for case let b as UIButton in view.subviews {
            b.sendActions(for: .touchUpInside)
        }
    }
}

struct BroadcastPickerHost: UIViewRepresentable {
    let holder: BroadcastPickerHolder
    func makeUIView(context: Context) -> UIView { holder.view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - QR コードの読み取り（カメラ映像は端末内で処理し、保存しない）

struct QRScannerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = "PC の画面に表示された QR コードを枠に入れてください"
    @State private var done = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                QRScannerView { text in
                    guard !done else { return }
                    guard let info = PairingInfo.parse(text) else {
                        message = "パズルルートの QR コードではないか、同じネットワークの PC ではありません"
                        return
                    }
                    done = true
                    message = "接続しています…"
                    Task {
                        await model.pair(with: info)
                        dismiss()
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(message).font(.callout).multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("QR コードで接続")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onFound = onFound
        return c
    }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFound: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "puzzleroute.qr")
    private var lastCheck = Date.distantPast
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async { ok ? self.setup() : self.showMessage("カメラの使用が許可されていません。設定アプリで許可してください") }
        }
    }

    private func setup() {
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            showMessage("カメラが使えません")
            return
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        let pl = AVCaptureVideoPreviewLayer(session: session)
        pl.videoGravity = .resizeAspectFill
        pl.frame = view.bounds
        view.layer.addSublayer(pl)
        preview = pl
        queue.async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        queue.async { self.session.stopRunning() }
    }

    private func showMessage(_ text: String) {
        let l = UILabel()
        l.text = text; l.textColor = .white; l.numberOfLines = 0; l.textAlignment = .center
        l.frame = view.bounds.insetBy(dx: 20, dy: 20)
        l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(l)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastCheck) > 0.2, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastCheck = Date()
        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
        if let text = req.results?.compactMap({ $0.payloadStringValue }).first {
            DispatchQueue.main.async { self.onFound?(text) }
        }
    }
}

// MARK: - 同じ Wi-Fi の PC を探す（Bonjour）＋ 6 桁コード

final class PCBrowser: ObservableObject {
    @Published var results: [NWBrowser.Result] = []
    @Published var state = "探しています…"
    private var browser: NWBrowser?

    func start() {
        let b = NWBrowser(for: .bonjour(type: PCLink.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            DispatchQueue.main.async { self.results = Array(results) }
        }
        b.stateUpdateHandler = { st in
            DispatchQueue.main.async {
                switch st {
                case .failed, .waiting: self.state = "探せませんでした。「ローカルネットワーク」の許可を確認してください"
                case .ready: self.state = "探しています…"
                default: break
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() { browser?.cancel(); browser = nil }
}

struct DiscoverySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = PCBrowser()
    @State private var selected: NWBrowser.Result?
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if browser.results.isEmpty {
                        HStack { ProgressView(); Text(browser.state).font(.callout) }
                    }
                    ForEach(Array(browser.results.enumerated()), id: \.offset) { _, r in
                        Button {
                            selected = r
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(name(of: r))
                                Spacer()
                                if selected?.endpoint == r.endpoint { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } header: {
                    Text("見つかった PC")
                } footer: {
                    Text("PC でビューアーを起動し、iPhone と同じ Wi-Fi につないでください。")
                }
                if let sel = selected {
                    Section("PC の画面に出ている 6 桁の接続コード") {
                        TextField("例 123456", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.title2.monospacedDigit())
                            .accessibilityIdentifier("pairCodeField")
                        Button("接続する") {
                            Task {
                                await model.pair(endpoint: sel.endpoint, code: code)
                                if model.connection != nil { dismiss() }
                            }
                        }
                        .disabled(code.count != 6 || model.busyConnecting)
                    }
                }
                if let m = model.connectionMessage { Section { Text(m).font(.callout) } }
            }
            .navigationTitle("同じ Wi-Fi の PC を探す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
        }
    }

    private func name(of r: NWBrowser.Result) -> String {
        if case let .service(name, _, _, _) = r.endpoint { return name }
        return "PC"
    }
}

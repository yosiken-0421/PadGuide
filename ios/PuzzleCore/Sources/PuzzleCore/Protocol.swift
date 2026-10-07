import Foundation

// MARK: - PC へ送るデータ（画面画像は含めない）

/// 解析結果。PC へ送るのはこの内容だけ（盤面サイズ・認識結果・信頼度・ルート・予想コンボ数・矢印座標・時刻）。
public struct ResultMessage: Codable, Equatable, Sendable {
    public var type = "result"
    public var v = 1
    /// UNIX 時刻（ミリ秒）
    public var ts: Int64
    public var cols: Int
    public var rows: Int
    /// 各マスの種類キー（OrbKind.key）
    public var cells: [String]
    /// 各マスの認識信頼度（0〜1、小数2桁）
    public var confidence: [Double]
    /// "ok" | "nocombo" | "unstable" | "dark" | "invalid"
    public var status: String
    public var start: Int?
    public var end: Int?
    /// 移動方向 "U" "D" "L" "R"
    public var moves: [String]
    public var path: [Int]
    /// 矢印 [x1, y1, x2, y2]（マス単位。左上のマスの中心が (0.5, 0.5)）
    public var arrows: [[Double]]
    public var combos: Int
    public var cleared: Int
    public var steps: Int
    public var elapsedMs: Int
    public var achieved: [String]
    /// "iphone"（自動解析）| "iphone-manual"（iPhone で手動修正）
    public var source: String
    /// 計算に使った敵の妨害の縛り（設定していなければ送らない）
    public var constraints: BoardConstraints?

    public init(ts: Int64, cols: Int, rows: Int, cells: [String], confidence: [Double], status: String,
                start: Int?, end: Int?, moves: [String], path: [Int], arrows: [[Double]],
                combos: Int, cleared: Int, steps: Int, elapsedMs: Int, achieved: [String], source: String,
                constraints: BoardConstraints? = nil) {
        self.ts = ts; self.cols = cols; self.rows = rows; self.cells = cells; self.confidence = confidence
        self.status = status; self.start = start; self.end = end; self.moves = moves; self.path = path
        self.arrows = arrows; self.combos = combos; self.cleared = cleared; self.steps = steps
        self.elapsedMs = elapsedMs; self.achieved = achieved; self.source = source
        self.constraints = constraints
    }

    /// 盤面の色の数から決まるコンボ数の上限（保存・送信はしない計算値）
    public var maxCombos: Int {
        let b = Board(size: BoardSize(cols: cols, rows: rows), cells: cells.map { OrbKind(key: $0) ?? .unknown })
        return Solver.theoreticalMaxCombos(constraints?.solvingBoard(b) ?? b)
    }

    /// 盤面で組める最大コンボに届いたか
    public var reachedMaxCombos: Bool { status == "ok" && combos >= maxCombos }

    /// 盤面とルートから作る
    public static func make(board: Board, confidence: [Double], route: Route?, goals: Goals,
                            status: String, source: String, constraints: BoardConstraints? = nil,
                            now: Date = Date()) -> ResultMessage {
        let ts = Int64(now.timeIntervalSince1970 * 1000)
        let conf = confidence.map { ($0 * 100).rounded() / 100 }
        let cons = constraints?.effective(for: board.size)
        guard let r = route, status == "ok" else {
            return ResultMessage(ts: ts, cols: board.size.cols, rows: board.size.rows,
                                 cells: board.cells.map { $0.key }, confidence: conf, status: status,
                                 start: nil, end: nil, moves: [], path: [], arrows: [],
                                 combos: route?.result.combos ?? 0, cleared: route?.result.cleared ?? 0,
                                 steps: 0, elapsedMs: Int((route?.elapsed ?? 0) * 1000), achieved: [], source: source,
                                 constraints: cons)
        }
        return ResultMessage(ts: ts, cols: board.size.cols, rows: board.size.rows,
                             cells: board.cells.map { $0.key }, confidence: conf, status: status,
                             start: r.start, end: r.end, moves: r.moves.map { $0.rawValue }, path: r.path,
                             arrows: Arrows.segments(path: r.path, cols: board.size.cols),
                             combos: r.result.combos, cleared: r.result.cleared, steps: r.steps,
                             elapsedMs: Int(r.elapsed * 1000), achieved: r.achieved(goals), source: source,
                             constraints: cons)
    }
}

/// 画面共有の開始・終了の通知
public struct ShareMessage: Codable, Equatable, Sendable {
    public var type = "share"
    /// "started" | "ended"
    public var state: String
    public var ts: Int64
    public init(state: String, ts: Int64) { self.state = state; self.ts = ts }
}

public enum Arrows {
    /// ルートの矢印座標。同じマスを何度も通るときは少しずらして、交差・往復が見分けられるようにする。
    public static func segments(path: [Int], cols: Int) -> [[Double]] {
        guard path.count >= 2 else { return [] }
        var visits: [Int: Int] = [:]
        var pts: [(Double, Double)] = []
        for (i, p) in path.enumerated() {
            let n = visits[p, default: 0]
            visits[p] = n + 1
            let off = i == 0 ? 0 : Double(min(n, 4)) * 0.08
            let x = Double(p % cols) + 0.5 + off
            let y = Double(p / cols) + 0.5 + off
            pts.append((x, y))
        }
        var out: [[Double]] = []
        for i in 1..<pts.count {
            out.append([round2(pts[i - 1].0), round2(pts[i - 1].1), round2(pts[i].0), round2(pts[i].1)])
        }
        return out
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

// MARK: - 接続（同一 LAN 内のみ）

/// PC ビューアーの QR コードに入っている接続情報
/// 形式: puzzleroute://pair?h=192.168.1.10&p=48123&t=<32桁の16進>
public struct PairingInfo: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var token: String

    public init(host: String, port: Int, token: String) {
        self.host = host; self.port = port; self.token = token
    }

    /// QR の文字列を検証して読み取る。LAN 外のアドレスや不正なトークンは受け付けない。
    public static func parse(_ text: String) -> PairingInfo? {
        guard let comps = URLComponents(string: text),
              comps.scheme == "puzzleroute", comps.host == "pair",
              let items = comps.queryItems else { return nil }
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let h = q("h"), let ps = q("p"), let port = Int(ps), let t = q("t"),
              (1024...65535).contains(port),
              LANAddress.isPrivateIPv4(h),
              Token.isValidPairToken(t) else { return nil }
        return PairingInfo(host: h, port: port, token: t)
    }
}

public enum Token {
    /// ペアリング用トークン（128bit を16進32桁）
    public static func isValidPairToken(_ t: String) -> Bool { isHex(t, length: 32) }
    /// セッショントークン（256bit を16進64桁）
    public static func isValidSessionToken(_ t: String) -> Bool { isHex(t, length: 64) }
    /// 6桁の接続コード
    public static func isValidCode(_ c: String) -> Bool {
        c.count == 6 && c.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func isHex(_ s: String, length: Int) -> Bool {
        s.count == length && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

public enum LANAddress {
    /// 同一 LAN とみなすアドレス（10/8, 172.16/12, 192.168/16, 169.254/16）
    public static func isPrivateIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var o: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let v = Int(p), v <= 255 else { return false }
            o.append(v)
        }
        if o[0] == 10 { return true }
        if o[0] == 172 && (16...31).contains(o[1]) { return true }
        if o[0] == 192 && o[1] == 168 { return true }
        if o[0] == 169 && o[1] == 254 { return true }
        return false
    }
}

/// 最小限の HTTP/1.1 メッセージ（Network.framework の生 TCP で送るため）
public enum MiniHTTP {
    public static func request(method: String, path: String, host: String, port: Int,
                               token: String?, body: Data) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(host):\(port)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if let t = token { head += "Authorization: Bearer \(t)\r\n" }
        head += "Connection: close\r\n\r\n"
        var d = Data(head.utf8)
        d.append(body)
        return d
    }

    /// (ステータスコード, 本文)。不完全な応答なら nil
    public static func parseResponse(_ data: Data) -> (Int, Data)? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8) else { return nil }
        let first = head.split(separator: "\r\n").first ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]) else { return nil }
        return (code, data[sep.upperBound...])
    }
}

public struct PairRequest: Codable, Sendable {
    public var token: String?
    public var code: String?
    public var device: String
    public init(token: String? = nil, code: String? = nil, device: String) {
        self.token = token; self.code = code; self.device = device
    }
}

public struct PairResponse: Codable, Sendable {
    public var session: String
    public var expiresInSec: Int
}

// MARK: - 画面共有中だけ保持するデータ

/// 画面共有中の一時データ。共有終了時に end() ですべて破棄する。画像は保持しない。
public final class LiveSession: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastReading: BoardReading?
    private var _lastSolved: [OrbKind]?
    private var _lastResult: ResultMessage?
    private var _stabilizer = BoardStabilizer(requiredFrames: 3, flickerTolerance: 1)
    /// 表示中のルートで起こりうる盤面（各手順の後の盤面）。ルートがなければ計算した盤面だけ
    private var _routeBoards: [[OrbKind]] = []
    private var _stableCells: [OrbKind]?
    /// 見ないマス（雲・ルーレット）。色が変わり続けても「盤面が変わった」とみなさない
    private var _ignored: Set<Int> = []
    /// 表示中のルートのどの盤面とも、このマス数以上違えば「次の盤面」とみなす
    public static let newBoardThreshold = 3
    public private(set) var isActive = false

    public init() {}

    public func begin() {
        lock.lock(); defer { lock.unlock() }
        clearLocked()
        isActive = true
    }

    /// 新しい読み取り結果を渡す。確定した「次の盤面」なら true（＝再計算が必要）
    ///
    /// ルートを表示した後は、ドロップを動かしている間の盤面は「ルートの途中の盤面」のどれかと一致する。
    /// 今の盤面がルートの途中のどの盤面とも 3 マス以上違えば、コンボで消えて新しいドロップが落ちてきた
    /// 次の盤面とみなして再計算する（消えた数が少なく、各色の個数がほとんど変わらない場合も見逃さない）。
    /// 指を止めている間など、ルートの途中の盤面と一致している間は再計算せず、表示中のルートを固定する。
    public func feed(_ reading: BoardReading) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isActive else { return false }
        _lastReading = reading
        var kinds = reading.cells.map { $0.kind }
        for i in _ignored where i < kinds.count { kinds[i] = .unknown }
        guard _stabilizer.feed(kinds), let cells = _stabilizer.consensus else { return false }
        _stableCells = cells
        if !_routeBoards.isEmpty {
            let closest = _routeBoards.map { Self.routeMismatch($0, cells) }.min() ?? Int.max
            if closest < Self.newBoardThreshold { return false }   // ルートの途中（操作中・変化なし）
        }
        _lastSolved = cells
        _routeBoards = [cells]          // ルートが決まるまでは、この盤面と比べる
        return true
    }

    /// 見ないマス（雲・ルーレット）を設定する。そのマスは「不明」として扱う
    public func setIgnored(_ cells: [Int]) {
        lock.lock(); _ignored = Set(cells); lock.unlock()
    }

    /// ルートの盤面との違い。どちらかが「不明」のマス（見ないマス・読めないマス）は数えない
    static func routeMismatch(_ route: [OrbKind], _ cells: [OrbKind]) -> Int {
        guard route.count == cells.count else { return Int.max }
        var n = 0
        for i in route.indices where route[i] != cells[i] && route[i] != .unknown && cells[i] != .unknown { n += 1 }
        return n
    }

    /// 確定した盤面（直近のフレームの多数決）。再計算にはこれを使う
    public var stableCells: [OrbKind]? { lock.lock(); defer { lock.unlock() }; return _stableCells }

    /// 計算したルートで起こりうる盤面を登録する（ルートがなければ計算した盤面だけ）
    public func setRoute(boards: [[OrbKind]]) {
        lock.lock(); defer { lock.unlock() }
        if !boards.isEmpty { _routeBoards = boards }
    }

    /// 表示中のルートを手放して、次に確定した盤面で必ず再計算する（「再探索」など）
    public func forceNextSolve() {
        lock.lock(); _lastSolved = nil; _routeBoards = []; _stabilizer.reset(); lock.unlock()
    }

    public func store(result: ResultMessage) {
        lock.lock(); _lastResult = result; lock.unlock()
    }

    /// 盤面が一時的に読めなくなった（指で隠れた・演出中など）。
    /// 表示中のルートは手放さず、確定までのカウントだけやり直す。
    public func invalidate() {
        lock.lock(); _stabilizer.reset(); lock.unlock()
    }

    public var lastReading: BoardReading? { lock.lock(); defer { lock.unlock() }; return _lastReading }
    public var lastResult: ResultMessage? { lock.lock(); defer { lock.unlock() }; return _lastResult }

    /// 画面共有終了：保持しているデータをすべて破棄
    public func end() {
        lock.lock(); defer { lock.unlock() }
        clearLocked()
        isActive = false
    }

    private func clearLocked() {
        _lastReading = nil
        _lastSolved = nil
        _lastResult = nil
        _routeBoards = []
        _stableCells = nil
        _stabilizer.reset()
    }
}

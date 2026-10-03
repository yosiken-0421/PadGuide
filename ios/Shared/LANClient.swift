import Foundation
import Network
import PuzzleCore

/// 接続先（IP とポート、または Bonjour で見つけた PC）
enum LANTarget {
    case hostPort(String, Int)
    case endpoint(NWEndpoint)
}

enum LANError: LocalizedError {
    case timeout, badResponse, notConnected
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "PC から応答がありません。同じ Wi-Fi か、ビューアーが起動しているか確認してください"
        case .badResponse: return "PC からの応答が読み取れませんでした"
        case .notConnected: return "PC と接続していません"
        case .http(_, let m): return m.isEmpty ? "PC に断られました" : m
        }
    }
}

struct LANResponse {
    var status: Int
    var body: Data
    /// 実際につながった相手のアドレス（Bonjour で接続したときに使う）
    var remoteHost: String?
    var remotePort: Int?
}

/// Network.framework の TCP で、同一 LAN 内の PC と最小限の HTTP をやり取りする
enum LANClient {

    static func send(_ target: LANTarget, method: String, path: String, token: String?, body: Data,
                     timeout: TimeInterval = 4, completion: @escaping (Result<LANResponse, Error>) -> Void) {
        let conn: NWConnection
        var headerHost = "pc"
        var headerPort = 0
        switch target {
        case .hostPort(let h, let p):
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: p)) else {
                completion(.failure(LANError.badResponse)); return
            }
            conn = NWConnection(host: NWEndpoint.Host(h), port: port, using: .tcp)
            headerHost = h; headerPort = p
        case .endpoint(let e):
            conn = NWConnection(to: e, using: .tcp)
        }
        let queue = DispatchQueue(label: "puzzleroute.lan")
        var finished = false
        var remoteHost: String?
        var remotePort: Int?

        func finish(_ r: Result<LANResponse, Error>) {
            if finished { return }
            finished = true
            conn.cancel()
            completion(r)
        }

        func receive(_ acc: Data) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                var acc = acc
                if let d = data { acc.append(d) }
                if acc.count > 1_000_000 { finish(.failure(LANError.badResponse)); return }
                if isComplete || error != nil {
                    if let (code, body) = MiniHTTP.parseResponse(acc) {
                        finish(.success(LANResponse(status: code, body: body, remoteHost: remoteHost, remotePort: remotePort)))
                    } else {
                        finish(.failure(error ?? LANError.badResponse))
                    }
                    return
                }
                receive(acc)
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                    if case let .ipv4(a) = host {
                        remoteHost = "\(a)".split(separator: "%").first.map(String.init)
                    }
                    remotePort = Int(port.rawValue)
                }
                let req = MiniHTTP.request(method: method, path: path, host: remoteHost ?? headerHost,
                                           port: remotePort ?? headerPort, token: token, body: body)
                conn.send(content: req, completion: .contentProcessed { err in
                    if let err { finish(.failure(err)) }
                })
                receive(Data())
            case .failed(let e), .waiting(let e):
                finish(.failure(e))
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(LANError.timeout)) }
    }

    static func send(_ target: LANTarget, method: String, path: String, token: String?, body: Data,
                     timeout: TimeInterval = 4) async throws -> LANResponse {
        try await withCheckedThrowingContinuation { cont in
            send(target, method: method, path: path, token: token, body: body, timeout: timeout) { cont.resume(with: $0) }
        }
    }
}

/// PC ビューアーとのやり取り
enum PCLink {
    static let serviceType = "_puzzleroute._tcp"

    /// QR のトークン、または 6 桁コードで接続し、接続情報を保存する
    static func pair(_ target: LANTarget, token: String?, code: String?) async throws -> PCConnection {
        let body = try JSONEncoder().encode(PairRequest(token: token, code: code, device: "iPhone"))
        let res = try await LANClient.send(target, method: "POST", path: "/api/pair", token: nil, body: body)
        guard res.status == 200 else {
            throw LANError.http(res.status, String(data: res.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        let pr = try JSONDecoder().decode(PairResponse.self, from: res.body)
        guard Token.isValidSessionToken(pr.session) else { throw LANError.badResponse }
        var host = "", port = 0
        switch target {
        case .hostPort(let h, let p): host = h; port = p
        case .endpoint: host = res.remoteHost ?? ""; port = res.remotePort ?? 0
        }
        guard LANAddress.isPrivateIPv4(host), port > 0 else { throw LANError.badResponse }
        let c = PCConnection(host: host, port: port, session: pr.session,
                             expiresAt: Date().addingTimeInterval(TimeInterval(pr.expiresInSec)))
        SharedStore.connection = c
        return c
    }

    /// 解析結果を送る（つながっていなければ何もしない）
    static func push(_ msg: ResultMessage, completion: ((Bool) -> Void)? = nil) {
        guard let c = SharedStore.connection, let body = try? JSONEncoder().encode(msg) else { completion?(false); return }
        LANClient.send(.hostPort(c.host, c.port), method: "POST", path: "/api/push", token: c.session, body: body, timeout: 3) { r in
            if case .success(let res) = r, res.status == 401 { SharedStore.connection = nil }
            if case .success(let res) = r { completion?(res.status == 204) } else { completion?(false) }
        }
    }

    /// 画面共有の開始・終了を知らせる
    static func share(_ state: String, completion: (() -> Void)? = nil) {
        guard let c = SharedStore.connection,
              let body = try? JSONEncoder().encode(ShareMessage(state: state, ts: Int64(Date().timeIntervalSince1970 * 1000))) else {
            completion?(); return
        }
        LANClient.send(.hostPort(c.host, c.port), method: "POST", path: "/api/share", token: c.session, body: body, timeout: 2) { _ in
            completion?()
        }
    }

    /// 接続が生きているか（nil = 応答なし）
    static func ping() async -> Int? {
        guard let c = SharedStore.connection else { return nil }
        let r = try? await LANClient.send(.hostPort(c.host, c.port), method: "GET", path: "/api/ping", token: c.session, body: Data(), timeout: 3)
        return r?.status
    }

    /// 切断（PC 側のトークンも無効にする）
    static func bye() async {
        if let c = SharedStore.connection {
            _ = try? await LANClient.send(.hostPort(c.host, c.port), method: "POST", path: "/api/bye", token: c.session, body: Data(), timeout: 2)
        }
        SharedStore.connection = nil
    }
}

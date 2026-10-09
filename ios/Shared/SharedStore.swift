import Foundation
import PuzzleCore

/// アプリ本体と画面共有拡張で共有する保存場所（端末内の App Group）。画像は保存しない。
enum AppGroup {
    static let id: String = Bundle.main.object(forInfoDictionaryKey: "PDAppGroup") as? String ?? "group.com.pdguide"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) ?? FileManager.default.temporaryDirectory
    }
}

/// 探索と認識の設定
struct AppSettings: Codable, Equatable {
    /// "auto" | "6x5" | "7x6" | "5x4"
    var sizeMode = "auto"
    var maxSteps = SolverOptions.defaultSteps
    var timeLimit = 1.0
    var goals = Goals()
    /// 敵の妨害による縛り（開始位置固定・操作不可など）。手動で設定し、解除するまで続く
    var constraints: BoardConstraints?
    /// ルーレットを画面の変化から自動で見つける（nil = オン。以前の保存データでもオンになる）
    var autoRoulette: Bool?
    var autoRouletteOn: Bool { autoRoulette ?? true }

    var fixedSize: BoardSize? {
        switch sizeMode {
        case "6x5": return .sixByFive
        case "7x6": return .sevenBySix
        case "5x4": return .fiveByFour
        default: return nil
        }
    }

    var solverOptions: SolverOptions {
        SolverOptions(maxSteps: maxSteps, timeLimit: timeLimit, beamWidth: 800, maxBeamWidth: 12_000, goals: goals,
                      constraints: constraints)
    }
}

/// PC ビューアーとの接続情報（同一 LAN 内のみ）
struct PCConnection: Codable, Equatable {
    var host: String
    var port: Int
    var session: String
    var expiresAt: Date

    var isExpired: Bool { Date() > expiresAt }
}

/// 拡張が書き、アプリが読む最新の解析状態（画面共有終了で削除）
struct LatestState: Codable {
    var seq: Int
    var reading: BoardReading?
    var result: ResultMessage
    /// ルートのうち何手目まで操作が進んだか（画面から推定。nil = 不明）
    var progress: Int?
    /// 操作がルートから外れた
    var offRoute: Bool?
    /// 診断用：画面共有の映像の形式と大きさ（画像そのものは保存しない）
    var videoFormat: String? = nil
    var frameSize: [Int]? = nil
    /// 画面共有側で自動で見つけたルーレットのマス
    var autoHidden: [Int]? = nil
    /// 診断用：ルーレットの自動判定の判断材料（文章）
    var rouletteInfo: String? = nil
    /// 画面共有側で自動で見つけた操作不可（テープ）のマス
    var autoTaped: [Int]? = nil
}

enum SharedStore {
    private static let settingsKey = "settings.v1"
    /// 映像の色の変換を直したので、以前の変換で覚えた色（v1）は使わない（色がずれていて読み違えの原因になる）
    private static let learnedKey = "learned.v2"
    private static let connectionKey = "connection.v1"
    private static let heartbeatKey = "sharing.heartbeat"
    private static var latestURL: URL { AppGroup.container.appendingPathComponent("latest.json") }

    // MARK: 設定
    static func loadSettings() -> AppSettings {
        guard let d = AppGroup.defaults.data(forKey: settingsKey),
              var s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        // 以前の選択肢（20手など）は、最大コンボを狙える今の既定値に置き換える
        if !SolverOptions.stepChoices.contains(s.maxSteps) { s.maxSteps = SolverOptions.defaultSteps }
        return s
    }
    static func saveSettings(_ s: AppSettings) {
        AppGroup.defaults.set(try? JSONEncoder().encode(s), forKey: settingsKey)
    }

    // MARK: 手動修正の学習（端末内のみ・外部へ送らない）
    static func loadLearned() -> [LearnedSample] {
        guard let d = AppGroup.defaults.data(forKey: learnedKey),
              let s = try? JSONDecoder().decode([LearnedSample].self, from: d) else { return [] }
        return s
    }
    static func saveLearned(_ s: [LearnedSample]) {
        AppGroup.defaults.set(try? JSONEncoder().encode(s), forKey: learnedKey)
    }

    // MARK: 接続
    static var connection: PCConnection? {
        get {
            guard let d = AppGroup.defaults.data(forKey: connectionKey),
                  let c = try? JSONDecoder().decode(PCConnection.self, from: d), !c.isExpired else { return nil }
            return c
        }
        set {
            if let v = newValue { AppGroup.defaults.set(try? JSONEncoder().encode(v), forKey: connectionKey) }
            else { AppGroup.defaults.removeObject(forKey: connectionKey) }
        }
    }

    // MARK: 「今の画面で計算し直す」の依頼（アプリ → 画面共有拡張）
    private static let forceSolveKey = "forceSolve"
    static func requestForceSolve() { AppGroup.defaults.set(true, forKey: forceSolveKey) }
    /// 依頼があれば true を返して取り消す
    static func takeForceSolve() -> Bool {
        guard AppGroup.defaults.bool(forKey: forceSolveKey) else { return false }
        AppGroup.defaults.removeObject(forKey: forceSolveKey)
        return true
    }

    // MARK: 画面共有中の目印
    static func heartbeat() { AppGroup.defaults.set(Date().timeIntervalSince1970, forKey: heartbeatKey) }
    static func clearHeartbeat() { AppGroup.defaults.removeObject(forKey: heartbeatKey) }
    static var isSharing: Bool {
        let t = AppGroup.defaults.double(forKey: heartbeatKey)
        return t > 0 && Date().timeIntervalSince1970 - t < 4
    }

    // MARK: 最新の解析状態
    static func writeLatest(_ s: LatestState) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: latestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func readLatest() -> LatestState? {
        guard let d = try? Data(contentsOf: latestURL) else { return nil }
        return try? JSONDecoder().decode(LatestState.self, from: d)
    }
    static func clearLatest() { try? FileManager.default.removeItem(at: latestURL) }
}

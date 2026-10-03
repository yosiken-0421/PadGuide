import Foundation

/// 小窓（ピクチャ・イン・ピクチャ）の状態管理。
/// iOS の API 呼び出しはアプリ側（PiPGuide）が行い、ここでは「押してよいか」「何を表示するか」を決める。
/// 押しても何も起きない状態にしないため、開始できない理由・失敗理由を必ず文章で返す。
public struct PiPState: Equatable, Sendable {
    public private(set) var supported: Bool
    public private(set) var prepared = false
    public private(set) var possible = false
    public private(set) var active = false
    public private(set) var starting = false
    public private(set) var lastError: String?
    /// 実際に開始を指示した回数（二重起動の確認用）
    public private(set) var startRequests = 0

    public static let notStartedMessage = "小窓が開始されませんでした。もう一度押してください"
    public static let unavailableMessage = "この端末または現在の状態では小窓表示を開始できません"

    public init(supported: Bool) { self.supported = supported }

    public mutating func setPrepared() { prepared = true }
    public mutating func setPossible(_ p: Bool) { possible = p }

    /// 開始できないときの具体的な理由（開始できるなら nil）
    public var unavailableReason: String? {
        if !supported { return "この端末は小窓表示（ピクチャ・イン・ピクチャ）に対応していません" }
        if !prepared { return "小窓の準備がまだできていません" }
        if !possible { return "小窓を開始できる状態になっていません。少し待ってからもう一度お試しください" }
        return nil
    }

    /// ボタンを押せるか（実行中なら「閉じる」として押せる）
    public var buttonEnabled: Bool { active || (unavailableReason == nil && !starting) }

    public enum Action: Equatable { case start, stop, none }

    /// ボタンが押されたときにすべきこと。開始中の連打は無視して二重起動を防ぐ。
    public mutating func pressButton() -> Action {
        if active { return .stop }
        if starting { return .none }
        if let reason = unavailableReason {
            lastError = reason
            return .none
        }
        lastError = nil
        starting = true
        startRequests += 1
        return .start
    }

    public mutating func didStart() {
        active = true
        starting = false
        lastError = nil
    }

    public mutating func failedToStart(_ message: String) {
        active = false
        starting = false
        lastError = "小窓を開始できませんでした：" + message
    }

    /// 開始を指示してから一定時間、開始も失敗も通知されなかった
    public mutating func startTimedOut() {
        guard starting, !active else { return }
        starting = false
        lastError = Self.notStartedMessage
    }

    public mutating func didStop() {
        active = false
        starting = false
    }

    /// 画面に出す1行の状態
    public var statusText: String {
        if let e = lastError { return e }
        if active { return "小窓を表示中です。ゲームに切り替えても表示されます" }
        if starting { return "小窓を開始しています…" }
        if unavailableReason != nil { return Self.unavailableMessage }
        return "「小窓で表示」を押すか、ゲームに切り替えると小窓になります"
    }

    /// 診断欄の各行
    public var diagnostics: [String] {
        var d = ["PiP対応：\(supported ? "はい" : "いいえ")",
                 "PiP開始可能：\(possible ? "はい" : "いいえ")",
                 "PiP実行中：\(active ? "はい" : "いいえ")",
                 "最後に発生したエラー：\(lastError ?? "なし")"]
        if !active, let r = unavailableReason { d.append("開始できない理由：\(r)") }
        return d
    }
}

import XCTest
@testable import PuzzleCore

private let S65 = BoardSize.sixByFive
private let S76 = BoardSize.sevenBySix

// MARK: - 色分類・盤面認識

final class RecognitionTests: XCTestCase {

    func testColorClassification() {
        let cls = ColorClassifier()
        for (kind, color) in SyntheticScreen.palette {
            let (k, conf) = cls.classify(color)
            XCTAssertEqual(k, kind, "\(kind.label) の色が \(k.label) と判定された")
            XCTAssertGreaterThan(conf, 0.3)
        }
        XCTAssertEqual(cls.classify(RGB(10, 10, 12)).0, .unknown, "真っ暗は不明")
    }

    private func screen(with board: Board, enhanced: Bool = false, decoy: Bool = true) -> (SyntheticScreen, Double, Double) {
        var sc = SyntheticScreen()
        let cell = Double(sc.width) / Double(board.size.cols)
        let y = Double(sc.height) - cell * Double(board.size.rows) - 110
        if decoy { sc.drawDecoyRow(y: Int(y) - 300, size: Int(cell * 0.85)) }
        sc.drawBoard(board, x: 0, y: y, cell: cell, enhanced: enhanced)
        return (sc, y, cell)
    }

    func testDetect6x5() {
        let board = SyntheticScreen.randomBoard(S65, seed: 1)
        let (sc, y, cell) = screen(with: board)
        let rd = BoardDetector.detect(sc)
        XCTAssertNotNil(rd)
        XCTAssertEqual(rd?.size, S65, "6×5 と判定されるべき")
        XCTAssertEqual(rd?.board, board)
        XCTAssertEqual(rd?.rect.y ?? 0, y, accuracy: cell * 0.1)
    }

    func testDetect7x6() {
        let board = SyntheticScreen.randomBoard(S76, seed: 2)
        let (sc, _, _) = screen(with: board)
        let rd = BoardDetector.detect(sc)
        XCTAssertEqual(rd?.size, S76, "7×6 と判定されるべき")
        XCTAssertEqual(rd?.board, board)
    }

    func testDetect5x4() {
        let board = SyntheticScreen.randomBoard(.fiveByFour, seed: 3)
        let (sc, _, _) = screen(with: board)
        XCTAssertEqual(BoardDetector.detect(sc)?.board, board)
    }

    func testManualSizeSelection() {
        let board = SyntheticScreen.randomBoard(S76, seed: 4)
        let (sc, _, _) = screen(with: board)
        let rd = BoardDetector.detect(sc, fixedSize: S76)
        XCTAssertEqual(rd?.size, S76)
        XCTAssertEqual(rd?.board, board)
    }

    func testEnhancedMarksKeepBaseColor() {
        let board = SyntheticScreen.randomBoard(S65, seed: 5)
        let (sc, _, _) = screen(with: board, enhanced: true)
        XCTAssertEqual(BoardDetector.detect(sc)?.board, board, "模様があっても基礎色で判定する")
    }

    func testJammerAndPoisonRecognized() {
        let board = Board(size: S65, string: """
            RBGLDH
            JPMRBG
            LDHRBG
            LDHJPM
            RBGLDH
            """)
        let (sc, y, cell) = screen(with: board)
        let rd = BoardReader.read(sc, rect: BoardRect(x: 0, y: y, cell: cell, size: S65), classifier: ColorClassifier())
        XCTAssertEqual(rd.board, board)
    }

    func testDarkScreenIsNotUsable() {
        var sc = SyntheticScreen(background: RGB(5, 5, 5))
        let board = SyntheticScreen.randomBoard(S65, seed: 6)
        let cell = Double(sc.width) / 6
        sc.drawBoard(board, x: 0, y: 1400, cell: cell)
        sc.darken(by: 8)   // 暗闇：画面全体を暗くする
        let rd = BoardReader.read(sc, rect: BoardRect(x: 0, y: 1400, cell: cell, size: S65), classifier: ColorClassifier())
        XCTAssertFalse(rd.isUsable, "暗い画面ではルートを確定しない")
        XCTAssertNil(BoardDetector.detect(sc))
    }

    func testLearnedCorrection() {
        var cls = ColorClassifier()
        let odd = RGB(200, 120, 60)   // 橙色：本来は火と判定される
        XCTAssertEqual(cls.classify(odd).0, .fire)
        cls.learn(odd, as: .light)
        XCTAssertEqual(cls.classify(odd).0, .light, "手動修正した色の傾向を使う")
        XCTAssertEqual(cls.classify(RGB(203, 118, 62)).0, .light, "近い色にも適用")
        XCTAssertEqual(cls.classify(RGB(50, 140, 240)).0, .water, "遠い色には影響しない")
    }

    func testStabilizerNeedsRepeatedFrames() {
        var st = BoardStabilizer(requiredFrames: 2)
        let a = SyntheticScreen.randomBoard(S65, seed: 7).cells
        let b = SyntheticScreen.randomBoard(S65, seed: 8).cells
        XCTAssertFalse(st.feed(a))
        XCTAssertFalse(st.feed(b), "変化し続ける（ルーレット等）間は確定しない")
        XCTAssertFalse(st.feed(a))
        XCTAssertTrue(st.feed(a))
    }
}

// MARK: - 交換・消去・落下・連鎖

final class RuleTests: XCTestCase {
    private func eval(_ s: String, _ size: BoardSize = S65) -> EvalResult {
        Evaluator(size: size).evaluate(Board(size: size, string: s))
    }

    func testSwapInFourDirections() {
        let b = Board(size: S65, string: "RBGLDH" + String(repeating: "?", count: 24))
        let r = BoardOps.apply(start: 0, moves: [.right], to: b)!
        XCTAssertEqual(r[0, 0], .water); XCTAssertEqual(r[0, 1], .fire)
        let d = BoardOps.apply(start: 0, moves: [.down], to: b)!
        XCTAssertEqual(d[1, 0], .fire); XCTAssertEqual(d[0, 0], .unknown)
        let back = BoardOps.apply(start: 0, moves: [.right, .down, .up, .left], to: b)!
        XCTAssertEqual(back[0, 0], .fire)
        XCTAssertEqual(BoardOps.apply(start: 7, moves: [.left, .up], to: b)![0, 0], b[1, 1])
    }

    func testMoveOutsideBoardIsRejected() {
        let b = SyntheticScreen.randomBoard(S65, seed: 9)
        XCTAssertNil(BoardOps.apply(start: 0, moves: [.up], to: b))
        XCTAssertNil(BoardOps.apply(start: 0, moves: [.left], to: b))
        XCTAssertNil(BoardOps.apply(start: 29, moves: [.down], to: b))
        XCTAssertNil(BoardOps.apply(start: 5, moves: [.right], to: b))
        XCTAssertNil(BoardOps.neighbor(5, .right, S65))
    }

    func testHorizontalAndVerticalThree() {
        let h = eval("RRR???" + String(repeating: "?", count: 24))
        XCTAssertEqual(h.combos, 1); XCTAssertEqual(h.cleared, 3)
        let v = eval("R?????R?????R?????" + String(repeating: "?", count: 12))
        XCTAssertEqual(v.combos, 1); XCTAssertEqual(v.cleared, 3)
    }

    func testLAdjacencyWithoutThreeIsNotCleared() {
        let r = eval("""
            R?????
            RR????
            ?R????
            ??????
            ??????
            """)
        XCTAssertEqual(r.combos, 0, "縦横に3個並んでいないL字の隣接は消えない")
    }

    func testTrueLShape() {
        let r = eval("""
            R?????
            R?????
            RRR???
            ??????
            ??????
            """)
        XCTAssertEqual(r.combos, 1); XCTAssertEqual(r.cleared, 5)
        XCTAssertTrue(r.shapes.contains(.lShape))
    }

    func testCrossRowSquare() {
        let cross = eval("""
            ?R????
            RRR???
            ?R????
            ??????
            ??????
            """)
        XCTAssertTrue(cross.shapes.contains(.cross)); XCTAssertEqual(cross.combos, 1)
        let row = eval(String(repeating: "?", count: 24) + "BBBBBB")
        XCTAssertTrue(row.shapes.contains(.row))
        let sq = eval("""
            GGG???
            GGG???
            GGG???
            ??????
            ??????
            """)
        XCTAssertTrue(sq.shapes.contains(.square)); XCTAssertEqual(sq.combos, 1)
    }

    func testMultipleCombos() {
        let r = eval("""
            RRRBBB
            ??????
            RRR???
            ??????
            HHHLLL
            """)
        XCTAssertEqual(r.combos, 5)
        XCTAssertEqual(r.cleared, 15)
        let touching = eval("RRR???RRR???" + String(repeating: "?", count: 18))
        XCTAssertEqual(touching.combos, 1, "つながった同色は1コンボ")
        XCTAssertEqual(touching.cleared, 6)
    }

    func testGravityAndChain() {
        let r = eval("""
            ??????
            G?????
            G?????
            RRR???
            G?????
            """)
        XCTAssertEqual(r.combos, 2, "火が消えて木が落ち、縦に3つ並んで連鎖する")
        XCTAssertEqual(r.cleared, 6)
    }

    func testUnknownNeverClears() {
        XCTAssertEqual(eval(String(repeating: "?", count: 30)).combos, 0)
    }

    func testFiveColors() {
        let r = eval("""
            RRRBBB
            GGGLLL
            DDD???
            ??????
            ??????
            """)
        XCTAssertTrue(r.fiveColors)
    }
}

// MARK: - 探索

final class SolverTests: XCTestCase {

    func testRouteIsValidAndMatchesEvaluation() {
        let b = SyntheticScreen.randomBoard(S65, seed: 11)
        let opt = SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 300)
        let route = Solver.solve(b, options: opt)
        XCTAssertLessThanOrEqual(route.steps, 20)
        XCTAssertEqual(route.path.count, route.steps + 1)
        // 上下左右に1マスずつ動いている（斜めなし）
        for i in 1..<route.path.count {
            let a = route.path[i - 1], c = route.path[i]
            XCTAssertEqual(abs(a / 6 - c / 6) + abs(a % 6 - c % 6), 1)
        }
        let after = BoardOps.apply(start: route.start, moves: route.moves, to: b)!
        XCTAssertEqual(Evaluator(size: S65).evaluate(after), route.result)
        XCTAssertGreaterThanOrEqual(route.result.combos, 3)
    }

    func testReproducible() {
        let b = SyntheticScreen.randomBoard(S76, seed: 12)
        let opt = SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 200)
        let r1 = Solver.solve(b, options: opt), r2 = Solver.solve(b, options: opt)
        XCTAssertEqual(r1.path, r2.path, "同じ入力なら同じ結果")
        XCTAssertEqual(r1.result, r2.result)
    }

    func testFindsObviousOneMove() {
        // 1手で火3つが揃う盤面：最短の1手が選ばれる
        let b = Board(size: S65, string: """
            RR?R??
            ??????
            ??????
            ??????
            ??????
            """)
        let r = Solver.solve(b, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 200))
        XCTAssertEqual(r.result.combos, 1)
        XCTAssertEqual(r.steps, 1, "同じ評価なら短いルートを優先")
    }

    func testCancelStops() {
        let b = SyntheticScreen.randomBoard(S76, seed: 13)
        let flag = CancellationFlag()
        flag.cancel()
        let r = Solver.solve(b, options: SolverOptions(maxSteps: 48, timeLimit: nil, beamWidth: 3000), cancel: flag)
        XCTAssertTrue(r.cancelled)
    }

    func testTimeLimitStops() {
        let b = SyntheticScreen.randomBoard(S76, seed: 14)
        var fake = 0.0
        let r = Solver.solve(b, options: SolverOptions(maxSteps: 48, timeLimit: 1, beamWidth: 3000),
                             clock: { fake += 0.01; return fake })
        XCTAssertTrue(r.stoppedEarly)
    }

    func testGoalPriorityColor() {
        let b = SyntheticScreen.randomBoard(S65, seed: 15)
        var g = Goals(); g.priorityColor = .heart
        let r = Solver.solve(b, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 300, goals: g))
        XCTAssertGreaterThan(r.result.healCleared, 0, "回復を優先すると回復を消す")
    }
}

// MARK: - 通信・接続・破棄

final class ProtocolTests: XCTestCase {

    func testPairingParse() {
        let t = String(repeating: "a1", count: 16)
        XCTAssertEqual(PairingInfo.parse("puzzleroute://pair?h=192.168.1.20&p=48123&t=\(t)"),
                       PairingInfo(host: "192.168.1.20", port: 48123, token: t))
        XCTAssertNil(PairingInfo.parse("puzzleroute://pair?h=8.8.8.8&p=48123&t=\(t)"), "LAN 外は拒否")
        XCTAssertNil(PairingInfo.parse("puzzleroute://pair?h=192.168.1.20&p=48123&t=xyz"), "不正トークン")
        XCTAssertNil(PairingInfo.parse("puzzleroute://pair?h=192.168.1.20&p=80&t=\(t)"), "予約ポート")
        XCTAssertNil(PairingInfo.parse("https://pair?h=192.168.1.20&p=48123&t=\(t)"), "別スキーム")
        XCTAssertNil(PairingInfo.parse("puzzleroute://pair?h=192.168.1&p=48123&t=\(t)"))
    }

    func testTokenValidation() {
        XCTAssertTrue(Token.isValidSessionToken(String(repeating: "0f", count: 32)))
        XCTAssertFalse(Token.isValidSessionToken(String(repeating: "0F", count: 32)), "大文字は不正")
        XCTAssertFalse(Token.isValidSessionToken("abc"))
        XCTAssertTrue(Token.isValidCode("012345"))
        XCTAssertFalse(Token.isValidCode("12345a"))
        XCTAssertFalse(Token.isValidCode("１２３４５６"), "全角数字は不正")
    }

    func testPrivateAddresses() {
        for ok in ["10.0.0.1", "172.16.5.4", "172.31.255.1", "192.168.0.10", "169.254.3.3"] {
            XCTAssertTrue(LANAddress.isPrivateIPv4(ok), ok)
        }
        for ng in ["172.32.0.1", "8.8.8.8", "127.0.0.1", "192.169.1.1", "256.1.1.1", "a.b.c.d", "1.2.3"] {
            XCTAssertFalse(LANAddress.isPrivateIPv4(ng), ng)
        }
    }

    func testResultMessageHasOnlyAllowedFields() throws {
        let b = SyntheticScreen.randomBoard(S65, seed: 21)
        let route = Solver.solve(b, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 100))
        let msg = ResultMessage.make(board: b, confidence: Array(repeating: 0.9, count: 30), route: route,
                                     goals: Goals(), status: "ok", source: "iphone")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(msg)) as! [String: Any]
        let allowed: Set<String> = ["type", "v", "ts", "cols", "rows", "cells", "confidence", "status", "start", "end",
                                    "moves", "path", "arrows", "combos", "cleared", "steps", "elapsedMs", "achieved", "source"]
        XCTAssertTrue(Set(obj.keys).isSubset(of: allowed), "画像などの余計なデータを送らない: \(obj.keys)")
        XCTAssertEqual(msg.arrows.count, route.steps)
        XCTAssertEqual(msg.cells.count, 30)
    }

    func testMiniHTTP() {
        let req = MiniHTTP.request(method: "POST", path: "/api/push", host: "192.168.1.2", port: 48123,
                                   token: "abc", body: Data("{}".utf8))
        let s = String(data: req, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("POST /api/push HTTP/1.1\r\n"))
        XCTAssertTrue(s.contains("Authorization: Bearer abc\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n{}"))
        let res = MiniHTTP.parseResponse(Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 2\r\n\r\nno".utf8))
        XCTAssertEqual(res?.0, 401)
        XCTAssertEqual(res.map { String(data: $0.1, encoding: .utf8) }, "no")
        XCTAssertNil(MiniHTTP.parseResponse(Data("garbage".utf8)))
    }

    private func reading(_ b: Board) -> BoardReading {
        BoardReading(rect: BoardRect(x: 0, y: 0, cell: 100, size: b.size),
                     cells: b.cells.map { CellReading(kind: $0, confidence: 0.9, color: RGB(0, 0, 0)) },
                     brightness: 0.6)
    }

    /// ルート表示後にドロップを動かしても（＝入れ替えただけ）、途中で別のルートに変わらない
    func testRouteStaysFixedWhileMovingOrbs() {
        let s = LiveSession()
        s.begin()
        let start = SyntheticScreen.randomBoard(S65, seed: 41)
        XCTAssertFalse(s.feed(reading(start)))
        XCTAssertTrue(s.feed(reading(start)), "最初の盤面でルートを計算する")

        // 操作の途中で指を止めた盤面（いくつかのドロップが入れ替わっている）
        let moving = BoardOps.apply(start: 0, moves: [.right, .right, .down, .down, .left, .down], to: start)!
        XCTAssertNotEqual(moving.cells, start.cells)
        XCTAssertFalse(s.feed(reading(moving)))
        XCTAssertFalse(s.feed(reading(moving)), "操作中は再計算しない")
        XCTAssertFalse(s.feed(reading(moving)))

        // 持っているドロップが一部読み違えられても同じターン扱い
        var held = moving
        held.cells[14] = .unknown
        XCTAssertFalse(s.feed(reading(held)))
        XCTAssertFalse(s.feed(reading(held)), "読み違い2個までは操作中のまま")

        // 指で隠れて読めなくなっても、表示中のルートは手放さない
        s.invalidate()
        XCTAssertFalse(s.feed(reading(moving)))
        XCTAssertFalse(s.feed(reading(moving)))

        // コンボで消えて新しいドロップが落ちてきた盤面（各色の個数が変わる）→ 次のターンとして再計算
        let next = SyntheticScreen.randomBoard(S65, seed: 77)
        XCTAssertFalse(LiveSession.isSameTurn(start.cells, next.cells))
        XCTAssertFalse(s.feed(reading(next)))
        XCTAssertTrue(s.feed(reading(next)), "次の盤面では再計算する")
    }

    func testForceNextSolve() {
        let s = LiveSession()
        s.begin()
        let b = SyntheticScreen.randomBoard(S65, seed: 42)
        XCTAssertFalse(s.feed(reading(b)))
        XCTAssertTrue(s.feed(reading(b)))
        XCTAssertFalse(s.feed(reading(b)), "同じ盤面では再計算しない")
        s.forceNextSolve()
        XCTAssertFalse(s.feed(reading(b)))
        XCTAssertTrue(s.feed(reading(b)), "再探索を指示したら同じ盤面でも再計算する")
    }

    func testIsSameTurn() {
        let a = Board(size: S65, string: String(repeating: "RBGLDH", count: 5)).cells
        var swapped = a; swapped.swapAt(0, 1); swapped.swapAt(5, 11)
        XCTAssertTrue(LiveSession.isSameTurn(a, swapped))
        var three = a; three[0] = .water; three[1] = .water; three[2] = .water   // 火・水・木→水水水（2個変化）
        XCTAssertTrue(LiveSession.isSameTurn(a, three))
        three[3] = .water; three[4] = .water                                    // さらに変化
        XCTAssertFalse(LiveSession.isSameTurn(a, three))
    }

    func testLiveSessionDiscardsOnShareEnd() {
        let s = LiveSession()
        s.begin()
        var sc = SyntheticScreen()
        let b = SyntheticScreen.randomBoard(S65, seed: 31)
        sc.drawBoard(b, x: 0, y: 1400, cell: Double(sc.width) / 6)
        let rd = BoardReader.read(sc, rect: BoardRect(x: 0, y: 1400, cell: Double(sc.width) / 6, size: S65),
                                  classifier: ColorClassifier())
        XCTAssertFalse(s.feed(rd))
        XCTAssertTrue(s.feed(rd), "2フレーム同じなら確定")
        XCTAssertFalse(s.feed(rd), "盤面に変化がなければ再計算しない")
        s.store(result: ResultMessage.make(board: b, confidence: [], route: nil, goals: Goals(), status: "nocombo", source: "iphone"))
        XCTAssertNotNil(s.lastReading); XCTAssertNotNil(s.lastResult)
        s.end()
        XCTAssertNil(s.lastReading, "画面共有の終了でデータを破棄")
        XCTAssertNil(s.lastResult)
        XCTAssertFalse(s.isActive)
        XCTAssertFalse(s.feed(rd), "終了後は受け付けない")
    }
}

// MARK: - 小窓（ピクチャ・イン・ピクチャ）の状態管理

final class PiPStateTests: XCTestCase {

    private func ready() -> PiPState {
        var s = PiPState(supported: true)
        s.setPrepared()
        s.setPossible(true)
        return s
    }

    func testUnsupportedDisablesButtonWithReason() {
        var s = PiPState(supported: false)
        s.setPrepared()
        XCTAssertFalse(s.buttonEnabled, "非対応ならボタンは押せない")
        XCTAssertEqual(s.statusText, PiPState.unavailableMessage)
        XCTAssertTrue(s.diagnostics.contains("PiP対応：いいえ"))
        XCTAssertTrue(s.diagnostics.contains { $0.hasPrefix("開始できない理由：") && $0.contains("対応していません") })
        XCTAssertEqual(s.pressButton(), .none, "押しても開始しない")
        XCTAssertNotNil(s.lastError, "押したら理由をエラー欄に出す（何も起きない状態にしない）")
    }

    func testNotPossibleYetDisablesButton() {
        var s = PiPState(supported: true)
        s.setPrepared()
        XCTAssertFalse(s.buttonEnabled)
        XCTAssertTrue(s.unavailableReason?.contains("開始できる状態") == true)
        s.setPossible(true)
        XCTAssertTrue(s.buttonEnabled)
        XCTAssertNil(s.unavailableReason)
    }

    func testDoubleStartIsPrevented() {
        var s = ready()
        XCTAssertEqual(s.pressButton(), .start)
        XCTAssertFalse(s.buttonEnabled, "開始中はボタンを押せない")
        XCTAssertEqual(s.pressButton(), .none, "連打しても二重に開始しない")
        XCTAssertEqual(s.pressButton(), .none)
        XCTAssertEqual(s.startRequests, 1)
        s.didStart()
        XCTAssertTrue(s.active)
        XCTAssertTrue(s.buttonEnabled, "実行中は「閉じる」として押せる")
        XCTAssertEqual(s.pressButton(), .stop)
        s.didStop()
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.pressButton(), .start)
        XCTAssertEqual(s.startRequests, 2)
    }

    func testStartFailureShowsError() {
        var s = ready()
        _ = s.pressButton()
        s.failedToStart("テストの理由")
        XCTAssertFalse(s.active)
        XCTAssertFalse(s.starting)
        XCTAssertEqual(s.lastError, "小窓を開始できませんでした：テストの理由")
        XCTAssertEqual(s.statusText, s.lastError)
        XCTAssertTrue(s.diagnostics.contains("最後に発生したエラー：小窓を開始できませんでした：テストの理由"))
        XCTAssertTrue(s.buttonEnabled, "失敗後はもう一度押せる")
        XCTAssertEqual(s.pressButton(), .start)
        XCTAssertNil(s.lastError, "やり直したらエラーを消す")
    }

    func testNoResponseTimesOutWithMessage() {
        var s = ready()
        _ = s.pressButton()
        s.startTimedOut()
        XCTAssertFalse(s.starting)
        XCTAssertEqual(s.lastError, PiPState.notStartedMessage)
        // 開始済みならタイムアウトは何もしない
        var t = ready()
        _ = t.pressButton()
        t.didStart()
        t.startTimedOut()
        XCTAssertNil(t.lastError)
        XCTAssertTrue(t.active)
    }
}

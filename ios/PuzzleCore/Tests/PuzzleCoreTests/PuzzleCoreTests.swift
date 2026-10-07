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

    private func shinyScreen(_ board: Board, hueShift: Double = 0, valueScale: Double = 1, enhanced: Bool = false, seed: UInt64 = 1) -> SyntheticScreen {
        var sc = SyntheticScreen()
        let cell = Double(sc.width) / Double(board.size.cols)
        let y = Double(sc.height) - cell * Double(board.size.rows) - 110
        sc.drawDecoyRow(y: Int(y) - 300, size: Int(cell * 0.85))
        sc.drawShinyBoard(board, x: 0, y: y, cell: cell, hueShift: hueShift, valueScale: valueScale, seed: seed, enhanced: enhanced)
        return sc
    }

    /// 光沢・陰影・ノイズのある球状のドロップでも正しく読める
    func testShinyOrbs() {
        for (i, size) in [S65, S76, BoardSize.fiveByFour].enumerated() {
            let board = SyntheticScreen.randomBoard(size, seed: 100 + UInt64(i))
            let rd = BoardDetector.detect(shinyScreen(board, seed: UInt64(i + 1)))
            XCTAssertEqual(rd?.size, size, "\(size) と判定される")
            XCTAssertEqual(rd?.board, board, "\(size) の盤面を正しく読む")
        }
    }

    /// 強化マークがあっても、光沢のある球で基礎色を読める
    func testShinyOrbsWithMarks() {
        let board = SyntheticScreen.randomBoard(S65, seed: 120)
        XCTAssertEqual(BoardDetector.detect(shinyScreen(board, enhanced: true))?.board, board)
    }

    /// 画面の色味が少しずれていても（色相のずれ・暗め）読める
    func testColorShiftAndDimmer() {
        let board = SyntheticScreen.randomBoard(S65, seed: 130)
        for (shift, scale) in [(12.0, 1.0), (-12.0, 1.0), (0.0, 0.8), (10.0, 0.85), (-10.0, 0.85)] {
            let rd = BoardDetector.detect(shinyScreen(board, hueShift: shift, valueScale: scale))
            XCTAssertEqual(rd?.board, board, "色相 \(shift)°・明るさ \(scale) でも正しく読む")
        }
    }

    /// 青みがかった灰色・陰影・暗い模様のあるお邪魔も、水や不明と間違えずに読める（水ドロップと隣り合っていても）
    func testDullJammerRecognized() {
        let board = Board(size: S65, string: """
            RBGLDH
            JBJRBG
            LDHJBG
            LJHRJG
            RBGLDH
            """)
        let cases: [(RGB, Double, Double)] = [
            (RGB(118, 128, 148), 1, 0), (RGB(100, 120, 148), 1, 0), (RGB(140, 145, 155), 0.8, 0),
            (RGB(118, 128, 148), 0.85, 10), (RGB(118, 128, 148), 0.85, -10), (RGB(185, 190, 200), 1, 0),
        ]
        for (jam, scale, shift) in cases {
            var sc = SyntheticScreen()
            let cell = Double(sc.width) / 6
            let y = Double(sc.height) - cell * 5 - 110
            sc.drawShinyBoard(board, x: 0, y: y, cell: cell, hueShift: shift, valueScale: scale,
                              jammerColor: jam, jammerPattern: true)
            let rd = BoardReader.read(sc, rect: BoardRect(x: 0, y: y, cell: cell, size: S65), classifier: ColorClassifier())
            XCTAssertEqual(rd.board, board, "お邪魔 \(jam) 明るさ \(scale) 色相 \(shift)")
            XCTAssertTrue(rd.isUsable)
        }
    }

    /// 光沢のある毒・猛毒・お邪魔が混ざっていても読める
    func testShinyJammerAndPoison() {
        let board = Board(size: S65, string: """
            RBGLDH
            JPMRBG
            LDHRBG
            LDHJPM
            RBGLDH
            """)
        for scale in [1.0, 0.85] {
            var sc = SyntheticScreen()
            let cell = Double(sc.width) / 6
            let y = Double(sc.height) - cell * 5 - 110
            sc.drawShinyBoard(board, x: 0, y: y, cell: cell, valueScale: scale,
                              jammerColor: RGB(118, 128, 148), jammerPattern: true)
            let rd = BoardReader.read(sc, rect: BoardRect(x: 0, y: y, cell: cell, size: S65), classifier: ColorClassifier())
            XCTAssertEqual(rd.board, board, "明るさ \(scale)")
        }
    }

    /// 読めた盤面の信頼度は高く、黄色枠（自信がないマス）が出ない
    func testConfidenceIsHighForClearOrbs() {
        let board = SyntheticScreen.randomBoard(S65, seed: 140)
        guard let rd = BoardDetector.detect(shinyScreen(board)) else { return XCTFail("盤面が見つからない") }
        XCTAssertTrue(rd.lowConfidenceIndices.isEmpty, "自信がないマス: \(rd.lowConfidenceIndices)")
        XCTAssertGreaterThan(rd.averageConfidence, 0.75)
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
        var st = BoardStabilizer(requiredFrames: 2, flickerTolerance: 0)
        let a = SyntheticScreen.randomBoard(S65, seed: 7).cells
        let b = SyntheticScreen.randomBoard(S65, seed: 8).cells
        XCTAssertFalse(st.feed(a))
        XCTAssertFalse(st.feed(b), "変化し続ける（ルーレット等）間は確定しない")
        XCTAssertFalse(st.feed(a))
        XCTAssertTrue(st.feed(a))
        XCTAssertEqual(st.consensus, a)
    }

    /// 1マスだけちらつく（光る演出など）フレームが混ざっても確定し、多数決で正しい盤面になる
    func testStabilizerToleratesFlicker() {
        var st = BoardStabilizer(requiredFrames: 3, flickerTolerance: 1)
        let a = SyntheticScreen.randomBoard(S65, seed: 9).cells
        var glint = a; glint[12] = .unknown
        XCTAssertFalse(st.feed(a))
        XCTAssertFalse(st.feed(glint))
        XCTAssertTrue(st.feed(a), "1マスのちらつきでは確定を妨げない")
        XCTAssertEqual(st.consensus, a, "多数決でちらついたマスは正しい色になる")
        var two = a; two[1] = .unknown; two[2] = .unknown
        XCTAssertFalse(st.feed(two), "2マス以上違えば確定しない")
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

    /// 色ごとの個数から決まる最大コンボ数（不明マスは数えない）
    func testTheoreticalMaxCombos() {
        let b = Board(size: S65, string: """
            RRRRRR
            BBBBB?
            GGGG??
            LLL???
            DDHH??
            """)
        // 火6→2、水5→1、木4→1、光3→1、闇2→0、回復2→0
        XCTAssertEqual(Solver.theoreticalMaxCombos(b), 5)
    }

    /// 最大コンボに届いたら、それ以上長いルートを探さない
    func testStopsAtMaxCombos() {
        let b = Board(size: S65, string: """
            RR?R??
            ??????
            ??????
            ??????
            ??????
            """)
        let r = Solver.solve(b, options: SolverOptions(maxSteps: 48, timeLimit: nil, beamWidth: 500))
        XCTAssertEqual(r.result.combos, Solver.theoreticalMaxCombos(b))
        XCTAssertEqual(r.steps, 1)
    }

    /// ランダムな盤面の多くで、盤面で組める最大コンボ数に届く
    func testReachesMaxCombosOnMostBoards() {
        var hit = 0
        for seed: UInt64 in 300..<308 {
            let b = SyntheticScreen.randomBoard(S65, seed: seed)
            let r = Solver.solve(b, options: SolverOptions(maxSteps: 48, timeLimit: nil, beamWidth: 1500))
            let after = BoardOps.apply(start: r.start, moves: r.moves, to: b)!
            XCTAssertEqual(Evaluator(size: S65).evaluate(after), r.result, "ルートの評価が正しい")
            XCTAssertLessThanOrEqual(r.result.combos, Solver.theoreticalMaxCombos(b))
            if r.result.combos == Solver.theoreticalMaxCombos(b) { hit += 1 }
        }
        XCTAssertGreaterThanOrEqual(hit, 4, "8盤面中 \(hit) 盤面で最大コンボ")
    }

    /// 時間が残っていれば、探索幅を広げて探し直して最大コンボに近づける
    func testWidensSearchWhenTimeRemains() {
        let b = SyntheticScreen.randomBoard(S65, seed: 311)
        let narrow = Solver.solve(b, options: SolverOptions(maxSteps: 48, timeLimit: nil, beamWidth: 200))
        var fake = 0.0
        let wide = Solver.solve(b, options: SolverOptions(maxSteps: 48, timeLimit: 1, beamWidth: 200, maxBeamWidth: 1500),
                                clock: { fake += 0.000001; return fake })
        XCTAssertLessThan(narrow.result.combos, Solver.theoreticalMaxCombos(b), "狭い探索では届かない盤面")
        XCTAssertGreaterThan(wide.expanded, narrow.expanded, "探し直している")
        XCTAssertGreaterThanOrEqual(wide.result.combos, narrow.result.combos)
        XCTAssertEqual(wide.result.combos, Solver.theoreticalMaxCombos(b), "広げた探索で最大コンボに届く")
        XCTAssertFalse(wide.stoppedEarly)
    }

    func testResultMessageMaxCombos() {
        let b = SyntheticScreen.randomBoard(S65, seed: 311)
        let r = Solver.solve(b, options: SolverOptions(maxSteps: 48, timeLimit: nil, beamWidth: 1500))
        let msg = ResultMessage.make(board: b, confidence: [], route: r, goals: Goals(), status: "ok", source: "iphone")
        XCTAssertEqual(msg.maxCombos, Solver.theoreticalMaxCombos(b))
        XCTAssertEqual(msg.reachedMaxCombos, r.result.combos >= msg.maxCombos)
    }
}

// MARK: - 敵の妨害（縛り）

final class ConstraintTests: XCTestCase {

    private func opts(_ c: BoardConstraints, width: Int = 400) -> SolverOptions {
        SolverOptions(maxSteps: 32, timeLimit: nil, beamWidth: width, constraints: c)
    }

    /// 操作開始位置の固定：指定したマスから動かし始める
    func testFixedStartPosition() {
        for (seed, start) in [(UInt64(401), 0), (402, 14), (403, 29)] {
            let b = SyntheticScreen.randomBoard(S65, seed: seed)
            let c = BoardConstraints(size: S65, fixedStart: start)
            let r = Solver.solve(b, options: opts(c))
            XCTAssertEqual(r.start, start, "開始位置 \(start) から動かす")
            XCTAssertGreaterThan(r.result.combos, 0)
            XCTAssertTrue(c.allows(path: r.path))
            // 開始位置を固定しないときと同じく、ルートの評価は実際に動かした盤面と一致する
            let after = BoardOps.apply(start: r.start, moves: r.moves, to: b)!
            XCTAssertEqual(Evaluator(size: S65).evaluate(after), r.result)
        }
    }

    /// 操作不可（テープ）と棘のマスには入らない
    func testBlockedAndThornCellsAreAvoided() {
        let b = SyntheticScreen.randomBoard(S65, seed: 404)
        // 中央の縦1列をテープ、右下に棘
        let c = BoardConstraints(size: S65, blocked: [2, 8, 14, 20, 26], thorns: [23, 29])
        let r = Solver.solve(b, options: opts(c))
        XCTAssertGreaterThan(r.steps, 0)
        XCTAssertTrue(c.allows(path: r.path), "通れないマスを通っている: \(r.path)")
        for i in r.path { XCTAssertFalse([2, 8, 14, 20, 26, 23, 29].contains(i)) }
        let after = BoardOps.apply(start: r.start, moves: r.moves, to: b)!
        for i in [2, 8, 14, 20, 26, 23, 29] { XCTAssertEqual(after.cells[i], b.cells[i], "動かせないマスのドロップは元のまま") }
    }

    /// 消せない状態の色は消さないものとして計算し、最大コンボの数からも除く
    func testUnclearableColor() {
        let b = SyntheticScreen.randomBoard(S65, seed: 405)
        let c = BoardConstraints(size: S65, unclearable: [.heart])
        let r = Solver.solve(b, options: opts(c, width: 800))
        XCTAssertEqual(r.result.clearedByKind[Int(OrbKind.heart.rawValue)], 0, "回復は消えない")
        XCTAssertEqual(Solver.theoreticalMaxCombos(c.solvingBoard(b)),
                       Solver.theoreticalMaxCombos(b) - b.cells.filter { $0 == .heart }.count / 3)
        XCTAssertGreaterThan(r.result.combos, 0)
    }

    /// 雲・ルーレットのマスは消えないものとして計算する（動かすことはできる）
    func testHiddenCellsAreNotCounted() {
        let b = Board(size: S65, string: """
            RRBGLD
            ??????
            ??????
            ??????
            ??????
            """)
        // 何もしなければ左上の火3つ目を揃えれば1コンボ…のはずが、2マス目が雲で色が分からない
        let c = BoardConstraints(size: S65, hidden: [1])
        XCTAssertEqual(c.solvingBoard(b).cells[1], .unknown)
        let r = Solver.solve(b, options: opts(c))
        XCTAssertEqual(r.result.combos, 0, "見えないマスを当てにしたルートは出さない")
    }

    /// 盤面の大きさが違う縛りは使わない
    func testConstraintsForOtherSizeAreIgnored() {
        let b = SyntheticScreen.randomBoard(S76, seed: 406)
        let c = BoardConstraints(size: S65, fixedStart: 3)
        let r1 = Solver.solve(b, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 200, constraints: c))
        let r2 = Solver.solve(b, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 200))
        XCTAssertEqual(r1.path, r2.path)
    }

    /// 「消せない色」は盤面の大きさが変わっても使う
    func testUnclearableAppliesToAnySize() {
        let b = SyntheticScreen.randomBoard(S76, seed: 408)
        let c = BoardConstraints(size: S65, fixedStart: 3, unclearable: [.water])
        let e = c.effective(for: S76)
        XCTAssertEqual(e?.unclearable, [.water])
        XCTAssertNil(e?.fixedStart)
        let r = Solver.solve(b, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 200, constraints: c))
        XCTAssertEqual(r.result.clearedByKind[Int(OrbKind.water.rawValue)], 0)
        XCTAssertNil(BoardConstraints(size: S65, fixedStart: 3).effective(for: S76))
    }

    func testToggleAndSummary() {
        var c = BoardConstraints(size: S65)
        XCTAssertTrue(c.isEmpty)
        c.toggle(.start, at: 7)
        XCTAssertEqual(c.fixedStart, 7)
        c.toggle(.blocked, at: 7)
        XCTAssertNil(c.fixedStart, "同じマスの別の縛りは外れる")
        XCTAssertEqual(c.blocked, [7])
        c.toggle(.blocked, at: 7)
        XCTAssertTrue(c.isEmpty, "もう一度押すと外れる")
        c.toggle(.thorn, at: 1); c.toggle(.hidden, at: 2); c.unclearable = [.fire]
        XCTAssertEqual(c.mark(1), .thorn)
        XCTAssertEqual(c.mark(2), .hidden)
        XCTAssertTrue(c.summary.contains("棘"))
        XCTAssertTrue(c.summary.contains("消せない：火"))
        XCTAssertFalse(c.canEnter(1))
        XCTAssertTrue(c.canEnter(2), "雲のマスは動かせる")
    }

    /// 保存データ：古い（項目が少ない）データも読める
    func testCodableCompatibility() throws {
        let c = BoardConstraints(size: S65, fixedStart: 4, blocked: [1], thorns: [2], hidden: [3], unclearable: [.poison])
        let back = try JSONDecoder().decode(BoardConstraints.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        let old = try JSONDecoder().decode(BoardConstraints.self, from: Data(#"{"cols":6,"rows":5}"#.utf8))
        XCTAssertTrue(old.isEmpty)
        let opt = try JSONDecoder().decode(SolverOptions.self, from: JSONEncoder().encode(SolverOptions()))
        XCTAssertNil(opt.constraints)
    }

    /// 結果のメッセージに縛りが入り、最大コンボ数も縛りを反映する
    func testResultMessageCarriesConstraints() {
        let b = SyntheticScreen.randomBoard(S65, seed: 407)
        let c = BoardConstraints(size: S65, fixedStart: 0, unclearable: [.fire])
        let r = Solver.solve(b, options: opts(c))
        let msg = ResultMessage.make(board: b, confidence: [], route: r, goals: Goals(), status: "ok", source: "iphone",
                                     constraints: c)
        XCTAssertEqual(msg.constraints, c)
        XCTAssertEqual(msg.start, 0)
        XCTAssertEqual(msg.maxCombos, Solver.theoreticalMaxCombos(c.solvingBoard(b)))
        let none = ResultMessage.make(board: b, confidence: [], route: r, goals: Goals(), status: "ok", source: "iphone",
                                      constraints: BoardConstraints(size: S65))
        XCTAssertNil(none.constraints, "空の縛りは送らない")
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
                                    "moves", "path", "arrows", "combos", "cleared", "steps", "elapsedMs", "achieved", "source",
                                    "constraints"]
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

    /// 3フレーム続けて渡す（確定させる）
    private func feedStable(_ s: LiveSession, _ b: Board) -> Bool {
        _ = s.feed(reading(b)); _ = s.feed(reading(b))
        return s.feed(reading(b))
    }

    /// 最初の盤面で計算し、そのルートを登録する
    private func startRoute(_ s: LiveSession, _ start: Board) -> Route {
        XCTAssertTrue(feedStable(s, start), "最初の盤面でルートを計算する")
        let route = Solver.solve(start, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 200))
        s.setRoute(boards: RouteTracker(board: start, path: route.path)!.boards)
        return route
    }

    /// ルート表示後にドロップを動かしても、途中で別のルートに変わらない
    func testRouteStaysFixedWhileMovingOrbs() {
        let s = LiveSession()
        s.begin()
        let start = SyntheticScreen.randomBoard(S65, seed: 41)
        let route = startRoute(s, start)

        // 操作の途中で指を止めた盤面（ルートの途中の盤面）
        for k in [2, 5, route.steps] {
            let moving = BoardOps.apply(start: route.start, moves: Array(route.moves.prefix(k)), to: start)!
            XCTAssertFalse(feedStable(s, moving), "\(k) 手目で止めても再計算しない")
        }
        // 持っているドロップが読めなくても同じ
        var held = BoardOps.apply(start: route.start, moves: Array(route.moves.prefix(3)), to: start)!
        held.cells[route.path[3]] = .unknown
        XCTAssertFalse(feedStable(s, held), "1マス読めなくても操作中のまま")
        // 指で隠れて読めなくなっても、表示中のルートは手放さない
        s.invalidate()
        XCTAssertFalse(feedStable(s, held))

        // コンボで消えて新しいドロップが落ちてきた盤面 → 次の盤面として再計算
        let next = SyntheticScreen.randomBoard(S65, seed: 77)
        XCTAssertTrue(feedStable(s, next), "次の盤面では自動で再計算する")
    }

    /// 消えた数が少なく、各色の個数がほとんど変わらない次の盤面も見逃さない
    func testSmallComboNextBoardIsDetected() {
        let s = LiveSession()
        s.begin()
        let start = Board(size: S65, string: """
            RRBGLD
            HBGLDH
            RBGLDH
            BGLDHR
            GLDHRB
            """)
        let route = startRoute(s, start)
        let end = BoardOps.apply(start: route.start, moves: route.moves, to: start)!
        // 一番上の段の3マスだけが入れ替わった（各色の個数の変化は2個以内）
        var next = end
        let top = [0, 1, 2]
        let colors: [OrbKind] = [.water, .fire, .wood]
        for (i, c) in zip(top, colors) where next.cells[i] != c { next.cells[i] = c }
        let changed = zip(end.cells, next.cells).filter { $0 != $1 }.count
        if changed >= LiveSession.newBoardThreshold {
            XCTAssertTrue(feedStable(s, next), "3マス以上変われば、色の個数がほぼ同じでも次の盤面として読み直す")
        }
        // 色の個数がほぼ同じ別の盤面（ドロップをまとめて並べ替えたような盤面）でも読み直す
        var shuffled = end
        shuffled.cells.reverse()
        XCTAssertTrue(feedStable(s, shuffled), "ルートの途中にない盤面なら読み直す")
    }

    func testForceNextSolve() {
        let s = LiveSession()
        s.begin()
        let b = SyntheticScreen.randomBoard(S65, seed: 42)
        XCTAssertTrue(feedStable(s, b))
        XCTAssertFalse(feedStable(s, b), "同じ盤面では再計算しない")
        s.forceNextSolve()
        XCTAssertTrue(feedStable(s, b), "再探索を指示したら同じ盤面でも再計算する")
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
        XCTAssertFalse(s.feed(rd))
        XCTAssertTrue(s.feed(rd), "3フレームほぼ同じなら確定")
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

// MARK: - 操作の進み具合

final class RouteTrackerTests: XCTestCase {

    /// ルートの各手順の後の盤面
    private func boards(_ board: Board, _ path: [Int]) -> [[OrbKind]] {
        var b = board.cells, out = [b]
        for k in 1..<path.count { b.swapAt(path[k - 1], path[k]); out.append(b) }
        return out
    }

    func testTracksProgressAlongRoute() {
        for seed: UInt64 in [201, 205, 206] {
            let board = SyntheticScreen.randomBoard(S65, seed: seed)
            let route = Solver.solve(board, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 200))
            guard var t = RouteTracker(board: board, path: route.path) else { return XCTFail("追跡を作れない") }
            let bs = boards(board, route.path)
            XCTAssertEqual(t.progress, 0)
            var cur = board
            var last = 0
            for k in 1...route.steps {
                cur.cells.swapAt(route.path[k - 1], route.path[k])
                t.update(cur.cells)
                // 盤面から区別できる範囲で正しく、手順を飛ばさない（同じ盤面が続くときは手前の手）
                let same = bs.indices.filter { bs[$0] == cur.cells && $0 >= last }
                XCTAssertEqual(t.progress, same.first, "\(k) 手目：盤面に一致するいちばん手前の手")
                XCTAssertLessThanOrEqual(t.progress, k, "先へ進みすぎない")
                XCTAssertGreaterThanOrEqual(t.progress, last, "戻らない")
                if bs[k] != bs[k - 1] { XCTAssertEqual(t.progress, k, "盤面が変わった手は正確に分かる") }
                XCTAssertFalse(t.offRoute)
                last = t.progress
            }
        }
    }

    func testToleratesHeldOrbMisread() {
        let board = SyntheticScreen.randomBoard(S65, seed: 202)
        let route = Solver.solve(board, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 200))
        var t = RouteTracker(board: board, path: route.path)!
        let bs = boards(board, route.path)
        var cur = BoardOps.apply(start: route.start, moves: Array(route.moves.prefix(4)), to: board)!
        cur.cells[route.path[4]] = .unknown          // 指で持っているドロップが読めない
        t.update(cur.cells)
        XCTAssertFalse(t.offRoute, "1マス読めなくてもルート上にいると分かる")
        XCTAssertTrue((1...4).contains(t.progress), "進み具合が分かる: \(t.progress)")
        XCTAssertLessThanOrEqual(RouteTracker.mismatch(bs[t.progress], cur.cells), 1)
    }

    func testDetectsLeavingRoute() {
        let board = SyntheticScreen.randomBoard(S65, seed: 203)
        let route = Solver.solve(board, options: SolverOptions(maxSteps: 20, timeLimit: nil, beamWidth: 200))
        var t = RouteTracker(board: board, path: route.path)!
        let other = SyntheticScreen.randomBoard(S65, seed: 999)
        t.update(other.cells)
        XCTAssertFalse(t.offRoute, "1回だけなら読み違いかもしれないので、まだ外れたとしない")
        t.update(other.cells)
        XCTAssertTrue(t.offRoute, "続けて合わなければルートから外れた")
        t.update(board.cells)
        XCTAssertFalse(t.offRoute)
        XCTAssertEqual(t.progress, 0)
    }

    func testRejectsInvalidPath() {
        let board = SyntheticScreen.randomBoard(S65, seed: 204)
        XCTAssertNil(RouteTracker(board: board, path: [0]))
        XCTAssertNil(RouteTracker(board: board, path: [0, 99]))
    }
}

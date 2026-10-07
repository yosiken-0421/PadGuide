import XCTest

/// iPhone 12 mini 相当の画面での UI テスト。
/// 実際のゲーム画面は使わず、アプリ内の独自配色の見本盤面（-demoBoard）で確認する。
final class PuzzleRouteUITests: XCTestCase {

    /// 画面外の要素は表示されるまで上へスクロールする（小さい画面向け）
    @discardableResult
    private func reveal(_ e: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        for _ in 0..<maxSwipes {
            if e.exists && e.isHittable { return true }
            app.swipeUp()
        }
        return e.waitForExistence(timeout: 2)
    }

    /// 上にある要素は下へスクロールして表示する
    @discardableResult
    private func revealAbove(_ e: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        for _ in 0..<maxSwipes {
            if e.exists && e.isHittable { return true }
            app.swipeDown()
        }
        return e.exists && e.isHittable
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testMainScreenShowsControlsAndNotice() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()

        XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["startShareButton"].exists, "画面共有の開始ボタンがある")
        XCTAssertTrue(app.staticTexts["shareStatus"].exists, "画面共有の状態が表示される")
        XCTAssertTrue(app.buttons["qrConnectButton"].exists, "QR コードで接続できる")
        XCTAssertTrue(app.buttons["discoverButton"].exists, "同じ Wi-Fi の PC を探せる")
        XCTAssertTrue(app.staticTexts["emptyBoard"].exists, "盤面がないときの案内")

        // 注意書き（一番下）
        let notice = app.staticTexts["disclaimer"]
        for _ in 0..<8 where !notice.isHittable { app.swipeUp() }
        XCTAssertTrue(notice.exists)
        XCTAssertTrue(notice.label.contains("本アプリは操作を自動実行しません"))
    }

    // MARK: 小窓（ピクチャ・イン・ピクチャ）

    /// スクリーンショットの中で、指定した色に近い画素の数を数える
    private func countColors(_ shot: XCUIScreenshot, _ targets: [(String, (Int, Int, Int))], tol: Int = 28) -> [String: Int] {
        guard let cg = shot.image.cgImage else { return [:] }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [String: Int] = [:]
        for (name, _) in targets { out[name] = 0 }
        var i = 0
        while i < px.count {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            for (name, c) in targets where abs(r - c.0) <= tol && abs(g - c.1) <= tol && abs(b - c.2) <= tol {
                out[name, default: 0] += 1
            }
            i += 4 * 2   // 1画素おき（十分な精度）
        }
        return out
    }

    /// 小窓の色（アプリ内の独自配色）
    private let pipColors: [(String, (Int, Int, Int))] = [
        ("火", (232, 71, 61)), ("水", (46, 140, 235)), ("木", (46, 184, 102)), ("背景", (38, 48, 74)),
    ]

    private func diagnostics(_ app: XCUIApplication) -> String {
        if !app.staticTexts["pipSupported"].exists { app.buttons["pipInfoButton"].tap() }
        return ["pipSupported", "pipPossible", "pipActive", "pipLastError", "pipReason", "pipStatus"]
            .map { app.staticTexts[$0] }.filter { $0.exists }.map { $0.label }.joined(separator: " / ")
    }

    /// 小窓を開始すると、ホーム画面に戻っても盤面とルートの図が表示されている
    func testPictureInPictureStartsAndShowsRoute() throws {
        #if targetEnvironment(simulator)
        // シミュレーターは小窓（PiP）に対応していない（iPhone は「非対応」、iPad は中身の出ない仮の窓）。
        // この確認は実機でテストを実行したときだけ行う。
        throw XCTSkip("シミュレーターでは小窓の中身を確認できないため、実機でのみ実行します")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demoBoard"]
        app.launch()
        XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))

        // 比較用：小窓がない状態のホーム画面
        XCUIDevice.shared.press(.home)
        sleep(2)
        let before = countColors(XCUIScreen.main.screenshot(), pipColors)
        app.activate()
        XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))
        sleep(3)   // 見本盤面のルート計算を待つ

        let button = app.buttons["pipButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "小窓ボタンがある")
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: button)
        if XCTWaiter.wait(for: [enabled], timeout: 20) != .completed {
            XCTFail("小窓ボタンが有効にならない：\(diagnostics(app))")
            return
        }

        // 連打しても二重に開始しない（2回目は開始中のため無視される）
        button.tap()
        if button.isEnabled { button.tap() }

        let status = app.staticTexts["pipStatus"]
        var started = false
        for _ in 0..<15 {
            if status.exists && status.label.contains("表示中") { started = true; break }
            sleep(1)
        }
        if !started {
            XCTFail("小窓が開始されない：\(diagnostics(app))")
            return
        }
        XCTAssertTrue(diagnostics(app).contains("PiP実行中：はい"))

        // ホーム画面に戻っても小窓に盤面とルートが表示されている
        XCUIDevice.shared.press(.home)
        sleep(3)
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "小窓（ホーム画面）"
        att.lifetime = .keepAlways
        add(att)
        let after = countColors(shot, pipColors)
        let delta = pipColors.map { ($0.0, (after[$0.0] ?? 0) - (before[$0.0] ?? 0)) }
        print("PIPCHECK: " + delta.map { "\($0.0)+\($0.1)" }.joined(separator: " ")
              + " (before " + pipColors.map { "\($0.0)=\(before[$0.0] ?? 0)" }.joined(separator: " ") + ")")
        let summary = "PIPCHECK: " + delta.map { "\($0.0)+\($0.1)" }.joined(separator: " ")
            + " (before " + pipColors.map { "\($0.0)=\(before[$0.0] ?? 0)" }.joined(separator: " ")
            + " after " + pipColors.map { "\($0.0)=\(after[$0.0] ?? 0)" }.joined(separator: " ") + ")"
        for (name, d) in delta {
            XCTAssertGreaterThan(d, 150, "小窓に「\(name)」の色が表示されていない（増えた画素 \(d)） \(summary)")
        }

        // アプリに戻って小窓を閉じられる
        app.activate()
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        for _ in 0..<5 where !(status.exists && status.label.contains("表示中")) { sleep(1) }
        if button.label.contains("閉じる") {
            button.tap()
            for _ in 0..<10 where status.label.contains("表示中") { sleep(1) }
            XCTAssertFalse(status.label.contains("表示中"), "小窓を閉じられる")
        }
        #endif
    }

    /// 小窓に出す図を大きく表示して記録する（見た目の確認用。開始前・3手目・最後）
    func testCapturePiPPreview() {
        for p in ["0", "3", "99"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uitest", "-demoBoard", "-demoProgress", p, "-pipPreviewLarge"]
            app.launch()
            XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))
            sleep(4)
            let preview = app.otherElements["pipPreview"]
            let shot = preview.exists ? preview.screenshot() : XCUIScreen.main.screenshot()
            let att = XCTAttachment(screenshot: shot)
            att.name = "小窓の図（進み具合 \(p)）"
            att.lifetime = .keepAlways
            add(att)
            app.terminate()
        }
    }

    /// 小窓に対応していない端末では、ボタンが押せず、理由が表示される（シミュレーターの iPhone は非対応）
    func testPictureInPictureButtonDisabledWhenUnsupported() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demoBoard"]
        app.launch()
        XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))
        app.buttons["pipInfoButton"].tap()
        let supported = app.staticTexts["pipSupported"]
        XCTAssertTrue(supported.waitForExistence(timeout: 5))
        guard supported.label.contains("いいえ") else {
            throw XCTSkip("この端末は小窓に対応しているため、非対応時の確認は行いません")
        }
        let button = app.buttons["pipButton"]
        XCTAssertTrue(button.exists)
        XCTAssertFalse(button.isEnabled, "非対応ならボタンは無効")
        XCTAssertTrue(app.staticTexts["pipStatus"].label.contains("この端末または現在の状態では小窓表示を開始できません"))
        XCTAssertTrue(app.staticTexts["pipReason"].label.contains("対応していません"))
        XCTAssertTrue(app.staticTexts["pipLastError"].label.contains("なし"))
    }

    /// 開始に失敗したら、エラーが表示され、もう一度押せる。開始中の連打では二重に開始しない
    func testPictureInPictureStartFailureShowsError() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demoBoard", "-pipSimulateFailure"]
        app.launch()
        XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))
        let button = app.buttons["pipButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: button)
        wait(for: [enabled], timeout: 10)

        button.tap()
        XCTAssertFalse(button.isEnabled, "開始中はボタンが無効（連打で二重に開始しない）")

        // 「開始しています…」は短時間だけの表示で、負荷の高い CI では tap() が戻る前に
        // 失敗状態へ遷移することがある。重要な挙動（連打防止と失敗表示）を直接確認する。
        let status = app.staticTexts["pipStatus"]
        let failed = expectation(for: NSPredicate(format: "label CONTAINS '小窓を開始できませんでした'"), evaluatedWith: status)
        wait(for: [failed], timeout: 10)
        XCTAssertTrue(button.isEnabled, "失敗後はもう一度押せる")
        app.buttons["pipInfoButton"].tap()
        XCTAssertTrue(app.staticTexts["pipLastError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["pipLastError"].label.contains("小窓を開始できませんでした"))
        XCTAssertTrue(app.staticTexts["pipActive"].label.contains("いいえ"))
    }

    /// 診断表示（対応・開始可能・実行中・エラー）が出る
    func testPictureInPictureDiagnosticsShown() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
        XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))
        let info = app.buttons["pipInfoButton"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()
        XCTAssertTrue(app.staticTexts["pipSupported"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["pipPossible"].exists)
        XCTAssertTrue(app.staticTexts["pipActive"].label.contains("いいえ"))
        XCTAssertTrue(app.staticTexts["pipLastError"].exists)
        // 開始できない場合はボタンが無効で、理由が表示される
        let button = app.buttons["pipButton"]
        if !app.staticTexts["pipSupported"].label.contains("はい") {
            XCTAssertFalse(button.isEnabled, "非対応ならボタンは無効")
            XCTAssertTrue(app.staticTexts["pipReason"].exists, "開始できない理由が出る")
        }
        let notice = app.staticTexts["pipNotice"]
        XCTAssertTrue(reveal(notice, in: app))
        XCTAssertTrue(notice.label.contains("小窓"))
    }

    func testManualCorrectionAndResearch() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demoBoard"]
        app.launch()

        XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))
        sleep(3)   // 見本盤面の探索（約1秒）を待つ
        let summary = app.staticTexts["routeSummary"]
        XCTAssertTrue(reveal(summary, in: app), "見本盤面のルートが表示される")
        let warning = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '不明なマス'")).firstMatch
        XCTAssertTrue(reveal(warning, in: app), "不明マスの警告が出る")

        // 不明マス（上から2段目・左から4列目）をタップして「光」に直す
        let cell = app.buttons["cell-9"]
        XCTAssertTrue(revealAbove(cell, in: app), "盤面のマスが表示される")
        // 画面下の小窓バーに隠れていないこと（隠れていたら少し下へスクロール）
        let bar = app.buttons["pipButton"]
        for _ in 0..<6 where bar.exists && cell.frame.maxY > bar.frame.minY - 60 {
            app.swipeDown(velocity: .slow)
        }
        // 画面下の小窓バーに隠れないよう、マスを画面の上のほうへ動かす
        for _ in 0..<4 where cell.frame.maxY > app.frame.height * 0.6 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        XCTAssertTrue(cell.label.contains("不明"), "対象のマスは不明: \(cell.label)")
        cell.tap()
        let light = app.buttons["光"]
        XCTAssertTrue(light.waitForExistence(timeout: 5), "色の選択肢が出る")
        light.tap()

        // 修正後：マスが「光」になり、再探索され、警告が消える
        let cell9 = app.buttons["cell-9"]
        for _ in 0..<15 where !(cell9.exists && cell9.label.contains("光")) { sleep(1) }
        if !(cell9.exists && cell9.label.contains("光")) {
            let btns = app.buttons.allElementsBoundByIndex.prefix(40).map { $0.label.isEmpty ? $0.identifier : $0.label }
            XCTFail("修正が反映されない: cell-9=\(cell9.exists ? cell9.label : "なし") 光ボタン残り=\(app.buttons["光"].exists) sheets=\(app.sheets.count) alerts=\(app.alerts.count) ボタン=\(btns.joined(separator: ","))")
            return
        }
        let warnQuery = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '不明なマス'"))
        for _ in 0..<15 where warnQuery.count > 0 { sleep(1) }
        if warnQuery.count > 0 {
            let left = warnQuery.allElementsBoundByIndex.prefix(3).map { "[\($0.elementType.rawValue)] \($0.identifier) \($0.label)" }
            XCTFail("警告が残っている: \(left.joined(separator: " / ")) / cell-9=\(app.buttons["cell-9"].label)")
        }
        sleep(2)
        XCTAssertTrue(reveal(app.staticTexts["routeSummary"], in: app))
        XCTAssertTrue(app.staticTexts["routeSummary"].label.contains("コンボ"))
    }

    /// 盤面のマスを、画面下の小窓バーに隠れない位置まで動かしてから押す
    private func tapCell(_ id: String, in app: XCUIApplication) {
        let cell = app.buttons[id]
        XCTAssertTrue(show(cell, in: app), "\(id) が表示される")
        for _ in 0..<4 where cell.frame.maxY > app.frame.height * 0.6 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        for _ in 0..<4 where cell.frame.minY < app.frame.height * 0.12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        cell.tap()
    }

    private func tapButton(_ id: String, in app: XCUIApplication) {
        let b = app.buttons[id]
        XCTAssertTrue(show(b, in: app), "\(id) が表示される")
        b.tap()
    }

    /// 上下どちらにあっても表示する
    @discardableResult
    private func show(_ e: XCUIElement, in app: XCUIApplication) -> Bool {
        if e.exists && e.isHittable { return true }
        return revealAbove(e, in: app, maxSwipes: 6) || reveal(e, in: app)
    }

    private func waitLabel(_ e: XCUIElement, contains text: String, timeout: Double = 15) -> Bool {
        let p = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: e)
        return XCTWaiter().wait(for: [p], timeout: timeout) == .completed
    }

    /// 敵の妨害（縛り）：開始位置を固定するとそこから始まるルートになり、操作不可のマスも設定・解除できる
    func testConstraintsFromBoard() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demoBoard"]
        app.launch()
        XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))
        sleep(3)

        // 開始位置：上から3段目・左から3列目（cell-14）
        tapButton("tool-start", in: app)
        tapCell("cell-14", in: app)
        let start = app.staticTexts["routeStart"]
        XCTAssertTrue(show(start, in: app))
        XCTAssertTrue(waitLabel(start, contains: "上から3段目・左から3列目"), "開始位置が固定される: \(start.label)")
        let summary = app.staticTexts["constraintSummary"]
        XCTAssertTrue(show(summary, in: app))
        XCTAssertTrue(waitLabel(summary, contains: "開始位置固定"), summary.label)

        // 操作不可：上から3段目・左から4列目（cell-15）
        tapButton("tool-blocked", in: app)
        tapCell("cell-15", in: app)
        XCTAssertTrue(show(summary, in: app))
        XCTAssertTrue(waitLabel(summary, contains: "操作不可 1マス"), summary.label)
        let rc = app.staticTexts["routeConstraints"]
        XCTAssertTrue(show(rc, in: app))
        XCTAssertTrue(waitLabel(rc, contains: "操作不可"), "ルートの計算に縛りが使われる: \(rc.label)")

        // 色を直すモードに戻すと、マスを押したときに色の選択肢が出る
        tapButton("tool-color", in: app)
        tapCell("cell-0", in: app)
        XCTAssertTrue(app.buttons["光"].waitForExistence(timeout: 5), "色の選択肢が出る")
        app.buttons["光"].tap()

        // すべて解除
        tapButton("clearConstraints", in: app)
        XCTAssertTrue(show(summary, in: app))
        XCTAssertTrue(waitLabel(summary, contains: "なし"), summary.label)
    }
}

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

    func testManualCorrectionAndResearch() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demoBoard"]
        app.launch()

        XCTAssertTrue(app.navigationBars["パズルルート"].waitForExistence(timeout: 10))
        sleep(3)   // 見本盤面の探索（約1秒）を待つ
        let summary = app.staticTexts["routeSummary"]
        XCTAssertTrue(reveal(summary, in: app), "見本盤面のルートが表示される")
        XCTAssertTrue(app.staticTexts["unknownWarning"].exists || app.otherElements["unknownWarning"].exists
                      || app.descendants(matching: .any)["unknownWarning"].exists, "不明マスの警告が出る")

        // 不明マス（上から2段目・左から4列目）をタップして「光」に直す
        let cell = app.buttons["cell-9"]
        if !cell.isHittable { app.swipeDown() }
        XCTAssertTrue(reveal(cell, in: app))
        cell.tap()
        let light = app.buttons["光"]
        XCTAssertTrue(light.waitForExistence(timeout: 5), "色の選択肢が出る")
        light.tap()

        // 修正後に再探索され、警告が消える
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.descendants(matching: .any)["unknownWarning"])
        waitForExpectations(timeout: 15)
        sleep(2)
        XCTAssertTrue(reveal(app.staticTexts["routeSummary"], in: app))
        XCTAssertTrue(app.staticTexts["routeSummary"].label.contains("コンボ"))
    }
}

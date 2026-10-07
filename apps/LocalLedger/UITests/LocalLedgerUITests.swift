import XCTest

final class LocalLedgerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchAndAddExpense() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["KakeiboLeaf"].waitForExistence(timeout: 10))

        let add = app.buttons["addEntryButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let amount = app.textFields["amountField"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("1200")

        let memo = app.textFields["memoField"]
        memo.tap()
        memo.typeText("テスト買い物")

        let save = app.buttons["saveEntryButton"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.staticTexts["テスト買い物"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1,200'")).firstMatch.exists)
    }
}

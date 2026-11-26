import XCTest

final class StrokeValidationTests: XCTestCase {
  func testSelectIncomingShotAndInspectContact() {
    continueAfterFailure = false
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()

    let entry = app.buttons["动作验证"]
    XCTAssertTrue(entry.waitForExistence(timeout: 8))
    entry.tap()
    let scene = app.buttons["validation.scene"]
    XCTAssertTrue(scene.waitForExistence(timeout: 8))
    scene.tap()
    let scenes = ["网前高点机会球", "贴网慢球", "网前低点下落球", "身体侧面平快球", "接杀防守",
                  "半场高球", "后场到位高球", "平快压底线", "反手底角深球"]
    for name in scenes { XCTAssertTrue(app.buttons[name].exists, name) }
    app.buttons["接杀防守"].tap()
    let directions = app.segmentedControls["validation.direction"]
    directions.buttons["斜线"].tap()
    XCTAssertTrue(directions.buttons["斜线"].isSelected)
    let lanes = app.segmentedControls["validation.lane"]
    lanes.buttons["左路"].tap()
    XCTAssertTrue(lanes.buttons["左路"].isSelected)
    let replies = app.segmentedControls["validation.reply"]
    for name in ["接杀挡网", "接杀挑高", "接杀反抽"] { XCTAssertTrue(replies.buttons[name].exists) }
    XCTAssertFalse(replies.buttons["高远球"].exists)
    replies.buttons["接杀挑高"].tap()
    XCTAssertTrue(replies.buttons["接杀挑高"].isSelected)
    XCTAssertEqual(app.staticTexts["validation.asset"].label, "当前回法尚无角色动作")

    scene.tap()
    app.buttons["后场到位高球"].tap()
    XCTAssertTrue(replies.buttons["高远球"].isSelected)
    let status = app.staticTexts["validation.status"]
    let contact = app.buttons["validation.contact"]
    XCTAssertEqual(contact.label, "触球帧")
    app.buttons["validation.replay"].tap()
    let stopped = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "触球暂停 · F24"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 8), .completed)
    app.buttons["播放"].tap()
    contact.tap()
    XCTAssertEqual(status.label, "触球暂停 · F24")
    XCTAssertTrue(app.staticTexts["validation.measurement"].exists)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "后场正手高远球触球帧"
    proof.lifetime = .keepAlways
    add(proof)

    app.buttons["球社"].tap()
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
  }
}

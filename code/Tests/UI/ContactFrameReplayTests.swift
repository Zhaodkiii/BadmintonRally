import XCTest

final class ContactFrameReplayTests: XCTestCase {
  func testBackView() { play(side: false) }
  func testSideView() { play(side: true) }

  func testBlindBackView() { playBlind(side: false) }
  func testBlindSideView() { playBlind(side: true) }

  func testMaskedBackView() { playBlind(side: false, mode: ["-contactMasked"]) }
  func testRecoveryBackView() { playBlind(side: false, mode: ["-contactRecovery"]) }

  private func playBlind(side: Bool, mode: [String] = []) {
    let app = XCUIApplication()
    app.launchArguments = ["-contactFrameReplay", "-contactBlind"] + mode + (side ? ["-contactSide"] : [])
    app.launch()
    let forbidden = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                "accepted", "outOfReach", "ms")
    XCTAssertFalse(app.staticTexts.matching(forbidden).firstMatch.exists)
    XCTAssertTrue(app.staticTexts["播放结束"].waitForExistence(timeout: 100))
    XCTAssertFalse(app.staticTexts.matching(forbidden).firstMatch.exists)
  }

  private func play(side: Bool) {
    let app = XCUIApplication()
    app.launchArguments = ["-contactFrameReplay"] + (side ? ["-contactSide"] : [])
    app.launch()
    XCTAssertTrue(app.staticTexts["六组固定输入回放结束"].waitForExistence(timeout: 65))
  }

  func testMatchVolumeButton() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("此用例需要 iPhone 实体按键")
    #else
    let app = XCUIApplication()
    app.launch()
    app.buttons["开始比赛"].tap()
    app.buttons["进入球场"].tap()
    let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已按 0 次")).firstMatch
    XCTAssertTrue(ready.waitForExistence(timeout: 15))
    XCUIDevice.shared.press(.volumeUp)
    let hit = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已按 1 次")).firstMatch
    XCTAssertTrue(hit.waitForExistence(timeout: 5))
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "正式单打实体键"
    proof.lifetime = .keepAlways
    add(proof)
    #endif
  }
}

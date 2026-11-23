import XCTest

final class CaptureButtonTests: XCTestCase {
  func testRepeatedVolumeUpMarks() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Hardware capture buttons require an iPhone")
    #else
    let app = XCUIApplication()
    app.launchArguments += ["-manualCapturePlayer", "QA-CameraButtons"]
    app.launch()
    app.buttons["连续采集"].tap()
    app.switches["拍摄标注（iPhone 相机）"].tap()
    app.buttons["开始连续采集"].tap()
    let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
    if alert.waitForExistence(timeout: 2) {
      let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["允许", "Allow", "OK", "好"])).firstMatch
      if allow.exists { allow.tap() }
    }
    XCTAssertTrue(app.staticTexts["相机就绪 · 按 ＋ 或 − 标记，松开拍摄"].waitForExistence(timeout: 15))
    for i in 1...20 {
      XCUIDevice.shared.press(.volumeUp)
      XCTAssertTrue(app.staticTexts["\(i) 拍已标记"].waitForExistence(timeout: 2))
      guard app.staticTexts["\(i) 拍已标记"].exists else { return }
    }
    app.buttons["结束并保存整组"].tap()
    #endif
  }
}

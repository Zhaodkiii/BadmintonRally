import XCTest

final class ClubFlowTests: XCTestCase {
  func testMotionTestEntryAndReturn() {
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    app.buttons["动作测试"].tap()
    XCTAssertTrue(app.staticTexts["动作测试"].exists)
    app.buttons["motion-test-正手扣杀"].tap()
    XCTAssertTrue(app.staticTexts["专项曲线识别"].exists)
    XCTAssertTrue(app.buttons["分步查看"].exists)
    app.buttons["选择动作"].tap()
    app.buttons["motion-test-平抽"].tap()
    XCTAssertTrue(app.staticTexts["比赛引擎识别"].exists)
    app.buttons["选择动作"].tap()
    app.buttons["返回球社"].tap()
    XCTAssertTrue(app.buttons["动作测试"].exists)
  }

  func testJointCaptureEntry() {
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    app.buttons["Mac 联合采集"].tap()
    XCTAssertTrue(app.buttons["查找附近的 Mac"].exists)
    XCTAssertTrue(app.staticTexts["联合动作采集"].exists)
    app.buttons["球社"].tap()
    XCTAssertTrue(app.buttons["标准动作采集"].exists)
  }
  func testCaptureDemonstration() {
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    app.buttons["标准动作采集"].tap()
    app.buttons["握持示范"].tap()
    XCTAssertTrue(app.staticTexts["胸前基准"].exists)
    app.buttons["停在目标姿势"].tap()
    XCTAssertTrue(app.buttons["重播动作"].exists)
    app.buttons["下一姿势"].tap()
    XCTAssertTrue(app.staticTexts["持拍侧伸"].exists)
    app.buttons["返回动作示范"].tap()
    app.buttons["分步查看"].tap()
    XCTAssertTrue(app.staticTexts["1  准备"].exists)
    app.buttons["分步查看"].tap()
    XCTAssertTrue(app.staticTexts["2  引拍"].exists)
    app.buttons["分步查看"].tap()
    XCTAssertTrue(app.staticTexts["从下往前上方送出"].exists)
    let stage = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    stage.name = "上挑触球分解"
    stage.lifetime = .keepAlways
    add(stage)
    app.buttons["分步查看"].tap()
    XCTAssertTrue(app.staticTexts["4  回位"].exists)
    XCTAssertTrue(app.buttons["开始校准"].exists)
    app.buttons["采集设置与文件"].tap()
    XCTAssertTrue(app.switches["跟随演示录制"].exists)
    app.buttons["完成"].tap()
    XCTAssertTrue(app.buttons["分步查看"].exists)
  }

  func testPlayPauseReplayAndPractice() {
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    app.buttons["开始比赛"].tap()
    app.buttons["进入球场"].tap()
    XCTAssertTrue(app.staticTexts["轻轻上挑发球"].waitForExistence(timeout: 8))
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "比赛画面"
    image.lifetime = .keepAlways
    add(image)
    app.buttons["上挑"].tap()
    XCTAssertTrue(app.buttons["暂停"].exists)
    app.buttons["暂停"].tap()
    app.buttons["继续比赛"].tap()
    app.buttons["暂停"].tap()
    app.buttons["结束本局"].tap()
    app.buttons["返回球社"].tap()
    app.buttons["自由练习"].tap()
    app.buttons["高球"].tap()
    app.buttons["进入球场"].tap()
    XCTAssertTrue(app.buttons["暂停"].exists)
    app.buttons["暂停"].tap()
    app.buttons["结束本局"].tap()
    app.buttons["返回球社"].tap()
    app.buttons["挥拍入门"].tap()
    app.buttons["进入球场"].tap()
    XCTAssertTrue(app.staticTexts["低球 · 上挑到后场"].exists)
    let cue = app.staticTexts["现在挥拍"]
    let cutoff = Date().addingTimeInterval(12)
    while !cue.exists && Date() < cutoff {
      RunLoop.current.run(until: Date().addingTimeInterval(0.09))
    }
    XCTAssertTrue(cue.exists)
    let lessonImage = XCTAttachment(screenshot: app.screenshot())
    lessonImage.name = "挥拍入门"
    lessonImage.lifetime = .keepAlways
    add(lessonImage)
    app.buttons["上挑"].tap()
    XCTAssertTrue(app.staticTexts["高球 · 向下扣杀"].waitForExistence(timeout: 5))
  }
}

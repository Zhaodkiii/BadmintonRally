import XCTest

final class FormalMatchAuditTests: XCTestCase {
  func testRawSwingOneBall() throws {
    try play(launchFlag: "-p038RawOne", waitForSettlement: false)
  }

  func testRawSwingTrainedOneBall() throws {
    try play(launchFlag: "-p038RawOne", waitForSettlement: false, extraArguments: ["-p038Candidate"])
  }

  func testRawSwingFullMatch() throws {
    try play(launchFlag: "-p038RawFull")
  }

  func testRawSwingBaselineMatch() throws {
    try play(launchFlag: "-p038RawFull", extraArguments: ["-p038Baseline"])
  }

  func testRecordedReturnTiming() throws {
    try play(launchFlag: "-p039Recorded", waitForSettlement: false)
  }

  func testCuedReturnTiming() throws {
    try play(launchFlag: "-p039Cued", waitForSettlement: false)
  }

  func testRecordedTimingFullMatch() throws {
    try play(launchFlag: "-p040TimedMatch")
  }

  func testCompleteMatch() throws {
    try play(launchFlag: "-p035Match")
  }

  func testCoverageMatch() throws {
    try play(launchFlag: "-p035Coverage")
  }

  func testBackhandAndNetOverreachFixtures() throws {
    try play(launchFlag: "-p037Audit", waitForSettlement: false)
  }

  private func play(launchFlag: String, waitForSettlement: Bool = true, extraArguments: [String] = []) throws {
    #if targetEnvironment(simulator)
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [launchFlag] + extraArguments
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()

    let start = app.buttons["开始比赛"]
    XCTAssertTrue(start.waitForExistence(timeout: 20))
    attach("P035-球社首页")
    start.tap()

    let enter = app.buttons["进入球场"]
    XCTAssertTrue(enter.waitForExistence(timeout: 15))
    app.buttons["一局定胜负"].tap()
    app.buttons["单打"].tap()
    app.buttons["标准"].tap()
    enter.tap()
    let scoreboard = app.staticTexts.matching(
      NSPredicate(format: "label MATCHES %@", "林澄\\s+0\\s+周野\\s+0")).firstMatch
    XCTAssertTrue(scoreboard.waitForExistence(timeout: 20))
    attach("P035-正式对局零比零")
    if launchFlag.hasPrefix("-p038") || launchFlag == "-p040TimedMatch" {
      let mode = app.staticTexts["match.audit.rawMode"]
      XCTAssertTrue(mode.waitForExistence(timeout: 5), "真实采样包须成功加载")
      let trained = launchFlag == "-p038RawOne" ? extraArguments.contains("-p038Candidate") :
        launchFlag == "-p038RawFull" && !extraArguments.contains("-p038Baseline")
      XCTAssertEqual(mode.label, trained ? "原始输入·训练模型" : "原始输入·基线模型")
    }

    if !waitForSettlement {
      let proof = launchFlag.hasPrefix("-p039") ? "match.audit.recordedReturns" :
                  launchFlag == "-p038RawOne" ? "match.audit.rawBall" : "match.audit.newActions"
      XCTAssertTrue(app.staticTexts[proof].waitForExistence(timeout: 95))
      attach("P037-专项回合完成")
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      return
    }

    let final = app.buttons["再来一局"]
    XCTAssertTrue(final.waitForExistence(timeout: 480), "正式比赛需自然到达结算")
    let score = app.staticTexts.matching(
      NSPredicate(format: "label MATCHES %@", "[0-9]+\\s*:\\s*[0-9]+")).firstMatch
    let details = app.staticTexts["match.audit.result"]
    XCTAssertTrue(score.exists)
    XCTAssertTrue(details.exists)
    let sides = score.label.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    XCTAssertEqual(sides.count, 2)
    XCTAssertGreaterThanOrEqual(sides.max() ?? 0, 21, score.label)
    attach("P035-正式结算")
    let record = XCTAttachment(string: [score.label, details.label].joined(separator: "\n"))
    record.name = "P035-原生结算读数"
    record.lifetime = .keepAlways
    add(record)
    // Retain the visible settlement for the continuous Simulator recording.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    #else
    throw XCTSkip("此用例只在指定 iOS 模拟器 Debug 构建中使用")
    #endif
  }

  private func attach(_ name: String) {
    let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    proof.name = name
    proof.lifetime = .keepAlways
    add(proof)
  }
}

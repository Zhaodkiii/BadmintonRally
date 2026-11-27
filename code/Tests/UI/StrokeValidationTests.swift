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
    let asset = app.staticTexts["validation.asset"]
    let loaded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label BEGINSWITH %@", "已载入"), object: asset)
    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 12), .completed)
    scene.tap()
    XCTAssertTrue(app.buttons["接杀防守"].waitForExistence(timeout: 8))
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
    let measurement = app.staticTexts["validation.measurement"]
    let measured = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label ENDSWITH %@", " mm"), object: measurement)
    XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 5), .completed)
    let words = measurement.label.split(separator: " ")
    guard words.count >= 2, let millimetres = Double(words[words.count - 2]) else {
      return XCTFail("无法读取球拍中心偏差，显示为 \(measurement.label)")
    }
    XCTAssertLessThanOrEqual(millimetres, 1, measurement.label)
    let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    proof.name = "后场正手高远球触球帧"
    proof.lifetime = .keepAlways
    add(proof)

    app.buttons["球社"].tap()
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
  }

  func testSwitchClearAndStraightDropOnSameFeed() throws {
    try inspectShotSwitch(replacement: "吊球", frame: 25, height: "2.40", flight: "直线吊球")
  }

  func testSwitchClearAndStraightSmashOnSameFeed() throws {
    try inspectShotSwitch(replacement: "扣杀", frame: 24, height: "2.48", flight: "直线扣杀")
  }

  func testNetHighFeedSwitchesAllThreeRepliesAndResets() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()

    let entry = app.buttons["动作验证"]
    XCTAssertTrue(entry.waitForExistence(timeout: 8))
    entry.tap()
    let scene = app.buttons["validation.scene"]
    let replies = app.segmentedControls["validation.reply"]
    let asset = app.staticTexts["validation.asset"]
    let status = app.staticTexts["validation.status"]
    let measurement = app.staticTexts["validation.measurement"]
    let camera = app.buttons["validation.camera"]
    let replay = app.buttons["validation.replay"]

    func waitForLabel(_ element: XCUIElement, _ label: String) {
      let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
      XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 12), .completed, label)
    }
    func capture(_ name: String) {
      let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      proof.name = name
      proof.lifetime = .keepAlways
      add(proof)
    }
    func select(_ name: String, reply: String) {
      scene.tap()
      let menu = app.collectionViews.firstMatch
      XCTAssertTrue(menu.waitForExistence(timeout: 5))
      let option = menu.buttons[name]
      if !option.exists || !option.isHittable {
        if name == "网前高点机会球" {
          menu.swipeDown()
        } else {
          menu.swipeUp()
        }
      }
      XCTAssertTrue(option.waitForExistence(timeout: 5), name)
      option.tap()
      waitForLabel(asset, "已载入 · 林澄正手" + reply)
      XCTAssertTrue(replies.buttons[reply].isSelected)
      XCTAssertTrue(app.segmentedControls["validation.lane"].buttons["右路"].isSelected)
      XCTAssertTrue(app.segmentedControls["validation.direction"].buttons["直线"].isSelected)
      XCTAssertEqual(status.label, "准备回放")
      XCTAssertFalse(measurement.exists)
    }
    func verifyContact(_ frame: Int, height: String) throws {
      waitForLabel(status, "触球暂停 · F\(frame)")
      let rendered = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label ENDSWITH %@", " mm"), object: measurement)
      XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 8), .completed)
      let reading = measurement.label
      XCTAssertTrue(reading.hasPrefix("球高 \(height) m"), reading)
      let error = try XCTUnwrap(reading.split(separator: " ").dropLast().last.flatMap { Double($0) })
      XCTAssertLessThanOrEqual(error, 1, reading)
    }

    waitForLabel(asset, "已载入 · 林澄正手高远球")
    select("网前高点机会球", reply: "扑球")
    for (index, reply) in ["扑球", "推球", "轻放网", "扑球"].enumerated() {
      if index > 0 {
        replies.buttons[reply].tap()
        waitForLabel(asset, "已载入 · 林澄正手" + reply)
      }
      XCTAssertTrue(replies.buttons[reply].isSelected)
      XCTAssertTrue(app.segmentedControls["validation.lane"].buttons["右路"].isSelected)
      XCTAssertTrue(app.segmentedControls["validation.direction"].buttons["直线"].isSelected)
      XCTAssertEqual(status.label, "准备回放")
      XCTAssertFalse(measurement.exists)

      replay.tap()
      try verifyContact(19, height: "1.86")
      let prefix = "\(index + 1)-网前" + reply
      capture(prefix + "触球")
      if index < 3 {
        camera.tap()
        waitForLabel(camera, "动作近景")
        capture(prefix + "全场球路")
        app.buttons["播放"].tap()
        waitForLabel(status, "回放结束")
        capture(prefix + "落点")
        camera.tap()
        waitForLabel(camera, "全场球路")
        app.buttons["validation.contact"].tap()
        try verifyContact(19, height: "1.86")
        capture(prefix + "手动触球")
      }
    }

    select("后场到位高球", reply: "高远球")
    replay.tap()
    try verifyContact(24, height: "2.35")
    capture("06-后场高远球回归")

    select("网前高点机会球", reply: "扑球")
    replay.tap()
    try verifyContact(19, height: "1.86")
    capture("07-返回网前扑球")
    app.buttons["球社"].tap()
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
  }

  func testMidcourtFlatFeedSwitchesAllThreeRepliesAndResets() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    let entry = app.buttons["动作验证"]
    XCTAssertTrue(entry.waitForExistence(timeout: 8))
    entry.tap()

    let scene = app.buttons["validation.scene"]
    let asset = app.staticTexts["validation.asset"]
    let replies = app.segmentedControls["validation.reply"]
    let status = app.staticTexts["validation.status"]
    let measurement = app.staticTexts["validation.measurement"]
    let camera = app.buttons["validation.camera"]

    func waitForLabel(_ element: XCUIElement, _ label: String) {
      let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
      XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 12), .completed, label)
    }
    func capture(_ name: String) {
      let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      proof.name = name
      proof.lifetime = .keepAlways
      add(proof)
    }

    waitForLabel(asset, "已载入 · 林澄正手高远球")
    scene.tap()
    let menu = app.collectionViews.firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    let flat = menu.buttons["身体侧面平快球"]
    if !flat.exists || !flat.isHittable { menu.swipeDown() }
    XCTAssertTrue(flat.waitForExistence(timeout: 5))
    flat.tap()

    let shots = [("正手平抽", 16, "1.51"), ("反手平抽", 17, "1.48"),
                 ("减力挡网", 16, "1.51"), ("正手平抽", 16, "1.51")]
    for (index, shot) in shots.enumerated() {
      let (name, frame, height) = shot
      if index > 0 { replies.buttons[name].tap() }
      waitForLabel(asset, "已载入 · 林澄" + name)
      XCTAssertTrue(replies.buttons[name].isSelected)
      XCTAssertTrue(app.segmentedControls["validation.lane"].buttons["右路"].isSelected)
      XCTAssertTrue(app.segmentedControls["validation.direction"].buttons["直线"].isSelected)
      XCTAssertEqual(status.label, "准备回放")
      XCTAssertFalse(measurement.exists)

      app.buttons["validation.replay"].tap()
      waitForLabel(status, "触球暂停 · F\(frame)")
      let rendered = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label ENDSWITH %@", " mm"), object: measurement)
      XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 8), .completed)
      let reading = measurement.label
      XCTAssertTrue(reading.hasPrefix("球高 \(height) m"), reading)
      let offset = try XCTUnwrap(reading.split(separator: " ").dropLast().last.flatMap { Double($0) })
      XCTAssertLessThanOrEqual(offset, 1, reading)
      let prefix = "\(index + 1)-\(name)"
      capture(prefix + "触球")
      if index < shots.count - 1 {
        camera.tap()
        waitForLabel(camera, "动作近景")
        capture(prefix + "全场球路")
        app.buttons["播放"].tap()
        waitForLabel(status, "回放结束")
        capture(prefix + "落点")
        camera.tap()
        waitForLabel(camera, "全场球路")
      }
    }

    app.buttons["球社"].tap()
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
  }

  func testServeReleaseContactAndDiagonalLanding() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()

    let entry = app.buttons["动作验证"]
    XCTAssertTrue(entry.waitForExistence(timeout: 8))
    entry.tap()
    let scene = app.buttons["validation.scene"]
    let asset = app.staticTexts["validation.asset"]
    let status = app.staticTexts["validation.status"]
    let measurement = app.staticTexts["validation.measurement"]
    let release = app.staticTexts["validation.releaseMeasurement"]
    let drop = app.staticTexts["validation.dropMeasurement"]
    let route = app.staticTexts["validation.serveRoute"]
    let camera = app.buttons["validation.camera"]

    func waitForLabel(_ element: XCUIElement, _ label: String) {
      let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
      XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 12), .completed, label)
    }
    func pick(_ name: String, using picker: XCUIElement, scrollUpToTop: Bool = false) {
      picker.tap()
      let menu = app.collectionViews.firstMatch
      XCTAssertTrue(menu.waitForExistence(timeout: 5))
      let option = menu.buttons[name]
      if scrollUpToTop && (!option.exists || !option.isHittable) { menu.swipeDown() }
      XCTAssertTrue(option.waitForExistence(timeout: 5), name)
      option.tap()
    }
    func capture(_ name: String) {
      let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      proof.name = name
      proof.lifetime = .keepAlways
      add(proof)
    }
    func error(_ element: XCUIElement) throws -> Double {
      let rendered = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label ENDSWITH %@", " mm"), object: element)
      XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 8), .completed)
      return try XCTUnwrap(element.label.split(separator: " ").dropLast().last.flatMap { Double($0) })
    }
    func value(_ label: String, before unit: String) throws -> Double {
      let parts = label.components(separatedBy: unit)
      return try XCTUnwrap(parts.first?.split(separator: " ").last.flatMap { Double($0) })
    }

    waitForLabel(asset, "已载入 · 林澄正手高远球")
    pick("我方发球", using: scene, scrollUpToTop: true)
    let serves = [("正手高远发球", 20, 24, 6.21), ("正手短发球", 20, 24, 2.61),
                  ("反手短发球", 15, 18, 2.51), ("反手偷后场", 15, 18, 5.40)]
    for (index, serve) in serves.enumerated() {
      let (name, releaseFrame, contactFrame, expectedDepth) = serve
      if index > 0 { pick(name, using: app.buttons["validation.serve"]) }
      waitForLabel(asset, "已载入 · 林澄" + name)
      XCTAssertEqual(status.label, "准备回放")
      XCTAssertFalse(measurement.exists)
      XCTAssertFalse(release.exists)
      XCTAssertFalse(route.exists)
      capture(name + "-左手持球")

      app.buttons["validation.release"].tap()
      waitForLabel(status, "放球暂停 · F\(releaseFrame)")
      XCTAssertLessThanOrEqual(try error(release), 1, release.label)
      let releaseReading = release.label
      let releaseHeight = try value(releaseReading, before: " m")
      capture(name + "-放球")
      app.buttons["validation.drop"].tap()
      XCTAssertTrue(drop.waitForExistence(timeout: 5))
      let dropReading = drop.label
      XCTAssertLessThan(try value(dropReading, before: " m"), releaseHeight, dropReading)
      capture(name + "-下落")

      app.buttons["validation.replay"].tap()
      waitForLabel(status, "触球暂停 · F\(contactFrame)")
      XCTAssertLessThanOrEqual(try error(measurement), 1, measurement.label)
      let contactReading = measurement.label
      XCTAssertTrue(route.label.hasPrefix("对角出球"), route.label)
      capture(name + "-触球")

      camera.tap()
      waitForLabel(camera, "动作近景")
      capture(name + "-全场球路")
      app.buttons["播放"].tap()
      waitForLabel(status, "回放结束")
      XCTAssertTrue(route.label.hasPrefix("合法对角落地"), route.label)
      let values = route.label.components(separatedBy: " · ")
      XCTAssertEqual(values.count, 4, route.label)
      XCTAssertGreaterThan(try value(values[1], before: " m"), 0, route.label)
      XCTAssertEqual(try value(values[2], before: " m"), expectedDepth, accuracy: 0.01, route.label)
      XCTAssertLessThan(try value(values[3], before: " m"), 0, route.label)
      let readings = XCTAttachment(string: [releaseReading, dropReading, contactReading, route.label].joined(separator: "\n"))
      readings.name = name + "-实测"
      readings.lifetime = .keepAlways
      add(readings)
      capture(name + "-落点")
      camera.tap()
      waitForLabel(camera, "全场球路")
      app.buttons["validation.contact"].tap()
      waitForLabel(status, "触球暂停 · F\(contactFrame)")
      XCTAssertLessThanOrEqual(try error(measurement), 1, measurement.label)
    }

    pick("后场到位高球", using: scene)
    waitForLabel(asset, "已载入 · 林澄正手高远球")
    app.buttons["validation.replay"].tap()
    waitForLabel(status, "触球暂停 · F24")
    XCTAssertLessThanOrEqual(try error(measurement), 1, measurement.label)
    capture("后场高远球回归")
    pick("我方发球", using: scene, scrollUpToTop: true)
    waitForLabel(asset, "已载入 · 林澄正手高远发球")
    waitForLabel(status, "准备回放")
    XCTAssertFalse(measurement.exists)
    XCTAssertFalse(route.exists)
    app.buttons["validation.release"].tap()
    waitForLabel(status, "放球暂停 · F20")
    XCTAssertLessThanOrEqual(try error(release), 1, release.label)
    capture("返回发球重置")
  }

  private func inspectShotSwitch(replacement: String, frame: Int, height: String, flight: String) throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    let entry = app.buttons["动作验证"]
    XCTAssertTrue(entry.waitForExistence(timeout: 8))
    entry.tap()
    let replies = app.segmentedControls["validation.reply"]
    let status = app.staticTexts["validation.status"]
    let asset = app.staticTexts["validation.asset"]
    let measurement = app.staticTexts["validation.measurement"]

    func waitForLabel(_ element: XCUIElement, _ label: String) {
      let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
      XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 12), .completed, label)
    }
    func capture(_ name: String) {
      let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      proof.name = name
      proof.lifetime = .keepAlways
      add(proof)
    }
    func inspectContact(frame: Int, height: String) throws {
      waitForLabel(status, "触球暂停 · F\(frame)")
      let rendered = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label ENDSWITH %@", " mm"), object: measurement)
      XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 8), .completed)
      let text = measurement.label
      XCTAssertTrue(text.hasPrefix("球高 \(height) m"), text)
      let offset = try XCTUnwrap(text.split(separator: " ").dropLast().last.flatMap { Double($0) })
      XCTAssertLessThanOrEqual(offset, 1, text)
    }

    for (index, shot) in ["高远球", replacement, "高远球"].enumerated() {
      if index > 0 { replies.buttons[shot].tap() }
      waitForLabel(asset, "已载入 · 林澄正手" + shot)
      XCTAssertTrue(replies.buttons[shot].isSelected)
      XCTAssertTrue(app.segmentedControls["validation.lane"].buttons["右路"].isSelected)
      XCTAssertTrue(app.segmentedControls["validation.direction"].buttons["直线"].isSelected)
      XCTAssertEqual(status.label, "准备回放")
      XCTAssertFalse(measurement.exists)
      app.buttons["validation.replay"].tap()
      let isReplacement = shot == replacement
      try inspectContact(frame: isReplacement ? frame : 24, height: isReplacement ? height : "2.35")
      capture("\(index + 1)-\(shot)触球")
      if isReplacement {
        app.buttons["validation.camera"].tap()
        waitForLabel(app.buttons["validation.camera"], "动作近景")
        capture("\(flight)全场球路")
        app.buttons["播放"].tap()
        waitForLabel(status, "回放结束")
        capture("\(flight)实际落点")
        app.buttons["validation.camera"].tap()
        waitForLabel(app.buttons["validation.camera"], "全场球路")
        capture("\(flight)收拍复位")
        app.buttons["validation.contact"].tap()
        try inspectContact(frame: frame, height: height)
        capture("\(flight)手动回到触球")
      }
    }
    app.buttons["球社"].tap()
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
  }
}

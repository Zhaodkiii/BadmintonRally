import SwiftUI

@MainActor
struct MotionTestView: View {
  let left: Bool
  let light: Bool
  let haptics: Bool
  let sound: Bool
  let close: () -> Void

  private final class Recorder {
    var trace: MotionTestTrace?
  }

  @State private var recorder = Recorder()
  @State private var diagnosticFiles: [URL] = []
  @State private var diagnosticError: String?
  @State private var feedback = MatchFeedback()
  @StateObject private var motion = MotionInput()
  @StateObject private var nearby = NearbyPhone()
  @ObservedObject private var studio = StudioSender.shared
  @State private var trustedMac: NearbyPairing.Ticket?
  @State private var triedNearbyMac = false
  @State private var showConnection = false
  @Environment(\.scenePhase) private var lifecycle
  @State private var target: StandardStroke?
  @State private var calibrating = false
  @State private var startAfterCalibration = false
  @State private var completed: [StandardStroke: Int] = [:]
  @State private var groupVerdicts: [Verdict] = []
  @State private var showingResults = false
  @State private var run: Task<Void, Never>?
  @State private var window: ClosedRange<Double>?
  @State private var candidates: [Candidate] = []
  @State private var attempts: [Attempt] = []
  @State private var prompt = "拿稳手机，完成握姿与挥拍校准"
  @State private var detail = ""

  private struct Candidate {
    let game: Stroke?
    let curve: SwingCurveModel.Match?
    let reason: String

    var text: String {
      let gameText = game?.rawValue ?? "未输出"
      let curveText = curve.map {
        String(format: "%@ · 相似度 %.2f · 分差 %.2f", $0.label, $0.score, $0.margin)
      } ?? "无匹配"
      return "游戏 \(gameText)｜曲线 \(curveText)" + (game == nil ? "｜" + reason : "")
    }
  }

  private enum Verdict: String {
    case match = "识别一致"
    case mismatch = "识别为其他动作"
    case uncertain = "未形成可靠判定"
    case missed = "未检出挥拍"
    case multiple = "检测到多个候选"
  }

  private struct Attempt {
    let target: StandardStroke
    let verdict: Verdict
    let detail: String
  }

  private func gameTarget(_ action: StandardStroke) -> Stroke? {
    switch action {
    case .lift: return .lift
    case .drive: return .drive
    default: return nil
    }
  }

  private var testedTargets: [StandardStroke] {
    Set(attempts.map(\.target)).sorted { $0.rawValue < $1.rawValue }
  }

  private func totals(_ action: StandardStroke) -> String {
    let rows = attempts.filter { $0.target == action }
    let matched = rows.filter { $0.verdict == .match }.count
    let missed = rows.filter { $0.verdict == .missed }.count
    let wrong = rows.filter { $0.verdict == .mismatch }.count
    let other = rows.count - matched - missed - wrong
    return "\(action.displayName) · 一致 \(matched)/\(rows.count) · 漏检 \(missed) · 错类 \(wrong) · 拒识或多候选 \(other)"
  }

  private var report: String {
    let header = "动作测试 · \(left ? "左手设置" : "右手设置") · \(light ? "轻挥" : "普通") · 曲线 \(motion.curveVersion)"
    let log = attempts.enumerated().map { index, row in
      "\(index + 1). \(row.target.displayName) · \(row.verdict.rawValue) · \(row.detail)"
    }
    return ([header] + testedTargets.map(totals) + log).joined(separator: "\n")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        if target != nil {
          Button("选择动作", systemImage: "chevron.left") { selectAction() }
        } else {
          Button("返回球社", systemImage: "chevron.left", action: close)
        }
        Spacer()
        Text(target?.displayName ?? "动作测试").font(.headline)
        Spacer()
        if run != nil || calibrating {
          Button("停止") { stopTest() }
        } else if !attempts.isEmpty || !diagnosticFiles.isEmpty || diagnosticError != nil {
          Button("结果记录") { showingResults = true }
        }
      }
      .frame(minHeight: 36)
      Button {
        showConnection = true
      } label: {
        Label(trustedMac == nil ? "连接测试 Mac" : (studio.diagnosticStatus.isEmpty ?
          "正在查找测试 Mac" : studio.diagnosticStatus),
          systemImage: trustedMac != nil && studio.linked ? "desktopcomputer" : "arrow.triangle.2.circlepath")
          .font(.caption)
      }.buttonStyle(.plain)
      if let target {
        actionPage(target)
      } else {
        actionList
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 8)
    .sheet(isPresented: $showingResults) { resultsPage }
    .sheet(isPresented: $showConnection) { connectionPage }
    .onAppear {
      diagnosticFiles = MotionTestTrace.archived()
      if let data = CaptureTrust.read("iphone-test-host") {
        trustedMac = try? JSONDecoder().decode(NearbyPairing.Ticket.self, from: data)
      }
      studio.resumeDiagnosticSync(trustedMac)
      nearby.paired = { ticket in
        trustedMac = ticket
        if let encoded = try? JSONEncoder().encode(ticket) {
          CaptureTrust.save(encoded, as: "iphone-test-host")
        }
        studio.resumeDiagnosticSync(ticket)
        showConnection = false
        nearby.stop()
      }
      if trustedMac == nil { nearby.browse() }
    }
    .task(id: nearby.names.keys.sorted { $0.uuidString < $1.uuidString }) {
      guard trustedMac == nil, !triedNearbyMac, nearby.names.count == 1 else { return }
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, trustedMac == nil, !triedNearbyMac,
            nearby.names.count == 1, let mac = nearby.names.keys.first else { return }
      triedNearbyMac = true
      nearby.pair(mac)
    }
    .onChange(of: nearby.status) { _, status in
      if trustedMac == nil && status.hasPrefix("核对码") { showConnection = true }
    }
    .onDisappear {
      stopTest()
      nearby.stop()
      nearby.paired = nil
      motion.onTestFrame = nil
      motion.onTestEvent = nil
    }
    .onChange(of: lifecycle) { _, phase in
      if phase == .active, let trustedMac { studio.resumeDiagnosticSync(trustedMac) }
      if phase != .active && (run != nil || calibrating || motion.ready) {
        stopTest()
        prompt = "测试已暂停"
        detail = "再次点开始，握稳后继续。"
      }
    }
    .onChange(of: motion.interrupted) { _, interrupted in
      if interrupted {
        stopTest()
        prompt = "传感器采样中断"
        detail = "点开始测试重新连接传感器。"
      }
    }
    .onChange(of: motion.ready) { _, ready in
      guard ready, calibrating, let target else { return }
      calibrating = false
      if startAfterCalibration {
        startAfterCalibration = false
        startGroup(target)
      }
    }
  }

  private var connectionPage: some View {
    NavigationStack {
      List {
        if let trustedMac {
          Text(trustedMac.host)
          Text(studio.diagnosticStatus)
          Button("更换接收 Mac") {
            CaptureTrust.forget("iphone-test-host")
            self.trustedMac = nil
            triedNearbyMac = false
            studio.resumeDiagnosticSync(nil)
            nearby.browse()
          }
        } else {
          Text("首次连接时，请在 Mac 打开 RallyCapture → 测试接收，核对两端配对码。")
          Text(nearby.status)
          ForEach(nearby.names.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
            Button(nearby.names[id] ?? "RallyCapture") {
              triedNearbyMac = true
              nearby.pair(id)
            }
          }
          Button("重新查找") {
            nearby.stop()
            triedNearbyMac = false
            nearby.browse()
          }
        }
      }
      .navigationTitle("测试接收 Mac")
      .toolbar { Button("完成") { showConnection = false } }
    }
  }

  private var actionList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("选一个动作，先看示范，再挥三拍。").font(.subheadline)
        ForEach(StandardStroke.trainingGroups, id: \.title) { section in
          Text(section.title).font(.headline).foregroundStyle(.mint)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(section.strokes) { action in
              Button {
                target = action
                prompt = ""
                detail = ""
                groupVerdicts = []
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(action.displayName).font(.subheadline.bold())
                    if let count = completed[action] {
                      Text(count == 3 ? "已通过" : "上组 \(count)/3")
                        .font(.caption).foregroundStyle(count == 3 ? Color.mint : Color.orange)
                    }
                  }
                  Spacer()
                  Image(systemName: "chevron.right").font(.caption)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("motion-test-" + action.rawValue)
            }
          }
        }
      }
    }
  }

  private func actionPage(_ action: StandardStroke) -> some View {
    HStack(spacing: 14) {
      StrokeDemonstration(
        stroke: action, left: left, elapsed: run == nil && !calibrating ? nil : 0,
        recording: run != nil || calibrating, speed: .slow
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      ScrollView {
        VStack(alignment: .leading, spacing: 9) {
          Text(gameTarget(action) == nil ? "专项曲线识别" : "比赛引擎识别")
            .font(.caption.bold()).foregroundStyle(.mint)
          if calibrating {
            Text("先完成握姿校准").font(.title3.bold())
            Text(motion.cue).font(.callout.bold())
            ProgressView(value: motion.progress)
            Text(motion.status).font(.caption)
          } else {
            Text(prompt.isEmpty ? "准备测试" : prompt)
              .font(.system(size: run == nil ? 25 : 34, weight: .bold, design: .rounded))
              .accessibilityAddTraits(.isHeader)
            if !detail.isEmpty { Text(detail).font(.callout) }
            if !groupVerdicts.isEmpty {
              HStack(spacing: 6) {
                ForEach(Array(groupVerdicts.enumerated()), id: \.offset) { index, verdict in
                  Label("\(index + 1)", systemImage: verdict == .match ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(verdict == .match ? Color.mint : Color.orange)
                    .accessibilityLabel("第 \(index + 1) 拍，\(verdict.rawValue)")
                }
              }
            }
            if run == nil {
              if motion.available {
                Button(groupVerdicts.isEmpty ? "开始测试" : "再测三拍", systemImage: "play.fill") {
                  if motion.ready { startGroup(action) }
                  else { startSensors() }
                }
                .buttonStyle(.borderedProminent)
                Text("等提示后挥一次，再收手。三拍均识别一致即通过。").font(.footnote)
              } else {
                Text("请在支持体感的 iPhone 上开始测试。").font(.footnote)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(width: 240)
    }
    .frame(maxHeight: .infinity)
  }

  private var resultsPage: some View {
    NavigationStack {
      List {
        Section("按动作统计") {
          ForEach(testedTargets) { action in Text(totals(action)) }
        }
        Section("传感器诊断文件") {
          if let diagnosticError { Text(diagnosticError).foregroundStyle(.orange) }
          ForEach(diagnosticFiles, id: \.self) { url in
            ShareLink(item: url) {
              Label(url.deletingPathExtension().lastPathComponent.dropLast(37).description,
                    systemImage: "square.and.arrow.up")
            }
          }
        }
        Section("逐拍记录") {
          ForEach(Array(attempts.enumerated().reversed()), id: \.offset) { index, row in
            VStack(alignment: .leading, spacing: 4) {
              Text("\(index + 1). \(row.target.displayName) · \(row.verdict.rawValue)").font(.headline)
              Text(row.detail).font(.caption)
            }
          }
        }
      }
      .navigationTitle("动作测试结果")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("完成") { showingResults = false } }
        ToolbarItem(placement: .primaryAction) { ShareLink(item: report) }
      }
    }
  }

  private func selectAction() {
    stopTest()
    target = nil
  }

  private func stopTest() {
    finishTrace("interrupted")
    endGroup()
    calibrating = false
    startAfterCalibration = false
    motion.stop()
    motion.calibrate(personal: true, keepExamples: true)
    UIApplication.shared.isIdleTimerDisabled = false
  }

  private func startSensors() {
    guard motion.available else { return }
    calibrating = true
    startAfterCalibration = true
    UIApplication.shared.isIdleTimerDisabled = true
    motion.stop()
    motion.light = light
    if let target { beginTrace(target) }
    motion.onTestFrame = { frame in recorder.trace?.frames.append(frame) }
    motion.onTestEvent = { event, game, curve in
      if event.kind == "candidate" || recorder.trace?.events.last?.text != event.text {
        recorder.trace?.events.append(event)
      }
      guard event.kind == "candidate", window?.contains(event.time) == true else { return }
      if motion.playing && motion.swingImpact == nil {
        lastPhaseRejection = event.text
        return
      }
      candidates.append(Candidate(game: game, curve: curve, reason: event.text))
    }
    motion.calibrate(personal: true, keepExamples: true)
    motion.start()
  }

  private func beginTrace(_ action: StandardStroke) {
    guard recorder.trace == nil else { return }
    recorder.trace = MotionTestTrace(target: action.rawValue, hand: left ? "left" : "right",
      curveVersion: motion.curveVersion, light: light,
      assist: UserDefaults.standard.bool(forKey: "curveAssist"))
  }

  private func saveTrace(sync: Bool = false) {
    guard let trace = recorder.trace else { return }
    do {
      let url = try trace.save()
      if !diagnosticFiles.contains(url) { diagnosticFiles.insert(url, at: 0) }
      if sync { studio.queueDiagnostic(url) }
      diagnosticError = nil
    } catch {
      diagnosticError = "诊断文件保存失败：\(error.localizedDescription)"
    }
  }

  private func finishTrace(_ state: String) {
    recorder.trace?.state = state
    saveTrace(sync: true)
    recorder.trace = nil
  }

  private func endGroup() {
    run?.cancel()
    run = nil
    window = nil
    if !candidates.isEmpty { candidates.removeAll() }
    prompt = "本组已结束"
    detail = ""
  }

  private func startGroup(_ action: StandardStroke) {
    guard run == nil, motion.ready else { return }
    motion.playing = true
    groupVerdicts = []
    beginTrace(action)
    UIApplication.shared.isIdleTimerDisabled = true
    run = Task {
      do {
        for round in 1...3 {
          recorder.trace?.events.append(.init(time: ProcessInfo.processInfo.systemUptime,
            kind: "countdown", text: "倒数开始", round: round))
          detail = "第 \(round)/3 拍 · \(action.displayName) · 回到准备姿势"
          for count in (1...3).reversed() {
            prompt = "\(count)"
            try await Task.sleep(for: .seconds(1))
          }
          lastPhaseRejection = nil
          candidates.removeAll()
          let now = ProcessInfo.processInfo.systemUptime
          window = now...(now + 3)
          recorder.trace?.events.append(.init(time: now, kind: "window", text: "挥拍窗口",
                                              round: round, end: now + 3))
          prompt = "现在挥一次"
          detail = action.cues[1] + "，" + action.cues[2] + "，自然减速"
          feedback.play("tap", sound: sound, vibration: false)
          if haptics { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
          try await Task.sleep(for: .seconds(3))
          prompt = "收手，回到准备姿势"
          // The detector can finish after the last eligible peak.
          try await Task.sleep(for: .milliseconds(360))
          try Task.checkCancellation()
          let result = assess(action)
          recorder.trace?.events.append(.init(time: ProcessInfo.processInfo.systemUptime,
            kind: "result", text: "\(result.verdict.rawValue) · \(result.detail)", round: round))
          window = nil
          saveTrace()
          attempts.append(result)
          groupVerdicts.append(result.verdict)
          prompt = result.verdict.rawValue
          detail = result.detail
          if result.verdict == .match {
            feedback.play("point", sound: sound, vibration: false)
          }
          if haptics {
            UINotificationFeedbackGenerator().notificationOccurred(result.verdict == .match ? .success : .warning)
          }
          try await Task.sleep(for: .milliseconds(1600))
        }
        let matches = groupVerdicts.filter { $0 == .match }.count
        finishTrace("complete")
        completed[action] = matches
        prompt = matches == 3 ? "测试通过" : "本组未通过"
        detail = "\(matches)/3 拍识别一致"
        run = nil
      } catch is CancellationError {
        // The caller has already closed this group's window.
      } catch {
        stopTest()
      }
    }
  }

  private func missingCandidateDetail() -> String {
    guard let window, let frames = recorder.trace?.frames.filter({ window.contains($0.time) }),
          !frames.isEmpty else { return "窗口内没有传感器样本" }
    if recorder.trace?.events.contains(where: {
      $0.kind == "candidate" && !window.contains($0.time)
        && (window.lowerBound - 0.5 ... window.upperBound + 0.36).contains($0.time)
    }) == true {
      return "提示前后检测到挥拍，主峰落在评分窗口外。"
    }
    if !frames.contains(where: { $0.armed || $0.tracking }) {
      return "检测器尚未就位，检查回到准备握姿后是否停稳。"
    }
    if !frames.contains(where: \.tracking) {
      return "检测器已就位，窗口内的挥动未触发阈值。"
    }
    return "检测器开始跟踪，但窗口内没有完成的候选。"
  }

  @State private var lastPhaseRejection: String?

  private func assess(_ action: StandardStroke) -> Attempt {
    let verdict: Verdict
    let explanation: String
    if candidates.isEmpty {
      verdict = .missed
      explanation = lastPhaseRejection ?? missingCandidateDetail()
    } else if candidates.count > 1 {
      verdict = .multiple
      explanation = candidates.map(\.text).joined(separator: " / ")
    } else {
      let candidate = candidates[0]
      explanation = candidate.text
      if let expected = gameTarget(action) {
        verdict = candidate.game.map { $0 == expected ? .match : .mismatch } ?? .uncertain
      } else if let curve = candidate.curve, curve.strong {
        verdict = curve.label == action.rawValue ? .match : .mismatch
      } else {
        verdict = .uncertain
      }
    }
    return Attempt(target: action, verdict: verdict, detail: explanation)
  }
}

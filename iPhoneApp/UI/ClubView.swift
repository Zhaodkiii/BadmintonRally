import Combine
import SwiftUI

enum Page { case home, setup, airplay, calibration, court, pause, result, lab, settings, sync, jointCapture }
struct ClubView: View {
  @ObservedObject private var studio = StudioSender.shared
  @StateObject private var motion = MotionInput()
  @State private var page = Page.home
  @State private var game = Rally()
  @State private var training = false
  @State private var lesson = false
  @State private var touch = false
  @State private var useTV = false
  @State private var lastTick = 0.0
  @State private var resumeAt = 0.0
  @State private var trial = StandardStroke.lift
  @State private var reviewLabel = StandardStroke.lift
  @State private var guidedCapture = true
  @State private var captureSpeed = CaptureSpeed.normal
  @State private var labLeft = false
  @State private var soloPreview: Int?
  @State private var showLabOptions = false
  @State private var showArchive = false
  @State private var participant = "P01"
  @State private var aim = 0.0
  @State private var drill = Drill.mixed
  @State private var resuming = false
  @State private var feedback = MatchFeedback()
  @AppStorage("difficulty") private var difficulty = 1
  @AppStorage("curveAssist") private var curveAssist = false
  @AppStorage("lightSwing") private var light = false
  @AppStorage("leftHand") private var left = false
  @AppStorage("sound") private var sound = true
  @AppStorage("haptic") private var haptic = true
  @AppStorage("syncMS") private var syncMS = 0.0
  @AppStorage("bestRally") private var best = 0
  @Environment(\.scenePhase) private var lifecycle
  @Environment(\.accessibilityReduceMotion) private var reduced
  let clock = Timer.publish(every: 1 / 60, on: .main, in: .common).autoconnect()
  let ink = Color(red: 0.045, green: 0.13, blue: 0.14)
  let cream = Color(red: 0.96, green: 0.94, blue: 0.86)
  let accent = Color(red: 0.97, green: 0.56, blue: 0.39)

  var body: some View {
    ZStack {
      ink.ignoresSafeArea()
      if page == .court || page == .pause || page == .result {
        CourtView(game: game, reduced: reduced, leftHanded: left).ignoresSafeArea()
        if page == .court {
          matchHUD
        } else {
          Color.black.opacity(0.65).ignoresSafeArea()
          if page == .pause { pauseCard } else { resultCard }
        }
      } else if page == .jointCapture {
        PhoneCaptureConsole {page = .home}
      } else if page == .lab {
        captureStudio
      } else if page == .home {
        home
      } else {
        panel
      }
    }
    .overlay(alignment:.top) {
      if !studio.instruction.isEmpty {Text("采集 · " + studio.instruction).font(.headline).padding(7).background(.black.opacity(0.8),in:Capsule()).allowsHitTesting(false)}
    }
    .foregroundStyle(cream).tint(accent)
    .onReceive(clock) { _ in tick() }
    .onAppear {
      touch = !motion.available
      motion.onStroke = { kind, direction, time in
        if page == .court && !touch && resumeAt == 0 {
          StudioSender.shared.event("prediction:" + kind.rawValue, at: time)
          hit(kind, aim: direction, age: ProcessInfo.processInfo.systemUptime - time)
        }
      }
    }
    .onChange(of: motion.interrupted) { _, interrupted in
      if interrupted && page == .court { pause() }
    }
    .onChange(of: lifecycle) { _, new in
      if new == .background { StudioSender.shared.interrupt() }
      if new != .active {
        if page == .court { pause() }
        if page != .lab || new == .background { motion.stop() }
      } else if page == .calibration || (page == .lab && !motion.recording && motion.soloStep == nil && !motion.soloArmed) {
        motion.calibrate(personal: page == .calibration, keepExamples: true)
        motion.start()
      }
    }
    .onDisappear {
      motion.stop()
      UIApplication.shared.isIdleTimerDisabled = false
    }
  }
  var home: some View {
    ZStack(alignment: .leading) {
      GeometryReader { geo in
        Image("clubhouse", bundle: .main).resizable().scaledToFill().frame(
          width: geo.size.width, height: geo.size.height
        ).clipped()
      }.ignoresSafeArea()
      LinearGradient(
        colors: [ink, ink.opacity(0.94), ink.opacity(0.16), .clear], startPoint: .leading,
        endPoint: .trailing
      ).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 12) {
        Text("晚风球社").font(.system(size: 48, weight: .heavy, design: .rounded))
        Text("羽毛球体感单打").font(.headline).foregroundStyle(.mint)
        HStack {
          action("开始比赛", "play.fill") { setup(false) }
          secondary("自由练习") { setup(true) }
          secondary("挥拍入门") { setup(true, guided: true) }
        }
        HStack {
          secondary("投屏指南") { page = .airplay }
          secondary("设置") { page = .settings }
          secondary("Mac 联合采集") { page = .jointCapture }
          secondary("标准动作采集") {
            labLeft = left
            motion.loadArchive()
            page = .lab
            motion.calibrate()
            motion.start()
          }
        }
        if best > 0 { Text("个人最长回合  \(best) 拍").font(.caption.monospacedDigit()) }
      }.padding(.leading, 28)
    }
  }
  func setup(_ practice: Bool, guided: Bool = false) {
    lesson = guided
    training = practice
    page = .setup
  }
  func action(_ title: String, _ icon: String, _ f: @escaping () -> Void) -> some View {
    Button(action: f) {
      Label(title, systemImage: icon).font(.headline).padding(.horizontal, 17).frame(minHeight: 44)
        .background(accent, in: Capsule()).foregroundStyle(ink)
    }
    .buttonStyle(.plain)
  }
  func secondary(_ title: String, _ f: @escaping () -> Void) -> some View {
    Button(title, action: f).font(.subheadline.bold()).padding(.horizontal, 13).frame(minHeight: 44)
      .background(.white.opacity(0.12), in: Capsule()).buttonStyle(.plain)
  }
  var title: String {
    switch page {
    case .airplay: return "投屏到电视"
    case .setup: return lesson ? "挥拍入门" : training ? "自由练习" : "快速单打"
    case .lab: return "挥拍采集"
    case .sync: return "电视节拍校准"
    case .settings: return "偏好设置"
    default: return "握姿校准"
    }
  }
  var panel: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button {
          motion.stop()
          UIApplication.shared.isIdleTimerDisabled = false
          page = .home
        } label: {
          Label("球社", systemImage: "chevron.left")
        }
        Spacer()
        Text(title).bold()
      }
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          switch page {
          case .setup:
            Text(
              lesson ? "跟随提示完成四种回球" : training ? "无限供球 · 练习判断高低与落点" : "先得 7 分 · 平分领先 2 分 · 10 分封顶"
            )
            .font(.title3.bold())
            if !training {
              Picker("对手", selection: $difficulty) {
                Text("入门").tag(0)
                Text("标准").tag(1)
                Text("挑战").tag(2)
              }.pickerStyle(.segmented)
            }
            if training && !lesson {
              Picker("练习内容", selection: $drill) {
                ForEach(Drill.allCases, id: \.self) { Text($0.rawValue) }
              }.pickerStyle(.segmented)
            }
            HStack {
              Toggle("使用触屏挥拍", isOn: $touch).disabled(!motion.available)
              Toggle("看电视游玩", isOn: $useTV)
            }
            Text(touch ? "选择左、中、右落点，再点上挑、平抽或下挥。发球用上挑。" : "用打球的手握稳手机，留出一臂空间。校准和比赛保持同一握法，短挥即可。").font(.callout)
            HStack {
              action(touch ? "进入球场" : "开始校准", "arrow.right") {
                if touch {
                  startMatch()
                } else {
                  resuming = false
                  calibrate()
                }
              }
              secondary("投屏说明") { page = .airplay }
            }
          case .airplay:
            Text("iPhone 与电视连接同一 Wi-Fi。").font(.title3.bold())
            Text("打开 iPhone 控制中心 → 屏幕镜像 → 选择 Apple TV 或兼容电视。看到同一画面后返回球社。")
            Text("比赛在手机上运行。若电视上的球总是慢半拍，可在设置里调整击球补偿。")
            action("已连接电视", "tv") {
              useTV = true
              page = .setup
            }
            secondary("在手机上玩") {
              useTV = false
              page = .setup
            }
          case .calibration:
            Text(motion.cue).font(.title3.bold())
            ProgressView(value: motion.progress)
            Text(motion.status)
            HStack {
              action("进入球场", "play.fill") { enterAfterCalibration() }.disabled(!motion.ready)
              secondary("重新校准") { calibrate() }
              secondary("改用触屏") {
                touch = true
                motion.stop()
                enterAfterCalibration()
              }
            }
          case .settings:
            secondary("打开 Mac 联合采集"){page = .jointCapture}
            HStack {
              Toggle("左手操作", isOn: $left)
              Toggle("轻挥模式", isOn: $light)
            }
            DisclosureGroup("动作曲线实验") {
              Toggle("辅助判定（下次完整校准生效）", isOn: $curveAssist)
              Text("曲线版本 " + motion.curveVersion).font(.caption)
              if !motion.curveObservation.isEmpty {
                Text("最近曲线匹配：" + motion.curveObservation).font(.caption)
              }
            }
            HStack {
              Toggle("击球音效", isOn: $sound)
              Toggle("击球触感", isOn: $haptic)
            }
            Text("投屏击球补偿   \(Int(syncMS)) ms").monospacedDigit()
            Slider(value: $syncMS, in: 0...250, step: 10)
            secondary("测量投屏延迟") { page = .sync }
            Text("本机从 0 ms 开始。电视画面较晚时逐步增加，再到自由练习试打。").font(.footnote)
          case .sync:
            SyncView {
              syncMS = $0
              page = .settings
            }
          default: EmptyView()
          }
        }.frame(maxWidth: 650, alignment: .leading).padding(.vertical, 8).frame(maxWidth: .infinity)
      }
    }.padding(.horizontal, 24).padding(.vertical, 10)
  }
  var captureStudio: some View {
    VStack(spacing: 6) {
      if !motion.recording && motion.soloStep == nil && !motion.soloArmed {
        HStack {
          Button { motion.stop(); page = .home } label: { Label("球社", systemImage: "chevron.left") }
          Spacer()
          Picker("示范动作", selection: $trial) {
            ForEach(StandardStroke.trainingGroups, id: \.title) { group in
              Section(group.title) {
                ForEach(group.strokes) { Text($0.displayName).tag($0) }
              }
            }
          }.pickerStyle(.menu)
          Spacer()
          Picker("采集速度", selection: $captureSpeed) {
            ForEach(CaptureSpeed.recordingOptions) { Text($0.title).tag($0) }
          }.pickerStyle(.menu)
          Button(soloPreview == nil ? "握持示范" : "返回动作示范") { soloPreview = soloPreview == nil ? 0 : nil }
          Button { showLabOptions = true } label: { Label("采集设置与文件", systemImage: "slider.horizontal.3") }
        }.font(.subheadline.bold())
      }
      if let step=motion.soloStep {
        PositionDemonstration(step: step, left: labLeft, feedback: motion.status, phoneOnly: true)
          .id(step)
      } else if let step = soloPreview {
        PositionDemonstration(step: step, left: labLeft, phoneOnly: true).id(step)
        Button("下一姿势") { soloPreview = (step + 1) % 4 }
      } else {
      StrokeDemonstration(stroke: trial, left: labLeft,
        elapsed: motion.recording && guidedCapture ? motion.elapsed : nil, recording: motion.recording,
        speed: captureSpeed)
        .id(trial.rawValue + captureSpeed.rawValue)
      }
      HStack {
        if motion.recording {
          Label("正在采集", systemImage: "record.circle.fill")
            .foregroundStyle(accent)
          Text("\(captureSpeed.title) · \(Int(motion.elapsed)) 秒 · \(motion.samples) 帧").monospacedDigit()
        } else {
          if motion.soloStep == nil { Text(motion.available ? motion.status : "模拟器可预览动作").lineLimit(2) }
          if motion.interrupted { Button("重连传感器") { motion.calibrate(); motion.start() } }
          if motion.exportURL != nil { Button("复核与分享") { showLabOptions = true } }
        }
        Spacer()
        if motion.soloArmed { secondary("重做校准") { motion.cancelSolo() } }
        action(motion.soloStep != nil ? "取消校准" : motion.recording ? "确认结束并保存" : motion.soloArmed ? "确认开始采集" : "开始校准", motion.recording ? "stop.fill" : "record.circle") {
          if motion.soloStep != nil {motion.cancelSolo()}
          else if motion.recording { motion.finishRecord() }
          else if motion.soloArmed { motion.confirmRecordingStart() }
          else {
            soloPreview = nil
            reviewLabel = trial
            motion.beginRecord(trial.rawValue, hand: labLeft ? "L" : "R", participant: participant, guided: guidedCapture, speed: captureSpeed)
          }
        }.disabled(!motion.available || (!motion.recording && !motion.soloArmed && motion.soloStep == nil && (!motion.ready || !participant.contains { $0.isLetter || $0.isNumber })))
      }.font(.caption.bold())
    }.padding(.horizontal, 12).padding(.vertical, 4)
    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    .sheet(isPresented: $showLabOptions) {
      NavigationStack {
        Form {
          Section("录制") {
            Toggle("左手示范与采集", isOn: $labLeft)
            Toggle("跟随演示录制", isOn: $guidedCapture)
            TextField("匿名编号", text: $participant)
            Text(guidedCapture ? "可跟随演示。校准通过后确认开始，做完并回位后确认结束。" : "按自身节奏挥拍，做完后在本页确认结束。")
          }
          if let id = trial.lesson.1, let source = URL(string: "https://www.youtube.com/watch?v=" + id) {
            Section("教学参考") {
              Link("观看 BWF 原版教学 · " + trial.rawValue, destination: source)
            }
          }
          Section("记录与分享") {
            if !motion.recording, let raw = motion.exportURL {
              HStack {
                Picker("实际动作", selection: $reviewLabel) {
                  ForEach(StandardStroke.gameTraining + [.background]) { Text($0.displayName).tag($0) }
                }
                Button("确认标签") { motion.review(as: reviewLabel.rawValue) }
                ShareLink("分享本条 CSV", item: raw)
              }
              Text("自动检测到 \(motion.candidateCount) 个候选。确认标签会单独保存人工复核结果。").font(.caption)
            }
            if !motion.recording && !motion.archive.isEmpty {
              DisclosureGroup("已保存文件（\(motion.archive.count)）", isExpanded: $showArchive) {
                ShareLink(items: motion.archive) { Label("分享全部到电脑", systemImage: "square.and.arrow.up") }
                ForEach(motion.archive, id: \.self) { url in
                  ShareLink(item: url) { Text(url.lastPathComponent).font(.caption).lineLimit(2) }
                }
              }
            }
            if motion.archive.isEmpty { Text("完成录制后可在这里复核和分享文件。") }
          }
        }.navigationTitle("采集设置与文件").navigationBarTitleDisplayMode(.inline)
          .toolbar { Button("完成") { showLabOptions = false } }
      }.presentationDragIndicator(.visible)
    }
  }
  var matchHUD: some View {
    ZStack {
      if !touch {
        VStack {
          Spacer()
          Button {
            game.toggleNet()
          } label: {
            Color.clear.contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("预选下一拍放网")
          .frame(maxWidth: .infinity)
          .frame(height: 120)
        }
      }
      VStack {
        HStack(alignment: .top) {
          VStack(alignment: .leading) {
            Text(lesson ? "挥拍入门" : training ? "自由练习" : "晚风球社 · 单打").font(.caption.bold())
            if lesson {
              Text(game.lesson?.title ?? "四种回球已完成").font(.headline)
              ProgressView(
                value: Double(game.lessonIndex), total: Double(LessonStep.allCases.count)
              )
              .frame(width: 148)
            } else {
              Text("林澄  \(game.score[0])    周野  \(game.score[1])").font(.headline.monospacedDigit())
            }
          }.padding(9).background(ink.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
          Spacer()
          if !touch { Text(motion.status).font(.caption.bold()).padding(6).background(ink.opacity(0.85), in: Capsule()) }
          secondary("暂停") { pause() }
        }
        Spacer()
        HStack {
          Text(hudMessage).bold().padding(7).background(
            training && game.hitWindowOpen ? Color.teal : ink.opacity(0.85), in: Capsule())
          Spacer()
          if touch {
            HStack(spacing: 5) {
              Button(["左", "中", "右"][aim < 0 ? 0 : aim > 0 ? 2 : 1]) {
                aim = aim == 0 ? 0.85 : aim > 0 ? -0.85 : 0
              }
              ForEach(Stroke.allCases, id: \.self) { kind in
                Button(kind.rawValue) { hit(kind, aim: aim) }
              }
              Button("放网") { game.toggleNet() }
            }.buttonStyle(.borderedProminent).tint(ink.opacity(0.92))
          } else {
            secondary(game.armed ? "取消放网" : "预选放网") { game.toggleNet() }
          }
        }.environment(\.layoutDirection, left ? .rightToLeft : .leftToRight)
      }.padding(8)
      if game.phase == .countdown || resumeAt > 0 {
        Text(
          "\(max(1,Int(ceil(resumeAt>0 ? resumeAt-ProcessInfo.processInfo.systemUptime : game.deadline-game.now))))"
        ).font(.system(size: 70, weight: .heavy)).shadow(radius: 6)
      }
    }
  }
  var hudMessage: String {
    if game.armed { return "下一拍放网" }
    if training && game.hitWindowOpen && game.message == "准备接球" { return "现在挥拍" }
    return game.message
  }
  var pauseCard: some View {
    VStack(spacing: 14) {
      Text(motion.interrupted ? "运动采样中断" : "已暂停").font(.largeTitle.bold())
      if motion.interrupted { Text("继续比赛将重新连接传感器并确认握姿。") }
      HStack {
        action("继续比赛", "play.fill") { resume() }
        secondary("重发本球") {
          replayPoint()
          resume()
        }
        secondary("结束本局") { finish() }
      }
    }
  }
  var resultCard: some View {
    VStack(spacing: 12) {
      Text(
        game.lessonComplete
          ? "挥拍入门完成"
          : training
            ? "练习结束"
            : Rally.won(game.score) ? (game.score[0] > game.score[1] ? "你赢了" : "本场结束") : "本局已结束"
      ).font(.title.bold())
      Text("\(game.score[0])   :   \(game.score[1])").font(
        .system(size: 46, weight: .heavy, design: .rounded).monospacedDigit())
      Text("成功回球 \(game.returns) 次     最长回合 \(game.longest) 拍")
      HStack {
        action("再来一局", "arrow.clockwise") {
          if touch {
            startMatch()
          } else {
            resuming = false
            calibrate()
          }
        }
        secondary("返回球社") { page = .home }
      }
    }
  }
  func calibrate(keepExamples: Bool = false) {
    page = .calibration
    motion.stop()
    motion.light = light
    motion.calibrate(personal: true, keepExamples: keepExamples)
    motion.start()
  }
  func startMatch() {
    game = Rally()
    game.practice = training
    game.lessonEnabled = lesson
    game.drill = drill
    game.playerServes = !training
    game.difficulty = difficulty
    game.offset = useTV ? syncMS / 1000 : 0
    aim = 0
    resumeAt = 0
    lastTick = ProcessInfo.processInfo.systemUptime
    StudioSender.shared.event("court", at: ProcessInfo.processInfo.systemUptime)
    page = .court
    if touch { motion.stop() }
    UIApplication.shared.isIdleTimerDisabled = true
  }
  func replayPoint() { game.replayPoint() }
  func enterAfterCalibration() {
    if resuming {
      resuming = false
      resumeClock()
    } else {
      startMatch()
    }
  }
  func resume() {
    if !touch {
      resuming = true
      calibrate(keepExamples: true)
    } else {
      resumeClock()
    }
  }
  func resumeClock() {
    lastTick = ProcessInfo.processInfo.systemUptime
    resumeAt = lastTick + 2
    StudioSender.shared.event("court", at: ProcessInfo.processInfo.systemUptime)
    page = .court
    UIApplication.shared.isIdleTimerDisabled = true
  }
  func pause() {
    page = .pause
    motion.stop()
    UIApplication.shared.isIdleTimerDisabled = false
  }
  func finish() {
    page = .result
    best = max(best, game.longest)
    motion.stop()
    UIApplication.shared.isIdleTimerDisabled = false
  }
  func hit(_ kind: Stroke, aim: Double, age: Double = 0) {
    guard page == .court, resumeAt == 0 else { return }
    let before = game.feedback
    game.swing(kind, aim: aim, age: age)
    if game.feedback != before {
      feedback.play(
        game.lastShot == .smash || game.lastShot == .power ? "smash" : "tap", sound: sound,
        vibration: haptic)
    }
  }
  func tick() {
    guard page == .court, lifecycle == .active else { return }
    let t = ProcessInfo.processInfo.systemUptime
    let dt = max(0, min(0.08, t - lastTick))
    lastTick = t
    if resumeAt > 0 {
      if t >= resumeAt { resumeAt = 0 }
      return
    }
    let points = game.pointCount
    game.tick(dt)
    if game.pointCount != points { feedback.play("point", sound: sound, vibration: false) }
    if game.phase == .finished { finish() }
  }
}

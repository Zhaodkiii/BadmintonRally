import AVFoundation
import Combine
import SwiftUI

enum Page { case home, setup, airplay, court, pause, result, lab, settings, sync, jointCapture, motionTest, manualBatch }
struct ClubView: View {
  @ObservedObject private var studio = StudioSender.shared
  @StateObject private var motion = MotionInput()
  #if DEBUG
  @AppStorage("liveRallyDebug") private var liveRallyDebug = true
  @State private var liveCapture = LiveRallyBuffer()
  @State private var screenError: String?
  #endif
  @State private var contactInput = VolumeContactInput()
  @State private var contactEpoch = UUID()
  @State private var contactCount = 0
  @State private var contactReady = false
  @State private var contactHint = ""
  @State private var referenceGroup = UUID()
  @State private var page = Page.home
  @State private var game = Rally()
  @State private var gamesToWin = 1
  @State private var format = CourtFormat.singles
  @State private var lastServeReadout = ""
  @State private var repeatFeedback = ""
  @State private var validating = false
  @State private var validation = ServeValidation()
  @State private var showValidationTrials = false
  @State private var validationError = ""
  @State private var repeating = false
  @State private var serveTraining = ServeTraining.free
  @State private var targetLane = "自由"
  @State private var guidedServeTargets = true
  @State private var targetEffort = "自由"
  @State private var targetDepth = "自由"
  @State private var area = CollectionArea.serve
  @State private var receiveSide = "正手侧"
  @State private var reply = "自由回球"
  @State private var acrossAreas = false
  @State private var startingScene = CollectionScene.serve
  @State private var randomScenes = false
  @State private var sceneBlockSize = 10
  @State private var training = false
  @State private var lesson = false
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
  @State private var drill = Drill.mixed
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
        SpatialCourt(game: game, reduced: reduced, leftHanded: left).ignoresSafeArea()
        if page == .court {
          matchHUD
        } else {
          Color.black.opacity(0.65).ignoresSafeArea()
          if page == .pause { pauseCard } else { resultCard }
        }
      } else if page == .manualBatch {
        ManualBatchView(left: left) { page = .home }
      } else if page == .motionTest {
        MotionTestView(left: left, light: light, haptics: haptic, sound: sound) { page = .home }
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
      #if DEBUG
      if page == .court, let screenError {
        Text("比赛画面 · " + screenError).font(.caption).padding(7).background(.black.opacity(0.8), in: Capsule())
      }
      #endif
      if !studio.instruction.isEmpty {Text("采集 · " + studio.instruction).font(.headline).padding(7).background(.black.opacity(0.8),in:Capsule()).allowsHitTesting(false)}
    }
    .foregroundStyle(cream).tint(accent)
    .onReceive(clock) { _ in tick() }
    .onAppear {
      reconnectStudio()

    }
    .onChange(of: motion.interrupted) { _, interrupted in
      if interrupted && page == .court { pause() }
    }
    .onChange(of: lifecycle) { _, new in
      if new == .active { reconnectStudio() }
      if new == .background { StudioSender.shared.interrupt() }
      if new != .active {
        if page == .court { pause() }
        if page != .lab || new == .background { motion.stop() }
      } else if page == .lab && !motion.recording && motion.soloStep == nil && !motion.soloArmed {
        motion.calibrate()
        motion.start()
      }
    }
    .onDisappear {
      stopContactInput()
      motion.stop()
      UIApplication.shared.isIdleTimerDisabled = false
    }
  }
  private func reconnectStudio() {
    if let data = CaptureTrust.read("iphone-test-host"),
       let ticket = try? JSONDecoder().decode(NearbyPairing.Ticket.self, from: data) {
      studio.resumeDiagnosticSync(ticket)
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
          secondary("连续采集") { page = .manualBatch }
          secondary("场景采集") { setup(false); repeating = true }
          secondary("动作测试") { page = .motionTest }
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
    contactHint = ""
    validating = false
    repeating = false
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
    case .setup: return repeating ? "场景采集" : lesson ? "挥拍入门" : training ? "自由练习" : "快速单打"
    case .lab: return "挥拍采集"
    case .sync: return "电视节拍校准"
    case .settings: return "偏好设置"
    default: return "球社"
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
              repeating ? "重复同一场景，自由选择打法" : lesson ? "跟随提示完成四种回球" : training ? "无限供球 · 练习判断高低与落点" : "每局 21 分 · 20 平后领先 2 分 · 30 分封顶"
            )
            .font(.title3.bold())
            if repeating {
              action("验证动作识别", "checkmark.circle") {
                validating = true
                startMatch()
              }
              Picker("接球区域", selection: $area) {
                ForEach(CollectionArea.allCases, id: \.self) { Text($0.rawValue).tag($0) }
              }.pickerStyle(.segmented)
                .onChange(of: area) { _, value in
                  startingScene = value.scenes[0]
                  reply = "自由回球"
                }
              if area != .serve {
                Picker("采集方式", selection: $randomScenes) {
                  Text("固定来球").tag(false)
                  Text("分组随机").tag(true)
                }.pickerStyle(.segmented)
                if randomScenes { Toggle("跨网前、中场、后场随机", isOn: $acrossAreas) }
                Picker(randomScenes ? "起始来球" : "本组来球", selection: $startingScene) {
                  ForEach(area.scenes, id: \.self) { Text($0.rawValue).tag($0) }
                }.onChange(of: startingScene) { _, _ in reply = "自由回球" }
                if startingScene != .backhand || randomScenes {
                  Picker("来球侧", selection: $receiveSide) {
                    ForEach(["正手侧","反手侧","追身"], id: \.self) { Text($0) }
                  }.pickerStyle(.segmented)
                }
                if !randomScenes {
                  Picker("本组目标回法", selection: $reply) {
                    ForEach(["自由回球"] + startingScene.replies, id: \.self) { Text($0) }
                  }
                }
                Text("可尝试：" + startingScene.replies.joined(separator: "、")).font(.callout)
                Picker("目标方向", selection: $targetLane) {
                  ForEach(["自由","偏左","居中","偏右"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                Picker("目标深度", selection: $targetDepth) {
                  ForEach(["自由","前场","中场","后场"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
              } else {
                Picker("发球专项", selection: $serveTraining) {
                  ForEach(ServeTraining.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("逐球提示方向和力度（9 球循环）", isOn: $guidedServeTargets)
                if !guidedServeTargets {
                  Picker("预期力度", selection: $targetEffort) {
                    ForEach(["自由","轻","中","重"], id: \.self) { Text($0) }
                  }.pickerStyle(.segmented)
                }
                if !guidedServeTargets {
                  Picker("对角区内瞄准", selection: $targetLane) {
                  ForEach(["自由","偏左","居中","偏右"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                }
                Picker("预期深度", selection: $targetDepth) {
                  ForEach(["自由","前场","中场","后场"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
              }
              if area != .serve && randomScenes {
                Stepper("每组完成 \(sceneBlockSize) 球后换场景", value: $sceneBlockSize, in: 1...100)
              }
              Text(startingScene == .serve ? "按所选专项重复发球。左右以玩家面向球网为准，预期落点用于训练标注。" : "同组的来球和站位一致，每球可自由选择回法。")
              #if DEBUG
              Text(!liveRallyDebug ? "比赛诊断已关闭，可在设置中开启" : studio.linked ? "Mac 已连接 · 将记录本组数据" : "Mac 未连接 · 请打开 RallyCapture 并连接 iPhone")
              #endif
            }
            if !training && !repeating {
              Picker("局数", selection: $gamesToWin) {
                Text("一局定胜负").tag(1)
                Text("三局两胜").tag(2)
              }.pickerStyle(.segmented)
              Picker("场地", selection: $format) {
                ForEach(CourtFormat.allCases, id: \.self) { Text($0.rawValue) }
              }.pickerStyle(.segmented)
              Text(format == .singles ? "偶右奇左，斜线发球。单打用内侧边线和底线。" :
                "自动切换到本方发接球员。双打用外侧边线和后发球线，发球方得分才换区。")
              Text("低位短引，再向前轻送、自然减速发短球；向前上方随挥发后场。").font(.callout)
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
              Toggle("看电视游玩", isOn: $useTV)
            }
            Text("挥拍时按音量＋或−确认击球。力度和挥向决定球路，静止按键会轻击。比赛使用后置相机，松键保存参考图。").font(.callout)
            if !contactHint.isEmpty { Text(contactHint).font(.caption) }
            HStack {
              action("进入球场", "arrow.right") { validating = false; startMatch() }
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
          case .settings:
            secondary("打开 Mac 联合采集"){page = .jointCapture}
            #if DEBUG
            Toggle("实时发送比赛诊断到测试 Mac", isOn: $liveRallyDebug)
            if liveRallyDebug {
              Text("首次请在动作测试配对 RallyCapture。下局开始发送。").font(.footnote)
            }
            #endif
            HStack {
              Toggle("左手操作", isOn: $left)
              Toggle("动作测试轻挥模式", isOn: $light)
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
      if !validating { VStack {
          Spacer()
          Button {
            toggleNet()
          } label: {
            Color.clear.contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("预选下一拍放网")
          .frame(maxWidth: .infinity)
          .frame(height: 120)
      } }
      VStack {
        HStack(alignment: .top) {
          VStack(alignment: .leading) {
            Text(validating ? "发球识别验证" : repeating ? "场景采集" : lesson ? "挥拍入门" : training ? "自由练习" : "晚风球社 · 单打").font(.caption.bold())
            Text(contactReady ? "按 ＋ 或 − 击球 · 已按 \(contactCount) 次" : contactHint).font(.caption.monospacedDigit())
            if validating {
              Text("第 \(game.repetition) 球 · 自由发球")
              if !validationError.isEmpty { Text(validationError) }
            } else if repeating {
              Text("\(game.collectionScene?.rawValue ?? "") · 第 \(game.repetition) 球")
              if game.collectionScene == .serve { Text("\(game.serveTraining.rawValue) · 方向 \(game.serveGoal.lane) · 力度 \(game.serveGoal.effort) · 深度 \(game.targetDepth)").font(.caption) }
              if let scene = game.collectionScene, scene != .serve {
                Text("\(game.trialSide) · \(game.trialReply) · \(game.targetLane)／\(game.targetDepth)").font(.caption)
              }
              if game.sceneBlockSize > 0 { Text("第 \(game.sceneGroup) 组 · 已完成 \(game.completedInGroup)/\(game.sceneBlockSize)").font(.caption) }
              if !repeatFeedback.isEmpty { Text(repeatFeedback).font(.caption) }
              #if DEBUG
              Text(liveCapture.active && studio.linked ? "Mac 已连接" : "Mac 未实时接收").font(.caption)
              #endif
            } else if lesson {
              Text(game.lesson?.title ?? "四种回球已完成").font(.headline)
              ProgressView(
                value: Double(game.lessonIndex), total: Double(LessonStep.allCases.count)
              )
              .frame(width: 148)
            } else {
              if game.gamesToWin > 1 { Text("局分  \(game.gamesWon[0]) – \(game.gamesWon[1])").font(.caption) }
              Text("林澄  \(game.score[0])    周野  \(game.score[1])").font(.headline.monospacedDigit())
            }
          }.padding(9).background(ink.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
          Spacer()
          if repeating && !validating && game.phase == .serve && game.playerServes { secondary("重试本球") { replayPoint() } }
          if !lastServeReadout.isEmpty {
            Text(lastServeReadout).font(.headline).padding(8)
              .background(ink.opacity(0.88), in: Capsule()).allowsHitTesting(false)
          }
          secondary("暂停") { pause() }
        }
        Spacer()
        HStack {
          Text(hudMessage).bold().padding(7).background(
            game.hitWindowOpen ? Color.teal : ink.opacity(0.85), in: Capsule())
          Spacer()
          if !validating { secondary(game.armed ? "取消放网" : "预选放网") { toggleNet() } }
        }.environment(\.layoutDirection, left ? .rightToLeft : .leftToRight)
      }.padding(8)

      if game.phase == .countdown || resumeAt > 0 {
        Text(
          "\(max(1,Int(ceil(resumeAt>0 ? resumeAt-ProcessInfo.processInfo.systemUptime : game.deadline-game.now))))"
        ).font(.system(size: 70, weight: .heavy)).shadow(radius: 6)
      }
    }
  }
  private func saveValidation() {
    do { try validation.save(); validationError = "" }
    catch { validationError = "验证记录保存失败 · " + error.localizedDescription }
  }

  private var validationResults: some View {
    VStack(spacing: 4) {
      Text("发球识别验证结果").font(.headline)
      ForEach(ServeValidation.strokes + ["动作待定"], id: \.self) { stroke in
        Text("\(stroke) · \(validation.trials.filter { $0.prediction == stroke }.count) 球")
      }
      Button("逐球记录 · 共 \(validation.trials.count) 球") { showValidationTrials = true }
        .sheet(isPresented: $showValidationTrials) {
          NavigationStack {
            List(validation.trials, id: \.number) { trial in
              VStack(alignment: .leading) {
                Text("第 \(trial.number) 球 · \(trial.prediction)")
                Text(trial.outcome ?? "本球未结束").font(.caption)
              }
            }.navigationTitle("发球验证逐球记录")
              .toolbar { Button("完成") { showValidationTrials = false } }
          }
        }
      if !validationError.isEmpty { Text(validationError) }
    }
  }

  var hudMessage: String {
    if game.waitingForDescent { return "高球 · 等下降" }
    if game.armed { return "下一拍放网" }
    if game.hitWindowOpen, let ball = game.flight?.at(game.now), ball.y < 0.75 {
      if ball.z > Flight.netHeight + 0.045 { return "网前高点 · 下压或轻托" }
      if ball.z < Flight.netHeight - 0.045 { return "低于网带 · 向上挑球" }
      return "网带附近 · 向前推球"
    }
    if game.hitWindowOpen { return "现在按键击球" }
    if game.preparingToReceive { return "准备挥拍" }
    return game.message
  }
  var pauseCard: some View {
    VStack(spacing: 14) {
      Text(motion.interrupted ? "运动采样中断" : "已暂停").font(.largeTitle.bold())
      if motion.interrupted { Text("继续比赛将重新连接传感器。") }
      HStack {
        action("继续比赛", "play.fill") { resume() }
        if !validating { secondary("重发本球") {
          replayPoint()
          resume()
        } }
        secondary("结束本局") { finish() }
      }
    }
  }
  var resultCard: some View {
    VStack(spacing: 12) {
      if validating { validationResults } else if repeating {
        Text("场景采集结束").font(.title.bold())
        Text("已完成 \(game.pointCount) 球")
      } else {
      Text(
        game.lessonComplete
          ? "挥拍入门完成"
          : training
            ? "练习结束"
            : Rally.won(game.score) ? (game.score[0] > game.score[1] ? "你赢了" : "本场结束") : "本局已结束"
      ).font(.title.bold())
      if game.gamesToWin > 1 { Text("局分  \(game.gamesWon[0]) – \(game.gamesWon[1])") }
      Text("\(game.score[0])   :   \(game.score[1])").font(
        .system(size: 46, weight: .heavy, design: .rounded).monospacedDigit())
      Text("成功回球 \(game.returns) 次     最长回合 \(game.longest) 拍")
      }
      HStack {
        action("再来一局", "arrow.clockwise") { startMatch() }
        secondary("返回球社") { page = .home }
      }
    }
  }
  func startMatch() {
    guard #available(iOS 17.2, *) else { contactHint = "音量键击球需要 iOS 17.2 或更高版本"; return }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .notDetermined:
      let origin = page
      AVCaptureDevice.requestAccess(for: .video) { _ in
        DispatchQueue.main.async { if page == origin { startMatch() } }
      }
      return
    case .authorized: break
    default: contactHint = "请在系统设置允许相机，以启用实体按键击球"; return
    }
    if validating && left { contactHint = "验证使用右手模型，请先在设置切换为右手操作"; return }
    validation = ServeValidation()
    validationError = ""
    referenceGroup = UUID()
    repeatFeedback = ""
    lastServeReadout = ""
    game = Rally()
    game.practice = training
    game.lessonEnabled = lesson
    game.drill = drill
    game.playerServes = !training
    game.gamesToWin = training ? 1 : gamesToWin
    game.format = training ? .singles : format
    if repeating {
      game.format = .singles
      game.gamesToWin = 1
      game.serveTraining = serveTraining
      game.targetLane = targetLane
      game.targetDepth = targetDepth
      game.guidedServeTargets = guidedServeTargets
      game.targetEffort = targetEffort
      game.collectionScene = startingScene
      game.receiveSide = receiveSide
      game.leftHanded = left
      game.intendedReply = randomScenes ? "自由回球" : reply
      game.randomAcrossAreas = acrossAreas
      game.sceneBlockSize = startingScene != .serve && randomScenes ? sceneBlockSize : 0
    }
    if validating {
      game.collectionScene = .serve
      game.serveTraining = .free
      game.sceneBlockSize = 0
      game.guidedServeTargets = false
      game.targetLane = "自由"
      game.targetDepth = "自由"
      game.targetEffort = "自由"
    }
    if !training { game.readyToServe() }
    motion.startButtonInput()
    motion.serving = game.phase == .serve && game.playerServes
    game.difficulty = difficulty
    game.offset = useTV ? syncMS / 1000 : 0
    resumeAt = 0
    lastTick = ProcessInfo.processInfo.systemUptime
    StudioSender.shared.event("court", at: ProcessInfo.processInfo.systemUptime)
    #if DEBUG
    prepareLiveCapture()
    if liveCapture.active { referenceGroup = liveCapture.match }
    flushLiveCapture(event: "start")
    #endif
    page = .court
    contactCount = 0
    startContactInput()
    UIApplication.shared.isIdleTimerDisabled = true
  }
  func toggleNet() {
    game.toggleNet()
    #if DEBUG
    flushLiveCapture(event: game.armed ? "netArmed" : "netDisarmed")
    #endif
  }

  func replayPoint() {
    game.replayPoint()
    #if DEBUG
    flushLiveCapture(event: "replayPoint")
    #endif
  }
  func resume() {
    lastTick = ProcessInfo.processInfo.systemUptime
    resumeAt = 0
    motion.startButtonInput()
    motion.serving = game.phase == .serve && game.playerServes
    StudioSender.shared.event("court", at: ProcessInfo.processInfo.systemUptime)
    page = .court
    startContactInput()
    #if DEBUG
    flushLiveCapture(event: "resume")
    #endif
    UIApplication.shared.isIdleTimerDisabled = true
  }
  func pause() {
    stopContactInput()
    #if DEBUG
    if liveCapture.active { liveCapture.screen.update(nil) }
    flushLiveCapture(event: "pause")
    #endif
    page = .pause
    motion.stop()
    UIApplication.shared.isIdleTimerDisabled = false
  }
  func finish() {
    stopContactInput()
    #if DEBUG
    if liveCapture.active { liveCapture.screen.update(nil) }
    flushLiveCapture(event: "finish")
    liveCapture.active = false
    #endif
    page = .result
    if !repeating { best = max(best, game.longest) }
    motion.stop()
    UIApplication.shared.isIdleTimerDisabled = false
  }
  private func confirmContact(_ sample: ButtonSwing.Hit, time: Double) {
    let kind = sample.stroke, aim = sample.aim, impact = sample.impact
    let before = game.feedback
    let isServe = game.phase == .serve && game.playerServes
    let incoming = game.flight
    let inReach = game.hitWindowOpen
    let decision = game.swing(kind, aim: aim, impact: impact, confirmedByButton: true)
    if validating && isServe && decision == .accepted {
      validation.trials.append(.init(number: game.repetition, contactTime: time,
        prediction: sample.recognizedServe ?? "动作待定"))
      saveValidation()
    }
    if isServe && decision == .accepted {
      lastServeReadout = "本次发球 · " + (sample.recognizedServe ?? "动作待定")
    } else if decision == .accepted {
      lastServeReadout = ""
    }
    if repeating { repeatFeedback = "第 \(game.repetition) 球 · " + kind.rawValue + " · " + (decision == .accepted ? game.lastShot.rawValue : game.message) }
    #if DEBUG
    if liveCapture.active {
      let now = ProcessInfo.processInfo.systemUptime
      if isServe && decision == .accepted {
        liveCapture.add(.init(time: now, kind: "serveRecognition", text: sample.recognizedServe ?? "动作待定",
          peakTime: time, gameTime: game.now))
      }
      do {
        let detail = String(format: "%@ · 力度 %.4f · 动力 %.4f · 幅度 %.4f · 上下 %.4f · 左右 %.4f", impact.label ?? "按键挥拍", impact.strength, impact.power, impact.sweep, impact.verticalSweep, aim)
        liveCapture.add(.init(time: now, kind: "impact", text: detail + (impact.approachLoad.map { String(format: " · 击球前轴向加速度 %+.3f g", $0) } ?? ""), peakTime: sample.peakTime, gameTime: game.now))
      }
      if decision == .accepted, let flight = game.flight, !flight.incoming {
        if let incoming, incoming.incoming, let scene = game.collectionScene, scene != .serve {
          let at = game.judgedContactTime ?? game.now
          let ball = incoming.at(at)
          let t0 = max(incoming.start, at - 0.005)
          let t1 = min(incoming.start + incoming.duration, at + 0.005)
          let a = incoming.at(t0), b = incoming.at(t1)
          let dt = max(0.000001, t1-t0)
          let velocity = t1 > t0 ? [(b.x-a.x)*3.05/dt,(b.y-a.y)*13.4/dt,(b.z-a.z)*1.524/Flight.netHeight/dt] : [0,0,0]
          func snapshot(_ f: Flight) -> LiveRallyTelemetry.Flight {
            .init(shot: f.shot.rawValue, incoming: f.incoming, start: f.start, duration: f.duration,
                  arc: f.arc, from: f.from.coordinates, to: f.to.coordinates, position: f.at(at).coordinates)
          }
          let record = LiveRallyTelemetry.Contact(trial: game.repetition, scenario: scene.rawValue,
            intendedReply: game.trialReply, targetLane: game.targetLane, targetDepth: game.targetDepth,
            incoming: snapshot(incoming), ball: ball.coordinates, player: [game.playerX,game.playerY],
            incomingVelocity: velocity, area: ball.contactArea,
            heightAboveNetMeters: (ball.z-Flight.netHeight)*1.524/Flight.netHeight,
            strength: impact.strength, vertical: impact.verticalSweep, lateral: aim,
            beforeNet: ball.y < 0.5, outsideReach: !inReach, outgoing: snapshot(flight),
            observedReply: game.returnDescription(incoming: incoming, outgoing: flight),
            power: impact.power, sweep: impact.sweep, braking: impact.braking,
            onBackhandSide: (ball.x - game.playerX) * (game.leftHanded ? -1 : 1) < 0,
            overheadByPosition: flight.overheadFromBackhandCorner, estimatedBackhand: flight.probableBackhand,
            predictedNetHit: flight.netCollision != nil)
          liveCapture.add(.init(time: time, kind: "receiveContact", text: ball.contactArea,
                                gameTime: at, contact: record))
        }
        let path = String(format: "%@ · 击球高度 %.3f · 目标深度 %.4f · 横向 %.4f · %@",
                          game.message, flight.from.z, flight.to.y, flight.to.x,
                          flight.netCollision == nil ? "预计过网" : "预计下网")
        liveCapture.add(.init(time: now, kind: "trajectory", text: path, gameTime: game.now))
      }
      liveCapture.add(.init(time: now, kind: "judgment", text: decision.rawValue, aim: aim,
        peakTime: time, gameTime: game.now, judgedAt: game.judgedContactTime,
        accepted: decision == .accepted,
        candidateGame: kind.rawValue))
      if repeating && decision == .accepted { flushLiveCapture(event: "contact") }
    }
    #endif
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
    guard contactReady else { return }
    let previousPhase = game.phase
    let previousFlight = game.flight?.start
    let points = game.pointCount
    game.tick(dt)
    if validating && previousPhase != .point && game.phase == .point, let i = validation.trials.indices.last {
      validation.trials[i].outcome = game.message
      saveValidation()
    }
    motion.serving = game.phase == .serve && game.playerServes
    motion.receiving = game.hitWindowOpen
    if game.pointCount != points { feedback.play("point", sound: sound, vibration: false) }
    #if DEBUG
    if liveCapture.active {
      liveCapture.screen.update(studio.linked ? liveCapture.match : nil)
      let ball = game.flight?.at(game.now)
      liveCapture.simulation.append(.init(time: t, gameTime: game.now, delta: dt,
        playerX: game.playerX, playerY: game.playerY, opponentX: game.opponentX, opponentY: game.opponentY,
        ball: ball.map { [$0.x, $0.y, $0.z] }))
    }
    let transition = points != game.pointCount ? "point" :
      previousPhase != game.phase ? "phase" : previousFlight != game.flight?.start ? "flight" : nil
    flushLiveCapture(event: transition)
    #endif
    if game.phase == .finished { finish() }
  }

  private func startContactInput() {
    let epoch = UUID()
    contactEpoch = epoch
    contactInput.onReady = { ready in
      contactReady = ready
      if ready { lastTick = ProcessInfo.processInfo.systemUptime }
    }
    contactInput.onHint = { contactHint = $0 }
    let folder = ManualBatch.folder.deletingLastPathComponent()
      .appendingPathComponent("比赛击球参考图").appendingPathComponent(referenceGroup.uuidString)
    contactInput.start(folder: folder) { time, button, photo in
      guard contactEpoch == epoch, page == .court else { return }
      if validating && game.phase != .serve { return }
      contactCount += 1
      tick()
      guard page == .court else { return }
      #if DEBUG
      if liveCapture.active {
        liveCapture.add(.init(time: time, kind: "manualContact", text: button, gameTime: game.now))
        liveCapture.add(.init(time: time, kind: "referencePhotoRequested", text: photo, gameTime: game.now))
      }
      #endif
      confirmContact(motion.buttonHit(time, left: left, serving: game.phase == .serve && game.playerServes), time: time)
    }
  }

  private func stopContactInput() {
    contactEpoch = UUID()
    contactInput.stop()
    contactInput.onReady = nil
    contactInput.onHint = nil
  }

  #if DEBUG
  private func prepareLiveCapture() {
    liveCapture.screen.update(nil)
    liveCapture.screen.error = { screenError = $0 }
    liveCapture.reset()
    motion.onTestFrame = nil
    motion.onTestEvent = nil
    guard liveRallyDebug, let data = CaptureTrust.read("iphone-test-host"),
      let ticket = try? JSONDecoder().decode(NearbyPairing.Ticket.self, from: data)
    else { return }
    StudioSender.shared.resumeDiagnosticSync(ticket)
    liveCapture.active = true
    let buffer = liveCapture
    motion.onTestFrame = { frame in
      guard buffer.active else { return }
      buffer.add(MotionRow(armed: frame.armed, tracking: frame.tracking, trigger: frame.trigger,
        gripSimilarity: frame.gripSimilarity, t: frame.time,
        v: frame.rotation + frame.acceleration + frame.gravity + frame.quaternion))
    }
    motion.onTestEvent = { event, stroke, _ in
      guard buffer.active, ["candidate", "shadow"].contains(event.kind) else { return }
      buffer.add(.init(time: event.time, kind: event.kind, text: event.text,
        recognizedAt: event.outputTime, candidateGame: stroke?.rawValue,
        curve: event.curve, curveScore: event.score, curveMargin: event.margin))
    }
  }

  private func flushLiveCapture(event: String? = nil) {
    guard liveCapture.active else { return }
    let t = ProcessInfo.processInfo.systemUptime
    if let event { liveCapture.add(.init(time: t, kind: "lifecycle", text: event)) }
    guard event != nil || t - liveCapture.sentAt >= 0.10 else { return }
    let flight = game.flight.map { flight in
      let ball = flight.at(game.now)
      return LiveRallyTelemetry.Flight(shot: flight.shot.rawValue, incoming: flight.incoming, start: flight.start,
        duration: flight.duration, arc: flight.arc, from: [flight.from.x, flight.from.y, flight.from.z],
        to: [flight.to.x, flight.to.y, flight.to.z], position: [ball.x, ball.y, ball.z])
    }
    let state = LiveRallyTelemetry.State(gameTime: game.now, phase: String(describing: game.phase),
      score: game.score, playerX: game.playerX, playerY: game.playerY,
      opponentX: game.opponentX, opponentY: game.opponentY, flight: flight,
      hitWindowOpen: game.hitWindowOpen, displayOffset: game.offset, message: hudMessage,
      input: "volumeButton", mode: validating ? "识别验证/我方发球/\(game.repetition)/\(validation.id)/\(validation.model)" : game.collectionMode ?? (lesson ? "lesson" : training ? "practice" : "match"),
      difficulty: game.difficulty, leftHand: left, lightSwing: light, curveVersion: motion.curveVersion)
    if repeating, event == "point", let end = game.landing {
      let result = String(format: "%@ · %@ · x %.5f · y %.5f · z %.5f",
                          state.mode, game.message, end.x, end.y, end.z)
      liveCapture.add(.init(time: t, kind: "trialOutcome", text: result, gameTime: game.now))
    }
    if repeating, event == "phase", flight?.incoming == true {
      liveCapture.add(.init(time: t, kind: "incomingFeed", text: state.mode, gameTime: game.now))
    }
    if repeating, event == "start" || (event == "phase" && game.phase == .serve) || event == "point" || event == "replayPoint" || event == "finish" {
      liveCapture.add(.init(time: t, kind: "repeatTrial", text: state.mode + "/" + (event ?? ""),
                            gameTime: game.now))
    }
    if event == "start" || event == "point" || (event == "phase" && game.phase == .serve) {
      liveCapture.add(.init(time: t, kind: "rules", text: "\(game.format.rawValue) · 局分 \(game.gamesWon) · \(game.servicePrompt)", gameTime: game.now))
    }
    StudioSender.shared.sendLiveRally(liveCapture.take(at: t, state: state))
  }
  #endif

}

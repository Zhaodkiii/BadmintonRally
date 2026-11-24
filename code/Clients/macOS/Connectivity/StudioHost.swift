import AVFoundation
import Network
import SwiftUI

final class StudioHost: ObservableObject {
  let serviceName: String = {
    let defaults = UserDefaults.standard
    if let name = defaults.string(forKey: "captureServiceName") { return name }
    let name = "羽球采集 " + String(Host.current().localizedName.orMac.prefix(12)) + " " + UUID().uuidString.prefix(4)
    defaults.set(name, forKey: "captureServiceName")
    return name
  }()
  let camera = CameraRecorder()
  let secret: String = {
    if let data = CaptureTrust.read("mac-host"), let value = String(data: data, encoding: .utf8) {
      return value
    }
    let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    let value = String((0..<24).map { _ in alphabet.randomElement()! })
    CaptureTrust.save(Data(value.utf8), as: "mac-host")
    return value
  }()
  let diagnosticDirectory = URL.applicationSupportDirectory
    .appendingPathComponent("RallyCapture/动作测试", isDirectory: true)
  @Published private(set) var diagnosticRecords: [SavedDiagnostic] = []
  @Published private(set) var diagnosticMessage = "等待 iPhone 测试数据"
  private let diagnosticInbox = DiagnosticInbox()
  let liveDirectory = URL.applicationSupportDirectory
    .appendingPathComponent("RallyCapture/比赛实时诊断", isDirectory: true)
  @Published private(set) var liveStatus = "等待比赛数据"
  @Published private(set) var liveFile: URL?
  @Published private(set) var courtVisible = false
  @Published private(set) var courtFPS = 0
  private var previewFrameCount = 0
  private var previewMeasuredAt = 0.0
  let courtDisplay = AVSampleBufferDisplayLayer()
  private var videoFormat: CMVideoFormatDescription?
  private var firstVideoTime = 0.0
  private var priorVideoTime = -Double.infinity
  private var previewNeedsKey = true
  @Published private(set) var matchCameraStatus = ""
  private var courtID: UUID?, segment: URL?, movie: CourtMovie?
  private var automaticCamera = false
  private var movieFailed = false
  private var lastCourtFrame = 0.0
  private var clockFile: FileHandle?

  private func closeCourt() {
    guard courtID != nil, let folder = segment else { return }
    movie?.finish { error in if let error { self.say("游戏录像保存失败 · " + error) } }
    movie = nil
    movieFailed = false
    try? clockFile?.close()
    clockFile = nil
    camera.stop { error in
      if let error {
        try? Data(error.utf8).write(to: folder.appendingPathComponent("camera_error.txt"))
        self.say("比赛摄像头 · " + error)
      }
    }
    if automaticCamera { camera.stopPreviewIfIdle() }
    automaticCamera = false
    segment = nil
    courtID = nil
    videoFormat = nil
    priorVideoTime = -.infinity
    ui {
      self.courtVisible = false
      self.courtFPS = 0
      self.previewFrameCount = 0
      self.previewMeasuredAt = 0
      self.previewNeedsKey = true
      self.courtDisplay.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
  }

  private func receiveCourt(_ frame: CourtVideoFrame, via link: CaptureWire?) throws {
    let id = frame.match
    let time = frame.time
    defer { link?.send(.courtFrameAck(id, time)) }
    guard identity != nil, archive == nil, time.isFinite, time > 0, time < 1e9 else { return }
    let received = Self.now
    if !frame.parameters.isEmpty {
      guard let format = frame.format() else { return }
      if courtID != id || videoFormat != format { closeCourt() }
      videoFormat = format
    }
    guard let format = videoFormat, time > priorVideoTime else { return }
    if courtID != id {
      guard !frame.parameters.isEmpty else { return }
      firstVideoTime = time
      let root = selectedRoot?.appendingPathComponent("比赛实时诊断") ?? liveDirectory
      let match = root.appendingPathComponent(id.uuidString)
      let folder = match.appendingPathComponent("视频").appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let clocks = folder.appendingPathComponent("clocks.jsonl")
      try Data().write(to: clocks)
      clockFile = try FileHandle(forWritingTo: clocks)
      for point in clockHistory { try recordCourtClock(point) }
      segment = folder
      courtID = id
      camera.arm(folder, trackWrist: false)
      let devices = CameraRecorder.cameras
      let selected = UserDefaults.standard.string(forKey: "courtCamera")
      let cameraID = devices.first(where: { $0.uniqueID == selected })?.uniqueID ?? devices.first?.uniqueID ?? ""
      let needsConfiguration = !camera.session.isRunning || !camera.session.inputs.contains {
        ($0 as? AVCaptureDeviceInput)?.device.uniqueID == cameraID
      }
      automaticCamera = !camera.session.isRunning
      ui {
        self.liveFile = match
        self.matchCameraStatus = self.camera.session.isRunning ? "摄像头录制中" : "正在开启摄像头"
      }
      if needsConfiguration {
        camera.configure(id: cameraID) { error in
          self.io.async {
            guard self.segment == folder else {
              if self.archive == nil && self.courtID == nil { self.camera.stopPreviewIfIdle() }
              return
            }
            self.ui { self.matchCameraStatus = error ?? "摄像头录制中" }
            if let error { try? Data(error.utf8).write(to: folder.appendingPathComponent("camera_error.txt")) }
          }
        }
      }
    }
    guard let sample = frame.sample(format: format, elapsed: time - firstVideoTime) else { return }
    priorVideoTime = time
    lastCourtFrame = received
    ui {
      let renderer = self.courtDisplay.sampleBufferRenderer
      if renderer.requiresFlushToResumeDecoding {
        renderer.flush()
        self.previewNeedsKey = true
      }
      if !renderer.isReadyForMoreMediaData {
        self.previewNeedsKey = true
        return
      }
      guard !self.previewNeedsKey || !frame.parameters.isEmpty else { return }
      self.previewNeedsKey = false
      if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
      }
      renderer.enqueue(sample)
      if self.previewMeasuredAt == 0 { self.previewMeasuredAt = received }
      self.previewFrameCount += 1
      let interval = received - self.previewMeasuredAt
      if interval >= 1 {
        self.courtFPS = Int((Double(self.previewFrameCount) / interval).rounded())
        self.previewFrameCount = 0
        self.previewMeasuredAt = received
      }
      if !self.courtVisible { self.courtVisible = true }
    }
    if !movieFailed, let segment {
      do {
        if movie == nil { movie = try CourtMovie(folder: segment, format: format) }
        if let recordingSample = frame.sample(format: format, elapsed: time - firstVideoTime) {
          try movie?.append(recordingSample, frame: frame, received: received)
        }
      } catch {
        movieFailed = true
        say("游戏录像写入失败 · " + error.localizedDescription)
      }
    }
  }

  private func recordCourtClock(_ point: ClockPoint) throws {
    guard let clockFile else { return }
    var row = try JSONEncoder().encode(point)
    row.append(10)
    try clockFile.write(contentsOf: row)
  }
  private var liveMatch: UUID?
  private var liveSequence = -1
  private var liveGaps = 0
  private var liveFrameCount = 0

  private func receiveLive(_ batch: LiveRallyTelemetry) throws {
    guard identity != nil, (0...150).contains(batch.frames.count), batch.events.count <= 100,
          batch.sequence >= 0, batch.frames.allSatisfy({ $0.v.count == 13 }) else { return }
    let root = selectedRoot?.appendingPathComponent("比赛实时诊断", isDirectory: true) ?? liveDirectory
    let folder = root.appendingPathComponent(batch.match.uuidString, isDirectory: true)
    let packets = folder.appendingPathComponent("batches", isDirectory: true)
    try FileManager.default.createDirectory(at: packets, withIntermediateDirectories: true)
    let url = packets.appendingPathComponent(String(format: "%012d.json", batch.sequence))
    if FileManager.default.fileExists(atPath: url.path) {
      wire?.send(.liveRallyAck(batch.match, batch.sequence))
      return
    }
    try JSONEncoder().encode(batch).write(to: url, options: .atomic)
    if batch.events.contains(where: { $0.kind == "lifecycle" && $0.text == "finish" }),
       let script = Bundle.main.url(forResource: "export_live_rally", withExtension: "py") {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [script.path, folder.path, folder.appendingPathComponent("分析").path]
      process.terminationHandler = { [weak self] task in
        if task.terminationStatus != 0 {
          self?.ui { self?.message = "比赛原始数据已保存，分析表导出失败" }
        }
      }
      do { try process.run() }
      catch { say("比赛原始数据已保存，分析表导出失败 · " + error.localizedDescription) }
    }
    wire?.send(.liveRallyAck(batch.match, batch.sequence))
    if batch.match != liveMatch {
      liveMatch = batch.match
      liveSequence = -1
      liveGaps = 0
      liveFrameCount = 0
    }
    liveGaps += max(0, batch.sequence - liveSequence - 1)
    liveSequence = batch.sequence
    liveFrameCount += batch.frames.count
    let message = "\(batch.state.mode) · \(batch.state.score.map(String.init).joined(separator: "–")) · \(liveFrameCount) 帧 · 缺 \(liveGaps) 批"
    ui {
      self.liveStatus = message
      self.liveFile = folder
    }
  }

  func loadDiagnostics() {
    io.async {
      let urls = (try? FileManager.default.contentsOfDirectory(
        at: self.diagnosticDirectory, includingPropertiesForKeys: nil)) ?? []
      let rows = urls.filter { $0.pathExtension == "json" }.compactMap { url in
        try? SavedDiagnostic.read(Data(contentsOf: url))
      }.sorted { $0.started > $1.started }
      self.ui { self.diagnosticRecords = rows }
    }
  }
  @Published var message = "选择目录、连接手机并开启预览"
  @Published var root: URL?
  @Published private(set) var guide = TrialPanel()
  @Published var participant = "P01" { didSet { updateInputs() } }
  @Published var hand = "右手" { didSet { updateInputs() } }
  @Published var grip = "自然握持" { didSet { updateInputs() } }
  private var plan = TrialPanel(), baseline: PositionRecord?, nextAfter = 0.0
  private var wLeft: WristObservation?, wRight: WristObservation?
  private var beganAt: Double?
  private var wristHistory: [WristObservation] = []
  private var lastFeedback = -Double.infinity
  @Published var online = false { didSet { updateInputs() } }
  @Published var cameraReady = false { didSet { updateInputs() } }
  @Published var busy = false
  @Published var listening = false
  @Published var count = 0
  @Published var videoReady = false
  @Published var latest: URL?
  @Published var rate = 0.0
  private let io = DispatchQueue(label: "rally.capture.host")
  private var videoWire: CaptureWire?, candidateVideoWire: CaptureWire?
  private var videoToken: UUID?

  private func acceptVideo(_ connection: NWConnection) {
    guard identity != nil, let token = videoToken, candidateVideoWire == nil else {
      connection.cancel()
      return
    }
    let link = CaptureWire(connection, queue: io)
    candidateVideoWire = link
    link.state = { [weak self, weak link] ready in
      guard let self, let link, !ready else { return }
      if self.candidateVideoWire === link { self.candidateVideoWire = nil }
      if self.videoWire === link { self.videoWire = nil; self.closeCourt() }
    }
    link.message = { [weak self, weak link] packet in
      guard let self, let link else { return }
      if self.candidateVideoWire === link, self.videoToken == token,
         case .videoJoin(let received) = packet, received == token {
        self.candidateVideoWire = nil
        self.videoWire?.close()
        self.videoWire = link
        link.binaryVideo = true
        link.send(.videoReady)
      } else if self.videoWire === link {
        switch packet {
        case .courtVideo(let frame):
          do { try self.receiveCourt(frame, via: link) } catch { self.say(error.localizedDescription) }
        case .courtClosed(let id): if id == self.courtID { self.closeCourt() }
        default: link.close()
        }
      } else { link.close() }
    }
    link.start()
    io.asyncAfter(deadline: .now() + 4) { [weak self, weak link] in
      if let link, self?.candidateVideoWire === link { link.close() }
    }
  }

  private var listener: NWListener?, wire: CaptureWire?, timer: DispatchSourceTimer?
  private var archive: CaptureArchive?, identity: (String, String, String)?
  private var clockHistory: [ClockPoint] = []
  private var recent: [MotionRow] = []
  private var selectedRoot: URL?
  private var hasImage = false, closing = false, videoEnded = false
  private var endReason: String?, videoError: String?
  private var ticks = 0, lastVideoStart = 0.0, phoneEnded = false
  private var observer: NSObjectProtocol?
  static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
  private func ui(_ body: @escaping () -> Void) { DispatchQueue.main.async(execute: body) }
  private func say(_ text: String) { ui { self.message = text } }
  init() {
    camera.wristTracker.observe = { [weak self] l, r in
      self?.io.async {
        guard let self else { return }
        self.wLeft = l
        self.wRight = r
        if let w = self.plan.left ? l : r {
          self.wristHistory.append(w)
          self.wristHistory.removeAll { $0.time < w.time - 1.1 }
        } else {
          self.wristHistory = []
        }
      }
    }
    camera.firstFrame = { [weak self] in self?.io.async { self?.firstImage() } }
    camera.failure = { [weak self] error in
      self?.io.async {
        self?.handleVideoFailure(error)
      }
    }
    observer = NotificationCenter.default.addObserver(
      forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, let d = note.object as? AVCaptureDevice,
        self.camera.session.inputs.contains(where: {
          ($0 as? AVCaptureDeviceInput)?.device.uniqueID == d.uniqueID
        })
      else { return }
      self.cameraReady = false
      self.io.async {
        self.handleVideoFailure("摄像头已断开")
      }
    }
    if let path = UserDefaults.standard.string(forKey: "studioRoot") {
      selectRoot(URL(fileURLWithPath: path))
    }
  }
  func selectRoot(_ url: URL) {
    root = url
    UserDefaults.standard.set(url.path, forKey: "studioRoot")
    io.async { self.selectedRoot = url }
    updateInputs()
  }
  func listen() {
    io.async {
      guard self.listener == nil else { return }
      do {
        let l = try NWListener(using: CaptureWire.parameters(self.secret))
        self.listener = l
        l.service = NWListener.Service(
          name: self.serviceName, type: CaptureWire.service)
        l.newConnectionHandler = { c in
          guard self.wire == nil else {
            self.acceptVideo(c)
            return
          }
          let w = CaptureWire(c, queue: self.io)
          self.wire = w
          w.state = { [weak w] ready in
            guard self.wire === w else { return }
            if ready {
              self.say("正在读取手机信息")
            } else {
              self.videoToken = nil
              self.candidateVideoWire?.close()
              self.videoWire?.close()
              self.closeCourt()
              self.diagnosticInbox.reset()
              self.wire = nil
              self.identity = nil
              self.clockHistory = []
              self.ui {
                self.online = false
                self.message = self.busy ? "连接中断，保留视频；重连后补传" : "等待手机连接"
              }
            }
          }
          w.message = { self.receive($0) }
          w.start()
          self.io.asyncAfter(deadline: .now() + 8) { [weak w] in
            if self.wire === w, self.identity == nil { w?.close() }
          }
        }
        l.stateUpdateHandler = { state in
          switch state {
          case .ready:
            self.ui {
              self.listening = true
              self.message = "等待 iPhone 配对"
            }
          case .failed(let err):
            self.say(err.localizedDescription)
            l.cancel()
            self.listener = nil
            self.ui { self.listening = false }
          default: break
          }
        }
        l.start(queue: self.io)
        if self.timer == nil {
          let t = DispatchSource.makeTimerSource(queue: self.io)
          self.timer = t
          t.schedule(deadline: .now(), repeating: .milliseconds(500))
          t.setEventHandler {
            self.ticks += 1
            if self.courtID != nil && Self.now - self.lastCourtFrame > 8 { self.closeCourt() }
            if self.identity != nil && (self.clockHistory.count < 20 || self.ticks % 10 == 0) {
              self.wire?.send(.ping(Self.now))
            }
            if self.ticks % 10 == 0, let a = self.archive, !self.closing,
              let free = try? a.dir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                .volumeAvailableCapacity, free < 64 * 1024 * 1024
            {
              self.stopInternal("磁盘空间不足")
            }
            if self.archive != nil && !self.hasImage && !self.closing
              && Self.now - self.lastVideoStart > 8
            {
              self.stopInternal("等待视频首帧超时")
            }
          }
          t.resume()
        }
      } catch { self.say(error.localizedDescription) }
    }
  }
  func preview(id: String) {
    cameraReady = false
    camera.configure(id: id) { error in
      self.ui {
        self.cameraReady = error == nil
        self.message = error ?? "摄像头预览就绪"
      }
    }
  }
  private func publish(change: Bool = false) {
    if change { plan.token = UUID() }
    let copy = plan
    wire?.send(.panel(copy))
    ui { self.guide = copy }
  }
  private func updateInputs() {
    let ready =
      root != nil && online && cameraReady
      && !participant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let left = hand == "左手"
    io.async {
      guard self.plan.prepared != ready || self.plan.left != left else { return }
      self.plan.prepared = ready
      self.plan.left = left
      self.publish(change: true)
    }
  }
  func act(_ command: TrialCommand) {
    let token = guide.token
    io.async { self.apply(command, token: token) }
  }
  private func apply(_ command: TrialCommand, token: UUID, fromPhone: Bool = false) {
    guard token == plan.token else {
      publish()
      return
    }
    do {
      switch command {
      case .select(let name):
        guard plan.phase == .idle, StandardStroke.gameTraining.contains(where: { $0.rawValue == name }) else {
          return
        }
        plan.stroke = name
        plan.feedback = ""
      case .setSpeed(let speed):
        guard plan.phase == .idle, CaptureSpeed.recordingOptions.contains(speed) else { return }
        plan.speed = speed
        plan.feedback = ""
      case .prepare:
        guard plan.phase == .idle, plan.prepared, identity != nil, archive == nil else {
          publish()
          return
        }
        plan.phase = .arming
        plan.step = 0
        plan.feedback = "等待相机首帧与手机样本"
        baseline = nil
        beganAt = nil
        let prompt = plan.stroke
        let speed = plan.selectedSpeed
        ui {
          self.start(
            participant: self.participant, hand: self.hand, grip: self.grip, prompt: prompt,
            speed: speed)
        }
      case .begin:
        guard fromPhone, plan.phase == .ready, let a = archive, !closing else { return }
        let now = Self.now
        try a.event("action_begin:" + plan.stroke, at: now, domain: "mac_host")
        beganAt = now
        plan.phase = .recording
        plan.feedback = "正在采集。做完并回位后，在 iPhone 确认结束"
      case .finish:
        guard fromPhone, plan.phase == .recording, let a = archive, let began = beganAt, !closing
        else {
          return
        }
        let end = Self.now
        try a.event("action_end:" + plan.stroke, at: end, domain: "mac_host")
        try a.writeWindow(start: began, end: end)
        stopInternal("complete")
        return
      case .cancel:
        guard archive != nil, !closing, fromPhone || plan.phase != .recording else { return }
        stopInternal("cancelled")
        return
      }
      publish(change: true)
    } catch {
      say(error.localizedDescription)
      wire?.send(.notice(error.localizedDescription))
    }
  }
  func confirmVisiblePosition() {
    let token = guide.token
    io.async { if token == self.plan.token { self.checkPosition(manual: true) } }
  }
  private func checkPosition(manual: Bool = false) {
    guard plan.phase == .calibrating, let a = archive, !closing, let last = recent.last else {
      return
    }
    let now = Self.now
    do {
      guard let t = ClockMap(points: a.clocks).host(last.t), abs(t - now) < 0.55 else {
        throw CaptureFailure("等待实时对时；补传数据不会推进校准")
      }
      let obs = plan.left ? wLeft : wRight
      let wrist = obs.flatMap { abs($0.time - t) < 0.45 ? $0 : nil }
      let record = try PositionGate.evaluate(
        step: plan.step, rows: recent.filter { $0.t > nextAfter }, base: baseline, wrist: wrist,
        manual: manual)
      if !manual {
        let stable = wristHistory.filter { abs($0.time - t) < 0.65 }
        guard let first = stable.first, let last = stable.last, last.time - first.time >= 0.32,
          stable.allSatisfy({ PositionTarget.all[plan.step].accepts($0, base: baseline?.wrist) })
        else { throw CaptureFailure("手腕已到位，保持位置约半秒") }
      }
      try a.appendLine("calibration.jsonl", record)
      try a.event("calibration:" + record.target, at: record.end, domain: "phone")
      if plan.step == 0 { baseline = record }
      nextAfter = last.t + 0.25
      if plan.step == 3 {
        plan.phase = .ready
        plan.feedback = "四个位置已保存，等待 iPhone 确认开始"
      } else {
        plan.step += 1
        plan.feedback = ""
      }
      publish(change: true)
    } catch {
      let msg = error.localizedDescription
      if msg != plan.feedback && (manual || now - lastFeedback > 0.45) {
        plan.feedback = msg
        lastFeedback = now
        // Store displayed changes, not every rejected sensor batch.
        try? a.event("calibration_hint:\(plan.step):" + msg, at: now, domain: "mac_host")
        publish()
      }
    }
  }
  private func resetGuide(_ feedback: String = "") {
    plan.phase = .idle
    if !CaptureSpeed.recordingOptions.contains(plan.selectedSpeed) { plan.speed = .normal }
    if !StandardStroke.gameTraining.contains(where: { $0.rawValue == plan.stroke }) {
      plan.stroke = StandardStroke.lift.rawValue
    }
    plan.step = 0
    plan.feedback = feedback
    baseline = nil
    beganAt = nil
    publish(change: true)
  }
  private func start(
    participant: String, hand: String, grip: String, prompt: String, speed: CaptureSpeed
  ) {
    guard !busy else { return }
    busy = true
    io.async {
      guard self.archive == nil, self.courtID == nil, let root = self.selectedRoot, let phone = self.identity,
        self.wire != nil
      else {
        self.resetGuide()
        self.ui {
          self.busy = false
          self.message = "请先选择目录并连接手机"
        }
        return
      }
      do {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let bytes = values.volumeAvailableCapacity, bytes < 150 * 1024 * 1024 {
          throw CaptureFailure("可用空间不足 150 MB，请更换目录")
        }
        let info = SessionInfo(
          id: UUID(), participant: participant, hand: hand, grip: grip, prompt: prompt,
          device: phone.0, system: phone.1, build: phone.2, created: Date(), speed: speed)
        let a = try CaptureArchive(root: root, info: info)
        self.archive = a
        try JSONEncoder().encode(PositionTarget.all).write(
          to: a.dir.appendingPathComponent("position_targets.json"), options: .atomic)
        self.resetFlags()
        for p in self.clockHistory { try a.clock(p) }
        self.ui {
          self.count = 0
          self.rate = 0
          self.latest = a.dir
          self.message = "正在等待视频和运动首帧"
        }
        self.lastVideoStart = Self.now
        self.camera.arm(a.dir)
      } catch {
        self.say(error.localizedDescription)
        if self.archive != nil {
          self.stopInternal("写入失败")
        } else {
          self.resetGuide()
          self.ui { self.busy = false }
        }
      }
    }
  }
  private func resetFlags() {
    recent = []
    wristHistory = []
    hasImage = false
    closing = false
    videoEnded = false
    endReason = nil
    videoError = nil
    phoneEnded = false
  }
  private func firstImage() {
    guard let a = archive, !closing else { return }
    hasImage = true
    wire?.send(.start(a.info.id))
    ui { self.videoReady = true }
  }
  private func handleVideoFailure(_ error: String) {
    if courtID != nil { ui { self.matchCameraStatus = error }; return }
    guard let archive, videoError == nil else { return }
    videoError = error
    try? archive.event("video_error:" + error, at: Self.now, domain: "mac_host")
    if plan.phase == .recording {
      plan.feedback = "视频中断，手机继续采集。请在 iPhone 确认结束"
      publish()
      say(error + " · 将保留为部分记录")
    } else {
      stopInternal(error)
    }
  }

  private func stopInternal(_ why: String) {
    guard let a = archive, !closing else { return }
    plan.phase = .saving
    plan.feedback = "正在封装与补传"
    publish(change: true)
    closing = true
    endReason = why == "complete" && beganAt == nil ? "incomplete_calibration" : why
    if hasImage { wire?.send(.stop(a.info.id)) } else { phoneEnded = true }
    say("正在封装录像与收取手机日志")
    camera.stop { error in
      self.io.async {
        self.videoError = self.videoError ?? error
        self.videoEnded = true
        self.finalizeIfReady()
      }
    }
  }
  private func finalizeIfReady() {
    guard let a = archive, closing, videoEnded, phoneEnded else { return }
    do {
      let reason = videoError ?? endReason ?? "partial"
      try a.close(reason: reason)
      wire?.send(.finished(a.info.id))
      archive = nil
      resetGuide(a.info.state == "complete" ? "已保存「" + a.info.prompt + "」，可继续下一拍" : "已保留部分记录，可重新校准")
      ui {
        self.count = a.samples
        self.busy = false
        self.videoReady = false
        self.latest = a.dir
        self.message = a.info.state == "complete" ? "已归档" : "已保留部分记录 · " + reason
      }
    } catch { say("归档失败：" + error.localizedDescription) }
  }
  func savePartial() {
    io.async {
      guard self.archive != nil else { return }
      self.endReason = "manual_partial"
      self.phoneEnded = true
      self.stopInternal("manual_partial")
      self.finalizeIfReady()
    }
  }
  private func receive(_ msg: CaptureMessage) {
    do {
      switch msg {
      case .courtVideo(let frame):
        do { try receiveCourt(frame, via: wire) } catch { say(error.localizedDescription) }
      case .courtFrame(let id, let time, _):
        wire?.send(.courtFrameAck(id, time))
        ui { self.liveStatus = "请更新 iPhone 开发版以显示比赛直播" }
      case .courtClosed(let id): if id == courtID { closeCourt() }
      case .liveRally(let batch):
        do { try receiveLive(batch) }
        catch { ui { self.liveStatus = "比赛诊断写入失败 · " + error.localizedDescription } }
      case .diagnostic(let chunk):
        guard identity != nil else { return }
        do {
          if let saved = try diagnosticInbox.receive(chunk, directory: diagnosticDirectory) {
            wire?.send(.diagnosticReceipt(chunk.id, chunk.digest, error: nil))
            ui {
              if !self.diagnosticRecords.contains(where: { $0.id == saved.id }) {
                self.diagnosticRecords.append(saved)
                self.diagnosticRecords.sort { $0.started > $1.started }
              }
              self.diagnosticMessage = "已保存 \(saved.target)"
            }
          }
        } catch {
          diagnosticInbox.reset()
          wire?.send(.diagnosticReceipt(chunk.id, chunk.digest, error: error.localizedDescription))
          ui { self.diagnosticMessage = error.localizedDescription }
        }
      case .command(let token, let cmd): apply(cmd, token: token, fromPhone: true)
      case .hello(let device, let system, let build, let pending):
        let capability = CaptureWire.videoCapability
        if build.hasSuffix(capability) {
          identity = (device, system, String(build.dropLast(capability.count)))
          let token = UUID()
          videoToken = token
          wire?.send(.videoOffer(token))
        } else {
          identity = (device, system, build)
        }
        publish()
        ui {
          self.online = true
          self.message = "已连接 " + device
        }
        if let pending {
          if archive == nil, let root = selectedRoot {
            let a = try CaptureArchive(open: root.appendingPathComponent(pending.uuidString))
            if a.info.state == "complete" {
              wire?.send(.finished(pending))
              return
            }
            archive = a
            resetFlags()
            hasImage = true
            closing = true
            videoEnded = true
            endReason = "recovered"
            plan.stroke = a.info.prompt
            plan.speed = a.info.speed
            plan.phase = .saving
            publish(change: true)
            ui {
              self.busy = true
              self.latest = a.dir
              self.count = a.samples
            }
          }
          guard let a = archive, a.info.id == pending else {
            throw CaptureFailure("请选择原采集根目录并重新连接，以补传手机日志")
          }
          wire?.send(.resume(pending, a.next))
          if closing { wire?.send(.stop(pending)) }
        } else if let a = archive, hasImage {
          if closing {
            phoneEnded = true
            finalizeIfReady()
          } else if a.samples == 0 {
            wire?.send(.start(a.info.id))
          } else {
            phoneEnded = true
            stopInternal("手机日志中断")
          }
        }
      case .pong(let m, let p1, let p2):
        let p = ClockPoint(m0: m, p1: p1, p2: p2, m3: Self.now)
        try recordCourtClock(p)
        clockHistory.append(p)
        if clockHistory.count > 30 { clockHistory.removeFirst() }
        if !closing { try archive?.clock(p) }
      case .batch(let id, let i, let rows):
        guard let a = archive, a.info.id == id else { return }
        if i == a.next {
          recent += rows
          recent.removeAll { $0.t < (rows.last?.t ?? 0) - 1.2 }
        }
        try a.accept(i, rows)
        wire?.send(.ack(id, a.next))
        if plan.phase == .arming && !closing {
          plan.phase = .calibrating
          nextAfter = rows.first?.t ?? 0
          plan.feedback = ""
          publish(change: true)
        }
        checkPosition()
        if i % 5 == 0 {
          let isStarting = i == 0 && !closing
          let n = a.samples
          let hz =
            rows.count > 1 ? Double(rows.count - 1) / max(0.001, rows.last!.t - rows.first!.t) : 0
          ui {
            self.count = n
            self.rate = hz
            if isStarting { self.message = "校准段已开始录制" }
          }
        }
      case .event(let id, let t, let label) where id == archive?.info.id:
        try archive?.event(label, at: t, domain: "phone")
      case .end(let id, let n, let why):
        guard let a = archive, a.info.id == id else { return }
        guard a.next == n else {
          wire?.send(.resume(id, a.next))
          return
        }
        phoneEnded = true
        if why != "complete" { endReason = why }
        if !closing { stopInternal(why) }
        finalizeIfReady()
      case .error(let text):
        say(text)
        if archive != nil {
          phoneEnded = true
          stopInternal(text)
        }
      default: break
      }
    } catch {
      say(error.localizedDescription)
      wire?.send(.error(error.localizedDescription))
    }
  }
}
extension Optional where Wrapped == String { fileprivate var orMac: String { self ?? "Mac" } }

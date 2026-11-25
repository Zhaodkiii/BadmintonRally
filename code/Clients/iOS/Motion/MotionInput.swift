import CoreMotion
import SwiftUI
import simd

final class MotionInput: ObservableObject {
  @Published private(set) var soloStep:Int?
  @Published private(set) var soloArmed = false
  private var soloCalibration:SoloPositionCalibration?
  func cancelSolo(){
    if soloArmed { soloArmed = false; status = "已退出待录"; return }
    guard let c=soloCalibration else{return}
    do {try c.finish("cancelled");status="已取消，校准记录已保存"}catch{status=error.localizedDescription}
    soloCalibration=nil;soloStep=nil;loadArchive()
  }
  private let curveModel = SwingCurveModel.load(Bundle.main.url(forResource: "SwingCurves", withExtension: "json"))
  private let reviewedCourt = ReviewedCourt.load(Bundle.main.url(forResource: "ReviewedCourt", withExtension: "json"))
  var curveVersion: String { (curveModel?.version ?? "未载入") + "/button-contact-v5/rear-corner-v1/overhead-return-v1/rear-clear-response-v1/serve-intent-v3" + ((reviewedCourt?.highServeReferences?.isEmpty == false) ? "/high-serve-v1" : "") }
  @Published private(set) var curveObservation = ""
  private var coach: SwingCoach?
  func resetServeAttempt() { coach?.resetServeAttempt() }
  var swingImpact: SwingImpact? { coach?.impact }
  private var buttonMode = false
  private var buttonSwing = ButtonSwing()
  private let buttonIntent = ServeIntentBank.load(Bundle.main.url(forResource: "ServeIntent", withExtension: "json"))
  func startButtonInput() {
    buttonSwing = ButtonSwing()
    buttonMode = true
    playing = true
    start()
  }
  func buttonHit(_ t: Double, left: Bool, serving: Bool) -> ButtonSwing.Hit {
    buttonSwing.press(t, left: left, serving: serving, bank: reviewedCourt, intent: buttonIntent)
  }
  @Published private(set) var cue = ""
  @Published private(set) var interrupted = false
  private var streamID = UUID()
  private let source = DeviceMotionSource.shared
  var available: Bool { source.available }
  @Published var progress = 0.0
  @Published var ready = false
  @Published var status = "手机顶部斜向电视，静止一秒"
  @Published var exportURL: URL?
  @Published var recording = false
  @Published var samples = 0
  @Published var acceptedURL: URL?
  @Published var candidateCount = 0
  @Published private(set) var elapsed = 0.0
  @Published private(set) var archive: [URL] = []
  private var guided = true
  private var captureSpeed = CaptureSpeed.normal
  private var trialDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MotionTrials")
  }
  func loadArchive() {
    archive = ((try? FileManager.default.contentsOfDirectory(at: trialDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter {
        ["csv", "json"].contains($0.pathExtension)
      }.sorted {
        let a = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let b = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return (a ?? .distantPast) > (b ?? .distantPast)
      }
  }
  private var featureRows: [[Double]] = []
  private var peakAcceleration = 0.0
  private let model = StrokeModel.bundled()
  var serving = false
  var receiving = false
  var playing = false
  var onSwingPreview: ((SwingImpact, Double) -> Void)?
  var onContact: ((Double) -> Void)?
  var light = false
  var onTestFrame: ((MotionTestTrace.Frame) -> Void)?
  var onTestEvent: ((MotionTestTrace.Event, Stroke?, SwingCurveModel.Match?) -> Void)?
  var onStroke: ((Stroke, Double, Double) -> Void)?
  private var still: Double?, baseline = 0.0, previous = 0.0, startTime = 0.0
  private var startPitch = 0.0, startYaw = 0.0, lastPitch = 0.0, lastYaw = 0.0
  private var peak = 0.0, peakTime = 0.0, peakYaw = 0.0, cooldown = 0.0
  private var waitingForRest = false
  private var buffer = "", label = "", recordStart = 0.0
  private var hand = "", participant = "", session = ""
  private var rowContext = ""
  private var sampleFile: FileHandle?
  private var pendingFile: URL?
  private let fields =
    "participant,session,hand,prompt,t_s,rx,ry,rz,ax_g,ay_g,az_g,gx,gy,gz,qx,qy,qz,qw,cue_phase,started_utc,hardware,ios,speed\n"
  func start() {
    guard available else {
      status = "此设备可使用触屏挥拍"
      return
    }
    interrupted = false
    let id = UUID()
    streamID = id
    previous = 0
    peak = 0
    waitingForRest = false
    still = nil
    source.subscribe("game") { [weak self] data, error in
      DispatchQueue.main.async { [weak self] in
      guard let self, self.streamID == id else { return }
      if error != nil {
        if self.buttonMode {
          self.buttonSwing = ButtonSwing()
          self.status = "运动采样中断，按键使用轻击力度"
          return
        }
        self.status = "运动采样中断，请重新校准"
        self.ready = false
        self.interrupted = true
        self.stop()
        return
      }
      if let data { self.consume(data) }
      }
    }
  }
  func stop() {
    buttonMode = false
    playing = false
    serving = false
    receiving = false
    streamID = UUID()
    source.remove("game")
    cancelSolo()
    if recording { finishRecord(reason: "interrupted") }
  }
  func calibrate(personal: Bool = false, keepExamples: Bool = false) {
    if personal {
      if !keepExamples || coach == nil {
        coach = SwingCoach(curveModel: curveModel, assist: UserDefaults.standard.bool(forKey: "curveAssist"))
        curveObservation = ""
      }
      coach?.reseat()
    } else {
      coach = nil
    }
    cue = coach?.instruction ?? ""

    ready = false
    progress = 0
    still = nil
    peak = 0
    status = personal ? "留出一臂空间，按平时打球的方式握住手机" : "手机顶部斜向电视，静止一秒"
  }
  func beginRecord(_ label: String, hand: String, participant: String, guided: Bool, speed: CaptureSpeed) {
    guard !recording,!soloArmed,soloCalibration==nil,ready,available else { return }
    self.guided = guided
    captureSpeed = speed
    elapsed = 0
    self.label = label
    self.hand = hand
    self.participant = participant.filter { $0.isLetter || $0.isNumber }.prefix(24).description
    do {
      let c=try SoloPositionCalibration(folder:trialDirectory,prompt:label,hand:hand,speed:speed)
      soloCalibration = c
      soloStep = 0
      session = c.id.uuidString
      exportURL = nil
      acceptedURL = nil
      status = "单机校准：按提示保持握向"
    }catch{status=error.localizedDescription}
  }
  func confirmRecordingStart() {
    guard soloArmed, !recording else { return }
    do {
      let url = trialDirectory.appendingPathComponent("\(session)-\(label)-interrupted.csv")
      try Data(fields.utf8).write(to: url, options: .atomic)
      let file = try FileHandle(forWritingTo: url)
      try file.seekToEnd()
      pendingFile = url
      sampleFile = file
    } catch { status = "无法开始录制："+error.localizedDescription; return }
    soloArmed = false
    var hardware = utsname()
    uname(&hardware)
    let device = withUnsafeBytes(of: &hardware.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    rowContext = [ISO8601DateFormatter().string(from: Date()), "\"\(device)\"", UIDevice.current.systemVersion, captureSpeed.rawValue].joined(separator: ",")

    StudioSender.shared.event("prompt:" + label, at: ProcessInfo.processInfo.systemUptime)
    recordStart = ProcessInfo.processInfo.systemUptime
    peak = 0
    waitingForRest = false
    featureRows = []
    candidateCount = 0
    acceptedURL = nil
    buffer = ""
    samples = 0
    exportURL = nil
    recording = true
  }
  private func flushSamples() throws {
    guard let sampleFile else { return }
    let batch = Data(buffer.utf8)
    buffer.removeAll(keepingCapacity: true)
    if !batch.isEmpty { try sampleFile.write(contentsOf: batch) }
  }
  func finishRecord(reason: String = "manual") {
    guard recording, let url = pendingFile else { return }
    recording = false
    defer {
      try? sampleFile?.close()
      sampleFile = nil
      pendingFile = nil
      loadArchive()
    }
    do {
      try flushSamples()
      try sampleFile?.close()
      sampleFile = nil
      if samples == 0 {
        try FileManager.default.removeItem(at: url)
        status = "没有采到样本，请重新录制"
        return
      }
      if reason == "manual" {
        let completed = trialDirectory.appendingPathComponent("\(session)-\(label)-manual.csv")
        try FileManager.default.moveItem(at: url, to: completed)
        exportURL = completed
        status = "已保存 \(samples) 个样本"
      } else {
        exportURL = url
        status = "录制中断，已保留 \(samples) 个样本"
      }
    } catch {
      exportURL = url
      status = "写入中断，已保留能写入的样本："+error.localizedDescription
    }
  }
  func acceptSingleCandidate(as actual: String) {
    guard !recording, let raw = exportURL, candidateCount == 1, let row = featureRows.first
    else { return }
    acceptedURL = nil
    let file = raw.deletingPathExtension().appendingPathExtension("accepted.csv")
    let header = (["participant", "session", "label"] + StrokeModel.columns + ["speed"]).joined(separator: ",")
    let values = ([participant, session, actual] + row.map { String($0) } + [captureSpeed.rawValue]).joined(separator: ",")
    do {
      try (header + "\n" + values + "\n").write(to: file, atomically: true, encoding: .utf8)
      loadArchive()
      acceptedURL = file
    } catch { status = error.localizedDescription }
  }
  func review(as actual: String) {
    guard !recording, let raw = exportURL else { return }
    let file = raw.deletingPathExtension().appendingPathExtension("review.json")
    let review = ["raw_file": raw.lastPathComponent, "actual_label": actual,
                  "prompt": label, "session": session, "participant": participant, "speed": captureSpeed.rawValue]
    do {
      try JSONEncoder().encode(review).write(to: file, options: .atomic)
      if candidateCount == 1 {
        acceptSingleCandidate(as: actual)
        guard acceptedURL != nil else { return }
      }
      loadArchive()
      status = "已复核为「\(actual)」"
    } catch { status = error.localizedDescription }
  }
  private func consume(_ d: CMDeviceMotion) {
    let t = d.timestamp
    let r = d.rotationRate
    let a = d.userAcceleration
    let g = d.gravity
    let q = d.attitude.quaternion
    if buttonMode {
      buttonSwing.append(t, .init(r.x,r.y,r.z), .init(a.x,a.y,a.z), .init(g.x,g.y,g.z))
      onTestFrame?(.init(time: t, rotation: [r.x,r.y,r.z], acceleration: [a.x,a.y,a.z],
                         gravity: [g.x,g.y,g.z], quaternion: [q.x,q.y,q.z,q.w],
                         armed: true, tracking: false, trigger: nil, gripSimilarity: nil))
      return
    }
    if let c=soloCalibration {
      do {
        let row=MotionRow(t:t,v:[r.x,r.y,r.z,a.x,a.y,a.z,g.x,g.y,g.z,q.x,q.y,q.z,q.w])
        if let hint=try c.feed(row) {
          if c.step==4 {
            try c.finish("complete")
            soloCalibration = nil
            soloStep = nil
            soloArmed = true
            status = "校准完成，请在 iPhone 确认开始"
          }else {
            if soloStep != c.step {soloStep=c.step}
            if status != hint {status=hint}
          }
        }
      }catch {cancelSolo();status=error.localizedDescription}
      return
    }
    if coach != nil {
      let gravity = SIMD3(g.x, g.y, g.z)
      let event = coach?.feed(t, rotation: .init(r.x, r.y, r.z),
        acceleration: .init(a.x, a.y, a.z), gravity: gravity, light: light, playing: playing, receiving: receiving, serving: serving)
      if let onTestFrame, let coach {
        onTestFrame(.init(time: t, rotation: [r.x, r.y, r.z], acceleration: [a.x, a.y, a.z],
          gravity: [g.x, g.y, g.z], quaternion: [q.x, q.y, q.z, q.w], armed: coach.isArmed,
          tracking: coach.isTracking, trigger: coach.diagnosticTrigger,
          gripSimilarity: coach.gripSimilarity(gravity)))
      }
      if let preview = coach?.preview { onSwingPreview?(preview, t) }
      guard let event else { return }
      if let match = coach?.curveMatch {
        let summary = String(format: "%@ · 相似度 %.2f · 分差 %.2f", match.label, match.score, match.margin)
        if curveObservation != summary { curveObservation = summary }
      }
      if let onTestEvent {
        let message: String
        let stroke: Stroke?
        switch event {
        case .contact: message = "检测到挥拍 · 方向未定"; stroke = nil
        case .hit(let kind, _, _): message = "检测到挥拍"; stroke = kind
        case .message(let text): message = text; stroke = nil
        case .ready: message = "校准通过"; stroke = nil
        case .progress: message = ""; stroke = nil
        }
        if let coach, let peak = coach.candidatePeak {
          #if DEBUG
          if let (version, label) = coach.shadowPrediction(at: peak) {
            onTestEvent(.init(time: peak, kind: "shadow", text: version, outputTime: t, curve: label), nil, nil)
          }
          #endif
          let curve = coach.curveMatch
          onTestEvent(.init(time: peak, kind: "candidate", text: message, outputTime: t,
            game: stroke?.rawValue, curve: curve?.label ?? coach.impact?.label, score: curve?.score, margin: curve?.margin,
            directionScore: coach.directionScore, directionMargin: coach.directionMargin), stroke, curve)
        } else if !message.isEmpty {
          onTestEvent(.init(time: t, kind: "status", text: message), nil, nil)
        }
      }
      switch event {
      case .progress(let fraction):
        progress = fraction
      case .message(let message):
        cue = coach?.instruction ?? ""
        status = message == cue ? "每拍结束，回到原握姿停一下" : message
        progress = coach?.fraction ?? 0
      case .ready:
        cue = coach?.instruction ?? ""
        status = "试挥一次可查看识别结果"
        progress = 1
        ready = true
      case .contact(let time):
        status = "已检测到挥拍"
        onContact?(time)
      case .hit(let stroke, let aim, let time):
        status = "最近识别：\(stroke.rawValue)"
        onStroke?(stroke, aim, time)
      }
      return
    }
    let capturesSample = recording && t >= recordStart
    if capturesSample {
      elapsed = t - recordStart
      let phase = guided ? StandardStroke.phases[StandardStroke.phase(elapsed * captureSpeed.playbackRate)] : "自由"
      let values = [
        t - recordStart, r.x, r.y, r.z, a.x, a.y, a.z, g.x, g.y, g.z, q.x, q.y, q.z, q.w,
      ]
      buffer +=
        ([participant, session, hand, label] + values.map { String($0) } + [phase, rowContext]).joined(separator: ",")
        + "\n"
      samples += 1
      if samples.isMultiple(of: 100) {
        do { try flushSamples() } catch {
          finishRecord(reason: "interrupted")
          status = "写入中断，已保留能写入的样本：" + error.localizedDescription
          return
        }
      }
    }
    let top = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w).act(SIMD3<Double>(0, 1, 0))
    let yaw = atan2(top.x, top.y)
    let pitch = asin(min(1, max(-1, top.z)))
    let rate = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
    if t - previous > 0.1 {
      peak = 0
      still = nil
      lastPitch = pitch
      lastYaw = yaw
    }
    previous = t
    defer {
      lastPitch = pitch
      lastYaw = yaw
    }
    if !ready {
      guard rate < 0.32, hypot(hypot(a.x, a.y), a.z) < 0.12 else {
        still = nil
        progress = 0
        return
      }
      if still == nil { still = t }
      progress = min(1, t - (still ?? t))
      if progress >= 1 {
        baseline = yaw
        ready = true
        status = "已校准，试一次上挑或下挥"
      }
      return
    }
    if waitingForRest {
      if rate < 0.8 && t >= cooldown { waitingForRest = false }
      return
    }
    let threshold = light ? 1.05 : 1.6
    if peak == 0 {
      guard rate > threshold else { return }
      peakAcceleration = 0
      startTime = t
      startPitch = lastPitch
      startYaw = lastYaw
    }
    peakAcceleration = max(peakAcceleration, sqrt(a.x * a.x + a.y * a.y + a.z * a.z))
    if rate >= peak {
      peak = rate
      peakTime = t
      peakYaw = yaw
    }
    guard t - startTime > 0.035, rate < peak * 0.70 || t - startTime > 0.27 else { return }
    let vertical = pitch - startPitch
    let side = atan2(sin(yaw - startYaw), cos(yaw - startYaw))
    let amplitude = max(abs(vertical), abs(side))
    let features = [vertical, abs(side), peak, peakAcceleration, t - startTime]
    if capturesSample {
      if candidateCount == 0 { featureRows = [features] }
      candidateCount += 1
    }
    peak = 0
    waitingForRest = true
    cooldown = t + 0.15
    guard amplitude > (light ? 0.065 : 0.11) else { return }
    var kind: Stroke = abs(vertical) > abs(side) * 0.66 ? (vertical > 0 ? .lift : .smash) : .drive
    if let model, let label = model.classify(features) {
      guard let prediction = Stroke(rawValue: label) else { return }
      kind = prediction
    }
    let lateral = atan2(sin(peakYaw - baseline), cos(peakYaw - baseline))
    onStroke?(kind, min(0.9, max(-0.9, lateral * 2 + side)), peakTime)
  }
}

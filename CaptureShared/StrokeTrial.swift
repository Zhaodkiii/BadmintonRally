import Foundation

enum TrialPhase: String, Codable {
  case idle, arming, calibrating, ready, recording, saving
}
enum CaptureSpeed: String, Codable, CaseIterable, Identifiable {
  case slow, normal, fast

  static let recordingOptions: [Self] = [.slow, .normal]
  var id: Self { self }
  var title: String {
    switch self {
    case .slow: "慢速演示"
    case .normal: "正常实战"
    case .fast: "快速实战"
    }
  }
  var playbackRate: Double {
    switch self {
    case .slow: 0.65
    case .normal: 1
    case .fast: 1.45
    }
  }
}

enum TrialCommand: Codable {
  case select(String)
  case setSpeed(CaptureSpeed)
  case prepare, begin, finish, cancel
}
struct TrialPanel: Codable {
  var token = UUID(), phase = TrialPhase.idle, stroke = StandardStroke.lift.rawValue
  var step = 0, left = false, prepared = false
  var feedback = ""
  var speed: CaptureSpeed?
  var selectedSpeed: CaptureSpeed { speed ?? .normal }
  static let positions = ["胸前基准", "持拍侧伸", "前上方伸展", "回到胸前"]
  static let instructions = [
    "用持拍手从下方托住手机，拇指搭在侧边。手肘放松，手机放胸前，屏幕朝上，机顶指向前方。",
    "手伸向持拍侧，约与肩同高。屏幕继续朝上，机顶转向同侧，停一秒。",
    "手抬到持拍肩前上方，机顶抬向斜上方，停一秒。",
    "手收回胸前，屏幕朝上，机顶重新指向前方，停一秒。",
  ]
  var title: String {
    switch phase {
    case .idle: return "选择采集动作"
    case .arming: return "正在准备视频和传感器"
    case .calibrating: return "校准 \(step+1)/4 · " + Self.positions[step]
    case .ready: return "校准完成"
    case .recording: return "动作采集中"
    case .saving: return "正在保存"
    }
  }
}
struct WristObservation: Codable {
  let time: Double, x: Double, y: Double, confidence: Double
  // Relative to shoulder midpoint, in shoulder widths. Positive x = racket side.
}
struct PositionRecord: Codable {
  let version: Int, step: Int, target: String, start: Double, end: Double, gravity: [Double],
    quaternion: [Double]
  let reference: String, evidence: String, wrist: WristObservation?, baseWrist: WristObservation?
}
struct PositionTarget: Codable {
  let step: Int, name: String, minX: Double?, maxX: Double?, minY: Double?, maxY: Double?
  let minSideDelta: Double?, minHeightDelta: Double?, returnTolerance: Double?
  let minTurnDegrees: Double?, maxTurnDegrees: Double?
  static let all: [Self] = [
    .init(
      step: 0, name: "胸前基准", minX: -0.85, maxX: 0.85, minY: -1.25, maxY: 0.25, minSideDelta: nil,
      minHeightDelta: nil, returnTolerance: nil, minTurnDegrees: nil, maxTurnDegrees: nil),
    .init(
      step: 1, name: "持拍侧伸", minX: 0.9, maxX: nil, minY: nil, maxY: nil, minSideDelta: 0.65,
      minHeightDelta: nil, returnTolerance: nil, minTurnDegrees: 40, maxTurnDegrees: 140),
    .init(
      step: 2, name: "前上方伸展", minX: nil, maxX: nil, minY: 0.12, maxY: nil, minSideDelta: nil,
      minHeightDelta: 0.4, returnTolerance: nil, minTurnDegrees: nil, maxTurnDegrees: nil),
    .init(
      step: 3, name: "回到胸前", minX: nil, maxX: nil, minY: nil, maxY: nil, minSideDelta: nil,
      minHeightDelta: nil, returnTolerance: 0.45, minTurnDegrees: nil, maxTurnDegrees: 25),
  ]
  func positionHint(_ w: WristObservation) -> String {
    switch step {
    case 0:
      if abs(w.x) > 0.85 { return "把持机手向胸口中间收一点" }
      return w.y < -1.25 ? "把持机手往上抬到胸前" : "把持机手降到肩膀下方"
    case 1: return "手腕需要再往持拍侧伸一点"
    case 2: return "把手腕抬到肩线以上，保持入镜"
    default: return "把手腕收回第一步的胸前位置"
    }
  }
  func accepts(_ w: WristObservation, base: WristObservation?) -> Bool {
    if w.x < (minX ?? -.infinity) || w.x > (maxX ?? .infinity) || w.y < (minY ?? -.infinity)
      || w.y > (maxY ?? .infinity)
    {
      return false
    }
    if let d = minSideDelta, w.x - (base?.x ?? 0) < d { return false }
    if let d = minHeightDelta, w.y - (base?.y ?? -0.4) < d { return false }
    if let tol = returnTolerance {
      return abs(w.x - (base?.x ?? 0)) < tol && abs(w.y - (base?.y ?? -0.45)) < tol
    }
    return true
  }
}
enum PositionGate {
  static func evaluate(
    step: Int, rows: [MotionRow], base: PositionRecord?, wrist: WristObservation?, manual: Bool
  ) throws -> PositionRecord {
    struct Rejection: LocalizedError {
      let message: String
      var errorDescription: String? { message }
    }
    guard (0..<4).contains(step), let last = rows.last, last.v.count == 13 else {
      throw Rejection(message: "等待手机采样")
    }
    let window = rows.filter { $0.t >= last.t - 0.95 }
    guard let first = window.first, last.t - first.t >= 0.8,
      zip(window, window.dropFirst()).allSatisfy({ $1.t > $0.t && $1.t - $0.t < 0.1 }),
      window.allSatisfy({
        $0.v.count == 13 && hypot(hypot($0.v[0], $0.v[1]), $0.v[2]) < 0.35
          && hypot(hypot($0.v[3], $0.v[4]), $0.v[5]) < 0.12
      })
    else { throw Rejection(message: "到位后稳住手机约一秒") }
    let q = Array(last.v[9...12])
    let g = Array(last.v[6...8])
    let target = PositionTarget.all[step]
    guard (0.95...1.05).contains(q.reduce(0) { $0 + $1 * $1 }),
      (0.9...1.1).contains(g.reduce(0) { $0 + $1 * $1 })
    else { throw Rejection(message: "等待有效机身姿态") }
    if step != 2 && g[2] > -0.68 { throw Rejection(message: "把屏幕翻向天花板") }
    if step != 2 && abs(g[1]) > 0.45 { throw Rejection(message: "把手机顶部放平，和底部保持同高") }
    if step == 2 && g[1] > -0.42 { throw Rejection(message: "将手机顶部抬高约 30–60°") }
    if step > 0 {
      guard let base else { throw Rejection(message: "请重新建立胸前基准") }
      let dot = abs(zip(base.quaternion, q).reduce(0) { $0 + $1.0 * $1.1 })
      let degrees = 2 * acos(min(1, dot)) * 180 / Double.pi
      if step == 1 && (degrees < target.minTurnDegrees! || degrees > target.maxTurnDegrees!) {
        throw Rejection(message: "转动手机，让机顶由前方转向持拍侧")
      }
      if step == 3 && degrees > target.maxTurnDegrees! { throw Rejection(message: "请恢复胸前基准的手机朝向") }
    }
    if !manual {
      guard let w = wrist, w.confidence >= 0.35 else {
        throw Rejection(message: "请让双肩和持机手腕入镜，或由 Mac 操作员核对位置")
      }
      guard target.accepts(w, base: base?.wrist) else {
        throw Rejection(message: target.positionHint(w))
      }
    }
    return PositionRecord(
      version: 1, step: step, target: TrialPanel.positions[step], start: first.t, end: last.t,
      gravity: g, quaternion: q, reference: "xArbitraryZVertical",
      evidence: manual ? "operator_confirmed_2d" : "camera_shoulder_relative_2d", wrist: wrist,
      baseWrist: base?.wrist)
  }
}

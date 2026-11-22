import Foundation
import simd

/// All vectors use Core Motion's device axes, so a player's own grip defines their examples.
struct SwingCoach {
  typealias Vector = SIMD3<Double>
  enum Event {
    case message(String), progress(Double), ready, hit(Stroke, Double, Double)
  }
  private static let order: [Stroke] = [.lift, .smash, .drive]
  private struct Example {
    let axis: Vector
    let peak: Double
    let turn: Double
  }
  private let curveModel: SwingCurveModel?
  private let assist: Bool
  private var history = SwingCurveHistory()
  private var verifiedCurveStrokes = Set<Stroke>()
  private(set) var curveMatch: SwingCurveModel.Match?

  init(curveModel: SwingCurveModel? = nil, assist: Bool = false) {
    self.curveModel = curveModel
    self.assist = assist
  }

  private var examples: [[Example]] = [[], [], []]
  private var grip: Vector?
  private var stableSince: Double?, gravitySum = Vector.zero, noise = 0.0
  private var last = -1.0, restingSince: Double?, armed = false
  private var began: Double?, integral = Vector.zero, peakAxis = Vector.zero
  private var awaySince: Double?, promptedForGrip = false
  private var peak = 0.0, peakAt = 0.0, accelPeak = 0.0
  private var stage = 0, verified = 0
  private var seated = false
  var complete: Bool { seated && verified == Self.order.count }
  var instruction: String {
    guard seated else { return "自然握紧手机，保持准备姿势一秒" }
    guard !complete else { return "校准完成，可以自由试挥或进入球场" }
    let i = min(stage, 2)
    let index = stage == 3 ? verified : i
    let cue = ["前臂从低处向前上方短挑", "从肩旁向前下方短挥", "在胸前向侧面水平短挥"][index]
    let prefix = stage == 3 ? "试打验收 \(verified + 1)/3" : "采样 \(i + 1)/3 · 第 \(examples[i].count + 1)/2 拍"
    return "\(prefix)  \(Self.order[index].rawValue) · \(cue)"
  }
  var fraction: Double {
    Double((seated ? 1 : 0) + examples.reduce(0) { $0 + $1.count } + verified) / 10
  }
  mutating func reseat() {
    history = SwingCurveHistory()
    curveMatch = nil
    seated = false
    stableSince = nil
    last = -1
    resetSegment()
  }
  private mutating func resetSegment() {
    began = nil
    armed = false
    restingSince = nil
    awaySince = nil
    promptedForGrip = false
  }
  mutating func feed(_ t: Double, rotation: Vector, acceleration: Vector, gravity: Vector, light: Bool) -> Event? {
    if curveModel != nil { history.append(t, rotation, acceleration) }
    let dt = t - last
    last = t
    if dt <= 0 || dt > 0.12 {
      resetSegment()
      stableSince = nil
      return nil
    }
    let rate = simd_length(rotation), accel = simd_length(acceleration)
    if !seated {
      guard rate < 0.35, accel < 0.12 else {
        stableSince = nil
        return .progress(0)
      }
      if stableSince == nil {
        stableSince = t
        gravitySum = .zero
        noise = 0
      }
      gravitySum += gravity
      noise = max(noise, rate)
      let elapsed = t - (stableSince ?? t)
      guard elapsed >= 1 else { return .progress(min(0.099, elapsed / 10)) }
      let current = simd_normalize(gravitySum)
      if let grip, simd_dot(current, grip) < 0.78 {
        stableSince = nil
        return .message("握姿变化较大，请回到原握姿，或点重新校准")
      }
      grip = current
      seated = true
      return complete ? .ready : .message(instruction)
    }

    let floor = max(light ? 0.48 : 0.65, noise * 2.3)
    let learned = examples.flatMap { $0 }.map(\.peak).min() ?? 2
    let trigger = min(max(floor, 0.9), max(floor, learned * 0.32))
    if !armed {
      // Returning the hand must not count as a second stroke.
      guard rate < 0.45, accel < 0.18,
        let grip, simd_dot(gravity, grip) > 0.65 else {
        restingSince = nil
        if awaySince == nil { awaySince = t }
        if !promptedForGrip, t - (awaySince ?? t) > 1.2 {
          promptedForGrip = true
          return .message("请回到最初的握姿，停一下再挥下一拍")
        }
        return nil
      }
      awaySince = nil
      if restingSince == nil { restingSince = t }
      if t - (restingSince ?? t) >= 0.12 {
        armed = true
        if promptedForGrip { return .message(complete ? "已就位" : instruction) }
      }
      return nil
    }
    if began == nil {
      guard rate >= trigger else { return nil }
      began = t
      integral = .zero
      peak = 0
      accelPeak = 0
    }
    integral += rotation * dt
    accelPeak = max(accelPeak, accel)
    if rate >= peak {
      peak = rate
      peakAt = t
      peakAxis = rotation / rate
    }
    let duration = t - (began ?? t)
    guard duration >= 0.045, rate < 0.67 * peak || duration >= 0.32 else { return nil }
    resetSegment()
    let travel = simd_length(integral)
    guard travel >= (light ? 0.035 : 0.055), peak >= trigger * 1.05,
      accelPeak > 0.035 || travel > 0.12 else {
      return .message("动作太小，请从准备姿势做一次清楚的短挥")
    }
    let axis = simd_normalize(peakAxis + integral / travel * 0.65)
    let sample = Example(axis: axis, peak: peak, turn: simd_dot(integral, gravity))
    if stage < Self.order.count {
      if examples.prefix(stage).joined().contains(where: { simd_dot($0.axis, axis) > 0.86 }) {
        return .message("和前一类动作太像，请按提示改变挥动方向")
      }
      if let first = examples[stage].first, simd_dot(first.axis, axis) < 0.78 {
        // Let the player recover from a mistaken first example.
        examples[stage] = [sample]
        return .message("两拍方向不同，已保留这一拍，请用相同方向再挥一次")
      }
      examples[stage].append(sample)
      if examples[stage].count == 2 { stage += 1 }
      return .message(instruction)
    }
    let scores = examples.enumerated().map { i, group in
      (i, group.map { simd_dot($0.axis, axis) }.reduce(0, +) / Double(group.count))
    }.sorted { $0.1 > $1.1 }
    curveMatch = history.curve(at: peakAt).flatMap { curveModel?.classify($0) }
    let best = scores[0]
    let kind = Self.order[best.0]
    let agrees = curveMatch?.strong == true && curveMatch?.stroke == kind
    // A validated global curve may confirm a close personal-template decision.
    let supportsCloseCall = assist && complete && agrees && verifiedCurveStrokes.contains(kind)
    guard best.1 >= 0.70, best.1 - scores[1].1 >= (supportsCloseCall ? 0.03 : 0.08) else {
      return .message("方向不明确，请回到准备姿势，再做一次")
    }
    if !complete {
      guard verified == best.0 else { return .message("刚才识别为\(Self.order[best.0].rawValue)，请重试提示动作") }
      if agrees { verifiedCurveStrokes.insert(kind) }
      verified += 1
      return complete ? .ready : .message(instruction)
    }
    let usual = examples[best.0].map(\.turn).reduce(0, +) / 2
    return .hit(Self.order[best.0], min(0.9, max(-0.9, (sample.turn - usual) * 2)), peakAt)
  }
}

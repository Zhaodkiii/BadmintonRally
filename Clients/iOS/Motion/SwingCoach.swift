import Foundation
import simd

/// All vectors use Core Motion's device axes, so a player's own grip defines their examples.
struct SwingCoach {
  typealias Vector = SIMD3<Double>
  enum Event {
    case contact(Double), message(String), progress(Double), ready, hit(Stroke, Double, Double)
  }
  private static let order: [Stroke] = [.lift, .smash, .drive]
  struct Example: Codable {
    let axis: Vector
    let peak: Double
    let turn: Double
  }
  struct Profile: Codable {
    let version: Int
    let grip: Vector
    let samples: [Example]
    var supported: [String]? = nil
  }
  private let quick: Bool
  var nextStroke: Stroke? { seated && stage < Self.order.count ? Self.order[stage] : nil }
  var profile: Profile? {
    guard quick, complete, let grip else { return nil }
    return Profile(version: 1, grip: grip, samples: examples.compactMap { $0.first },
                   supported: verifiedCurveStrokes.map(\.rawValue).sorted())
  }
  private let curveModel: SwingCurveModel?
  #if DEBUG
  func shadowPrediction(at peak: Double) -> (String, String)? {
    guard let svm = ShadowSVM.bundled, let features = history.phaseFeatures(at: peak),
          let label = svm.predict(features) else { return nil }
    return (svm.version, label)
  }
  #endif
  private let reviewedCourt: ReviewedCourt?
  var serveIntentBank = ServeIntentBank.load(Bundle.main.url(forResource: "ServeIntent", withExtension: "json"))
  private var usesRightHand = true
  private let assist: Bool
  private var history = SwingCurveHistory()
  private var verifiedCurveStrokes = Set<Stroke>()
  private(set) var diagnosticTrigger: Double?
  private(set) var directionScore: Double?
  private(set) var directionMargin: Double?
  private var sequence = StrokeSequence()
  private var crest: (time: Double, rate: Double, gravity: Vector)?
  private var lastMatchHit = -Double.infinity
  private var matchMode = false
  private var wasServing = false
  mutating func resetServeAttempt() {
    sequence = StrokeSequence()
    history = SwingCurveHistory()
    crest = nil
    lastMatchHit = -.infinity
  }
  private(set) var impact: SwingImpact?
  private(set) var preview: SwingImpact?
  var isArmed: Bool { matchMode ? sequence.available : armed }
  var isTracking: Bool { matchMode ? sequence.tracking : began != nil }
  func gripSimilarity(_ gravity: Vector) -> Double? { grip.map { simd_dot($0, gravity) } }

  private(set) var candidatePeak: Double?
  private(set) var curveMatch: SwingCurveModel.Match?

  init(curveModel: SwingCurveModel? = nil, reviewedCourt: ReviewedCourt? = nil, assist: Bool = false, quick: Bool = false, profile: Profile? = nil) {
    self.reviewedCourt = reviewedCourt
    self.curveModel = curveModel
    self.assist = assist
    self.quick = quick
    if quick, let profile, profile.version == 1, profile.samples.count == Self.order.count,
       abs(simd_length(profile.grip) - 1) < 0.01,
       profile.samples.allSatisfy({ abs(simd_length($0.axis) - 1) < 0.01 && $0.peak > 0 && $0.turn.isFinite }) {
      verifiedCurveStrokes = Set((profile.supported ?? []).compactMap(Stroke.init(rawValue:)))
      grip = profile.grip
      examples = profile.samples.map { [$0] }
      stage = Self.order.count
      verified = stage
    }
  }

  mutating func enterCourt(left: Bool) {
    usesRightHand = !left
    if stage != Self.order.count {
      let fallback = [Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 0, 1)]
      examples = zip(["上挑", "正手扣杀", "平抽"], fallback).map { label, standard in
        var axis = standard
        if let curve = curveModel?.prototypes[label], curve.count == 96 {
          let peak = Vector(curve[90], curve[91], curve[92])
          if simd_length(peak) > 0.001 { axis = simd_normalize(peak) }
        }
        if left { axis = Vector(axis.x, -axis.y, -axis.z) }
        return [Example(axis: axis, peak: 4, turn: 0)]
      }
      stage = Self.order.count
      verified = stage
    }
    seated = true
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
    if quick { return "\(Self.order[index].rawValue) · \(cue)" }
    let prefix = stage == 3 ? "试打验收 \(verified + 1)/3" : "采样 \(i + 1)/3 · 第 \(examples[i].count + 1)/2 拍"
    return "\(prefix)  \(Self.order[index].rawValue) · \(cue)"
  }
  var fraction: Double {
    if quick { return seated ? Double(1 + stage) / 4 : 0 }
    return Double((seated ? 1 : 0) + examples.reduce(0) { $0 + $1.count } + verified) / 10
  }
  mutating func reseat() {
    sequence = StrokeSequence()
    crest = nil
    lastMatchHit = -.infinity
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
  mutating func feed(_ t: Double, rotation: Vector, acceleration: Vector, gravity: Vector, light: Bool, playing: Bool = false, receiving: Bool = false, serving: Bool = false) -> Event? {
    matchMode = playing && complete
    if serving && !wasServing { resetServeAttempt() }
    wasServing = serving
    impact = nil
    preview = nil
    candidatePeak = nil
    diagnosticTrigger = nil
    if curveModel != nil || serving { history.append(t, rotation, acceleration) }
    let dt = t - last
    last = t
    if dt <= 0 || dt > 0.12 {
      sequence = StrokeSequence()
      crest = nil
      lastMatchHit = -.infinity
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
    diagnosticTrigger = trigger
    if matchMode {
      if usesRightHand, let bank = reviewedCourt,
         let event = reviewedSwing(t, rotation: rotation, gravity: gravity, bank: bank, serving: serving) { return event }
      let result = sequence.feed(t, rotation, acceleration, dt: dt, trigger: trigger, gravity: gravity, receiving: receiving, serving: serving)
      preview = sequence.preview
      guard let result else { return nil }
      candidatePeak = result.time
      directionScore = nil
      directionMargin = nil
      curveMatch = nil
      let intent = serving ? history.serveFeatures(at: result.time).flatMap { serveIntentBank?.intent($0) } : nil
      if serving && usesRightHand && reviewedServePhase(result.time) == false {
        return .message("后引或放手 · 等待向前主挥")
      }
      if serving && intent != true {
        return .message(intent == false ? "准备或收手 · 未发球" : "发球主挥证据不足")
      }
      let fullServe = serving && intent == true && result.speed > 6 && result.acceleration > 0.5
        && simd_length(result.turn) > 0.35
      if let reason = result.rejection,
         !(fullServe && reason == "方向反复或卸力不完整") { return .message(reason) }
      sequence.confirm(at: t)
      lastMatchHit = t
      peak = result.speed
      peakAt = result.time
      integral = result.turn
      peakAxis = result.axis
      accelPeak = result.acceleration
      let scale = examples.flatMap { $0 }.map(\.peak).sorted()
      let personalPower = max(3, (scale.isEmpty ? 4 : scale[scale.count / 2]) * 1.55)
      let fullPower = grip == nil && usesRightHand ? reviewedCourt?.fullPower ?? personalPower : personalPower
      impact = SwingImpact(power: min(1, peak / fullPower),
                           sweep: min(1, simd_length(integral) / 1.4), label: nil,
                           verticalSweep: result.vertical, lateralSweep: result.lateral, followThrough: result.followThrough)
      impact?.serveIntentConfirmed = serving && intent == true
      // A reviewed full forward stroke with cross-body recovery establishes
      // intent, but its return rotation cannot identify the serve subtype.
      if fullServe && result.rejection != nil { return .contact(peakAt) }
    } else {
      if !armed {
        // Returning the hand must not count as a second stroke.
        guard rate < 0.45, accel < 0.18, (gripSimilarity(gravity) ?? 0) > 0.65 else {
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
    }
    directionScore = nil
    directionMargin = nil
    candidatePeak = peakAt
    curveMatch = nil
    let travel = simd_length(integral)
    guard travel >= (light ? 0.035 : 0.055), peak >= trigger * 1.05,
      accelPeak > 0.035 || travel > 0.12 else {
      return .message("动作太小，请从准备姿势做一次清楚的短挥")
    }
    let axis = simd_normalize(peakAxis + integral / travel * 0.65)
    guard axis.x.isFinite && axis.y.isFinite && axis.z.isFinite else { return .message("请回到身前，再做一次短挥") }
    let sample = Example(axis: axis, peak: peak, turn: simd_dot(integral, gravity))
    if stage < Self.order.count {
      if examples.prefix(stage).joined().contains(where: { simd_dot($0.axis, axis) > 0.86 }) {
        return .message("和前一类动作太像，请按提示改变挥动方向")
      }
      if quick {
        if let curve = history.curve(at: peakAt), let match = curveModel?.classify(curve),
           match.strong, match.stroke == Self.order[stage] { verifiedCurveStrokes.insert(Self.order[stage]) }
        examples[stage] = [sample]
        stage += 1
        if stage == Self.order.count {
          verified = stage
          return .ready
        }
        return .message("已记住这一拍，回到身前准备下一拍")
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
    if curveMatch?.strong == true { impact?.label = curveMatch?.label }
    let best = scores[0]
    directionScore = best.1
    directionMargin = best.1 - scores[1].1
    let kind = Self.order[best.0]
    if matchMode, sequence.risingArc, curveMatch?.strong != true || curveMatch?.label == "网前扑球" {
      impact?.label = nil
      return .hit(.lift, 0, peakAt)
    }
    if matchMode, receiving, let impact, impact.verticalSweep < -0.50,
       -impact.verticalSweep >= abs(impact.lateralSweep) + 0.15 {
      return .hit(.smash, 0, peakAt)
    }
    let agrees = curveMatch?.strong == true && curveMatch?.stroke == kind
    // A validated global curve may confirm a close personal-template decision.
    let supportsCloseCall = assist && complete && agrees && verifiedCurveStrokes.contains(kind)
    guard best.1 >= 0.70, best.1 - scores[1].1 >= (supportsCloseCall ? 0.03 : 0.08) else {
      if playing && complete, let impact {
        // Classify the direction of the phone tip during the main swing.
        // The same downward stroke may be played on either side of the body.
        if impact.verticalSweep < -0.44 { return .hit(.smash, 0, peakAt) }
        if impact.verticalSweep > 0.44 { return .hit(.lift, 0, peakAt) }
        if abs(impact.lateralSweep) > 0.55 { return .hit(.drive, 0, peakAt) }
        return .contact(peakAt)
      }
      return .message("方向不明确，请回到准备姿势，再做一次")
    }
    if !complete {
      guard verified == best.0 else { return .message("刚才识别为\(Self.order[best.0].rawValue)，请重试提示动作") }
      if agrees { verifiedCurveStrokes.insert(kind) }
      verified += 1
      return complete ? .ready : .message(instruction)
    }
    let usual = examples[best.0].map(\.turn).reduce(0, +) / Double(examples[best.0].count)
    return .hit(Self.order[best.0], min(0.9, max(-0.9, (sample.turn - usual) * 2)), peakAt)
  }

  private func reviewedServePhase(_ time: Double) -> Bool? {
    guard let direction = serveIntentBank?.direction, let curve = history.curve(at: time) else { return nil }
    return direction.phase(curve)
  }

  // An independently validated trajectory can finish while the player's hand is
  // still moving. The generic recognizer remains available for unfamiliar swings.
  private mutating func reviewedSwing(_ t: Double, rotation: Vector, gravity: Vector,
                                      bank: ReviewedCourt, serving: Bool) -> Event? {
    let rate = simd_length(rotation)
    if t - lastMatchHit < 0.30 {
      crest = nil
      return nil
    }
    if serving, let direction = serveIntentBank?.direction,
       let peak = history.recentServePeak(minSpeed: direction.minPeak, minAcceleration: direction.minAcceleration),
       reviewedServePhase(peak.time) == true,
       let motion = history.forwardMotion(at: peak.time) {
      crest = nil
      candidatePeak = peak.time
      directionScore = nil
      directionMargin = nil
      curveMatch = nil
      lastMatchHit = t
      sequence.confirm(at: t)
      impact = SwingImpact(power: min(1, peak.speed / bank.fullPower),
                           sweep: min(1, simd_length(motion) / 1.4), serveIntentConfirmed: true,
                           label: "正手高远发球")
      return .hit(.lift, min(0.9, max(-0.9, simd_dot(motion, gravity) * 2)), peak.time)
    }
    if let prior = crest, t - prior.time > 0.18 { crest = nil }
    if rate >= 3, rate >= (crest?.rate ?? 0) {
      crest = (t, rate, gravity)
      return nil
    }
    guard let peak = crest, t - peak.time >= 0.05, rate <= peak.rate * 0.82 else { return nil }
    crest = nil
    guard let curve = history.curve(at: peak.time),
          let match = bank.match(for: curve, gravity: peak.gravity, serving: serving),
          let metrics = history.forwardMotion(at: peak.time) else { return nil }
    if serving {
      guard reviewedServePhase(peak.time) != false, ["反手偷后场", "正手高远发球", "反手短发", "正手短发球"].contains(match.label),
            history.serveFeatures(at: peak.time).flatMap({ serveIntentBank?.intent($0) }) != false else { return nil }
    }
    let kind: Stroke
    switch match.label {
    case "正手扣杀": kind = .smash
    case "反手偷后场", "正手高远发球", "上挑": kind = .lift
    case "反手短发", "正手短发球", "平抽": kind = .drive
    default: return nil
    }
    candidatePeak = peak.time
    curveMatch = match
    directionScore = nil
    directionMargin = nil
    lastMatchHit = t
    sequence.confirm(at: t)
    impact = SwingImpact(power: min(1, peak.rate / bank.fullPower),
                         sweep: min(1, simd_length(metrics) / 1.4), label: match.label,
                         verticalSweep: simd_dot(simd_cross(simd_normalize(metrics), Vector(0, 1, 0)), -peak.gravity),
                         lateralSweep: simd_dot(simd_normalize(metrics), -peak.gravity))
    return .hit(kind, min(0.9, max(-0.9, simd_dot(metrics, gravity) * 2)), peak.time)
  }

}

// Match-only causal segmentation. Keep the first lobe as preparation while looking
// for a separately accelerated forward lobe. A peak alone never emits a stroke.
private struct StrokeSequence {
  typealias V = SIMD3<Double>
  struct Frame {
    let t, dt: Double
    let w: V
    let gravity: V
    let receiving: Bool
    let linear: V
  }
  struct Result {
    let time, speed, acceleration: Double
    let axis, turn: V
    let vertical, lateral, followThrough: Double
    let rejection: String?
  }
  private var frames: [Frame] = []
  private var peak = 0.0, peakTime = 0.0
  private var blockedUntil = -Double.infinity
  private var quietSince: Double?
  private(set) var risingArc = false
  private var previewed = false
  private(set) var preview: SwingImpact?
  private(set) var tracking = false
  private(set) var available = true

  mutating func feed(_ t: Double, _ w: V, _ a: V, dt: Double, trigger: Double, gravity: V, receiving: Bool, serving: Bool) -> Result? {
    preview = nil
    let rate = simd_length(w)
    if !available {
      if rate < trigger { if quietSince == nil { quietSince = t } } else { quietSince = nil }
      if t >= blockedUntil, let quietSince, t - quietSince >= 0.05 { available = true }
      return nil
    }
    frames.removeAll { $0.t < t - 0.85 }
    frames.append(Frame(t: t, dt: dt, w: w, gravity: gravity, receiving: receiving, linear: a))
    if !tracking {
      guard rate >= trigger else { return nil }
      tracking = true
      previewed = false
      peak = 0
    }
    if rate > peak { peak = rate; peakTime = t }
    if !previewed, rate >= max(1.25, trigger), simd_length(a) >= 0.09 {
      let axis = w / rate
      let lead = frames.reversed().prefix {
        t - $0.t <= 0.045 && simd_dot($0.w, axis) >= 0.55 * rate
      }
      let impulse = lead.reduce(V.zero) { $0 + $1.linear * $1.dt }
      if let first = lead.last, t - first.t >= 0.025, simd_length(impulse) >= 0.004 {
        previewed = true
        preview = SwingImpact(power: min(1, rate / 8), sweep: min(1, rate / 8),
                              verticalSweep: simd_dot(simd_cross(axis, V(0, 1, 0)), -gravity),
                              lateralSweep: simd_dot(axis, -gravity))
      }
    }
    guard t - peakTime >= 0.05, rate < 0.55 * peak else { return nil }
    tracking = false
    guard let centre = frames.lastIndex(where: { $0.t == peakTime }) else { return nil }
    let axis = frames[centre].w / peak
    var start = centre
    while start > 0, simd_dot(frames[start - 1].w, axis) > 0.22 * peak,
          peakTime - frames[start - 1].t < 0.34 { start -= 1 }
    let main = frames[start...centre]
    let tail = frames.suffix(from: centre + 1)
    let prep = frames[..<start].filter { frames[start].t - $0.t <= 0.48 }
    let back = prep.reduce(V.zero) { $0 + $1.w * $1.dt }
    let backLength = simd_length(back)
    let forward = main.reduce(V.zero) { $0 + $1.w * $1.dt }
    let length = simd_length(forward)
    let accel = main.map { simd_length($0.linear) }.max() ?? 0
    // Short device-frame impulse proxy. A single acceleration spike or
    // opposing jitter should not stand in for sustained forward motion.
    let impulse = main.reduce(V.zero) { $0 + $1.linear * $1.dt }
    let sustained = main.reduce(0.0) { $0 + (simd_length($1.linear) >= 0.07 ? $1.dt : 0) }
    var reason: String?
    let prepPath = prep.reduce(0.0) { $0 + simd_length($1.w) * $1.dt }
    let preparationTime = prep.reduce(0.0) { $0 + (simd_length($1.w) > trigger * 0.35 ? $1.dt : 0) }
    let directedReturn = (frames[centre].receiving || serving) && peak >= 1.5 && length >= 0.085
      && sustained >= 0.04 && simd_length(impulse) >= 0.010
      && main.allSatisfy { simd_dot($0.w, axis) >= 0.65 * simd_length($0.w) }
    let vertical = main.reduce(0.0) { sum, f in
      sum + simd_dot(simd_cross(f.w, V(0, 1, 0)), -f.gravity) * f.dt
    }
    let lateral = main.reduce(0.0) { $0 + simd_dot($1.w, -$1.gravity) * $1.dt }
    let path = max(0.0001, main.reduce(0.0) { $0 + simd_length($1.w) * $1.dt })
    if !directedReturn && preparationTime < 0.065 {
      reason = "引拍时间不足"
    } else if !directedReturn && backLength < 0.045 {
      reason = "引拍幅度不足"
    } else if !directedReturn && backLength < 0.48 * prepPath {
      reason = "引拍方向反复"
    } else if !directedReturn && simd_dot(back, axis) > backLength * 0.60 {
      reason = "引拍与主挥方向接近"
    } else if peakTime - frames[start].t < 0.035 || main.first.map({ simd_length($0.w) > peak * 0.80 }) == true || length < 0.085 || accel < 0.055 {
      reason = "主挥过短或缺少前送"
    } else if sustained < 0.030 || simd_length(impulse) < 0.006 {
      reason = "转动明显，主挥缺少持续前送"
    } else if t - peakTime > 0.30 || tail.contains(where: { simd_dot($0.w, axis) < -0.42 * peak }) ||
                tail.filter({ simd_length($0.w) < 0.78 * peak }).count < 2 {
      reason = "方向反复或卸力不完整"
    }
    let movingTail = tail.prefix { simd_dot($0.w, axis) >= 0.22 * peak }
    let followThrough = min(0.055, max(0, (movingTail.last?.t ?? peakTime) - peakTime))
    // A rising racket can rotate around a lateral axis. Check the change in
    // elevation of the phone tip against the early, gravity-aligned impulse.
    let lead = frames.filter { $0.t >= peakTime - 0.22 && $0.t <= peakTime - 0.07 }
    let peakGravity = tail.last(where: { $0.t <= peakTime + 0.055 })?.gravity ?? frames[centre].gravity
    let tipRise = (lead.first?.gravity.y ?? peakGravity.y) - peakGravity.y
    let verticalImpulse = lead.reduce(0.0) { $0 + simd_dot($1.linear,$1.gravity) * $1.dt }
    risingArc = reason == nil && peak >= 3 && length >= 0.16 && tipRise > 0.28 && verticalImpulse > 0.065

    return Result(time: peakTime, speed: peak, acceleration: accel, axis: axis, turn: forward, vertical: vertical / path, lateral: lateral / path, followThrough: followThrough, rejection: reason)
  }
  mutating func confirm(at t: Double) {
    tracking = false
    available = false
    quietSince = nil
    blockedUntil = t + 0.17
    frames.removeAll(keepingCapacity: true)
  }

}

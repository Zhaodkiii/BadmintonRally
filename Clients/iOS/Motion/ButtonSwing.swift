import Foundation
import simd

/// A press consumes the preceding stroke. Sensor frames alone never submit a game input.
struct ButtonSwing {
  typealias V = SIMD3<Double>
  private struct Frame { let t: Double; let w, a, gravity: V }
  private var frames: [Frame] = []
  private var consumed = -Double.infinity
  struct Hit {
    let stroke: Stroke
    let aim: Double
    let impact: SwingImpact
    let peakTime: Double
  }
  mutating func append(_ t: Double, _ w: V, _ a: V, _ g: V) {
    if let last = frames.last, t <= last.t || t - last.t > 0.05 { frames.removeAll(keepingCapacity: true) }
    frames.removeAll { $0.t < t - 0.45 }
    frames.append(Frame(t: t, w: w, a: a, gravity: g))
  }
  mutating func press(_ t: Double, left: Bool, serving: Bool, bank: ReviewedCourt?,
                      intent: ServeIntentBank?) -> Hit {
    let tap = Hit(stroke: .drive, aim: 0, impact: SwingImpact(power: 0, sweep: 0, serveIntentConfirmed: serving), peakTime: t)
    let pre = frames.filter { $0.t > max(t - 0.32, consumed) && $0.t <= t }
    consumed = max(consumed, t)
    guard pre.count >= 5, let last = pre.last, t - last.t < 0.06 else { return tap }
    // Find a sustained lobe near the button. Do not choose a single noisy peak.
    var best = 0.0, end = 0
    var latestAxis: V?
    for i in (2..<pre.count).reversed() where pre[i].t >= t - 0.23 {
      let mean = (pre[i].w + pre[i-1].w + pre[i-2].w) / 3
      let speed = simd_length(mean)
      if let axis = latestAxis {
        if speed < 0.35 || simd_dot(mean, axis) <= 0 { break }
      } else {
        guard speed >= 0.55 else { continue }
        latestAxis = mean / speed
      }
      if speed > best { best = speed; end = i }
    }
    guard best > 0.55 else { return tap }
    let axis = simd_normalize(pre[end].w + pre[end-1].w + pre[end-2].w)
    var first = end
    while first > 0, simd_dot(pre[first-1].w, axis) > best * 0.12 { first -= 1 }
    var lastIndex = end
    while lastIndex + 1 < pre.count, simd_dot(pre[lastIndex+1].w, axis) > best * 0.12 { lastIndex += 1 }
    let lobe = pre[first...lastIndex]
    var turn = 0.0, impulse = 0.0, rise = 0.0, side = 0.0
    for (a,b) in zip(lobe,lobe.dropFirst()) {
      let dt = b.t-a.t
      turn += simd_length(b.w)*dt
      impulse += simd_length(b.a)*dt
      rise += simd_dot(simd_cross(b.w,V(0,1,0)), -b.gravity)*dt
      side += simd_dot(b.w,-b.gravity)*dt
    }
    guard turn >= 0.04, impulse >= 0.003, pre[lastIndex].t-pre[first].t >= 0.028 else { return tap }
    let vertical = max(-1,min(1,rise/turn))
    // Blend the direction of the stroke with its signed horizontal rotation.
    var lateral = tanh(1.35 * (0.60 * side / turn + 0.40 * side)) * (left ? -1 : 1)
    var kind: Stroke = vertical > 0.20 ? .lift : vertical < -0.24 ? .smash : .drive
    var label: String?
    if !left {
      var history = SwingCurveHistory()
      for f in pre { history.append(f.t,f.w,f.a) }
      if let curve = history.curve(at: pre[end].t) {
        if serving, let dir = intent?.direction, best >= dir.minPeak,
           simd_length(pre[end].a) >= dir.minAcceleration, dir.phase(curve) == true {
          label = "正手高远发球"; kind = .lift
        } else if let match = bank?.match(for: curve, gravity: pre[end].gravity, serving: serving),
                  !serving || ["反手短发","正手短发球","正手高远发球","反手偷后场"].contains(match.label) {
          label = match.label
          if ["正手高远发球","反手偷后场","上挑"].contains(match.label) { kind = .lift }
          if match.label == "正手扣杀" { kind = .smash }
        }
      }
    }
    let power = 0.75 * tanh(best / (bank?.fullPower ?? 22)) + 0.25 * tanh(impulse / 0.45)
    var launchSweep = vertical
    if serving {
      // Use the approach to the button, including low-rotation forearm translation.
      let approach = pre.filter { $0.t >= t - 0.15 }
      var dtSum = 0.0, axial = 0.0, lateralSupport = 0.0
      for (p,q) in zip(approach, approach.dropFirst()) {
        let dt = q.t - p.t
        axial += dt * simd_dot(q.a, q.gravity)
        let across = simd_cross(V(0,1,0), q.gravity)
        lateralSupport += dt * abs(simd_dot(q.a, across)) / max(0.1,simd_length(across))
        dtSum += dt
      }
      if dtSum >= 0.08 {
        launchSweep = 0.30 * vertical + 0.70 * tanh(axial / (1.4 * dtSum))
        // A twisting wrist alone gives weak evidence of lateral placement.
        lateral *= 0.45 + 0.55 * tanh(lateralSupport / dtSum)
      }
    }
    let impact = SwingImpact(power: power, sweep: tanh(turn / 2.0), serveIntentConfirmed: serving,
                             label: label, verticalSweep: launchSweep, lateralSweep: lateral)
    return Hit(stroke: kind, aim: lateral, impact: impact, peakTime: pre[end].t)
  }
}

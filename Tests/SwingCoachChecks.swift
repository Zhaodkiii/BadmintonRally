import Foundation
import simd

@main struct SwingCoachChecks {
  static func main() {
    for sign: Double in [-1, 1] {
      var coach = SwingCoach(), t = 0.0, count = 0
      var last: Stroke?
      let grip = SIMD3(0.0, sign, 0)
      func sample(_ r: SIMD3<Double>, _ a: Double = 0, g: SIMD3<Double>? = nil) {
        t += 0.01
        if case .hit(let stroke, _, let peakTime) = coach.feed(t, rotation: r,
          acceleration: .init(a, 0, 0), gravity: g ?? grip, light: true) {
          precondition(peakTime <= t)
          count += 1
          last = stroke
        }
      }
      func rest(_ n: Int) { for _ in 0..<n { sample(.zero) } }
      let lift = SIMD3(sign, 0, 0), drive = SIMD3(0, 0, sign)
      func swing(_ axis: SIMD3<Double>) {
        rest(24)
        for speed in [0.8, 1.2, 1.6, 2.0, 2.4, 2, 1.5, 1, 0.5] { sample(axis * speed, 0.12) }
      }
      rest(110)
      swing(lift)
      swing(lift)
      let passedLift = coach.fraction
      swing(lift)
      precondition(coach.fraction == passedLift)
      swing(-lift)
      swing(-lift)
      swing(drive)
      swing(drive)
      precondition(!coach.complete)
      swing(drive)
      precondition(coach.fraction == 0.7)
      swing(lift)
      swing(-lift)
      swing(drive)
      precondition(coach.complete && count == 0)
      swing(lift)
      for _ in 0..<20 { sample(-lift * 3, 0.1) }
      precondition(last == .lift && count == 1)
      coach.reseat()
      for _ in 0..<130 { sample(.zero, g: -grip) }
      precondition(!coach.complete)
      rest(230)
      precondition(coach.complete)
      swing(drive)
      precondition(last == .drive && count == 2)
    }
    checkCurveAssist()
    print("SwingCoach checks passed")
  }

  static func checkCurveAssist() {
    let lift = SIMD3<Double>(1, 0, 0), drive = SIMD3<Double>(0, 0, 1)
    let close = simd_normalize(lift + drive * 0.93)
    let speeds = [0.8, 1.2, 1.6, 2.0, 2.4, 2.0, 1.5, 1.0, 0.5]
    let acceleration = SIMD3(0.12, 0.0, 0.0)
    var history = SwingCurveHistory()
    for i in 0..<24 { history.append(Double(i) * 0.01, .zero, .zero) }
    for (i, speed) in speeds.enumerated() {
      history.append(Double(i + 24) * 0.01, close * speed, acceleration)
    }
    let feature = history.curve(at: 0.28)!
    let norm = sqrt(feature.reduce(0) { $0 + $1 * $1 })
    let prototype = feature.map { $0 / norm }
    for enabled in [false, true] {
      let model = SwingCurveModel(schema: 1, version: "fixture",
        prototypes: ["上挑": prototype, "平抽": prototype.map { -$0 }])
      var coach = SwingCoach(curveModel: model, assist: enabled)
      var t = 0.0, hits = 0
      func sample(_ rotation: SIMD3<Double>, _ accel: SIMD3<Double>) {
        t += 0.01
        if case .hit = coach.feed(t, rotation: rotation, acceleration: accel,
                                  gravity: .init(0, 1, 0), light: true) { hits += 1 }
      }
      func swing(_ axis: SIMD3<Double>) {
        for _ in 0..<24 { sample(.zero, .zero) }
        for speed in speeds { sample(axis * speed, acceleration) }
      }
      for _ in 0..<110 { sample(.zero, .zero) }
      for axis in [lift, lift, -lift, -lift, drive, drive, lift, -lift, drive] { swing(axis) }
      precondition(coach.complete && hits == 0)
      swing(close)
      precondition(hits == (enabled ? 1 : 0))
    }
  }
}

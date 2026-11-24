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
    checkPlayableContact()
    checkCompactReturn()
    checkQuickCalibration()
    checkCurveAssist()
    print("SwingCoach checks passed")
  }

  static func checkQuickCalibration() {
    for sign: Double in [-1, 1] {
      var coach = SwingCoach(quick: true)
      var t = 0.0
      var hits: [Stroke] = []
      func feed(_ v: SIMD3<Double>) {
        t += 0.01
        if case .hit(let kind, _, _) = coach.feed(t, rotation: v,
          acceleration: v == .zero ? .zero : .init(0.1, 0, 0), gravity: .init(0, 1, 0), light: false) {
          hits.append(kind)
        }
      }
      func rest(_ frames: Int) { for _ in 0..<frames { feed(.zero) } }
      func swing(_ axis: SIMD3<Double>) {
        rest(24)
        for speed in [1.2, 1.6, 2, 2.4, 2, 1.5, 1, 0.5] { feed(axis * speed) }
      }
      let up = SIMD3(sign, 0, 0), across = SIMD3(0, 0, sign)
      rest(110)
      swing(up)
      swing(up)
      precondition(coach.nextStroke == .smash)
      swing(-up)
      swing(across)
      precondition(coach.complete && hits.isEmpty)
      let bytes = try! JSONEncoder().encode(coach.profile!)
      coach = SwingCoach(quick: true, profile: try! JSONDecoder().decode(SwingCoach.Profile.self, from: bytes))
      precondition(!coach.complete)
      rest(110)
      precondition(coach.complete)
      swing(up)
      swing(-up)
      swing(across)
      precondition(hits == [.lift, .smash, .drive])
    }
  }

  static func checkPlayableContact() {
    let x = SIMD3<Double>(1, 0, 0), y = SIMD3<Double>(0, 1, 0), z = SIMD3<Double>(0, 0, 1)
    let profile = SwingCoach.Profile(version: 1, grip: y, samples: [x, -x, z].map { .init(axis: $0, peak: 3, turn: 0) })
    var coach = SwingCoach(quick: true, profile: profile)
    var t = 0.0, contacts = 0
    func feed(_ rotation: SIMD3<Double>, _ accel: Double = 0) {
      t += 0.01
      let event = coach.feed(t, rotation: rotation, acceleration: x * accel, gravity: y,
                             light: false, playing: true)
      switch event { case .contact, .hit: contacts += 1; default: break }
    }
    func rest(_ frames: Int) { for _ in 0..<frames { feed(.zero) } }
    rest(150)
    for _ in 0..<5 {
      for rate in [1.8, 2.0, -1.8, -2.0] { feed(z * rate, 0.2) }
    }
    rest(90)
    for _ in 0..<13 { feed(z * 0.6, 0.1) }
    rest(90)
    precondition(contacts == 0)
    // The same rotational swing with a single acceleration spike used to score.
    for _ in 0..<13 { feed(z * 0.6, 0.1) }
    for speed in [0.6, 0.9, 1.3, 1.7, 2.1, 2.6, 3.0, 2.7, 2.1, 1.6, 1.1, 0.6, 0.3] {
      feed(-z * speed, speed == 3 ? 0.18 : 0.02)
    }
    rest(65)
    precondition(contacts == 0)
    for _ in 0..<2 {
      for _ in 0..<13 { feed(z * 0.6, 0.1) }
      for speed in [0.6, 0.9, 1.3, 1.7, 2.1, 2.6, 3.0, 2.7, 2.1, 1.6, 1.1, 0.6, 0.3] {
        feed(-z * speed, 0.18)
      }
      rest(65)
    }
    precondition(contacts == 2)
  }

  static func checkCompactReturn() {
    let x = SIMD3<Double>(1, 0, 0), y = SIMD3<Double>(0, 1, 0), z = SIMD3<Double>(0, 0, 1)
    let profile = SwingCoach.Profile(version: 1, grip: z, samples: [y, -y, x].map { .init(axis: $0, peak: 3, turn: 0) })
    for direction in [x, z] {
      var coach = SwingCoach(quick: true, profile: profile)
      coach.enterCourt(left: false)
      var previewAt: Double?
      var hit: Stroke?
      for (index, speed) in [0, 0, 0.6, 0.95, 1.2, 1.5, 1.75, 1.95, 2.15, 2.0, 1.8, 1.3, 0.7, 0.3, 0].enumerated() {
        let time = Double(index) * 0.01
        let event = coach.feed(time, rotation: direction * speed, acceleration: x * 0.22,
                               gravity: z, light: false, playing: true, receiving: true)
        if coach.preview != nil { previewAt = time }
        if case .hit(let kind, _, _) = event {
          hit = kind
          precondition(previewAt != nil && previewAt! < time)
          precondition((coach.impact?.followThrough ?? 0) > 0)
        }
      }
      precondition(hit == (direction == x ? .smash : .drive))
    }
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

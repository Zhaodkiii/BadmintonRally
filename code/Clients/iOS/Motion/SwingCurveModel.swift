import Foundation
import simd

struct SwingCurveModel: Decodable {
  let schema: Int
  let version: String
  let prototypes: [String: [Double]]

  static func load(_ url: URL?) -> Self? {
    guard let url, let data = try? Data(contentsOf: url),
          let model = try? JSONDecoder().decode(Self.self, from: data),
          model.schema == 1, !model.version.isEmpty, model.prototypes.count >= 2,
          model.prototypes.values.allSatisfy({ $0.count == 96 && $0.allSatisfy(\.isFinite) })
    else { return nil }
    return model
  }

  struct Match {
    let label: String
    let score: Double
    let margin: Double
    var stroke: Stroke? {
      switch label {
      case "上挑": return .lift
      case "正手扣杀", "下挥": return .smash
      case "平抽", "接杀反抽": return .drive
      default: return nil
      }
    }
    var strong: Bool { score >= 0.80 && margin >= 0.08 }
  }

  func classify(_ curve: [Double]) -> Match? {
    let norm = sqrt(curve.reduce(0) { $0 + $1 * $1 })
    guard curve.count == 96, norm > 0 else { return nil }
    var ranks: [(label: String, score: Double)] = []
    for (label, prototype) in prototypes {
      var dot = 0.0
      for i in curve.indices { dot += curve[i] * prototype[i] }
      ranks.append((label, dot / norm))
    }
    ranks.sort { a, b in
      if a.score == b.score { return a.label < b.label }
      return a.score > b.score
    }
    guard ranks.count >= 2 else { return nil }
    return Match(label: ranks[0].0, score: ranks[0].1, margin: ranks[0].1 - ranks[1].1)
  }
}

/// Rolling history includes the lead-in to a candidate and ends at its observed peak.
struct SwingCurveHistory {
  typealias Vector = SIMD3<Double>
  private struct Sample {
    let time: Double
    let rotation, acceleration: Vector
  }
  private var samples: [Sample] = []

  mutating func append(_ time: Double, _ rotation: Vector, _ acceleration: Vector) {
    if let last = samples.last, time <= last.time || time - last.time > 0.04 {
      samples.removeAll(keepingCapacity: true)
    }
    if let first = samples.first, first.time < time - 0.6 {
      samples.removeAll { $0.time < time - 0.6 }
    }
    samples.append(Sample(time: time, rotation: rotation, acceleration: acceleration))
  }

  func serveFeatures(at peak: Double) -> [Double]? {
    var result: [Double] = []
    for i in 0..<4 {
      let part = samples.filter {
        let age = peak - $0.time
        return age >= Double(3-i)*0.04-0.000001 && age < Double(4-i)*0.04
      }
      guard part.count >= 2 else { return nil }
      let count = Double(part.count)
      result.append(log1p(part.reduce(0) { $0 + simd_length($1.rotation) } / count))
      result.append(log1p(part.reduce(0) { $0 + simd_length($1.acceleration) } / count))
    }
    return result
  }

  func recentServePeak(minSpeed: Double, minAcceleration: Double) -> (time: Double, speed: Double)? {
    guard samples.count >= 3 else { return nil }
    let end = samples.count - 1
    let peak = samples[end - 1]
    let speed = simd_length(peak.rotation)
    guard speed >= minSpeed, simd_length(peak.acceleration) >= minAcceleration,
          simd_length(samples[end - 2].rotation) < speed,
          simd_length(samples[end].rotation) <= speed else { return nil }
    return (peak.time, speed)
  }

  func forwardMotion(at peak: Double) -> Vector? {
    let main = samples.filter { $0.time >= peak - 0.12 && $0.time <= peak }
    var impulse = Vector.zero, turn = Vector.zero, sustained = 0.0
    for (a, b) in zip(main, main.dropFirst()) {
      let dt = b.time - a.time
      turn += b.rotation * dt
      impulse += b.acceleration * dt
      if simd_length(b.acceleration) >= 0.07 { sustained += dt }
    }
    guard sustained >= 0.04, simd_length(impulse) >= 0.018, simd_length(turn) >= 0.22 else { return nil }
    return turn
  }

  func curve(at peak: Double) -> [Double]? {
    guard let first = samples.first, let last = samples.last,
          first.time <= peak - 0.15, last.time >= peak else { return nil }
    var rotations: [Vector] = [], accelerations: [Vector] = []
    var index = 0
    for step in 0..<16 {
      let time = peak + Double(step - 15) * 0.01
      while index + 1 < samples.count && samples[index + 1].time < time { index += 1 }
      guard index + 1 < samples.count else { return nil }
      let a = samples[index], b = samples[index + 1]
      let w = (time - a.time) / (b.time - a.time)
      rotations.append(a.rotation + (b.rotation - a.rotation) * w)
      accelerations.append(a.acceleration + (b.acceleration - a.acceleration) * w)
    }
    let rNorm = max(1e-9, sqrt(rotations.reduce(0) { $0 + simd_length_squared($1) }))
    let aNorm = max(1e-9, sqrt(accelerations.reduce(0) { $0 + simd_length_squared($1) }))
    var result: [Double] = []
    for i in rotations.indices {
      let r = rotations[i] / rNorm, a = accelerations[i] / aNorm
      result.append(contentsOf: [r.x, r.y, r.z, a.x, a.y, a.z])
    }
    return result
  }
}

#if DEBUG
extension SwingCurveHistory {
  func phaseFeatures(at peak: Double) -> [Double]? {
    guard let first = samples.first, let last = samples.last,
          first.time <= peak - 0.24, last.time >= peak else { return nil }
    var values = Array(repeating: 0.0, count: 32)
    var index = 0
    for step in 0..<25 {
      let t = peak + Double(step - 24) * 0.01
      while index + 1 < samples.count && samples[index + 1].time < t { index += 1 }
      guard index + 1 < samples.count else { return nil }
      let a = samples[index], b = samples[index + 1]
      let w = (t - a.time) / (b.time - a.time)
      let r = a.rotation + w * (b.rotation - a.rotation)
      let g = a.acceleration + w * (b.acceleration - a.acceleration)
      let offset = step / 5 * 6
      for axis in 0..<3 {
        values[offset + axis] += r[axis] / 5
        values[offset + axis + 3] += g[axis] / 5
      }
      values[30] = max(values[30], simd_length(r))
      values[31] = max(values[31], simd_length(g))
    }
    return values
  }
}

struct ShadowSVM: Decodable {
  let version: String
  let labels: [String], counts: [Int]
  let mean, scale, bias: [Double]
  let dual, vectors: [[Double]]
  let gamma: Double
  static let bundled: ShadowSVM? = {
    guard let url = Bundle.main.url(forResource: "SwingShadow", withExtension: "json"),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }()

  func predict(_ features: [Double]) -> String? {
    let n = labels.count
    guard features.count == 32, mean.count == 32, scale.count == 32, n >= 2,
          counts.count == n, counts.allSatisfy({ $0 >= 0 }), counts.reduce(0,+) == vectors.count,
          vectors.allSatisfy({ $0.count == 32 }), dual.count == n - 1,
          dual.allSatisfy({ $0.count == vectors.count }), bias.count == n * (n - 1) / 2 else { return nil }
    let z = features.indices.map { (features[$0] - mean[$0]) / scale[$0] }
    let kernels = vectors.map { vector in exp(-gamma * z.indices.reduce(0) {
      let d = z[$1] - vector[$1]
      return $0 + d * d
    }) }
    var first = 0
    let ranges = counts.map { count in
      defer { first += count }
      return first..<(first + count)
    }
    var votes = Array(repeating: 0, count: n), pair = 0
    for i in 0..<n {
      for j in (i + 1)..<n {
        var score = bias[pair]
        for k in ranges[i] { score += dual[j - 1][k] * kernels[k] }
        for k in ranges[j] { score += dual[i][k] * kernels[k] }
        let positive = n == 2 ? j : i
        votes[score > 0 ? positive : (positive == i ? j : i)] += 1
        pair += 1
      }
    }
    return labels[votes.firstIndex(of: votes.max()!)!]
  }
}
#endif

/// Reviewed right-hand trajectories. All classes compete, but only classes that
/// survived cross-session validation are allowed to override a direction.
struct ReviewedCourt: Decodable {
  let schema: Int
  let templates: [String: [[Double]]]
  var highServeReferences: [[Double]]? = nil
  let enabled: [String]
  let threshold, margin, fullPower: Double

  static func load(_ url: URL?) -> Self? {
    guard let url, let data = try? Data(contentsOf: url),
          let bank = try? JSONDecoder().decode(Self.self, from: data), bank.schema == 1,
          bank.highServeReferences?.allSatisfy({ $0.count == 99 && $0.allSatisfy(\.isFinite) }) != false,
          bank.fullPower > 0, bank.templates.count >= 2,
          bank.templates.values.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.count == 99 } })
    else { return nil }
    return bank
  }

  func match(for curve: [Double], gravity: SIMD3<Double>, serving: Bool = false) -> SwingCurveModel.Match? {
    let norm = sqrt(curve.reduce(0) { $0 + $1 * $1 })
    guard curve.count == 96, norm > 0 else { return nil }
    guard simd_length(gravity) > 0.5 else { return nil }
    let g = simd_normalize(gravity)
    let feature = curve + [g.x, g.y, g.z]
    var ranks: [(String, [Double])] = []
    var candidates = templates
    if serving, let references = highServeReferences, references.count >= 2 {
      candidates["正手高远发球", default: []] += references
    }
    for (label, examples) in candidates {
      var scores: [Double] = []
      for example in examples {
        var dot = 0.0
        for i in feature.indices { dot += feature[i] * example[i] }
        scores.append(dot / sqrt(norm * norm + 1))
      }
      ranks.append((label, scores.sorted(by: >)))
    }
    ranks.sort { $0.1[0] > $1.1[0] }
    let (label, scores) = ranks[0]
    let trainedServe = serving && label == "正手高远发球" && (highServeReferences?.count ?? 0) >= 2
    guard (enabled.contains(label) || trainedServe), scores.count >= 2, scores[1] >= threshold,
          scores[0] - ranks[1].1[0] >= margin else { return nil }
    return .init(label: label, score: scores[0], margin: scores[0] - ranks[1].1[0])
  }
}

struct ServeIntentBank: Decodable {
  let positive, negative: [[Double]]
  struct Direction: Decodable {
    let minPeak, minAcceleration: Double
    let positive, negative: [[Double]]

    func phase(_ curve: [Double]) -> Bool? {
      func support(_ rows: [[Double]]) -> Double {
        let scores = rows.map { row in zip(curve, row).reduce(0.0) { $0 + $1.0 * $1.1 } / 2 }
        return scores.sorted(by: >).dropFirst().first ?? -1
      }
      let forward = support(positive), backward = support(negative)
      if backward >= 0.73 && backward - forward >= 0.20 { return false }
      if forward >= 0.90 && forward - backward >= 0.20 { return true }
      return nil
    }
  }
  var direction: Direction? = nil
  static func load(_ url: URL?) -> Self? {
    guard let url, let data = try? Data(contentsOf: url),
          let bank = try? JSONDecoder().decode(Self.self, from: data),
          bank.direction.map({ ($0.positive + $0.negative).allSatisfy { $0.count == 96 && $0.allSatisfy(\.isFinite) } }) != false,
          !bank.positive.isEmpty, !bank.negative.isEmpty,
          (bank.positive + bank.negative).allSatisfy({ $0.count == 8 && $0.allSatisfy(\.isFinite) }) else { return nil }
    return bank
  }
  // Abstain outside the neighbourhood of a reviewed example.
  func intent(_ x: [Double]) -> Bool? {
    func nearest(_ rows: [[Double]]) -> Double {
      rows.map { row in zip(row,x).reduce(0.0) { $0 + pow($1.0-$1.1,2) } / 8 }.min() ?? .infinity
    }
    let yes = nearest(positive), no = nearest(negative)
    if no < 0.055 && no < 0.6*yes { return false }
    if yes < 0.022 && yes < 0.4*no { return true }
    return nil
  }
}

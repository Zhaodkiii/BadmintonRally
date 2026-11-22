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

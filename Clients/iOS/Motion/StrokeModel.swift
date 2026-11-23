import Foundation

/// Optional calibrated prototype model. Training and inference share feature order and units.
struct StrokeModel: Decodable {
  static let columns = ["pitch_change", "yaw_magnitude", "peak_rate", "peak_accel", "duration"]
  let columns: [String]
  let mean, scale: [Double]
  let centers: [String: [Double]]
  let radius: [String: Double]
  static func bundled() -> StrokeModel? {
    guard let url = Bundle.main.url(forResource: "StrokeModel", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let model = try? JSONDecoder().decode(Self.self, from: data),
      model.columns == columns, model.mean.count == columns.count,
      model.scale.count == columns.count,
      model.scale.allSatisfy({ $0 > 0 }),
      model.centers.values.allSatisfy({ $0.count == columns.count })
    else { return nil }
    return model
  }
  func classify(_ feature: [Double]) -> String? {
    let normalized = feature.indices.map { (feature[$0] - mean[$0]) / scale[$0] }
    let distances = centers.map { label, center in
      (label, zip(normalized, center).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) })
    }
    .sorted { $0.1 < $1.1 }
    guard let best = distances.first, let limit = radius[best.0], best.1 <= limit else {
      return nil
    }
    return best.0
  }
}

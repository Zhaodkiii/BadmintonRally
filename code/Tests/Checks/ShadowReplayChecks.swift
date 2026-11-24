import Foundation

/// Replay the unscaled sensor samples and compare the iOS shadow prediction with sklearn.
@main enum ShadowReplayChecks {
  struct Row: Decodable {
    let session: String
    let peak: Double
    let prediction: String?
  }
  static func main() throws {
    let data = URL(fileURLWithPath: CommandLine.arguments[1])
    let run = URL(fileURLWithPath: CommandLine.arguments[2])
    let model = try JSONDecoder().decode(ShadowSVM.self, from: Data(contentsOf: run.appendingPathComponent("SwingShadow.json")))
    let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: run.appendingPathComponent("examples.json")))
    var matched = 0
    for row in rows {
      guard let prediction = row.prediction else { continue }
      let csv = data.appendingPathComponent(row.session + "/samples.csv")
      guard FileManager.default.fileExists(atPath: csv.path) else { continue }
      var history = SwingCurveHistory()
      for line in try String(contentsOf: csv, encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst() {
        let values = line.split(separator: ",").prefix(8).map { Double($0)! }
        if values[1] > row.peak + 0.01 { break }
        if values[1] >= row.peak - 0.4 {
          history.append(values[1], .init(values[2], values[3], values[4]), .init(values[5], values[6], values[7]))
        }
      }
      precondition(model.predict(history.phaseFeatures(at: row.peak)!) == prediction)
      matched += 1
    }
    precondition(matched > 0)
    print("Swift/sklearn predictions matched for all \(matched) held-out specialist strokes")
  }
}

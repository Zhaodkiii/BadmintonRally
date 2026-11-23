import Foundation

/// Check the device implementation against the curves exported by Python for real captures.
@main struct CurveReplayChecks {
  struct Row: Decodable {
    let session: String
    let first, peak: Int
    let curve: [Double]
    let label, split: String
  }
  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let run = URL(fileURLWithPath: CommandLine.arguments[2])
    let model = SwingCurveModel.load(run.appendingPathComponent("SwingCurves.json"))!
    let lines = try String(contentsOf: run.appendingPathComponent("curves.jsonl"), encoding: .utf8)
      .split(separator: "\n")
    var held = 0, correct = 0
    for line in lines {
      let row = try JSONDecoder().decode(Row.self, from: Data(line.utf8))
      let url = root.appendingPathComponent(row.session).appendingPathComponent("samples.csv")
      let records = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
      var history = SwingCurveHistory(), peakAt = 0.0
      for i in row.first...row.peak {
        let v = records[i + 1].split(separator: ",").prefix(8).map { Double($0)! }
        history.append(v[1], .init(v[2], v[3], v[4]), .init(v[5], v[6], v[7]))
        peakAt = v[1]
      }
      let curve = history.curve(at: peakAt)!
      precondition(zip(curve, row.curve).allSatisfy { abs($0 - $1) < 1e-7 })
      if row.split == "test" {
        held += 1
        if model.classify(curve)?.label == row.label { correct += 1 }
      }
      history.append(peakAt + 1, .zero, .zero)
      precondition(history.curve(at: peakAt + 1) == nil)
    }
    print("Verified \(lines.count) Swift curves; held-out label matches \(correct)/\(held)")
  }
}

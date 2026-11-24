import Foundation

// Stream normalized IMU rows from replay_court.py through the shipping match recognizer.
@main enum ReplayCourt {
  static func main() throws {
    guard let model = SwingCurveModel.load(URL(fileURLWithPath: CommandLine.arguments[1])) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let reviewed = ReviewedCourt.load(URL(fileURLWithPath: CommandLine.arguments[1])
      .deletingLastPathComponent().appendingPathComponent("ReviewedCourt.json"))
    var profile: SwingCoach.Profile?
    if CommandLine.arguments.count > 2 {
      let url = URL(fileURLWithPath: CommandLine.arguments[2])
      profile = try JSONDecoder().decode(SwingCoach.Profile.self, from: Data(contentsOf: url))
    }
    let serveBank = ServeIntentBank.load(URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("ServeIntent.json"))
    var coach = SwingCoach()
    var light = false
    while let line = readLine() {
      let fields = line.split(separator: "\t")
      if fields.first == "session" {
        coach = SwingCoach(curveModel: model, reviewedCourt: reviewed, quick: true, profile: profile)
        coach.serveIntentBank = serveBank
        coach.enterCourt(left: fields[2] == "1")
        light = fields[3] == "1"
        print(line)
        continue
      }
      let v = fields.compactMap { Double($0) }
      guard v.count == 11 || v.count == 12 else { throw CocoaError(.fileReadCorruptFile) }
      guard let event = coach.feed(v[0], rotation: .init(v[1], v[2], v[3]),
        acceleration: .init(v[4], v[5], v[6]), gravity: .init(v[7], v[8], v[9]),
        light: light, playing: true, receiving: v[10] != 0, serving: v.count == 12 && v[11] != 0), let peak = coach.candidatePeak else { continue }
      let direction: String
      switch event {
      case .hit(let kind, _, _): direction = kind.rawValue
      case .contact: direction = "方向未定"
      case .message(let reason): direction = reason
      default: continue
      }
      print([String(peak), String(v[0]), direction, coach.impact?.label ?? "",
             String(coach.impact?.power ?? 0)].joined(separator: "\t"))
    }
  }
}

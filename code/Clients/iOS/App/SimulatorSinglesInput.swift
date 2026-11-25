#if DEBUG && (targetEnvironment(simulator) || P006_OFFLINE)
import Foundation

/// A virtual player for full-match recording. Only the match engine can award a point.
final class SimulatorSinglesInput {
  static let seed: UInt64 = 6006
  private var attemptedFlight: Double?
  private var servedPoint: Int?
  private let output: URL
  private var lines = ["event\tpoint\tnear\tfar\tnearServesNext\tgameSeconds\treturns\tdetail"]

  init(output: URL) { self.output = output }

  func record(_ event: String, game: Rally, detail: String) {
    let time = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), game.now)
    let line = [event, String(game.pointCount), String(game.score[0]), String(game.score[1]),
                String(game.playerServes), time, String(game.returns), detail].joined(separator: "\t")
    lines.append(line)
    do {
      try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
    } catch {
      NSLog("P006 failed to save match record: %@", error.localizedDescription)
    }
    NSLog("P006 %@", line)
  }

  func input(for game: Rally) -> ButtonSwing.Hit? {
    if game.phase == .serve && game.playerServes && servedPoint != game.pointCount {
      guard game.now >= 0.65 else { return nil }
      servedPoint = game.pointCount
      return .init(stroke: .lift, aim: 0, impact: .init(power: 0.74, sweep: 0.7,
        serveIntentConfirmed: true, verticalSweep: 0.76), peakTime: game.now)
    }
    guard game.phase == .flight, let f = game.flight, f.incoming,
          attemptedFlight != f.start, let point = game.predictedIntercept else { return nil }
    // One untouched return every six points gives the scorekeeper a no-input control.
    if game.pointCount % 6 == 4 {
      attemptedFlight = f.start
      record("hold", game: game, detail: "withhold press on this incoming flight")
      return nil
    }
    let ball = f.at(game.now)
    guard ball.y >= point.y else { return nil }
    attemptedFlight = f.start
    let aim = game.opponentX >= 0 ? -0.86 : 0.86
    let shot: Stroke = game.returns.isMultiple(of: 3) ? .lift : .drive
    let vertical = shot == .lift ? 0.8 : 0.08
    return .init(stroke: shot, aim: aim, impact: .init(power: 0.8, sweep: 0.76,
      verticalSweep: vertical, lateralSweep: aim), peakTime: game.now)
  }
}
#endif

#if DEBUG && (targetEnvironment(simulator) || P006_OFFLINE)
import Foundation

/// A virtual player for full-match recording. Only the match engine can award a point.
final class SimulatorSinglesInput {
  static let seed: UInt64 = 6006
  private var attemptedFlight: Double?
  private var servedPoint: Int?
  private let output: URL
  private let matchStrokes, coverage, newActions: Bool
  private var fixtureFall = false
  private(set) var completedNewFixtures = false
  private var coverageIndex = 0
  private var preparedPoint: Int?
  private var preparedAt = 0.0
  private var fixtureStroke: MatchStroke?
  private var serveIndex = 0
  private var returnIndex = 0
  private var lines = ["event\tpoint\tnear\tfar\tnearServesNext\tgameSeconds\treturns\tdetail"]

  init(output: URL, matchStrokes: Bool = false, coverage: Bool = false, newActions: Bool = false) {
    self.output = output
    self.matchStrokes = matchStrokes
    self.coverage = coverage
    self.newActions = newActions
  }

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
    NSLog("%@ %@", matchStrokes ? "P035" : "P006", line)
  }

  func prepare(_ game: inout Rally) {
    guard coverage || newActions, game.phase == .serve, preparedPoint != game.pointCount else { return }
    preparedPoint = game.pointCount
    fixtureFall = false
    if newActions && coverageIndex == 2 {
      coverageIndex += 1
      fixtureStroke = nil
      fixtureFall = game.prepareMatchFallFixture()
      record("fixture", game: game, detail: MatchFallEvent.animation)
      return
    }
    if newActions && coverageIndex > 2 { completedNewFixtures = true }
    let cases: [MatchStroke] = newActions ? [.backhandDrive, .backhandRearClear] : MatchStroke.allCases
    guard coverageIndex < cases.count else { fixtureStroke = nil; return }
    let stroke = cases[coverageIndex]
    coverageIndex += 1
    preparedAt = game.now
    fixtureStroke = game.prepareMatchStrokeFixture(stroke) ? stroke : nil
    record("fixture", game: game, detail: stroke.rawValue)
  }

  func input(for game: Rally) -> ButtonSwing.Hit? {
    if game.phase == .serve && game.playerServes && servedPoint != game.pointCount {
      if matchStrokes && !game.matchServeReady { return nil }
      guard game.now >= (fixtureStroke == nil ? 0.65 : preparedAt + 0.4) else { return nil }
      servedPoint = game.pointCount
      if matchStrokes {
        let serves: [MatchStroke] = [.forehandHighServe, .forehandShortServe, .backhandShortServe, .backhandFlickServe]
        let stroke = fixtureStroke ?? serves[serveIndex % serves.count]
        serveIndex += 1
        return Self.hit(stroke, time: game.now)
      }
      return .init(stroke: .lift, aim: 0, impact: .init(power: 0.74, sweep: 0.7,
        serveIntentConfirmed: true, verticalSweep: 0.76), peakTime: game.now)
    }
    guard game.phase == .flight, let f = game.flight, f.incoming,
          attemptedFlight != f.start, let point = game.predictedIntercept else { return nil }
    if fixtureFall {
      guard game.canCommitNetOverreach, f.at(game.now).y < 0.5 else { return nil }
      attemptedFlight = f.start
      return Self.hit(.netKill, time: game.now)
    }
    // One untouched return every six points gives the scorekeeper a no-input control.
    if fixtureStroke == nil && game.pointCount % 6 == 4 {
      attemptedFlight = f.start
      record("hold", game: game, detail: "withhold press on this incoming flight")
      return nil
    }
    let ball = f.at(game.now)
    if matchStrokes, let interceptTime = game.predictedInterceptTime {
      guard game.now >= interceptTime else { return nil }
    } else {
      guard ball.y >= point.y else { return nil }
    }
    attemptedFlight = f.start
    let aim = game.opponentX >= 0 ? -0.86 : 0.86
    if let fixtureStroke { return Self.hit(fixtureStroke, time: game.now) }
    if matchStrokes {
      let options: [MatchStroke]
      switch ball.contactArea {
      case "网前": options = [.netKill, .netPush, .softNet]
      case "中场": options = [.forehandDrive, .backhandDrive, .softBlock]
      default: options = [.clear, .drop, .smash]
      }
      let index = returnIndex
      returnIndex += 1
      let intent = (index.isMultiple(of: 2) ? game.previewMatchStroke : nil) ?? options[index % options.count]
      return Self.hit(intent, time: game.now, aim: aim * 0.6)
    }
    let shot: Stroke = game.returns.isMultiple(of: 3) ? .lift : .drive
    let vertical = shot == .lift ? 0.8 : 0.08
    return .init(stroke: shot, aim: aim, impact: .init(power: 0.8, sweep: 0.76,
      verticalSweep: vertical, lateralSweep: aim), peakTime: game.now)
  }

  private static func hit(_ stroke: MatchStroke, time: Double, aim: Double = 0) -> ButtonSwing.Hit {
    let (kind, power, sweep, vertical): (Stroke, Double, Double, Double) = switch stroke {
    case .forehandHighServe: (.lift, 0.91, 0.79, 0.68)
    case .forehandShortServe: (.drive, 0.14, 0.09, 0.18)
    case .backhandShortServe: (.drive, 0.11, 0.08, 0.27)
    case .backhandFlickServe: (.lift, 0.76, 0.63, 0.44)
    case .netKill: (.smash, 0.66, 0.48, -0.40)
    case .netPush: (.drive, 0.57, 0.50, 0)
    case .softNet: (.drive, 0.23, 0.18, 0.18)
    case .forehandDrive, .backhandDrive: (.drive, 0.60, 0.60, 0.06)
    case .softBlock: (.drive, 0.24, 0.18, 0.04)
    case .clear: (.lift, 0.69, 0.72, 0.55)
    case .backhandRearClear: (.lift, 0.65, 0.69, 0.52)
    case .drop: (.drive, 0.36, 0.25, 0.04)
    case .smash: (.smash, 0.69, 0.72, -0.45)
    }
    return .init(stroke: kind, aim: aim, impact: .init(power: power, sweep: sweep,
                  label: stroke.rawValue, probableBackhand: stroke == .backhandDrive || stroke == .backhandRearClear,
                  verticalSweep: vertical, lateralSweep: aim), peakTime: time)
  }
}
#endif

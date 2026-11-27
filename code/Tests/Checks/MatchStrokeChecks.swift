import Foundation

#if DEBUG && (targetEnvironment(simulator) || P006_OFFLINE)
@main enum MatchStrokeChecks {
  static func main() {
    var covered = Set<MatchStroke>()
    for leftHanded in [false, true] {
      for stroke in MatchStroke.allCases {
        var rally = Rally()
        rally.leftHanded = leftHanded
        rally.usesMatchStrokes = true
        rally.tick(3.1)
        precondition(rally.prepareMatchStrokeFixture(stroke), stroke.rawValue)
        if stroke.isServe {
          let (kind, impact) = input(stroke)
          precondition(rally.swing(kind, aim: 0, impact: impact, confirmedByButton: true) == .locked)
          for _ in 0..<120 where !rally.matchServeReady { rally.tick(1 / 60.0) }
          precondition(rally.matchServeReady)
        }
        if let intercept = rally.predictedInterceptTime {
          while rally.now < intercept { rally.tick(1 / 60.0) }
        }
        let (kind, signal) = input(stroke)
        let timePressed = rally.now
        let decision = rally.swing(kind, aim: 0, impact: signal, confirmedByButton: true) { candidate in
          guard let event = candidate.matchStrokeEvent else { return false }
          return event.stroke == stroke && event.stroke.canReach(event.contact, from: event.feet,
                                                                leftHanded: leftHanded)
        }
        precondition(decision == .accepted, "\(stroke.rawValue) [\(leftHanded)]: \(decision)")
        guard let event = rally.matchStrokeEvent, let flight = rally.flight else { preconditionFailure() }
        precondition(event.stroke == stroke && flight.matchStroke == stroke && event.point == 1)
        precondition(event.contact.coordinates == flight.from.coordinates)
        precondition(flight.netCollision == nil, stroke.rawValue)
        if stroke.isServe {
          precondition(abs(event.time - timePressed - Rally.matchServeLead) < 0.000_001 && event.time == flight.start)
          precondition(flight.at(timePressed).coordinates == flight.from.coordinates)
          precondition(rally.format.legalLanding(flight.to, serverNear: true, serverX: event.feet.x))
        } else {
          precondition(event.time == timePressed && rally.returns == 1)
        }
        precondition(rally.swing(kind, aim: 0, impact: signal, confirmedByButton: true) == .noIncoming)
        covered.insert(event.stroke)
      }
    }
    precondition(covered == Set(MatchStroke.allCases))
    missesKeepIncoming()
    overreachKeepsIncomingAndScore()
    serviceAssistancePreservesFlight()
    collectionDoesNotSelectMatchStroke()
    print("PASS: 14 authored clips × two hands, planned stance, launch, net, serve timing, one press and reject controls")
  }

  private static func serviceAssistancePreservesFlight() {
    for difficulty in [0, 1, 2] {
      for opponentServe in [true, false] {
        var game = Rally()
        game.usesMatchStrokes = true
        game.difficulty = difficulty
        game.tick(3)
        let source = Flight(from: Position(x: 0.335, y: 0.261, z: 0.183),
          to: Position(x: -0.41, y: 0.673), start: game.now, duration: 1.28,
          arc: 0.395, incoming: true, shot: .net, measured: true)
        game.replayRecordedIncoming(source, feet: Position(x: -0.43, y: 0.70),
                                    velocity: .zero, opponentServe: opponentServe)
        guard let live = game.flight else { preconditionFailure() }
        let expected = difficulty <= 1 && opponentServe ? 0.42 : 0
        precondition(abs(live.duration - source.duration - expected) < 1e-8)
        precondition(live.netCollision?.coordinates == source.netCollision?.coordinates)
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
          let a = live.at(live.start + fraction * live.duration)
          let b = source.at(source.start + fraction * source.duration)
          precondition(zip(a.coordinates, b.coordinates).allSatisfy { abs($0-$1) < 1e-8 })
        }
        var precommitSteps = 0
        while game.now < live.start + live.duration {
          if let time = game.bufferedContactTime {
            precondition(difficulty <= 1 && !game.hitWindowOpen && (0.001...0.18).contains(time-game.now))
            precommitSteps += 1
          }
          game.tick(1/60.0)
        }
        precondition((precommitSteps > 0) == (difficulty <= 1))
        precondition(game.bufferedContactTime == nil)
      }
    }
  }

  private static func missesKeepIncoming() {
    var rally = Rally()
    rally.usesMatchStrokes = true
    rally.tick(3.1)
    precondition(rally.prepareMatchStrokeFixture(.netKill))
    let (kind, impact) = input(.netKill)
    precondition(rally.swing(kind, aim: 0, impact: impact, confirmedByButton: true) == .early)
    precondition(rally.flight?.incoming == true && rally.matchStrokeEvent == nil)
    guard let time = rally.predictedInterceptTime else { preconditionFailure() }
    while rally.now < time { rally.tick(1 / 60.0) }
    precondition(rally.swing(kind, aim: 0, impact: impact, confirmedByButton: true) { _ in false } == .outOfReach)
    precondition(rally.flight?.incoming == true && rally.returns == 0 && rally.matchStrokeEvent == nil)

    var low = Rally()
    low.usesMatchStrokes = true
    low.tick(3.1)
    precondition(low.prepareMatchStrokeFixture(.netKill))
    while let flight = low.flight, flight.at(low.now).z > 0.24 || flight.at(low.now).y < 0.5 {
      low.tick(1 / 60.0)
    }
    precondition(low.flight?.incoming == true)
    precondition(low.swing(kind, aim: 0, impact: impact, confirmedByButton: true) == .outOfReach)
    precondition(low.message == "当前拍型够不到" && low.flight?.incoming == true && low.matchStrokeEvent == nil)
  }

  private static func overreachKeepsIncomingAndScore() {
    for leftHanded in [false, true] {
      var game = Rally()
      game.usesMatchStrokes = true
      game.leftHanded = leftHanded
      game.readyToServe()
      precondition(game.prepareMatchFallFixture())
      let incoming = game.flight!
      let (kind, impact) = input(.netKill)
      precondition(game.swing(kind, aim: 0, impact: impact, confirmedByButton: true) { _ in true } == .early)
      precondition(game.matchFallEvent == nil)
      for _ in 0..<100 {
        game.tick(1 / 60.0)
        guard game.canCommitNetOverreach, incoming.at(game.now).y < 0.5 else { continue }
        precondition(game.swing(kind, aim: 0, impact: impact, confirmedByButton: true) { _ in true } == .early)
        break
      }
      precondition(game.matchFallEvent != nil)
      precondition(game.flight?.start == incoming.start && game.flight?.incoming == true)
      precondition(game.returns == 0 && game.score == [0, 0])
      precondition(game.swing(kind, aim: 0, impact: impact, confirmedByButton: true) { _ in true } == .locked)
      for _ in 0..<140 { game.tick(1 / 60.0) }
      precondition(game.pointCount == 1 && game.score == [0, 1])
    }
  }

  private static func collectionDoesNotSelectMatchStroke() {
    var collection = Rally()
    collection.usesMatchStrokes = true
    collection.collectionScene = .serve
    collection.tick(3.1)
    let (kind, impact) = input(.backhandFlickServe)
    precondition(collection.swing(kind, aim: 0, impact: impact, confirmedByButton: true) == .accepted)
    precondition(collection.matchStrokeEvent == nil && collection.flight?.matchStroke == nil)
    precondition(collection.flight?.start == collection.now)
  }

  private static func input(_ stroke: MatchStroke) -> (Stroke, SwingImpact) {
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
    return (kind, SwingImpact(power: power, sweep: sweep, label: stroke.rawValue,
                              probableBackhand: stroke == .backhandDrive || stroke == .backhandRearClear, verticalSweep: vertical))
  }
}
#endif

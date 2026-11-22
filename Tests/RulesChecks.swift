import Foundation

@main enum RulesChecks {
  static func main() {
    precondition(!Rally.won([7, 6]) && Rally.won([8, 6]))
    precondition(!Rally.won([9, 9]) && Rally.won([9, 10]))
    var round = Rally()
    round.tick(3.1)
    round.swing(.smash, aim: 0)
    precondition(round.phase == .serve)
    round.swing(.lift, aim: 0)
    precondition(round.phase == .flight && round.feedback == 1)
    var training = Rally()
    training.practice = true
    training.playerServes = false
    training.drill = .clears
    for _ in 0..<300 { training.tick(0.016) }
    precondition(training.flight?.incoming == true && training.flight?.shot == .clear)
    while let f = training.flight, training.now < f.start + f.duration * 0.83 {
      training.tick(0.01)
    }
    training.toggleNet()
    training.swing(.lift, aim: 0.7)
    precondition(training.lastShot == .net && training.returns == 1)
    training.swing(.smash, aim: 0)
    precondition(training.returns == 1)
    var match = Rally()
    for _ in 0..<30000 {
      match.tick(0.016)
      if match.phase == .serve && match.playerServes { match.swing(.lift, aim: 0) }
      if match.phase == .finished { break }
    }
    precondition(match.phase == .finished && Rally.won(match.score))
    checkTutorial()
    checkTimingAndReplay()
    print(
      "PASS: serve, deuce, cap, practice feeds, net preset, duplicate hit, full match, tutorial progression, timing, replay and net clearance"
    )
  }

  static func checkTutorial() {
    var game = Rally()
    game.practice = true
    game.lessonEnabled = true
    game.playerServes = false
    let sequence: [Stroke] = [.lift, .smash, .drive, .lift]
    for (step, stroke) in sequence.enumerated() {
      for _ in 0..<600 {
        if game.hitWindowOpen { break }
        game.tick(1.0 / 60)
      }
      precondition(game.hitWindowOpen && game.lessonIndex == step)
      if step == 3 { game.toggleNet() }
      game.swing(stroke, aim: 0)
      precondition(game.lessonIndex == step + 1)
    }
    game.tick(2)
    precondition(game.lessonComplete && game.phase == .finished && game.score == [0, 0])
  }

  static func checkTimingAndReplay() {
    var game = Rally()
    game.practice = true
    game.drill = .clears
    game.playerServes = false
    game.offset = 0.20
    for _ in 0..<240 { game.tick(1.0 / 60) }
    guard let incoming = game.flight else { preconditionFailure("Expected an incoming ball") }
    game.swing(.lift, aim: 0)
    precondition(game.message == "挥早了" && game.returns == 0)
    while game.now < incoming.start + incoming.duration + 0.10 { game.tick(1.0 / 120) }
    game.swing(.lift, aim: 0)
    precondition(game.returns == 1)
    guard let outgoing = game.flight else { preconditionFailure("Expected a return") }
    let crossing = (0.5 - outgoing.from.y) / (outgoing.to.y - outgoing.from.y)
    precondition(outgoing.at(outgoing.start + crossing * outgoing.duration).z >= Flight.netHeight)
    game.replayPoint()
    precondition(game.phase == .countdown && game.flight == nil && game.returns == 1)
  }
}

import Foundation

@main enum RulesChecks {
  static func main() {
    precondition(!Rally.won([21, 20]) && Rally.won([22, 20]))
    precondition(!Rally.won([29, 29]) && Rally.won([29, 30]))
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
    checkSwingInterval()
    checkNetTiming()
    checkMeasuredServe()
    checkServiceCourts()
    checkThreeGames()
    checkTutorial()
    checkTimingAndReplay()
    print(
      "PASS: serve, deuce, cap, practice feeds, net preset, duplicate hit, full match, tutorial progression, timing, replay and net clearance"
    )
  }

  static func checkSwingInterval() {
    var game = Rally()
    game.phase = .flight
    game.playerY = 0.58
    game.flight = Flight(from: .init(x: 0, y: 0.4, z: 0.4), to: .init(x: 0, y: 0.6),
                         start: 0, duration: 1, arc: 0.3, incoming: true, shot: .drive)
    while !game.hitWindowOpen {
      game.playerY = 0.58
      game.tick(0.001)
    }
    let crossing = game.now
    game.previewSwing(SwingImpact(power: 0.4, sweep: 0.5))
    precondition(game.flight!.incoming && game.returns == 0)
    game.tick(0.020)
    let impact = SwingImpact(power: 0.7, sweep: 1, followThrough: 0.055)
    let age = game.now - crossing + 0.013
    var stopped = game, tooEarly = game
    precondition(stopped.swing(.drive, aim: 0, age: age, impact: .init(power: 0.7, sweep: 1)) == .early)
    precondition(tooEarly.swing(.drive, aim: 0, age: 0.29, impact: impact) == .early)
    precondition(game.swing(.drive, aim: 0, age: age, impact: impact) == .accepted)
    precondition(game.judgedContactTime! >= crossing - 0.001 && game.swingTime == crossing)
  }

  static func checkNetTiming() {
    func incoming(_ fraction: Double, x: Double = 0) -> Rally {
      var rally = Rally()
      rally.practice = true
      rally.playerServes = false
      rally.drill = .netTiming
      rally.readyToServe()
      rally.tick(0.91)
      let flight = rally.flight!
      for _ in 0..<100 { rally.tick(flight.duration * fraction / 100) }
      rally.playerX = x
      // Record the lateral offset in the same history used for delayed IMU decisions.
      rally.tick(0.00001)
      return rally
    }
    let strong = SwingImpact(power: 1, sweep: 1)
    let soft = SwingImpact(power: 0.1, sweep: 0.2)
    var early = incoming(0.15)
    precondition(early.swing(.smash, aim: 0, impact: strong) == .early && early.flight!.incoming)
    precondition(early.swing(.lift, aim: 0) == .locked)
    var kill = incoming(0.52), touch = kill
    precondition(kill.swing(.smash, aim: 0, impact: strong) == .accepted && kill.lastShot == .smash)
    precondition(kill.flight!.netCollision == nil && kill.flight!.at(kill.now + 0.02).z < kill.flight!.from.z)
    precondition(touch.swing(.lift, aim: 0, impact: soft) == .accepted && touch.lastShot == .net && touch.flight!.netCollision == nil)
    var push = incoming(0.65), stretch = incoming(0.65, x: 0.44)
    precondition(push.swing(.drive, aim: 0, impact: strong) == .accepted)
    precondition(stretch.swing(.drive, aim: 0, impact: strong) == .accepted)
    precondition(stretch.flight!.to.y > push.flight!.to.y && stretch.flight!.netCollision == nil)
    var lift = incoming(0.83), shallow = lift, low = lift, miss = incoming(0.83, x: 0.49)
    precondition(lift.swing(.lift, aim: 0, impact: strong) == .accepted && lift.flight!.netCollision == nil)
    precondition(shallow.swing(.lift, aim: 0, impact: soft) == .accepted && shallow.flight!.netCollision == nil)
    precondition(lift.flight!.to.y < shallow.flight!.to.y)
    precondition(low.swing(.smash, aim: 0, impact: strong) == .accepted && low.flight!.netCollision != nil)
    low.tick(1)
    precondition(low.message == "击球下网" && low.score == [0,1])
    precondition(miss.swing(.smash, aim: 0, impact: soft) == .outOfReach && miss.flight!.incoming)
  }

  static func checkThreeGames() {
    var game = Rally()
    game.gamesToWin = 2
    game.playerServes = false
    game.score = [0, 20]
    for gameNumber in 1...2 {
      game.readyToServe()
      if gameNumber == 2 {
        precondition(game.score == [0, 0] && !game.playerServes)
        game.score = [0, 20]
      }
      game.tick(1)
      game.tick(3)
      precondition(game.gamesWon == [0, gameNumber])
      precondition(game.phase == (gameNumber == 1 ? .point : .finished))
    }
  }

  static func checkMeasuredServe() {
    func serve(_ strength: Double) -> Rally {
      var game = Rally()
      game.readyToServe()
      let impact = SwingImpact(power: strength, sweep: strength, label: "反手短发")
      precondition(game.swing(.drive, aim: 0, impact: impact) == .accepted)
      return game
    }
    for format in [CourtFormat.singles, .doubles] {
      func high(_ power: Double) -> Flight {
        var match = Rally()
        match.format = format
        match.readyToServe()
        let motion = SwingImpact(power: power, sweep: power, label: "正手高远发球")
        precondition(match.swing(.lift, aim: 0, impact: motion) == .accepted)
        return match.flight!
      }
      let soft = high(0.25), full = high(1)
      precondition(full.arc > soft.arc && full.duration > soft.duration && full.to.y < soft.to.y)
      precondition(full.netCollision == nil && format.legalLanding(full.to, serverNear: true, serverX: full.from.x))
    }
    var weak = serve(0)
    let strong = serve(1)
    precondition(weak.flight!.netCollision != nil && strong.flight!.netCollision == nil)
    precondition(weak.flight!.duration > strong.flight!.duration && weak.flight!.to.y > strong.flight!.to.y)
    weak.tick(1)
    precondition(weak.score == [0, 1] && weak.message == "击球下网" && weak.landing?.y == 0.5)
  }

  static func checkServiceCourts() {
    for format in CourtFormat.allCases {
      for points in 0...1 {
        for near in [true, false] {
          var game = Rally()
          game.format = format
          game.score = [points, points]
          game.playerServes = near
          game.readyToServe()
          let x = near ? game.playerX : game.opponentX
          if near { precondition(game.swing(.drive, aim: -1, neutral: true) == .accepted) }
          else { game.tick(1) }
          let serve = game.flight!
          precondition(serve.incoming != near && serve.from.z < 1.15 * Flight.netHeight / 1.55)
          precondition(format.legalLanding(serve.to, serverNear: near, serverX: x))
        }
      }
      precondition(format.legalLanding(.init(x: -format.halfWidth, y: format.backLine), serverNear: true, serverX: 0.4))
      precondition(!format.legalLanding(.init(x: 0.2, y: 0.2), serverNear: true, serverX: 0.4))
    }
    var game = Rally()
    game.format = .doubles
    game.playerServes = false
    game.readyToServe()
    for _ in 0..<400 {
      if game.phase == .point { break }
      game.tick(0.01)
    }
    precondition(game.score == [0, 1] && game.rightPlayer == [0, 1] && game.servicePlayer(1) == 0)
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

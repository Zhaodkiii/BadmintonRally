import Foundation

@main enum ButtonContactChecks {
  static func checkReceivingScenes() {
    for scene in CollectionScene.allCases where scene != .serve {
      var game = Rally()
      game.collectionScene = scene
      game.readyToServe()
      game.tick(0.91)
      let feed = game.flight!
      let contact = game.predictedIntercept!
      precondition(feed.incoming && abs(contact.y - scene.feed!.receiveY) < 0.05)
      if scene.area == .front {
        precondition(game.opponentY <= 0.23 && feed.from.y == game.opponentY)
        precondition(contact.y > 0.50 && contact.y < 0.65)
        precondition(feed.jumpHeightMeters == 0)
      }
      if scene == .netHigh { precondition(contact.z > Flight.netHeight) }
      if scene == .netLow { precondition(contact.z < Flight.netHeight) }
      while game.flight!.at(game.now).y < contact.y { game.tick(0.005) }
      for (stroke, power) in [(Stroke.drive, 0.18), (.smash, 0.85), (.lift, 0.85)] {
        var copy = game
        let impact = SwingImpact(power: power, sweep: power)
        precondition(copy.swing(stroke, aim: 0.4, impact: impact, confirmedByButton: true) == .accepted)
        let reply = copy.flight!
        precondition(!reply.incoming && reply.to.x >= reply.from.x)
        if scene == .defense && stroke == .drive && power == 0.18 {
          precondition(reply.shot == .net && reply.returnedSmash)
          precondition(reply.netCollision == nil && reply.to.y > 0.35)
        }
        if scene == .netLow && stroke == .smash { precondition(reply.netCollision != nil) }
        if scene == .high && stroke == .drive { precondition(reply.shot == .net && reply.netCollision == nil) }
      }
      game.tick(3)
      game.readyToServe()
      game.tick(0.91)
      precondition(game.flight!.to.x == feed.to.x && game.flight!.to.y == feed.to.y)
      game.sceneBlockSize = 1
      game.readyToServe()
      precondition(game.collectionScene != scene && game.collectionScene?.area == scene.area)
    }
  }

  static func checkNetApproach() {
    func reply(load: Double, height: Double, aim: Double) -> Flight {
      var round = Rally()
      round.playerX = 0.34
      round.playerY = 0.65
      round.phase = .flight
      round.flight = Flight(from: .init(x: 0.34,y: 0.61,z: height),to: .init(x: 0.45,y: 0.70),
                            start: 0,duration: 1,arc: 0.25,incoming: true,shot: .weak)
      let impact = SwingImpact(power: 0.6,sweep: 0.6,approachLoad: load,verticalSweep: -0.10)
      precondition(round.swing(.drive,aim: aim,impact: impact,confirmedByButton: true) == .accepted)
      return round.flight!
    }
    let high = reply(load: -2.4,height: 0.44,aim: 0.8)
    precondition(high.shot == .smash && high.netCollision == nil)
    precondition(reply(load: -2.4,height: 0.30,aim: 0.8).netCollision != nil)
    let push = reply(load: -0.6,height: 0.44,aim: 0.8)
    precondition(push.shot == .drive && push.to.x < CourtFormat.singles.halfWidth)
    precondition(reply(load: -0.6,height: 0.44,aim: 0.9).to.x > push.to.x)
  }

  static func checkMeasuredReturns() {
    func sample(_ scene: CollectionScene, _ stroke: Stroke, _ power: Double, _ sweep: Double,
                _ vertical: Double, aim: Double = 0.15, fps: Int = 60, braking: Double? = nil) -> Flight {
      var game = Rally()
      game.collectionScene = scene
      game.intendedReply = "故意设置无关目标"
      game.readyToServe()
      for _ in 0..<(fps*4) {
        game.tick(1/Double(fps))
        if let f = game.flight, let at = game.predictedIntercept, f.at(game.now).y >= at.y {
          let impact = SwingImpact(power:power,sweep:sweep,verticalSweep:vertical,braking:braking)
          precondition(game.swing(stroke,aim:aim,impact:impact,confirmedByButton:true) == .accepted)
          return game.flight!
        }
      }
      preconditionFailure("未能生成接球场景")
    }
    func launchSlope(_ f: Flight) -> Double {
      let next = f.at(f.start + 0.001)
      return (next.z-f.from.z)*1.524/Flight.netHeight / hypot((next.x-f.from.x)*3.05,(next.y-f.from.y)*13.4)
    }
    for fps in [30,60,120] {
      let kill = sample(.netHigh,.smash,0.78,0.30,-0.77,fps:fps)
      let push = sample(.netHigh,.drive,0.54,0.65,0.07,fps:fps)
      let touch = sample(.netHigh,.drive,0.16,0.15,0.13,fps:fps)
      precondition((1.85...1.98).contains(kill.from.z*1.524/Flight.netHeight))
      precondition(kill.netCollision == nil && push.netCollision == nil && touch.netCollision == nil)
      precondition(launchSlope(kill) < launchSlope(push) && push.to.y < touch.to.y)
      let tap = sample(.halfHigh,.smash,0.64,0.28,-0.61,fps:fps)
      let attack = sample(.halfHigh,.smash,0.86,0.84,-0.77,fps:fps)
      precondition(tap.netCollision == nil && tap.to.y > attack.to.y)
      precondition(sample(.netLow,.smash,0.80,0.80,-0.78,fps:fps).netCollision != nil)
      let block = sample(.flat,.drive,0.50,0.27,0.12,fps:fps,braking:0.65)
      let drive = sample(.flat,.drive,0.50,0.27,0.12,fps:fps,braking:0.05)
      precondition(block.shot == .net && block.netCollision == nil && drive.shot == .drive)
    }
  }

  static func main() {
    checkMeasuredReturns()
    checkNetApproach()
    let feet = Position(x: 0,y: 0.62)
    let high = Position(x: 0,y: 0.58,z: 2.64 * Flight.netHeight / 1.524)
    for shot in [Shot.net, .drive, .clear] {
      precondition(Flight.attackingJump(shot: shot, contact: high, feet: feet, strength: 1) == 0)
    }
    precondition(Flight.attackingJump(shot: .smash, contact: high, feet: feet, strength: 0.9) > 0)
    precondition(Flight.attackingJump(shot: .smash, contact: high, feet: Position(x:0.8,y:0.62), strength: 1) == 0)
    checkReceivingScenes()
    var input = ButtonSwing()
    let tap = input.press(0, left: false, serving: true, bank: nil, intent: nil)
    var game = Rally()
    game.readyToServe()
    precondition(tap.impact.strength == 0)
    precondition(game.swing(tap.stroke, aim: tap.aim, impact: tap.impact, confirmedByButton: true) == .accepted)
    precondition(game.swing(tap.stroke, aim: tap.aim, impact: tap.impact, confirmedByButton: true) == .noIncoming)
    for i in 1...30 {
      let rate = i <= 14 ? -20.0 : 5.0
      input.append(Double(i)/100, .init(rate,0,0), .init(0,0,1), .init(0,0,-1))
    }
    // A much stronger backswing precedes the upward stroke at contact.
    let hit = input.press(0.30, left: false, serving: false, bank: nil, intent: nil)
    precondition(hit.stroke == .lift && hit.impact.strength > tap.impact.strength)
    precondition(input.press(0.31, left: false, serving: false, bank: nil, intent: nil).impact.strength == 0)
    game.flight = Flight(from: .init(x: -0.8,y: 0.1,z: 0.5), to: .init(x: 0.9,y: 0.99),
                         start: game.now, duration: 1, arc: 0.2, incoming: true, shot: .drive)
    precondition(!game.hitWindowOpen)
    precondition(game.swing(hit.stroke, aim: hit.aim, impact: hit.impact, confirmedByButton: true) == .early)
    precondition(game.flight?.incoming == true && game.returns == 0)
    for style in ServeTraining.allCases {
      for format in [CourtFormat.singles, .doubles] {
        func target(_ effort: Double, _ aim: Double) -> Position {
          var round = Rally()
          round.format = format
          round.collectionScene = .serve
          round.serveTraining = style
          round.readyToServe()
          let impact = SwingImpact(power: effort, sweep: effort, serveIntentConfirmed: true)
          precondition(round.swing(.drive, aim: aim, impact: impact, confirmedByButton: true) == .accepted)
          return round.flight!.to
        }
        let short = target(0,0), middle = target(0.5,0), deep = target(1,0)
        precondition(abs(middle.y - (short.y + deep.y) / 2) < 0.000001 && deep.y < middle.y)
        precondition(target(0.5,-1).x < middle.x && target(0.5,1).x > middle.x)
        precondition(format.legalLanding(target(1,-1), serverNear: true, serverX: 0.43))
      }
    }
    print("PASS: stationary contact, outbound duplicate, stronger backswing, consumed samples, early incoming return")
  }
}

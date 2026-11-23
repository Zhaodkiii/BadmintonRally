import Foundation

@main enum ButtonContactChecks {
  static func main() {
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
    precondition(game.swing(hit.stroke, aim: hit.aim, impact: hit.impact, confirmedByButton: true) == .accepted)
    precondition(game.flight?.incoming == false && game.returns == 1)
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

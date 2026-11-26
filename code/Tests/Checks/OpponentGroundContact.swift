import Foundation

@main enum OpponentGroundContact {
  static func main() {
    let flight = Flight(from: Position(x: 0, y: 0.75, z: 0.4),
                        to: Position(x: 0, y: 0.16), start: 0, duration: 1,
                        arc: 0.32, incoming: false, shot: .drive)
    // Keep the receiver within lateral/depth reach in all three cases.
    // At 60 Hz a landing may coincide with a tick or fall between two ticks.
    for time in [0.99, 1.0, 1.01] {
      var game = Rally()
      game.phase = .flight
      game.opponentY = 0.16
      game.flight = flight
      game.now = time - 1.0 / 60
      game.tick(1.0 / 60)
      if time < 1 {
        precondition(game.flight?.incoming == true && game.score == [0, 0])
        precondition(abs(game.flight!.from.z - flight.at(time).z) < 1e-8)
      } else {
        precondition(game.phase == .point && game.flight == nil && game.score == [1, 0])
      }
    }
    print("PASS: airborne low return, exact landing, tick crossing landing")
  }
}

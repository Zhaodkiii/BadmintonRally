import Foundation
import SceneKit
import simd

/// Samples the on-court character nodes at simulation ticks, in world metres.
/// Run code/Tools/check_receive_continuity.sh from any working directory.
@main enum ReceiveContinuity {
  static let parts = ["MatchJersey", "Head", "RacketHand", "StringBed", "CourtShoeUpper"]

  static func main() throws {
    var game = Rally()
    game.readyToServe()
    game.seedSimulatorMatch(SimulatorSinglesInput.seed)
    let bot = SimulatorSinglesInput(output: URL(fileURLWithPath: CommandLine.arguments[1]))
    let court = CourtScene()
    court.cameraAspect = 1320.0 / 610.0
    let near = court.scene.rootNode.childNode(withName: "V2Player", recursively: true)!
    let nodes = parts.map { near.childNode(withName: $0, recursively: true)! }
    var previous: [SIMD3<Float>] = []
    var previousInFlight = false
    var measured: [[Float]] = Array(repeating: [], count: nodes.count)
    var sampled = Set<Int>()
    var lastStep = 0

    for step in 0...15000 {
      if step > 0 {
        game.tick(1.0 / 60.0)
        if let input = bot.input(for: game) {
          _ = game.swing(input.stroke, aim: input.aim, impact: input.impact, confirmedByButton: true) {
            court.canContact($0, left: false)
          }
        }
      }
      court.update(game, reduced: false, left: false)
      let current = nodes.map { $0.simdWorldPosition }
      let inFlight = game.phase == .flight
      if inFlight && previousInFlight {
        let displacement = zip(current, previous).map { simd_distance($0.0, $0.1) }
        for j in nodes.indices { measured[j].append(displacement[j]) }

        // Reacquisition of a wide feed, then two consecutive wobbling frames
        // on the next incoming shuttle in the same long rally.
        if [3803,4219,4220].contains(step) {
          precondition(game.score == [9,3] && game.flight?.incoming == true)
          let limits: [Float] = step == 3803
            ? [0.16, 0.16, 0.24, 0.24, 0.12] : [0.09, 0.09, 0.09, 0.09, 0.10]
          for j in nodes.indices {
            precondition(displacement[j] <= limits[j],
                         "9:3 step \(step) \(parts[j]) moved \(displacement[j]) m")
          }
          print("9:3 step",step,displacement)
          sampled.insert(step)
        }
      }
      previous = current
      previousInFlight = inFlight
      lastStep = step
      if game.phase == .finished { break }
    }
    precondition(game.phase == .finished && game.score == [21,5] && lastStep == 8816)
    precondition(sampled.count == 3 && measured[0].count == 6582)
    // A normal fast stroke may travel farther than a waiting racket.
    // Use whole-match percentiles in addition to the exact preparation frames.
    let p95Limits: [Float] = [0.09, 0.10, 0.16, 0.16, 0.10]
    for j in nodes.indices {
      let sorted = measured[j].sorted()
      let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
      precondition(p95 <= p95Limits[j], "\(parts[j]) P95 rose to \(p95) m")
      print(parts[j],"P95",p95,"m")
    }
    print("21:5,",lastStep + 1,"ticks,",measured[0].count,"consecutive flight frames")
  }
}

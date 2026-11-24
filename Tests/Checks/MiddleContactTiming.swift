import Foundation
import simd

/// Compile with Rally.swift, ReturnMotion.swift and SpatialCourt.swift on macOS.
/// Outputs one CSV row per synthetic button press, including off-schedule contacts.
@main enum MiddleContactTiming {
  private typealias Trial = (name: String, scene: CollectionScene, stroke: Stroke,
                             power: Double, vertical: Double, aim: Double, sweep: Double)
  private static let trials: [Trial] = [
    ("正手平抽",.flat,.drive,0.71,0.02,0.18,0.72), ("反手平抽",.flat,.drive,0.68,0.03,0.18,0.70),
    ("减力挡网",.flat,.drive,0.20,0.12,0.10,0.12), ("接杀挡网",.defense,.drive,0.19,0.13,0.10,0.14),
    ("接杀挑高",.defense,.lift,0.79,0.82,0.10,0.74), ("接杀反抽",.defense,.drive,0.83,0.06,-0.40,0.84),
    ("点杀",.halfHigh,.smash,0.64,-0.61,0.14,0.28), ("下压突击",.halfHigh,.smash,0.86,-0.77,0.32,0.84),
    ("轻吊",.halfHigh,.drive,0.22,-0.15,0.22,0.26)
  ]
  static func main() {
    print("回法,左手,偏移ms,识别,触球高度m,握点跳变cm,拍头误差cm,过网")
    for trial in trials {
      for left in [false,true] {
        for ms in [-100,-50,0,50,100] { measure(trial, left:left, offset:ms) }
      }
    }
  }
  private static func measure(_ t: Trial, left: Bool, offset: Int) {
    let court = CourtScene(), dt = 1.0/60
    var game = Rally(), contactTime: Double?
    game.leftHanded = left
    game.collectionScene = t.scene
    game.readyToServe()
    for _ in 0..<280 {
      let previous = court.nearArmPoints()[1]
      game.tick(dt)
      if let f = game.flight, f.incoming, let point = game.predictedIntercept {
        if contactTime == nil {
          var lo = f.start, hi = lo + f.duration
          for _ in 0..<24 {
            let mid = (lo+hi)/2
            if f.at(mid).y < point.y { lo = mid } else { hi = mid }
          }
          contactTime = (lo+hi)/2 + Double(offset)/1000
        }
        if let at = contactTime, game.now + dt/2 >= at {
          let aim = t.aim * (left ? -1.0 : 1.0)
          let input = SwingImpact(power:t.power,sweep:t.sweep,probableBackhand:t.name == "反手平抽",
                                  verticalSweep:t.vertical,lateralSweep:aim)
          let decision = game.swing(t.stroke,aim:aim,impact:input,confirmedByButton:true)
          precondition(decision == .accepted)
          court.update(game,reduced:false,left:left)
          let result = game.flight!
          let distance = simd_distance(previous,court.nearArmPoints()[1])
          let fields = [t.name,String(left),String(offset),game.returnDescription(incoming:f,outgoing:result),
                        String(result.from.z*1.524/Flight.netHeight),String(distance*100),
                        String(court.nearRacketError(to:result.from)*100),String(result.netCollision == nil)]
          print(fields.joined(separator:","))
          return
        }
      }
      court.update(game,reduced:false,left:left)
    }
    preconditionFailure("未能安排中场按键测试")
  }
}

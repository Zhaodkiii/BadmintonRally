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
    print("回法,左手,偏移ms,识别,触球高度m,握点跳变cm,拍头误差cm,过网,出球时间误差ms,出球位置误差mm,出射仰角度,出球初速mps,网顶余量m,距网终止深度m,横向终点m,最高m,全程秒")
    verifyLowDownwardFault()
    for trial in trials {
      for left in [false,true] {
        for ms in [-100,-50,0,50,100] { measure(trial, left:left, offset:ms) }
      }
    }
  }
  private static func verifyLowDownwardFault() {
    var game = Rally()
    game.phase = .flight
    game.flight = Flight(from:Position(x:0.32,y:0.66,z:0.225),to:Position(x:0.45,y:0.88),
                         start:0,duration:0.6,arc:0.12,incoming:true,shot:.smash)
    let input = SwingImpact(power:0.78,sweep:0.72,verticalSweep:-0.82)
    var distant = game
    precondition(distant.swing(.smash,aim:0.1,impact:input,confirmedByButton:true) == .outOfReach,
                 "原站位应判为超出触达范围")
    precondition(distant.flight?.incoming == true, "够不到时来球应继续飞行")

    game.playerX = 0.32
    game.playerY = 0.70
    precondition(game.swing(.smash,aim:0.1,impact:input,confirmedByButton:true) == .accepted)
    precondition(game.flight?.netCollision != nil, "低点下压应该允许撞网")
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
          func metres(_ p: Position) -> SIMD3<Double> {
            SIMD3(p.x*3.05,p.y*13.4,p.z*1.524/Flight.netHeight)
          }
          let delta = 0.001
          let velocity = (metres(result.at(result.start+delta))-metres(result.from))/delta
          let elevation = atan2(velocity.z,hypot(velocity.x,velocity.y))*180/Double.pi
          let launchError = simd_distance(metres(f.at(game.now)),metres(result.at(result.start)))
          var lo = result.start, hi = lo + result.duration
          for _ in 0..<30 {
            let mid = (lo+hi)/2
            if result.at(mid).y > 0.5 { lo = mid } else { hi = mid }
          }
          let crossingTime = (lo+hi)/2
          let clearance = metres(result.at(crossingTime)).z-1.524
          precondition((clearance > 0) == (result.netCollision == nil))
          if t.name == "接杀挡网" && offset == -50 {
            precondition((0.625...0.690).contains(result.from.y), "测试未覆盖网前至中场过渡段")
            precondition(clearance > 0.01, "有意的开放拍面在跨区时缺少过网余量")
          }
          let stopTime = result.netCollision == nil ? result.start + result.duration : crossingTime
          let endpoint = result.at(stopTime)
          let apex = (0...240).map { metres(result.at(result.start+(stopTime-result.start)*Double($0)/240)).z }.max()!
          var fields = [t.name,String(left),String(offset),game.returnDescription(incoming:f,outgoing:result),
                        String(result.from.z*1.524/Flight.netHeight),String(distance*100),
                        String(court.nearRacketError(to:result.from)*100),String(result.netCollision == nil)]
          fields += [String((result.start-game.now)*1000),String(launchError*1000),String(elevation),
                     String(simd_length(velocity)),String(clearance),String((0.5-endpoint.y)*13.4),
                     String(endpoint.x*3.05),String(apex),String(stopTime-result.start)]
          print(fields.joined(separator:","))
          return
        }
      }
      court.update(game,reduced:false,left:left)
    }
    preconditionFailure("未能安排中场按键测试")
  }
}

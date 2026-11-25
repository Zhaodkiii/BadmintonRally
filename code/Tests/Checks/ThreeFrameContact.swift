import Foundation
import SceneKit
import simd

/// Run on macOS with Rally.swift, ReturnMotion.swift and SpatialCourt.swift.
/// Coordinates are SceneKit world metres. This samples the production scene graph.
@main enum ThreeFrameContact {
  typealias Point = SIMD3<Float>
  static let dt = 1.0 / 60

  struct Nodes {
    let bed, cork, upperArm, hand: SCNNode
    let a, b, corkRadius: Float

    init(_ court: CourtScene) {
      let root = court.scene.rootNode
      bed = root.childNode(withName: "StringBed", recursively: true)!
      hand = root.childNode(withName: "RacketHand", recursively: true)!
      upperArm = root.childNode(withName: "RacketUpperArm", recursively: true)!
      // Identify the shuttle by its cork-and-skirt geometry, independently of names.
      let shuttles = root.childNodes.filter { node in
        node.childNodes.contains { $0.geometry is SCNCone } &&
        node.childNodes.contains { $0.geometry is SCNSphere }
      }
      precondition(shuttles.count == 1)
      cork = shuttles[0].childNodes.first { $0.geometry is SCNSphere }!
      corkRadius = Float((cork.geometry as! SCNSphere).radius)
      let rim = bed.geometry as! SCNTorus
      let inner = Float(rim.ringRadius - rim.pipeRadius)
      a = inner * simd_length(bed.simdConvertVector(Point(1,0,0), to: nil))
      b = inner * simd_length(bed.simdConvertVector(Point(0,0,1), to: nil))
    }

    /// Distance from a point to the filled elliptical string-bed disk. For a point
    /// outside the projected ellipse solve its closest boundary point by bisection.
    func sample() -> (values: [String], gap: Float) {
      let ball = cork.simdWorldPosition, center = bed.simdWorldPosition
      let xAxis = simd_normalize(bed.simdConvertVector(Point(1,0,0), to: nil))
      let zAxis = simd_normalize(bed.simdConvertVector(Point(0,0,1), to: nil))
      let normal = simd_normalize(simd_cross(zAxis, xAxis))
      let offset = ball - center
      let x = abs(simd_dot(offset, xAxis)), z = abs(simd_dot(offset, zAxis))
      let plane = simd_dot(offset, normal)
      var lateral: Float = 0
      if x*x/(a*a) + z*z/(b*b) > 1 {
        var lo: Float = 0, hi = max(a,b) * hypot(x,z)
        for _ in 0..<32 {
          let mid = (hi + lo) / 2
          let u = a*x/(mid + a*a), v = b*z/(mid + b*b)
          if u*u + v*v > 1 { lo = mid } else { hi = mid }
        }
        lateral = hypot(x - a*a*x/(hi + a*a), z - b*b*z/(hi + b*b))
      }
      let gap = hypot(lateral, plane) - corkRadius
      let shoulder = upperArm.simdConvertPosition(Point(0,-0.5,0), to: nil)
      let elbow = upperArm.simdConvertPosition(Point(0,0.5,0), to: nil)
      let vectors = [ball, center, normal, xAxis*a, zAxis*b, shoulder, elbow, hand.simdWorldPosition]
      let coordinates = vectors.flatMap { [$0.x,$0.y,$0.z] }
      let metrics = [a, b, corkRadius, simd_length(offset), plane, lateral, gap]
      return ((coordinates + metrics).map { String($0) }, gap)
    }
  }

  static func run(left: Bool, offset: Int, miss: Bool) -> Bool {
    let court = CourtScene(), nodes = Nodes(court)
    var game = Rally(), target: Double?, previous: [String]?
    var previousWrist = Point.zero, previousElbow = Point.zero
    game.leftHanded = left
    game.collectionScene = .flat
    game.readyToServe()
    let id = "flat-backhand-\(left ? "L" : "R")-\(offset)-\(miss ? "far" : "regular")"
    func fields(_ frame: Int) -> ([String], Float) {
      let sample = nodes.sample()
      return ([id, String(frame), String(game.now), String(game.flight!.incoming), String(game.returns)] + sample.values, sample.gap)
    }
    for _ in 0..<280 {
      game.tick(dt)
      if let incoming = game.flight, incoming.incoming, let intercept = game.predictedIntercept {
        if target == nil {
          var lo = incoming.start, hi = lo + incoming.duration
          for _ in 0..<24 {
            let mid = (lo+hi)/2
            if incoming.at(mid).y < intercept.y { lo = mid } else { hi = mid }
          }
          target = (lo+hi)/2 + Double(offset)/1000
        }
        // Isolate a deliberately unreachable station on the same incoming path.
        if miss { game.playerX = left ? 0.97 : -0.97; game.playerY = 0.98 }
        if game.now + dt/2 >= target! {
          let aim = left ? -0.18 : 0.18
          let impact = SwingImpact(power:0.68,sweep:0.70,probableBackhand:true,
                                   verticalSweep:0.03,lateralSweep:aim)
          let countBefore = game.returns
          #if BASELINE_CONTACT
          let decision = game.swing(.drive,aim:aim,impact:impact,confirmedByButton:true)
          #else
          let decision = game.swing(.drive,aim:aim,impact:impact,confirmedByButton:true,
                                    validateContact: { court.canContact($0,left:left) })
          #endif
          court.update(game,reduced:false,left:left)
          let (current, gap) = fields(0)
          let wrist = nodes.hand.simdWorldPosition
          let elbow = nodes.upperArm.simdConvertPosition(Point(0,0.5,0), to:nil)
          game.tick(dt)
          if miss { game.playerX = left ? 0.97 : -0.97; game.playerY = 0.98 }
          court.update(game,reduced:false,left:left)
          let (next, nextGap) = fields(1)
          for row in [previous!,current,next] {
            print((row + [decision.rawValue]).joined(separator:","))
          }
          // Screen this fixed 60 Hz backhand for one-frame discontinuities.
          // 20 cm leaves margin over the unchanged adjacent accepted controls.
          let nextElbow = nodes.upperArm.simdConvertPosition(Point(0,0.5,0), to:nil)
          let steps = [simd_distance(previousWrist,wrist), simd_distance(wrist,nodes.hand.simdWorldPosition),
                       simd_distance(previousElbow,elbow), simd_distance(elbow,nextElbow)]
          if !miss && steps.contains(where: { $0 > 0.20 }) { return false }
          if miss || offset == -100 {
            let expected = incoming.at(game.now), actual = game.flight!.at(game.now)
            let preserved = actual.x == expected.x && actual.y == expected.y && actual.z == expected.z
            return decision == .outOfReach && current[3] == "true" && next[3] == "true" &&
              game.returns == countBefore && preserved && gap > 0 && nextGap > 0
          }
          return decision == .accepted && current[3] == "false" &&
            game.returns == countBefore + 1 && gap <= 0.0001
        }
      }
      court.update(game,reduced:false,left:left)
      if game.flight?.incoming == true {
        previous = fields(-1).0
        previousWrist = nodes.hand.simdWorldPosition
        previousElbow = nodes.upperArm.simdConvertPosition(Point(0,0.5,0), to:nil)
      }
    }
    return false
  }

  static func main() {
    let components = ["cork","bed","normal","innerAcross","innerAlong","shoulder","elbow","wrist"]
      .flatMap { p in ["x","y","z"].map { p + "_" + $0 } }
    let metrics = ["innerHalfWidth_m","innerHalfLength_m","corkRadius_m","centerDistance_m",
                   "signedPlane_m","outsideEllipse_m","corkDiskGap_m","decision"]
    print((["case","frame","gameTime_s","incoming","returns"] + components + metrics).joined(separator:","))
    var passed = true
    for left in [false,true] {
      for offset in [-100,-50,0] {
        if !run(left:left,offset:offset,miss:false) {
          FileHandle.standardError.write(Data("Failed regular left=\(left), offset=\(offset) ms\n".utf8))
          passed = false
        }
      }
      if !run(left:left,offset:0,miss:true) {
        FileHandle.standardError.write(Data("Failed out-of-reach left=\(left)\n".utf8))
        passed = false
      }
    }
    if !passed { exit(1) }
  }
}

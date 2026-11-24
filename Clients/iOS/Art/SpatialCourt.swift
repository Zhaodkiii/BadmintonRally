import SceneKit
import SwiftUI

// Game coordinates map to metres once. SceneKit owns only the presentation.
private typealias V = SIMD3<Float>
private func world(_ p: Position) -> V {
  V(Float(p.x * 3.05), Float(p.z * 1.524 / Flight.netHeight), Float((p.y - 0.5) * 13.4))
}

#if os(macOS)
private typealias UIColor = NSColor
#else
struct SpatialCourt: UIViewRepresentable {
  let game: Rally
  let reduced, leftHanded: Bool
  func makeCoordinator() -> CourtScene { CourtScene() }
  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.scene = context.coordinator.scene
    view.pointOfView = context.coordinator.camera
    view.antialiasingMode = .multisampling2X
    view.isUserInteractionEnabled = false
    return view
  }
  func updateUIView(_ view: SCNView, context: Context) {
    context.coordinator.update(game, reduced: reduced, left: leftHanded)
    view.setNeedsDisplay()
  }
}

#endif

private func mesh(_ shape: SCNGeometry, _ color: UIColor, _ parent: SCNNode, _ at: V = .zero) -> SCNNode {
  let mat = SCNMaterial()
  mat.diffuse.contents = color
  shape.materials = [mat]
  let node = SCNNode(geometry: shape)
  parent.addChildNode(node)
  node.simdPosition = at
  return node
}

private func link(_ node: SCNNode, _ a: V, _ b: V) {
  let delta = b - a
  let length = simd_length(delta)
  node.simdPosition = (a+b)*0.5
  node.simdScale.y = max(length, 0.001)
  if length > 0.001 { node.simdOrientation = simd_quatf(from: V(0,1,0), to: delta/length) }
}

private final class CourtPlayer {
  let root = SCNNode()
  var groundShadow: SCNNode?
  private let limbs: [SCNNode]
  private let torso, head, hair: SCNNode
  private let shoes: [SCNNode]
  private let rim, grip, palm, thumb, elbowJoint, wristJoint: SCNNode
  private var localContact = V.zero
  private var latestContact = -Double.infinity
  private var armTime: Double?
  private var gripAxis: V?
  private var rearTurn: Float = 0
  private var crossBodyTurn: Float = 0
  private var supportShift: Float = 0
  private var gripRoll: Float = 0
  private var elbowPlane: V?
  private var lastHand: Float = 0
  private var stridePhase: Float = 0
  private var previous: V?
  private var planted: [V?] = [nil,nil]
  private var launchTime = -Double.infinity
  private var launchSpeed: Float = 0
  private var jumpedFlight = -Double.infinity
  init(_ parent: SCNNode, _ shirt: UIColor) {
    parent.addChildNode(root)
    let skin = UIColor(red: 0.83, green: 0.59, blue: 0.43, alpha: 1)
    torso = mesh(SCNCapsule(capRadius: 0.21, height: 0.65), shirt, root, V(0,1.12,0))
    torso.simdScale.z = 0.72
    head = mesh(SCNSphere(radius: 0.12), skin, root, V(0,1.62,0))
    hair = mesh(SCNSphere(radius: 0.115), .darkGray, root, V(0,1.665,0.015))
    let skeleton = root
    limbs = [0.09,0.065,0.09,0.065,0.055,0.045,0.006,0.055,0.045].enumerated().map {
      mesh(SCNCylinder(radius: $0.element, height: 1), [0,2].contains($0.offset) ? .darkGray : $0.offset == 6 ? .white : skin, skeleton)
    }
    shoes = [-1,1].map { _ in mesh(SCNBox(width:0.115,height:0.085,length:0.25,chamferRadius:0.035),.white,skeleton) }
    elbowJoint = mesh(SCNSphere(radius:0.051),skin,root)
    wristJoint = mesh(SCNSphere(radius:0.036),skin,root)
    grip = mesh(SCNCylinder(radius:0.017,height:1),.darkGray,root)
    palm = mesh(SCNSphere(radius:0.046),skin,root)
    thumb = mesh(SCNSphere(radius:0.021),skin,root)
    rim = mesh(SCNTorus(ringRadius: 0.14, pipeRadius: 0.009), .systemMint, root)
    rim.simdScale = V(0.76,1,1)
    for k in -2...2 {
      let offset = Float(k)*0.045
      let span = sqrt(0.14*0.14-offset*offset)
      let warp = mesh(SCNCylinder(radius:0.004,height:1),.white,rim)
      let weft = mesh(SCNCylinder(radius:0.004,height:1),.white,rim)
      link(warp,V(offset,0,-span),V(offset,0,span))
      link(weft,V(-span,0,offset),V(span,0,offset))
    }
  }
  #if os(macOS)
  var legLengths: [Float] { limbs.prefix(4).map { $0.simdScale.y } }
  var armPoints: [V] {
    let elbow = limbs[4].simdPosition + limbs[4].simdOrientation.act(V(0,limbs[4].simdScale.y/2,0))
    return [elbow,palm.simdPosition,rim.simdPosition]
  }
  #endif
  var tipInWorld: V { root.simdPosition + rim.simdPosition }
  func pose(_ feet: V, side: Float, facing: Float, now: Double, elapsed: Double,
            stroke: Stroke, impact: SwingImpact?, incoming: Flight?, outgoing: Flight?, intercept: Position?, still: Bool) {
    let interval = now - (armTime ?? now)
    let continuous = armTime != nil && interval >= 0 && interval < 0.15 &&
      lastHand == side && !still && simd_distance(feet,previous ?? feet) < 0.6
    armTime = now
    lastHand = side
    let frameTime = Float(max(0,interval))
    let delta = feet - (previous ?? feet)
    let distance = simd_length(delta)
    previous = feet
    stridePhase += min(0.35,distance)*8
    var readyHeight: Float = 0
    if let incoming {
      let soon = world(incoming.at(now + 0.18)) - feet
      let groundDistance = hypot(soon.x,soon.z)
      if soon.z*facing > -0.15, groundDistance < 1.45,
         now + 0.18 <= incoming.start + incoming.duration {
        readyHeight = soon.y
      }
    }
    var windup: Float = 0
    var tracksArrival = false
    var interceptLead: Float?
    var preparationPoint = incoming == nil ? nil : intercept
    if let f = incoming, let intercept, !still {
      // Solve the arrival time on the same drag curve that draws the shuttle.
      var lo = f.start, hi = f.start + f.duration
      for _ in 0..<11 {
        let mid = (lo + hi) / 2
        if (f.at(mid).y < intercept.y) == (f.to.y > f.from.y) { lo = mid } else { hi = mid }
      }
      let lead = Float(hi-now)
      let target = world(intercept)-feet
      let rearCourt = abs(intercept.y-0.5) > 0.30
      let middleCourt = (0.15...0.30).contains(abs(intercept.y-0.5))
      tracksArrival = rearCourt || middleCourt
      let stillReachable = tracksArrival && now <= f.start+f.duration &&
        simd_length(world(f.at(now))-feet-V(0,1,0)) < 1.8
      if (lead >= -0.06 || stillReachable) && lead < 0.42 && hypot(target.x,target.z) < 1.55 {
        interceptLead = lead
        if tracksArrival {
          // Intercept anchors the feet. As the shuttle enters arm's reach,
          // prepare at its actual height and depth instead of the nominal point.
          let anticipation = middleCourt ? 0.86 : 0.50
          let ahead = min(1.0/30,Double(frameTime))*anticipation
          let arrival = now+Double(lead)
          preparationPoint = f.at(max(now+ahead,arrival-(middleCourt ? 0.10 : 0.09)))
        }
        readyHeight = preparationPoint.map { world($0).y } ?? target.y
        windup = min(1,max(0,(0.42-lead)/0.26))
        let height = min(0.34,max(0,target.y-2.26))
        let v = sqrt(2*9.81*height)
        if height > 0.07, lead >= 0, lead <= v/9.81, jumpedFlight != f.start {
          launchSpeed = v; launchTime = now; jumpedFlight = f.start
        }
      }
    }
    let age = Float(now-launchTime)
    let airtime = 2*launchSpeed/9.81
    let airPhase = airtime > 0 ? min(1,max(0,age/airtime)) : 0
    let lift: Float = !still && age >= 0 && age < airtime ? age*(launchSpeed-4.905*age) : 0
    let amplitude = launchSpeed*launchSpeed/19.62
    let landingAge = age-airtime
    let contactAge = outgoing.map { now-$0.start }
    let confirmed = contactAge.map { $0 >= 0 && $0 < 0.55 } ?? false
    let supportPhase = confirmed ? max(0, 1 - max(0, Float(contactAge!) - 0.07)/0.28) : windup
    let crouch: Float = !still && landingAge >= 0 && landingAge < 0.18
      ? amplitude*0.35*sin(.pi*landingAge/0.18) : (lift == 0 ? 0.065*supportPhase : 0)
    groundShadow?.simdPosition = feet + V(0,0.012,0)
    root.simdPosition = feet + V(0,lift,0)
    let step = distance > 0.0001 && !still ? sin(stridePhase)*0.22 : 0
    let travel = distance > 0.0001 ? delta/distance : V(0,0,facing)
    let clock = contactAge.map { Float($0) + 0.14 } ?? Float(elapsed)
    let active = clock >= 0 && clock < (confirmed ? 0.69 : 0.54)
    let high = confirmed ? world(outgoing!.from).y > 1.95 : readyHeight > 1.95 || lift > 0
    let low = confirmed ? world(outgoing!.from).y < 1.05 : readyHeight > 0 && readyHeight < 1.05
    let atNet = confirmed && abs(outgoing!.from.y - 0.5) <= 0.15
    let spot = confirmed ? outgoing?.from : preparationPoint
    let relativeContact = spot.map { world($0)-feet } ?? .zero
    // A body shot keeps a narrow base. A wide low ball loads the leg on its own side.
    let grounded = !still && lift < 0.01
    // A flat feed can pass shoulder, waist and knee height within a few
    // frames. Lower the hips continuously as it descends through the waist.
    let rearReceiving = spot.map { abs($0.y-0.5) > 0.30 } ?? false
    let preparationHeight = confirmed ? relativeContact.y : readyHeight
    let waistLoad: Float
    if rearReceiving && preparationHeight > 0 {
      let t = min(1,max(0,(1.35-preparationHeight)/0.55))
      waistLoad = t*t*(3-2*t)
    } else { waistLoad = low ? 1 : 0 }
    let lowSupport: Float = high ? 0.22 : 0.66+0.34*waistLoad
    let desiredShift = grounded ? min(1,max(-1,relativeContact.x/0.55))*lowSupport*supportPhase : 0
    supportShift += (desiredShift-supportShift)*(continuous ? 1-exp(-20*frameTime) : 1)
    let load = abs(supportShift)
    let pelvis = V(supportShift*0.17,0,load*facing*0.035)
    let reachDip: Float = max(0.21*waistLoad,atNet && grounded ? 0.09 : 0)
    let lunge = reachDip*supportPhase
    let dip = crouch + lunge + load*0.055
    for i in 0..<2 {
      let sign: Float = i == 0 ? -1 : 1
      var ankle = V(sign*0.20,0.05 + lift*(sign > 0 ? 0.32 : 0.12),facing*(sign*side*lunge*1.7-sign*lift*0.22)) + travel*(sign*step)
      let loaded = max(0,sign*supportShift)
      ankle.x += sign*(0.07*load + 0.21*loaded)
      // Exchange lead and trailing legs during the overhead scissor jump.
      ankle.z += facing*sign*side*lift*1.25*cos(.pi*airPhase)
      if !still, lift < 0.005, distance < 0.35, distance > 0.0001 {
        let stance = sign*cos(stridePhase) < 0
        if stance {
          if planted[i] == nil { planted[i] = feet+ankle }
          ankle = planted[i]! - feet
        } else {
          planted[i] = nil
          ankle.y += 0.105 * max(0,sign*cos(stridePhase))
        }
      } else { planted[i] = nil }
      // Plant on the floor and solve a two-link leg. If a stride overshoots,
      // move the foot along the ground instead of lengthening the shin.
      let hip = pelvis + V(sign*0.12,0.88-dip,0)
      let thigh: Float = 0.445, shin: Float = 0.445
      let limit = thigh+shin-0.001
      let dy = ankle.y-hip.y
      let horizontal = V(ankle.x-hip.x,0,ankle.z-hip.z)
      let available = sqrt(max(0,limit*limit-dy*dy))
      if simd_length(horizontal) > available {
        ankle = hip + horizontal*(available/max(0.001,simd_length(horizontal))) + V(0,dy,0)
      }
      let axis = simd_normalize(ankle-hip)
      let length = simd_distance(ankle,hip)
      let guide = V(sign*(0.10+loaded*0.12),0,facing)
      let pole = simd_normalize(guide-axis*simd_dot(guide,axis))
      let along = (thigh*thigh-shin*shin+length*length)/(2*length)
      let knee = hip+axis*along+pole*sqrt(max(0,thigh*thigh-along*along))
      shoes[i].simdPosition = ankle + V(0,-0.007,facing*0.045)
      link(limbs[2*i],hip,knee)
      link(limbs[2*i+1],knee,ankle)
    }
    let inferredSide = relativeContact.x*side < -0.30 && !high
    // A previous return remains in Rally for replay. Its grip must not leak
    // into the next incoming shuttle's preparation.
    let currentImpact = confirmed || (elapsed >= 0 && elapsed < 0.32) ? impact : nil
    let measuredSide = outgoing?.returnStyle == .roundHead ? false : outgoing?.probableBackhand
    let backhand = measuredSide ?? currentImpact.map { $0.probableBackhand || $0.label?.contains("反手") == true } ?? inferredSide
    let rearSide = spot.map { abs($0.y-0.5) >= 0.30 && Float($0.x)*side < -0.22 } ?? false
    let frontSpot = spot.map { abs($0.y-0.5) <= 0.15 } ?? false
    let block = confirmed ? outgoing?.returnedSmash == true && outgoing?.shot == .net :
      incoming?.shot == .power || incoming?.shot == .smash
    let highNet = frontSpot && (spot?.z ?? 0) > Flight.netHeight
    let motion = confirmed ? outgoing?.returnStyle?.motion : nil
    let compact = block || highNet
    let preparation = confirmed ? max(0,1-Float(contactAge!)/0.28) : windup
    let swingTurn = active ? sin(min(1,clock/0.32)*2 * .pi) * (compact ? 0.16 : 0.58) : 0
    let rearCourt = rearReceiving
    let shoulderToBall = confirmed ? relativeContact : incoming.map { world($0.at(now))-feet } ?? relativeContact
    // When the shuttle passes the shoulder the player opens side-on, even
    // for a forehand. Use court geometry so the same feed admits either pose.
    let besideBody = min(1,max(0,(0.55-facing*shoulderToBall.z)/0.65))
    let desiredRearTurn: Float = rearSide && (!confirmed || backhand) ? 0.87*preparation
      : rearCourt ? (0.16+0.65*besideBody)*preparation : 0
    rearTurn += (desiredRearTurn-rearTurn)*(continuous ? 1-exp(-18*frameTime) : 1)
    let shoulderTurn = rearTurn
    let sideDrive = !frontSpot && !high && (confirmed ? outgoing?.shot == .drive : incoming?.shot == .drive)
    let crossBody = sideDrive && backhand ? 0.68*supportPhase : 0
    crossBodyTurn += (crossBody-crossBodyTurn)*(continuous ? 1-exp(-20*frameTime) : 1)
    // Enter the confirmed rotation from the prepared shoulder angle. A
    // discrete phase change otherwise adds a second wrist displacement at
    // the button, on top of the distance the incoming shuttle just travelled.
    let entry = confirmed && rearCourt ? min(1,Float(contactAge!)/0.085) : 1
    let turn = side*facing*(swingTurn*entry + shoulderTurn + crossBodyTurn)
    torso.simdEulerAngles.y = turn
    let netReach: Float = frontSpot && grounded ? 0.11*supportPhase : 0
    let upperShift = pelvis + V(supportShift*0.07,0,facing*(load*0.08+netReach))
    torso.simdEulerAngles.z = -0.16*supportShift
    torso.simdEulerAngles.x = facing*(load*0.14+netReach)
    let shoulder = upperShift + V(side*0.20*cos(turn),1.37-dip,-side*0.20*sin(turn))
    let guardPose = V(side*0.35,1.62-dip,facing*0.48)
    let swingSide = backhand ? -side : side
    var back = V(swingSide*(high ? 0.47 : 0.80),high ? 1.98 : low || stroke == .lift ? 0.75 : 1.30,-facing*0.32)
    var strike = V(swingSide*0.38,high ? 2.05 : low ? 0.72 : 1.38,facing*0.83)
    if confirmed, let outgoing {
      if latestContact != outgoing.start || !continuous {
        localContact = world(outgoing.from)-root.simdPosition
      }
      // At impact the string bed meets the shuttle in world space. After
      // release the arm moves with the player recovering toward court centre.
      strike = outgoing.returnStyle == nil ? world(outgoing.from)-root.simdPosition : localContact
    }
    var finish = V(-swingSide*(high ? 0.51 : 0.26),high || stroke == .smash ? 0.91 : stroke == .lift ? 1.87 : 1.45,facing*0.50)
    if atNet, lift < 0.01 {
      back = guardPose + V(-0.08*swingSide,low ? -0.35 : 0.08,-0.12*facing)
      let followY: Float = outgoing?.shot == .clear ? 0.48 : outgoing?.shot == .smash || outgoing?.shot == .power ? -0.28 : 0.06
      let push: Float = outgoing?.shot == .drive ? 0.31 : 0.12
      finish = strike + V(-0.08*swingSide,followY,push*facing)
    }
    if confirmed, !atNet, !high, outgoing?.shot == .net {
      finish = strike + V(-swingSide*0.06,0.05,facing*0.12)
    }
    if block {
      back = V(side*0.12,1.14-dip,facing*0.44)
      finish = strike + V(-swingSide*0.035,0.07,0.085*facing)
    } else if highNet {
      back = V(side*0.28,1.72-dip,facing*0.45)
      if confirmed && (outgoing?.shot == .smash || outgoing?.shot == .power) {
        finish = strike + V(-side*0.04,-0.21,0.14*facing)
      }
    } else if rearSide {
      if !confirmed { back = V(-side*0.24,1.52-dip,0.12*facing) }
      if confirmed && backhand {
        finish = strike + V(side*0.19,outgoing?.shot == .clear ? 0.10 : -0.09,0.12*facing)
      }
    }
    // Follow the outgoing flight in court coordinates. Direction comes from the
    // actual return, never the exercise label, even in fixed-scenario collection.
    if confirmed, let flight = outgoing, flight.measured, impact?.serveIntentConfirmed != true {
      let path = world(flight.to)-world(flight.from)
      let bearing = V(path.x,0,path.z)/max(0.01,hypot(path.x,path.z))
      let effort = Float(min(1,max(0,impact?.strength ?? 0.5)))
      let vertical = Float(min(1,max(-1,impact?.verticalSweep ?? 0)))
      let short = frontSpot || block
      let reachBehind = rearSide && backhand
      let sweep = Float(min(1,max(0,impact?.sweep ?? 0.5)))
      let forward: Float
      let rise: Float
      switch flight.shot {
      case .drive:
        forward = (short ? 0.17 : 0.21) + sweep*0.20
        rise = vertical*0.12
      case .clear, .weak:
        forward = reachBehind ? 0.22 : 0.26+0.12*effort
        rise = high ? -0.16 : 0.28+0.31*effort
      case .net:
        forward = (block ? 0.065 : short ? 0.10 : 0.18) + effort*0.07
        rise = block ? 0.035 : high ? -0.20 : low ? 0.13 : 0.065
      case .power, .smash:
        forward = short ? 0.13 : 0.21+effort*0.08
        rise = -(short ? 0.16+0.12*effort : 0.21+0.25*sweep+0.19*effort)
      }
      let acrossBody: Float
      if high && !short { acrossBody = (reachBehind ? 0.11 : -0.23)*side*effort }
      else if flight.shot == .drive { acrossBody = (backhand ? 0.16 : -0.16)*side*sweep }
      else { acrossBody = 0 }
      let room: Float = rearCourt ? 1-0.32*besideBody : 1
      if let motion {
        let carry = 0.78 + 0.28*sweep
        finish = strike + bearing*(motion.along*room*carry)
          + V(side*motion.across, motion.up*(0.80+0.26*effort) + vertical*0.023, 0)
      } else {
        finish = strike + bearing*(forward*room) + V(acrossBody,rise,0)
      }
    }
    if let name = currentImpact?.label, let style = ServeTraining(rawValue: name), style != .free {
      switch style {
      case .forehandHigh:
        back = V(side*0.65, 0.64, -facing*0.42)
        finish = V(-side*0.34, 1.83, facing*0.47)
      case .forehandShort:
        back = V(side*0.43, 0.86, facing*0.21)
        finish = strike + V(-side*0.08, 0.14, facing*0.20)
      case .backhandShort, .flick:
        back = V(-side*0.19, 0.96, facing*0.37)
        finish = strike + V(side*0.10, style == .flick ? 0.49 : 0.10,
                            facing*(style == .flick ? 0.38 : 0.16))
      case .free: break
      }
    }
    func blend(_ a: V, _ b: V, _ raw: Float) -> V {
      let t = max(0,min(1,raw))
      return a+(b-a)*(t*t*(3-2*t))
    }
    let followTime = motion?.brakeTime ?? 0.17
    let release = 0.14 + followTime
    var tip = guardPose
    if active {
      if clock < 0.08 { tip = blend(guardPose,back,clock/0.08) }
      else if clock < 0.14 { tip = blend(back,strike,(clock-0.08)/0.06) }
      else if clock < release { tip = blend(strike,finish,(clock-0.14)/followTime) }
      else {
        // Yielding blocks and rear drops decelerate before recovering; a
        // 230ms return from full reach makes the recovery faster than the hit.
        tip = blend(finish,guardPose,(clock-release)/((confirmed ? 0.69 : 0.54)-release))
      }
    } else if windup > 0 {
      tip = blend(guardPose,back,windup)
      if let incoming, let intercept {
        let approach = world(incoming.at(now))-world(intercept)
        let extensionTime: Float = compact || rearSide ? 0.27 : 0.18
        // Flat deep feeds offer a short interception interval. Present the racket
        // before the near edge; a blend ending only at the centre cannot show
        // a credible contact when the player chooses the early edge.
        let lead = Double(interceptLead ?? 0)
        let byTime = tracksArrival ? min(1,max(0,(0.37-Float(lead))/0.24))
          : 1 - min(1,max(0,(interceptLead ?? extensionTime)/extensionTime))
        let near = max(byTime,1 - min(1,simd_length(approach)/0.62))
        // The button can arrive between two ticks. Approach the near edge of
        // that interval using the same flight, up to half a render frame ahead.
        let target = tracksArrival ? (preparationPoint ?? intercept)
          : incoming.at(now + lead + min(1.0/60,Double(frameTime))*(incoming.shot == .drive ? 0.63 : 0.5))
        tip = blend(tip,world(target)-root.simdPosition,near)
      }
    } else if high, incoming != nil {
      // An outgoing high return can still be confirmed on the last rounded
      // recovery tick. Only a new incoming shuttle should raise the racket.
      tip = blend(guardPose,back,0.40)
    }
    // After the follow-through, adjacent states can choose different guards
    // (a new feed, a landing, or expiry of the previous shot). Carry the
    // previous rendered racket position through these transitions.
    if !continuous { latestContact = -.infinity }
    if confirmed, let outgoing { latestContact = outgoing.start }
    let sinceContact = now-latestContact
    if continuous, !still, sinceContact > 0.23, sinceContact < 1.2,
       (interceptLead ?? 1) > 0.18, !(elapsed >= 0 && elapsed < 0.12) {
      let previousTip = rim.simdPosition
      let movement = tip-previousTip
      let distance = simd_length(movement)
      let step = frameTime * (block ? 2.7 : 4.2)
      if distance > step { tip = previousTip + movement*(step/distance) }
    }
    let axis = tip-shoulder
    let reachDirection = axis/max(simd_length(axis),0.001)
    // Let the body lean into a stretched return; keep the racket shaft rigid.
    let lean = reachDirection*min(0.38,max(0,simd_length(axis)-1.04))
    torso.simdPosition = (pelvis+upperShift)*0.5 + V(0,1.12-dip,0)+lean*0.55
    head.simdPosition = upperShift + V(0,1.62-dip,0)+lean
    hair.simdPosition = head.simdPosition+V(0,0.045,0.015)
    let socket = shoulder + lean
    // Fixed upper arm and forearm. Out-of-reach button hits must not stretch the arm.
    // In guard the head sits above the grip, with the hand in front of the elbow.
    // At full reach gradually align the shaft with the arm to keep contact attainable.
    let serveGrip = impact?.label.flatMap { ServeTraining(rawValue:$0) } != nil && confirmed
    let shaftPose = serveGrip ? simd_normalize(V(-side*0.50,-0.72,facing*0.55))
      : simd_normalize(V(swingSide*(backhand ? 0.52 : 0.38),
                                     low && active ? 0.24 : 0.85, facing*0.43))
    var preferred = shaftPose
    if continuous, let old = gripAxis {
      let recovering = incoming == nil && sinceContact > 0.20 && sinceContact < 1.20
      let alpha = 1-exp(-frameTime*(recovering ? 8 : compact ? 17 : 23))
      let mixed = old*(1-alpha)+shaftPose*alpha
      if simd_length_squared(mixed)>0.0001 { preferred = simd_normalize(mixed) }
    }
    // Multiple grip positions can put the string bed at the same contact. In the
    // first few frames use the closest feasible grip, then release into follow-through.
    let handoff: Float = continuous && confirmed ? max(0,1-Float(contactAge!)/0.085) : 0
    if handoff > 0 {
      let fromPalm = tip-palm.simdPosition
      if simd_length_squared(fromPalm)>0.01 {
        let candidate = preferred*(1-handoff)+simd_normalize(fromPalm)*handoff
        if simd_length_squared(candidate)>0.001 { preferred = simd_normalize(candidate) }
      }
    }
    let reach = simd_length(tip-socket)
    let shaft: Float = 0.49
    let alignment = simd_dot(preferred,reachDirection)
    let transverse = preferred-reachDirection*alignment
    let minCos = min(1,max(-1,(reach*reach+shaft*shaft-0.588*0.588)/(2*shaft*max(reach,0.001))))
    let cosAngle = max(alignment,minCos)
    let dir = simd_length(transverse) > 0.001
      ? reachDirection*cosAngle + simd_normalize(transverse)*sqrt(max(0,1-cosAngle*cosAngle))
      : reachDirection
    gripAxis = dir
    let deltaWrist = tip - dir*shaft - socket
    let ray = simd_length(deltaWrist) > 0.001 ? simd_normalize(deltaWrist) : dir
    let length = min(0.588,max(0.065,simd_length(deltaWrist)))
    let wrist = socket + ray*length
    let pole = V(side*0.46,-0.78,-facing*0.36)
    var perpendicular = pole - ray*simd_dot(pole,ray)
    if simd_length(perpendicular) < 0.01 { perpendicular = simd_cross(ray,V(0,0,1)) }
    let upper: Float = 0.31, fore: Float = 0.28
    let along = (upper*upper-fore*fore+length*length)/(2*length)
    let center = socket + ray*along
    let radius = sqrt(max(0,upper*upper-along*along))
    var bend = simd_normalize(perpendicular)
    if high, !frontSpot, !still, let phase = confirmed ? contactAge.map(Float.init) : interceptLead.map({ -$0 }) {
      // Fit the measured elbow elevation on the feasible shoulder/wrist IK circle.
      // The broadcast reference is relative to torso length, in the near player's view.
      let up = V(0,1,0)-ray*ray.y
      let verticalRange = radius*simd_length(up)
      if verticalRange > 0.015 {
        let vertical = simd_normalize(up)
        var outward = simd_cross(ray,vertical)
        if simd_dot(outward,pole) < 0 { outward = -outward }
        let pulse = max(0,min(1,(phase+0.20)/0.16,(0.26-phase)/0.16))
        let relativeHeight = -0.50 + 0.71*pulse*pulse*(3-2*pulse)
        let ratio = min(1,max(-1,(socket.y + 0.46*relativeHeight-center.y)/verticalRange))
        bend = vertical*ratio + outward*sqrt(max(0,1-ratio*ratio))
      }
    }
    // Carry the previous bend direction into the new shoulder-to-hand plane.
    // This preserves both bone lengths when alternative IK solutions swap sides.
    if continuous, let old = elbowPlane {
      let projected = old - ray*simd_dot(old,ray)
      if simd_length_squared(projected) > 0.001 {
        let start = simd_normalize(projected)
        let angle = atan2(simd_dot(ray,simd_cross(start,bend)),simd_dot(start,bend))
        let limit = frameTime*(compact ? 5 : 8)
        bend = simd_quatf(angle:min(limit,max(-limit,angle)),axis:ray).act(start)
      }
    }
    if handoff > 0 {
      let previousElbow = elbowJoint.simdPosition-center
      let onCircle = previousElbow-ray*simd_dot(previousElbow,ray)
      if simd_length_squared(onCircle)>0.0001 {
        let target = bend*(1-handoff)+simd_normalize(onCircle)*handoff
        if simd_length_squared(target)>0.001 { bend = simd_normalize(target) }
      }
    }
    let elbow = center + bend*radius
    elbowPlane = bend
    tip = wrist + dir*0.49
    let forearm = simd_normalize(wrist-elbow)
    // The hand closes around the grip at an angle. The wrist crease is behind
    // the palm along the forearm; the thumb rests along the near grip bevel.
    let handAxis = simd_normalize(0.76*forearm + 0.24*dir)
    let crease = wrist - handAxis*0.053
    // Axial forearm rotation brings the string bed square at impact. Short
    // blocks need only a small rotation. Keep the thumb on the same grip bevel.
    let rollSpan: Float = motion?.forearmRoll ?? (block ? 0.11 : highNet ? 0.25 : high ? 0.51 : 0.30)
    let post = Float(min(1,max(0,(contactAge ?? 0)/0.12)))
    let settle = Float(max(0,1-max(0,(contactAge ?? 0)-0.12)/0.23))
    let desiredRoll = swingSide*facing*rollSpan*(confirmed ? -post*settle : windup)
    gripRoll += (desiredRoll-gripRoll)*(continuous ? 1-exp(-24*frameTime) : 1)
    let forearmRoll = simd_quatf(angle:gripRoll,axis:handAxis)
    var knuckleSide = simd_cross(handAxis,V(0,0,facing))
    if simd_length_squared(knuckleSide)<0.002 {
      knuckleSide = simd_cross(handAxis,V(0,1,0))
    }
    knuckleSide = forearmRoll.act(simd_normalize(knuckleSide)*side*facing)
    elbowJoint.simdPosition = elbow
    wristJoint.simdPosition = crease
    link(limbs[4],socket,elbow)
    link(limbs[5],elbow,crease)
    link(limbs[6],wrist+dir*0.08,tip-dir*0.14)
    link(grip,wrist-dir*0.065,wrist+dir*0.085)
    palm.simdPosition = wrist
    palm.simdOrientation = simd_quatf(simd_float3x3(columns:(knuckleSide,handAxis,simd_cross(knuckleSide,handAxis))))
    palm.simdScale = V(0.86,1.34,0.82)
    thumb.simdPosition = wrist + dir*0.023 - knuckleSide*0.025
    let offShoulder = upperShift + V(-side*0.18*cos(turn),1.37-dip,side*0.18*sin(turn))+lean
    // Counterbalance the planted leg and the reach. The free arm opens back and
    // out on a lunge, guides an overhead preparation and folds away on contact.
    let guide: Float = high && !frontSpot ? (confirmed ? max(0,1-Float(contactAge!)/0.16)*0.62 : windup) : 0
    let spread = min(1, load*1.4 + netReach*4.8 + (confirmed ? crossBodyTurn*0.5 : 0))
    let recoil = confirmed ? min(1,max(0,Float(contactAge!)/0.15))*supportPhase : 0
    let upperArm = V(-side*(0.16+0.51*spread+0.16*guide),
                     -0.59+1.04*guide-0.08*recoil, facing*(0.20-0.74*spread+0.18*guide))
    let lowerArm = V(-side*(0.12+0.44*spread), 0.17+0.64*guide-0.60*spread-0.28*recoil,
                     facing*(0.70-1.40*spread+0.10*guide))
    let offElbow = offShoulder + simd_normalize(upperArm)*0.31
    let offHand = offElbow + simd_normalize(lowerArm)*0.28
    link(limbs[7],offShoulder,offElbow)
    link(limbs[8],offElbow,offHand)
    rim.simdPosition = tip
    // Local Z follows the long axis of the hoop. Roll its string bed with the forearm.
    let face = simd_normalize(V((backhand ? -side : side)*0.32,low ? 0.52 : 0.12,facing))
    var across = simd_cross(face,dir)
    if simd_length(across) < 0.04 { across = simd_cross(V(0,1,0),dir) }
    across = simd_quatf(angle:gripRoll,axis:dir).act(simd_normalize(across))
    rim.simdOrientation = simd_quatf(simd_float3x3(columns:(across,simd_cross(dir,across),dir)))
  }

}

final class CourtScene {
  let scene = SCNScene(), camera = SCNNode()
  private var cameraTime: Double?
  private var tracking = V.zero
  private let players: [CourtPlayer]
  private let trail: [SCNNode]
  private let shuttle = SCNNode()
  private let shadow, landing, intercept, service: SCNNode
  init() {
    let root = scene.rootNode
    scene.background.contents = UIColor(red: 0.44,green: 0.67,blue: 0.78,alpha: 1)
    func box(_ x: CGFloat,_ y: CGFloat,_ z: CGFloat,_ at: V,_ color: UIColor) -> SCNNode {
      mesh(SCNBox(width:x,height:y,length:z,chamferRadius:0),color,root,at)
    }
    let surround = UIColor(red:0.21,green:0.30,blue:0.42,alpha:1)
    _ = box(42,0.09,44,V(0,-0.08,0),surround)
    // Tier edges and side rails provide stable depth references behind the play.
    for row in 0..<5 {
      let height = CGFloat(row+1)*0.38, depth = Float(row)*0.72
      let seat = row.isMultiple(of:2) ? UIColor(red:0.17,green:0.32,blue:0.44,alpha:1) : surround
      _ = box(22,height,0.72,V(0,Float(height)/2,-9-depth),seat)
      for side: Float in [-1,1] {
        _ = box(0.72,height,17,V(side*(7+depth),Float(height)/2,-0.7),seat)
      }
    }
    for side: Float in [-1,1] {
      _ = box(0.08,0.08,16,V(side*5.8,0.68,-0.5),.lightGray)
      for z: Float in [-8,-4,0,4,7] {
        _ = box(0.06,0.68,0.06,V(side*5.8,0.34,z),.lightGray)
      }
    }
    _ = box(6.1,0.045,13.4,V(0,-0.025,0),UIColor(red:0.13,green:0.42,blue:0.57,alpha:1))
    for z: Float in [-6.7,-5.94,-1.98,1.98,5.94,6.7] { _ = box(6.1,0.012,0.04,V(0,0,z),.white) }
    for x: Float in [-3.05,-2.59,2.59,3.05] { _ = box(0.04,0.012,13.4,V(x,0,0),.white) }
    for sign: Float in [-1,1] { _ = box(0.04,0.012,4.72,V(0,0,sign*4.34),.white) }
    for x: Float in [-3.06,3.06] { _ = box(0.045,1.55,0.045,V(x,0.775,0),.lightGray) }
    for side: Float in [-1,1] {
      let band = box(3.05,0.035,0.022,V(side*1.525,1.537-0.0175,0),.white)
      band.simdEulerAngles.z = side*atan2(0.026,3.05)
    }
    for x in stride(from: Float(-3),through:3,by:0.15) { _ = box(0.008,0.74,0.008,V(x,1.14,0),.darkGray) }
    for y in stride(from: Float(0.78),through:1.5,by:0.12) { _ = box(6.1,0.009,0.009,V(0,y,0),.darkGray) }
    trail = (0..<14).map { i in
      let fade = CGFloat(i+1)/14
      let node = mesh(SCNCylinder(radius:0.006 + 0.036*fade,height:1),.white,root)
      node.geometry?.firstMaterial?.lightingModel = .constant
      node.opacity = fade*0.88
      return node
    }
    players = [CourtPlayer(root,.systemOrange),CourtPlayer(root,.systemCyan),CourtPlayer(root,.systemOrange),CourtPlayer(root,.systemCyan)]
    for player in players {
      let shadow = mesh(SCNCylinder(radius:0.27,height:0.006),UIColor.black.withAlphaComponent(0.30),root)
      shadow.simdScale.z = 0.65
      player.groundShadow = shadow
    }
    // A light canopy frames the backdrop without crossing the flight corridor.
    for x: Float in [-8,8] {
      for z: Float in [-13,-6,1] {
        _ = box(0.17,5.2,0.17,V(x,2.6,z),.lightGray)
      }
      _ = box(3.6,0.12,17,V(x,5.18,-6.1),UIColor(red:0.71,green:0.83,blue:0.87,alpha:1))
      for z: Float in [-11,-6,-1,4] {
        _ = box(0.22,1.5,0.22,V(x*0.75,0.75,z),.brown)
        let leaves = mesh(SCNSphere(radius:0.82),UIColor(red:0.23,green:0.53,blue:0.37,alpha:1),root,V(x*0.75,2.0,z))
        leaves.simdScale.y = 1.18
      }
    }
    root.addChildNode(shuttle)
    _ = mesh(SCNSphere(radius:0.065),.systemYellow,shuttle)
    _ = mesh(SCNCone(topRadius:0.1,bottomRadius:0.04,height:0.17),.white,shuttle,V(0,0.1,0))
    shadow = mesh(SCNCylinder(radius:0.11,height:0.008),.black,root)
    landing = mesh(SCNTorus(ringRadius:0.22,pipeRadius:0.016),.white,root)
    intercept = mesh(SCNTorus(ringRadius:0.12,pipeRadius:0.025),.systemMint,root)
    service = box(2.59,0.005,4.72,.zero,UIColor.systemMint.withAlphaComponent(0.28))
    camera.camera = SCNCamera()
    camera.camera?.fieldOfView = 43
    camera.position = SCNVector3(0,4.05,10.8)
    camera.look(at: SCNVector3(0,1.12,0.6))
    root.addChildNode(camera)
    for type in [SCNLight.LightType.ambient,.directional] {
      let lamp = SCNNode()
      lamp.light = SCNLight()
      lamp.light?.type = type
      lamp.light?.intensity = type == .ambient ? 560 : 880
      lamp.eulerAngles = SCNVector3(-0.9,-0.5,0)
      root.addChildNode(lamp)
    }
  }
  #if os(macOS)
  func nearLegLengths() -> [Float] { players[0].legLengths }
  func nearArmPoints() -> [SIMD3<Float>] { players[0].armPoints }
  #endif
  func nearRacketError(to contact: Position) -> Float {
    simd_distance(players[0].tipInWorld, world(contact))
  }
  func update(_ game: Rally,reduced: Bool,left: Bool) {
    let f = game.flight
    for i in players.indices {
      let near = i.isMultiple(of:2), main = i<2
      players[i].root.isHidden = !main && game.format != .doubles
      players[i].groundShadow?.isHidden = players[i].root.isHidden
      if players[i].root.isHidden { continue }
      let x = main ? (near ? game.playerX : game.opponentX) : (near ? -game.nearServiceX : game.nearServiceX)
      let y = main ? (near ? game.playerY : game.opponentY) : (near ? 0.92 : 0.11)
      let contact = main && f?.incoming == !near ? f : nil
      let incoming = main && f?.incoming == near ? f : nil
      players[i].pose(world(Position(x:x,y:y)),side:near ? (left ? -1 : 1) : -1,facing:near ? -1 : 1,
                      now:game.now,elapsed:main ? game.now-(near ? game.swingTime : game.rivalSwing) : 1,
                      stroke:near ? game.stroke : f?.shot == .power ? .smash : .drive,
                      impact:near && main ? game.animationImpact : nil,incoming:incoming,outgoing:contact,intercept:main ? (near ? game.predictedIntercept : game.opponentIntercept) : nil,still:reduced)
    }
    // Track court movement in metres; keep the horizon steady through jumps.
    let feet = world(Position(x:game.playerX,y:game.playerY))
    let ball = f.map { world($0.at(game.now)) } ?? feet
    let cameraTarget = V(feet.x*0.84+ball.x*0.06,min(0.75,max(0,ball.y-1.6)*0.38),(feet.z-3.7)*0.84)
    let dt = game.now - (cameraTime ?? game.now)
    if reduced { tracking = .zero }
    else if cameraTime == nil || dt < 0 { tracking = cameraTarget }
    else { tracking += (cameraTarget-tracking)*Float(1-exp(-5*min(0.2,dt))) }
    cameraTime = game.now
    camera.simdPosition = V(tracking.x+0.34,3.15,9.75+tracking.z)
    if reduced { camera.simdPosition = V(0,4.05,10.8) }
    camera.look(at:SCNVector3(tracking.x*0.56,1.65+tracking.y,0.05+tracking.z*0.48))
    service.isHidden = game.phase != .serve || game.practice
    let half = Float(game.format.halfWidth)*3.05, near = !game.playerServes
    let sign: Float = (near ? game.nearServiceX : -game.nearServiceX) >= 0 ? 1 : -1
    let end = Float(6.7-game.format.backLine*13.4)
    service.simdScale = V(half/2.59,1,(end-1.98)/4.72)
    service.simdPosition = V(sign*half/2,0.009,(near ? 1 : -1)*(end+1.98)/2)
    shuttle.isHidden = f == nil; shadow.isHidden = f == nil
    let target = f.map { $0.netCollision ?? $0.to } ?? game.landing
    landing.isHidden = target == nil
    if let target { landing.simdPosition = world(Position(x:target.x,y:target.y)) + V(0,0.015,0) }
    intercept.isHidden = game.waitingForDescent || !(f.map { $0.incoming && game.now < $0.start + $0.duration } ?? false) || game.predictedIntercept == nil
    for (i,segment) in trail.enumerated() {
      segment.isHidden = reduced || f == nil
      if let f, !reduced {
        let step = f.shot == .clear || f.shot == .weak ? 0.024 : 0.014
        let end = game.now - Double(trail.count-1-i)*step
        segment.isHidden = end <= f.start || end-step >= f.start+f.duration
        let color: UIColor
        switch f.shot {
        case .clear, .weak: color = .systemMint
        case .power, .smash: color = .systemOrange
        case .drive: color = .systemCyan
        case .net: color = .white
        }
        segment.geometry?.firstMaterial?.diffuse.contents = color
        link(segment,world(f.at(end-step)),world(f.at(end)))
      }
    }
    if let f {
      let ball = world(f.at(game.now))
      shuttle.simdPosition = ball
      let velocity = world(f.at(game.now+0.008))-world(f.at(game.now-0.008))
      if simd_length(velocity)>0.0001 { shuttle.simdOrientation = simd_quatf(from:V(0,1,0),to:-simd_normalize(velocity)) }
      shadow.simdPosition = V(ball.x,0.015,ball.z)
      if let contact = game.predictedIntercept {
        let spot = world(contact)
        intercept.simdPosition = V(spot.x,0.024,spot.z)
      }
    }
  }
}

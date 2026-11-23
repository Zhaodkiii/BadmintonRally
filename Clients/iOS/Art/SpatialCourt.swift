import SceneKit
import SwiftUI

// Game coordinates map to metres once. SceneKit owns only the presentation.
private typealias V = SIMD3<Float>
private func world(_ p: Position) -> V {
  V(Float(p.x * 3.05), Float(p.z * 1.524 / Flight.netHeight), Float((p.y - 0.5) * 13.4))
}

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
  private let rim: SCNNode
  private var stridePhase: Float = 0
  private var previous: V?
  init(_ parent: SCNNode, _ shirt: UIColor) {
    parent.addChildNode(root)
    let skin = UIColor(red: 0.83, green: 0.59, blue: 0.43, alpha: 1)
    torso = mesh(SCNCapsule(capRadius: 0.21, height: 0.65), shirt, root, V(0,1.12,0))
    torso.simdScale.z = 0.72
    head = mesh(SCNSphere(radius: 0.12), skin, root, V(0,1.62,0))
    hair = mesh(SCNSphere(radius: 0.115), .darkGray, root, V(0,1.665,0.015))
    let skeleton = root
    limbs = [0.09,0.065,0.09,0.065,0.055,0.045,0.018,0.06].enumerated().map {
      mesh(SCNCylinder(radius: $0.element, height: 1), [0,2].contains($0.offset) ? .darkGray : $0.offset == 6 ? .white : skin, skeleton)
    }
    shoes = [-1,1].map { _ in mesh(SCNBox(width:0.115,height:0.085,length:0.25,chamferRadius:0.035),.white,skeleton) }
    rim = mesh(SCNTorus(ringRadius: 0.14, pipeRadius: 0.018), .systemMint, root)
    for k in -2...2 {
      let offset = Float(k)*0.045
      let span = sqrt(0.14*0.14-offset*offset)
      let warp = mesh(SCNCylinder(radius:0.004,height:1),.white,rim)
      let weft = mesh(SCNCylinder(radius:0.004,height:1),.white,rim)
      link(warp,V(offset,0,-span),V(offset,0,span))
      link(weft,V(-span,0,offset),V(span,0,offset))
    }
  }
  private var jumpStart = -Double.infinity
  private var jumpedFlight: Double?
  func pose(_ feet: V, side: Float, facing: Float, now: Double, elapsed: Double,
            stroke: Stroke, impact: SwingImpact?, incoming: Flight?, outgoing: Flight?, still: Bool) {
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
        if soon.y > 2.1, soon.y < 2.85, groundDistance < 1.12,
           jumpedFlight != incoming.start, now - jumpStart > 0.65 {
          jumpStart = now
          jumpedFlight = incoming.start
        }
      }
    }
    if now < jumpStart { jumpStart = -.infinity; jumpedFlight = nil }
    let age = Float(now - jumpStart)
    let airborne = min(1,max(0,(age-0.08)/0.43))
    let lift = 0.44 * 4 * airborne * (1-airborne)
    let crouch: Float
    if (0..<0.08).contains(age) { crouch = 0.10*sin(.pi*age/0.08) }
    else if (0.51..<0.68).contains(age) { crouch = 0.12*sin(.pi*(age-0.51)/0.17) }
    else { crouch = 0 }
    groundShadow?.simdPosition = feet + V(0,0.012,0)
    root.simdPosition = feet + V(0,lift,0)
    let step = distance > 0.0001 && !still ? sin(stridePhase)*0.22 : 0
    let travel = distance > 0.0001 ? delta/distance : V(0,0,facing)
    let contactAge = outgoing.map { now-$0.start }
    let confirmed = contactAge.map { $0 >= 0 && $0 < 0.40 } ?? false
    let clock = confirmed ? Float(contactAge!) + 0.14 : Float(elapsed)
    let active = clock >= 0 && clock < 0.54
    let high = confirmed ? world(outgoing!.from).y > 1.95 : readyHeight > 1.95 || lift > 0
    let low = confirmed ? world(outgoing!.from).y < 1.05 : readyHeight > 0 && readyHeight < 1.05
    let lunge = low && active ? 0.19*sin(.pi*min(1,clock/0.54)) : 0
    let dip = crouch + lunge
    for i in 0..<2 {
      let sign: Float = i == 0 ? -1 : 1
      let ankle = V(sign*0.20,0.05 + lift*(sign > 0 ? 0.32 : 0.12),facing*(sign*lunge-sign*lift*0.22)) + travel*(sign*step)
      shoes[i].simdPosition = ankle + V(0,-0.007,facing*0.045)
      let knee = V(sign*0.16,0.46-dip*0.45,facing*(0.09+dip+lift*0.20)) + travel*(sign*step*0.5)
      link(limbs[2*i], V(sign*0.12,0.88-dip,0), knee)
      link(limbs[2*i+1],knee,ankle)
    }
    let turn = active ? sin(min(1,clock/0.32)*2 * .pi) * side * facing * 0.58 : 0
    torso.simdEulerAngles.y = turn
    let shoulder = V(side*0.20*cos(turn),1.37-dip,-side*0.20*sin(turn))
    let guardPose = V(side*0.49,1.34-dip,facing*0.38)
    let backhand = impact?.label?.contains("反手") == true || impact?.label == "接杀反抽"
    let swingSide = backhand ? -side : side
    let back = V(swingSide*(high ? 0.47 : 0.80),high ? 1.98 : low || stroke == .lift ? 0.75 : 1.30,-facing*0.32)
    var strike = V(swingSide*0.38,high ? 2.05 : low ? 0.72 : 1.38,facing*0.83)
    if confirmed { strike = world(outgoing!.from)-root.simdPosition }
    let finish = V(-swingSide*(high ? 0.51 : 0.26),high || stroke == .smash ? 0.91 : stroke == .lift ? 1.87 : 1.45,facing*0.50)
    func blend(_ a: V, _ b: V, _ raw: Float) -> V {
      let t = max(0,min(1,raw))
      return a+(b-a)*(t*t*(3-2*t))
    }
    var tip = guardPose
    if active {
      if clock < 0.08 { tip = blend(guardPose,back,clock/0.08) }
      else if clock < 0.14 { tip = blend(back,strike,(clock-0.08)/0.06) }
      else if clock < 0.31 { tip = blend(strike,finish,(clock-0.14)/0.17) }
      else { tip = blend(finish,guardPose,(clock-0.31)/0.23) }
    } else if high { tip = blend(guardPose,back,0.66) }
    let axis = tip-shoulder
    let dir = axis/max(simd_length(axis),0.001)
    // Let the body lean into a stretched return; keep the racket shaft rigid.
    let lean = dir*min(0.38,max(0,simd_length(axis)-1.04))
    torso.simdPosition = V(0,1.12-dip,0)+lean*0.55
    head.simdPosition = V(0,1.62-dip,0)+lean
    hair.simdPosition = head.simdPosition+V(0,0.045,0.015)
    let wrist = tip-dir*0.49
    let elbow = (shoulder+lean+wrist)*0.5 + V(side*0.10,-0.13,-facing*0.05)
    link(limbs[4],shoulder+lean,elbow); link(limbs[5],elbow,wrist); link(limbs[6],wrist,tip)
    link(limbs[7],V(-side*0.18,1.37-dip,0)+lean,V(-side*(0.34+lift*0.42),0.99-dip+lift*0.78,facing*0.14))
    rim.simdPosition = tip
    let sideways = V(side,0,0)
    let normal = simd_cross(dir,sideways)
    if simd_length(normal) > 0.01 {
      rim.simdOrientation = simd_quatf(from:V(0,1,0),to:simd_normalize(normal))
    }
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
                      impact:near && main ? game.animationImpact : nil,incoming:incoming,outgoing:contact,still:reduced)
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

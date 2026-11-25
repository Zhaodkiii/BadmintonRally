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
  var scene: CourtScene? = nil
  var poseUpdatedByMatchClock = false
  func makeCoordinator() -> CourtScene { scene ?? CourtScene() }
  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.scene = context.coordinator.scene
    view.pointOfView = context.coordinator.camera
    view.antialiasingMode = .multisampling2X
    view.isUserInteractionEnabled = false
    return view
  }
  func updateUIView(_ view: SCNView, context: Context) {
    if view.bounds.height > 0 {
      context.coordinator.cameraAspect = Float(view.bounds.width/view.bounds.height)
    }
    if !poseUpdatedByMatchClock {
      context.coordinator.update(game, reduced: reduced, left: leftHanded)
    }
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

// A single closed jersey shell, authored in metres from the hip to the collar.
// Its upper edge meets both shoulder caps even when the spine leans to the side.
private func jerseyGeometry() -> SCNGeometry {
  let rings: [(y: Float, width: Float, depth: Float)] = [
    (-0.065,0.133,0.105), (-0.045,0.159,0.119), (0.048,0.158,0.116),
    (0.265,0.186,0.134), (0.405,0.210,0.137), (0.463,0.211,0.122),
    (0.492,0.179,0.107), (0.511,0.074,0.073)
  ]
  let sides = 24
  var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], triangles: [Int32] = []
  for (r,ring) in rings.enumerated() {
    let below = rings[max(0,r-1)], above = rings[min(r+1,rings.count-1)]
    for column in 0..<sides {
      let angle = 2*Float.pi*Float(column)/Float(sides)
      let c = cos(angle), z = sin(angle)
      vertices.append(SCNVector3(V(ring.width*c,ring.y,ring.depth*z)))
      let rise = V((above.width-below.width)*c,above.y-below.y,(above.depth-below.depth)*z)
      let along = V(-ring.width*z,0,ring.depth*c)
      normals.append(SCNVector3(simd_normalize(simd_cross(rise,along))))
      if r+1 < rings.count {
        let a = Int32(r*sides+column), b = Int32(r*sides+(column+1)%sides)
        let n = Int32(sides)
        triangles += [a,a+n,b, b,a+n,b+n]
      }
    }
  }
  let top = Int32((rings.count-1)*sides)
  for i in 1..<(sides-1) {
    let j = Int32(i)
    triangles += [0,j,j+1,top,top+j+1,top+j]
  }
  return SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals)],
                     elements:[SCNGeometryElement(indices:triangles,primitiveType:.triangles)])
}

// Elliptical sections along a centreline, with end caps and smooth normals.
// The same topology describes a tapered finger, shoe last, sole or palm.
private func equipmentMesh(_ centers: [V], widths: [Float], depths: [Float], reference: V, sides: Int = 12) -> SCNGeometry {
  precondition(centers.count >= 2 && widths.count == centers.count && depths.count == centers.count)
  var vertices = [V](), indices = [Int32]()
  for ring in centers.indices {
    let tangent = simd_normalize(centers[min(ring+1,centers.count-1)]-centers[max(0,ring-1)])
    let fallback = abs(tangent.y) < 0.9 ? V(0,1,0) : V(1,0,0)
    let ref = abs(simd_dot(tangent,reference)) < 0.96 ? reference : fallback
    let major = simd_normalize(ref-tangent*simd_dot(ref,tangent))
    let minor = simd_cross(tangent,major)
    for column in 0..<sides {
      let angle = 2*Float.pi*Float(column)/Float(sides)
      vertices.append(centers[ring]+major*(cos(angle)*widths[ring])+minor*(sin(angle)*depths[ring]))
      if ring > 0 {
        let a = Int32((ring-1)*sides+column), b = Int32((ring-1)*sides+(column+1)%sides)
        let n = Int32(sides)
        indices += [a,b,a+n,b,b+n,a+n]
      }
    }
  }
  let last = Int32(vertices.count-sides)
  for i in 1..<(sides-1) {
    let j = Int32(i)
    indices += [0,j+1,j,last,last+j,last+j+1]
  }
  var normals = Array(repeating:V.zero,count:vertices.count)
  for i in stride(from:0,to:indices.count,by:3) {
    let a = Int(indices[i]), b = Int(indices[i+1]), c = Int(indices[i+2])
    let normal = simd_cross(vertices[b]-vertices[a],vertices[c]-vertices[a])
    normals[a] += normal; normals[b] += normal; normals[c] += normal
  }
  return SCNGeometry(sources:[SCNGeometrySource(vertices:vertices.map(SCNVector3.init)),
                              SCNGeometrySource(normals:normals.map { SCNVector3(simd_normalize($0)) })],
                     elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
}

private final class PlayerHands {
  let racket = SCNNode(), free = SCNNode()
  let wristBridge: SCNNode
  private var previousGrip: (shaft: V, knuckles: V)?
  init(parent:SCNNode, skin:UIColor) {
    wristBridge = mesh(equipmentMesh([V(0,-0.5,0),V.zero,V(0,0.5,0)],widths:[0.023,0.021,0.017],depths:[0.022,0.020,0.016],reference:V(1,0,0)),skin,parent)
    wristBridge.name = "WristToPalm"
    parent.addChildNode(racket)
    parent.addChildNode(free)
    racket.name = "GripFingers"; free.name = "BalanceHand"
    let axis = V(0,1,0)
    func digit(_ node:SCNNode, _ name:String, _ points:[V], _ radius:Float) {
      let taper: [Float] = [0.84,1,0.91,0.78,0.43]
      let finger = mesh(equipmentMesh(points,widths:taper.map { $0*radius },
                                     depths:taper.map { $0*radius*0.94 },reference:axis),skin,node)
      finger.name = name
    }
    // Local Y is the handle axis. The knuckles sit on one side of the bevel;
    // the finger pads turn around it and the thumb closes from the other side.
    _ = mesh(equipmentMesh([V(0.022,-0.043,0),V(0.027,-0.029,0),V(0.028,0.006,0),V(0.024,0.036,0)],
              widths:[0.010,0.015,0.016,0.012],depths:[0.016,0.024,0.026,0.018],reference:V(1,0,0)),skin,racket)
    for i in 0..<4 {
      let height = Float(i)*0.017-0.028
      digit(racket,["Little","Ring","Middle","Index"][i],
            [V(0.028,height,0.009),V(0.020,height+0.003,0.023),V(0.002,height+0.006,0.025),
             V(-0.015,height+0.008,0.016),V(-0.019,height+0.009,0.004)],0.007+Float(i)*0.00045)
    }
    digit(racket,"Thumb",[V(0.030,0.006,-0.011),V(0.021,0.022,-0.024),
                           V(0.004,0.029,-0.026),V(-0.012,0.030,-0.019),V(-0.020,0.026,-0.008)],0.010)
    _ = mesh(equipmentMesh([V.zero,V(0,0.024,0),V(0,0.055,0),V(0,0.069,0)],
             widths:[0.019,0.029,0.033,0.028],depths:[0.016,0.018,0.015,0.011],reference:V(1,0,0)),skin,free)
    for i in 0..<4 {
      let x = (Float(i)-1.5)*0.016
      let length = [Float(0.040),0.052,0.056,0.049][i]
      digit(free,"Finger-\(i)",[V(x,0.058,0),V(x,0.069,0),V(x*1.08,0.066+length*0.55,0.003),
                                  V(x*1.12,0.063+length*0.88,0.007),V(x*1.14,0.062+length,0.011)],0.007)
    }
    digit(free,"Thumb",[V(0.018,0.017,0),V(0.027,0.024,0),V(0.038,0.032,0.002),
                        V(0.046,0.043,0.006),V(0.048,0.052,0.009)],0.009)
  }

  func pose(wrist:V, crease:V, shaft:V, knuckles:V, freeHand:V, freeElbow:V, side:Float, continuous:Bool, frameTime:Float) {
    let outward = knuckles-shaft*simd_dot(knuckles,shaft)
    let alternate = abs(shaft.z)<0.9 ? V(0,0,1) : V(1,0,0)
    var x = simd_length_squared(outward)>0.0001 ? simd_normalize(outward) : simd_normalize(simd_cross(shaft,alternate))
    if continuous, let old = previousGrip {
      // Transport the last grip with the shaft. When the arm points towards
      // the court axis, its projected knuckle reference can reverse by 180°.
      // Only the residual wrist roll is rate-limited; the hand follows every
      // translation and direction change of the actual handle immediately.
      let transported = simd_quatf(from:old.shaft,to:shaft).act(old.knuckles)
      let angle = atan2(simd_dot(shaft,simd_cross(transported,x)),simd_dot(transported,x))
      let maxRoll = 2 * Float.pi * frameTime
      x = simd_quatf(angle:min(maxRoll,max(-maxRoll,angle)),axis:shaft).act(transported)
      x = simd_normalize(x-shaft*simd_dot(x,shaft))
    }
    previousGrip = (shaft,x)
    link(wristBridge,crease,wrist+x*0.024)
    racket.simdPosition = wrist
    racket.simdOrientation = simd_quatf(simd_float3x3(columns:(x,shaft,simd_cross(x,shaft))))
    free.simdPosition = freeHand
    free.simdOrientation = simd_quatf(from:V(0,1,0),to:simd_normalize(freeHand-freeElbow))
    free.simdScale.x = side
  }
}

private func courtShoe(_ parent:SCNNode, cream:UIColor, coral:UIColor) {
  let zs: [Float] = [-0.14,-0.121,-0.084,-0.035,0.017,0.061,0.096,0.119]
  let widths: [Float] = [0.024,0.050,0.064,0.066,0.057,0.051,0.049,0.032]
  let heights: [Float] = [0.018,0.027,0.038,0.046,0.055,0.050,0.041,0.027]
  let centers = zip(zs,heights).map { V(0,$1-0.034,$0) }
  let upper = mesh(equipmentMesh(centers,widths:widths,depths:heights,reference:V(1,0,0)),cream,parent)
  upper.name = "CourtShoeUpper"
  let sole = mesh(equipmentMesh(zs.map { V(0,-0.032,$0) },widths:widths,depths:Array(repeating:0.010,count:zs.count),reference:V(1,0,0)),coral,parent)
  sole.name = "Outsole"
  for i in 0..<3 {
    let z = Float(i)*0.015-0.054
    let lace = mesh(SCNCapsule(capRadius:0.003,height:0.055),.white,parent,V(0,0.051+Float(i)*0.005,z))
    lace.simdEulerAngles.z = .pi/2-0.15
  }
}

struct CourtContactSample {
  let time: Double
  // The two bed vectors span the world-space inner semi-axes.
  let shoulder, elbow, wrist, bedCenter, bedAcross, bedAlong, corkCenter: SIMD3<Float>
  let corkRadius: Float

  var touchesBed: Bool {
    let a = simd_length(bedAcross), b = simd_length(bedAlong)
    guard a > 0, b > 0, corkRadius > 0 else { return false }
    let u = bedAcross/a, v = bedAlong/b
    let d = corkCenter-bedCenter
    let height = simd_dot(d,simd_normalize(simd_cross(u,v)))
    guard abs(height) <= corkRadius else { return false }
    let x = simd_dot(d,u), y = simd_dot(d,v)
    if x*x/(a*a) + y*y/(b*b) <= 1 { return true }

    // Project an exterior point onto the ellipse by solving its monotone
    // Lagrange multiplier equation. Include the out-of-plane gap for the cork.
    let ax = a*x, by = b*y
    var lo: Float = 0, hi = hypot(ax,by)
    for _ in 0..<24 {
      let t = (lo+hi)/2
      let px = ax/(a*a+t), py = by/(b*b+t)
      if px*px+py*py > 1 { lo = t } else { hi = t }
    }
    let dx = x*hi/(a*a+hi), dy = y*hi/(b*b+hi)
    return dx*dx+dy*dy+height*height <= corkRadius*corkRadius
  }
}

private final class CourtPlayer {
  private var hands: PlayerHands?
  let root = SCNNode()
  var groundShadow: SCNNode?
  private let limbs: [SCNNode]
  private let torso, neck, head, hair, sleeve, offSleeve: SCNNode
  private let shoes: [SCNNode]
  private let rim, grip, palm, thumb, elbowJoint, wristJoint: SCNNode
  private var limbSkins: [PlayerLimbSkin] = []
  private struct PoseHistory {
    var localContact = V.zero
    var latestContact = -Double.infinity
    var armTime: Double?
    var gripAxis: V?
    var rearTurn: Float = 0
    var rearLean: Float = 0
    var rearLateral: Float = 0
    var crossBodyTurn: Float = 0
    var rivalLoad: Float = 0
    var serveSetup: Float = 0
    var supportShift: Float = 0
    var rescueReach = V.zero
    var missStartTip = V.zero
    var missedRescueTip = V.zero
    var confirmedRescue = V.zero
    var rescueStart = -Double.infinity
    var gripRoll: Float = 0
    var elbowPlane: V?
    var lastHand: Float = 0
    var stridePhase: Float = 0
    var previous: V?
    var braceOffset = [Float](repeating:0,count:2)
    var bracePoint: Int?
    var planted: [V?] = [nil,nil]
    var launchTime = -Double.infinity
    var launchSpeed: Float = 0
    var jumpedFlight = -Double.infinity
  }
  private var history = PoseHistory()
  init(_ parent: SCNNode, _ shirt: UIColor, heroine: Bool = false, rival: Bool = false) {
    parent.addChildNode(root)
    let skin = UIColor(red: 0.83, green: 0.59, blue: 0.43, alpha: 1)
    torso = mesh(jerseyGeometry(),shirt,root)
    torso.name = "MatchJersey"
    neck = mesh(SCNCylinder(radius:0.064,height:1),skin,root)
    sleeve = mesh(SCNCapsule(capRadius:0.071,height:0.20),shirt,root)
    offSleeve = mesh(SCNCapsule(capRadius:0.071,height:0.20),shirt,root)
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
    if heroine || rival { styleMatchPlayer(rival: rival) }
  }

  private func installLimbSkins(shirt: UIColor, shorts: UIColor) {
    let skin = UIColor(red:0.92,green:0.66,blue:0.49,alpha:1)
    for (i,name) in ["LeftLeg","RightLeg","RacketArm","FreeArm"].enumerated() {
      limbSkins.append(PlayerLimbSkin(parent:root,name:name,leg:i<2,skin:skin,cloth:i<2 ? shorts : shirt))
    }
    // Keep the original transforms as IK and diagnostic landmarks.
    for i in [0,1,2,3,4,5,7,8] {
      limbs[i].geometry = nil
    }
    for node in [elbowJoint,sleeve,offSleeve] { node.geometry = nil }
  }

  private func styleMatchPlayer(rival: Bool) {
    root.name = rival ? "MatchRival" : "V2Player"
    let ink = UIColor(red:0.23,green:0.15,blue:0.12,alpha:1)
    let coral = rival ? UIColor(red:0.86,green:0.76,blue:0.57,alpha:1) : UIColor(red:0.93,green:0.45,blue:0.37,alpha:1)
    let teal = rival ? UIColor(red:0.29,green:0.28,blue:0.27,alpha:1) : UIColor(red:0.23,green:0.53,blue:0.51,alpha:1)
    let cream = UIColor(red:1,green:0.93,blue:0.82,alpha:1)
    @discardableResult func oval(_ parent: SCNNode, _ name: String, _ center: V, _ radii: V, _ color: UIColor) -> SCNNode {
      let node = mesh(SCNSphere(radius:1),color,parent,center)
      node.name = name
      node.simdScale = radii
      return node
    }
    // Ring meshes retain editable material groups after exporting the posed model.
    // The meridian direction supplies normals, including asymmetric temple and cheek profiles.
    func rings(_ points: [[V]], colors: [UIColor], group: (Int, Int) -> Int = { _,_ in 0 }) -> SCNGeometry {
      let columns = points[0].count
      var indices = [[Int32]](repeating:[], count:colors.count)
      var verts = [SCNVector3](), normals = [SCNVector3]()
      for (row, ring) in points.enumerated() {
        let center = ring.reduce(V.zero,+)/Float(columns)
        for j in ring.indices {
          let next = (j+1)%columns
          let t = ring[next]-ring[(j+columns-1)%columns]
          let rise = points[min(row+1,points.count-1)][j]-points[max(0,row-1)][j]
          let raw = simd_cross(rise,t)
          let radial = ring[j]-center
          let normal = simd_normalize(simd_length_squared(raw)>1e-16 ? raw : radial)
          let outward = simd_dot(normal,radial) >= 0
          verts.append(SCNVector3(ring[j]))
          normals.append(SCNVector3(outward ? normal : -normal))
          if row+1 < points.count {
            let a = Int32(row*columns+j), b = Int32(row*columns+next), n = Int32(columns)
            indices[group(row,j)] += outward ? [a,a+n,b,b,a+n,b+n] : [a,b,a+n,b,b+n,a+n]
          }
        }
      }
      let geom = SCNGeometry(sources:[SCNGeometrySource(vertices:verts),SCNGeometrySource(normals:normals)],
                             elements:indices.map { SCNGeometryElement(indices:$0,primitiveType:.triangles) })
      geom.materials = colors.map {
        let m = SCNMaterial(); m.diffuse.contents = $0; m.isDoubleSided = true; return m
      }
      return geom
    }
    typealias Section = (p:V, w:Float, d:Float)
    func sweep(_ parent:SCNNode, _ name:String, _ controls:[Section], _ colors:[UIColor], streak:Bool = false) {
      // Catmull-Rom interpolation rounds the outside silhouette of each drawn lock.
      // Keep deterministic cross-sections so the base mesh can be exchanged with DCC tools.
      var shape = [Section]()
      for i in 0..<controls.count-1 {
        let a = controls[max(i-1,0)].p, b = controls[i].p, c = controls[i+1].p
        let d = controls[min(i+2,controls.count-1)].p
        for sub in 0..<3 {
          let u = Float(sub)/3, u2 = u*u, u3 = u2*u
          let center = (2*u3-3*u2+1)*b + (u3-2*u2+u)*(c-a)*0.5
            + (-2*u3+3*u2)*c + (u3-u2)*(d-b)*0.5
          shape.append((center, controls[i].w*(1-u)+controls[i+1].w*u,
            controls[i].d*(1-u)+controls[i+1].d*u))
        }
      }
      shape.append(controls.last!)
      let sides = 16
      var ringsAtPath = [[V]]()
      for i in shape.indices {
        let tangent = simd_normalize(shape[min(i+1,shape.count-1)].p-shape[max(i-1,0)].p)
        let guide = abs(tangent.x)>0.90 ? V(0,0,1) : V(1,0,0)
        let across = simd_normalize(guide-tangent*simd_dot(guide,tangent))
        let depth = simd_cross(tangent,across)
        ringsAtPath.append((0..<sides).map { j in
          let a = Float(j)*2*Float.pi/Float(sides)
          return shape[i].p + across*(shape[i].w*cos(a)) + depth*(shape[i].d*sin(a))
        })
      }
      let n = SCNNode(geometry:rings(ringsAtPath,colors:colors) { _,j in streak && (3...4).contains(j) ? 1 : 0 })
      n.name = name; parent.addChildNode(n)
    }
    let faceSkin = UIColor(red:0.99,green:0.76,blue:0.61,alpha:1)
    let lock = UIColor(red:0.35,green:0.24,blue:0.17,alpha:1)
    let glint = UIColor(red:0.46,green:0.32,blue:0.22,alpha:1)
    let rose = UIColor(red:0.77,green:0.28,blue:0.25,alpha:1)
    let gold = UIColor(red:0.66,green:0.36,blue:0.10,alpha:1)
    head.name = "Head"
    let face: [(y:Float,w:Float,d:Float,z:Float)] = [
      (-0.158,0.004,0.004,-0.035),(-0.149,0.041,0.043,-0.035),(-0.132,0.071,0.063,-0.023),
      (-0.105,0.099,0.093,-0.007),(-0.070,0.121,0.117,0),(-0.038,0.134,0.130,0.002),
      (0,0.137,0.135,0.005),(0.042,0.138,0.139,0.007),(0.081,0.134,0.137,0.010),
      (0.117,0.125,0.125,0.012),(0.146,0.103,0.101,0.015),(0.170,0.060,0.060,0.017),(0.179,0.001,0.001,0.017)]
    head.geometry = rings(face.map { f in (0..<40).map { j in
      let a = Float(j)*2*Float.pi/40
      return V(cos(a)*f.w,f.y,f.z+sin(a)*f.d)
    } },colors:[faceSkin])
    neck.geometry?.firstMaterial?.diffuse.contents = faceSkin
    hair.name = "Hair"
    // Position is driven 45 mm above the face origin by the runtime skeleton.
    var capRings = [[V]]()
    for i in 0...16 {
      capRings.append((0..<48).map { j in
        let a = Float(j)*2*Float.pi/48
        let front = max(0,-sin(a))
        let hairline = -0.068 - 0.024*max(0,sin(a)) + 0.133*front*front - 0.026*cos(a)*front
        let lat = asin((hairline-0.025)/0.172)
        let phi = lat + (1.568-lat)*Float(i)/16
        return V(0.156*cos(phi)*cos(a), -0.020+0.177*sin(phi), 0.005+0.157*cos(phi)*sin(a))
      })
    }
    hair.geometry = rings(capRings,colors:[ink,lock]) { _,j in [1,2,9,10,21,22,40].contains(j) ? 1 : 0 }
    // A larger face and a continuous crown read in the far player's few dozen pixels.
    head.simdScale = V(1.09,1.06,1.08)
    hair.simdScale = head.simdScale
    if rival {
      head.simdEulerAngles.y = .pi
      hair.simdEulerAngles.y = .pi
      let band = (0...2).map { row in (0..<40).map { j -> V in
        let a = 2*Float.pi*Float(j)/40
        return V(0.157*cos(a),Float(row)*0.017+0.010,0.160*sin(a))
      } }
      let headband = SCNNode(geometry:rings(band,colors:[cream]))
      headband.name = "RivalHeadband"
      hair.addChildNode(headband)
    } else {
      oval(hair,"HairTie",V(-0.01,0.115,0.136),V(0.058,0.050,0.050),coral)
      for side: Float in [-1,1] {
        let loop = oval(hair,"RibbonLoop",V(side*0.055-0.01,0.140,0.153),V(0.046,0.025,0.018),coral)
        loop.simdEulerAngles.z = side*0.56
      }
      for k in 0..<4 {
        let offset = Float(k)-1.5
        let x = offset*0.030, z = abs(offset)*0.018, end = offset*0.046
        let curl: [Section] = [
          (V(-0.01+x*0.25,0.109,0.116),0.018,0.019),
          (V(-0.028+x*0.70,0.156,0.157+z),0.033,0.040),
          (V(-0.065+x,0.158,0.205+z),0.041,0.043),
          (V(-0.100+x,0.103,0.249+z),0.043,0.041),
          (V(-0.110+x,0.035,0.263+z),0.042,0.036),
          (V(-0.087+x,-0.032,0.251+z),0.040,0.034),
          (V(-0.092+x,-0.110,0.255+z),0.033,0.030),
          (V(-0.128+end,-0.189+offset*0.010,0.275+z),0.026,0.023),
          (V(-0.170+end,-0.218+offset*0.022,0.320+z),0.012,0.012),
          (V(-0.192+end,-0.205+offset*0.029,0.353+z),0.001,0.001)]
        sweep(hair,k == 0 ? "Ponytail" : "PonytailLock\(k)",curl,[k%2 == 0 ? ink : lock,glint],streak:true)
      }
    }
    // Bangs sweep from the part into tapered side locks; eyes remain visible in three-quarter view.
    for s: Float in [-1,1] {
      let longer = s < 0
      let fringe: [Section] = [
        (V(0.037,0.113,-0.064),0.017,0.017),(V(s*0.044,0.089,-0.108),0.037,0.025),
        (V(s*0.081,0.068,-0.114),0.033,0.019),(V(s*0.113,0.030,-0.097),0.025,0.021),
        (V(s*0.129,-0.014,-0.079),0.022,0.018),(V(s*0.137,-0.062,-0.074),0.016,0.015),
        (V(s*0.131,longer ? -0.124 : -0.096,-0.074),0.001,0.001)]
      sweep(hair,"Fringe",fringe,[ink,glint],streak:true)
      oval(head,"Ear",V(s*0.128,-0.020,0),V(0.024,0.038,0.014),faceSkin)
      let eye = oval(head,"Eye",V(s*0.053,0.002,-0.119),V(0.033,0.031,0.010),cream)
      eye.simdEulerAngles.y = -s*0.30
      eye.simdEulerAngles.z = s*0.11
      oval(eye,"AmberIris",V(-s*0.07,-0.01,-0.78),V(0.64,0.89,0.49),gold)
      oval(eye,"Pupil",V(-s*0.07,0.06,-1.05),V(0.34,0.65,0.33),ink)
      oval(eye,"Catchlight",V(-0.17,0.35,-1.29),V(0.18,0.19,0.14),.white)
      sweep(head,"UpperLash",[(V(s*0.020,0.010,-0.128),0.001,0.001),(V(s*0.039,0.031,-0.127),0.004,0.004),(V(s*0.065,0.031,-0.119),0.004,0.004),(V(s*0.090,0.020,-0.103),0.001,0.001)],[ink])
      oval(head,"Brow",V(s*0.054,0.055,-0.118),V(0.027,0.006,0.005),ink).simdEulerAngles.y = -s*0.34
    }
    sweep(head,"Nose",[(V(0,0.019,-0.128),0.001,0.001),(V(0,-0.016,-0.134),0.010,0.005),
                       (V(0,-0.041,-0.148),0.015,0.009),(V(0,-0.048,-0.134),0.007,0.003)],[faceSkin])
    sweep(head,"Smile",[(V(-0.031,-0.072,-0.112),0.001,0.001),(V(-0.015,-0.079,-0.118),0.002,0.002),
                        (V(0,-0.080,-0.120),0.003,0.002),(V(0.017,-0.076,-0.117),0.002,0.002),
                        (V(0.030,-0.070,-0.114),0.001,0.001)],[rose])

    // Split the continuous shirt into sewing panels on ring boundaries.
    let pattern: [(Float,Float,Float,Float,Float)] = [
      (-0.050,0.143,0.103,0.96,0.20),(-0.034,0.151,0.108,0.88,0.17), (0.020,0.159,0.116,0.68,0.13),
      (0.110,0.149,0.109,0.45,0.16),(0.195,0.141,0.103,0.28,0.28),(0.290,0.157,0.122,0.25,0.42),
      (0.357,0.181,0.134,0.28,0.44),(0.420,0.192,0.124,0.21,0.53),(0.458,0.198,0.112,0.14,0.56),
      (0.486,0.164,0.106,0.08,0.54),(0.509,0.079,0.067,0.03,0.53),(0.521,0.069,0.062,0.03,0.53)]
    var shirtRings = [[V]]()
    for (y,w,d,half,shift) in pattern {
      let anchors: [Float] = [-half+shift,half+shift,Float.pi-half-shift,Float.pi+half-shift,2*Float.pi-half+shift]
      var row = [V]()
      for n in 0..<4 {
        for j in 0..<8 {
          let a = anchors[n]+(anchors[n+1]-anchors[n])*Float(j)/8
          let collarDrop = y >= 0.486 ? max(0,-sin(a))*max(0,-sin(a))*0.022 : 0
          // A loose jersey breaks into small diagonal folds as it meets the waistband.
          let hem = max(0,1-abs(y-0.03)/0.20)
          let fold = hem*(0.004*cos(6*a+10*y) + 0.003*sin(3*a-13*y))
          row.append(V((w*1.12+fold)*cos(a),y-collarDrop,(d*1.07+fold)*sin(a)))
        }
      }
      shirtRings.append(row)
    }
    let seam = rival ? UIColor(red:0.62,green:0.51,blue:0.39,alpha:1) : UIColor(red:0.80,green:0.34,blue:0.27,alpha:1)
    torso.geometry = rings(shirtRings,colors:[coral,seam,cream]) { i,j in
      if i == pattern.count-2 { return 2 }
      return (i == 0 || (i < 8 && (j<5 || (17..<22).contains(j)))) ? 1 : 0
    }
    // Cut the waistband to the same axes as the jersey, then flare over both
    // hip sockets. The inseam rises between the moving thigh panels.
    let waistSections: [(y:Float,width:Float,depth:Float,rise:Float)] = [
      (-0.105,0.164,0.088,0.020),(-0.090,0.198,0.124,0.017),
      (-0.053,0.210,0.137,0.006),(-0.013,0.204,0.135,0),
      (0.035,0.176,0.127,0),(0.051,0.170,0.125,0),
      (0.058,0.165,0.122,0),(0.059,0.149,0.107,0)]
    let panels: [[V]] = waistSections.map { r in
      (0..<40).map { i in
        let a = 2*Float.pi*Float(i)/40
        return V(r.width*cos(a),r.y+r.rise*pow(abs(sin(a)),4),r.depth*sin(a))
      }
    }
    let waistband = UIColor(red:0.05,green:0.39,blue:0.40,alpha:1)
    let shorts = SCNNode(geometry:rings(panels,colors:[teal,waistband]) { row,_ in row >= 4 ? 1 : 0 })
    shorts.name = "Shorts"
    torso.addChildNode(shorts)
    for shoe in shoes {
      shoe.geometry?.firstMaterial?.colorBufferWriteMask = []
      shoe.geometry?.firstMaterial?.writesToDepthBuffer = false
      if rival { shoe.simdEulerAngles.y = .pi }
      courtShoe(shoe,cream:cream,coral:UIColor(red:0.83,green:0.51,blue:0.24,alpha:1))
    }
    let skin = (head.geometry?.firstMaterial?.diffuse.contents as? UIColor) ?? .systemOrange
    wristJoint.geometry = nil
    hands = PlayerHands(parent:root,skin:skin)
    palm.geometry = nil
    thumb.geometry = nil
    sleeve.name = "RacketSleeve"
    limbs[4].name = "RacketUpperArm"
    palm.name = "RacketHand"
    grip.name = "RacketGrip"
    rim.name = "StringBed"
    rim.geometry?.firstMaterial?.diffuse.contents = UIColor(red:0.56,green:0.35,blue:0.14,alpha:1)
    for wire in rim.childNodes { wire.geometry?.firstMaterial?.diffuse.contents = cream }
    limbs[6].geometry?.firstMaterial?.diffuse.contents = ink
    installLimbSkins(shirt:coral,shorts:teal)
    root.enumerateChildNodes { node,_ in
      for mat in node.geometry?.materials ?? [] {
        mat.lightingModel = .constant
        mat.shaderModifiers = [.surface: """
        #pragma body
        float3 n = normalize(_surface.normal);
        float light = dot(n, normalize(float3(-0.44, 0.70, 0.57)));
        float shade = 0.65*smoothstep(-0.23,0.20,light) + 0.35*smoothstep(0.29,0.79,light);
        _surface.diffuse.rgb *= mix(float3(0.58,0.53,0.51),float3(1.0,0.97,0.92),shade);
        _surface.diffuse.rgb *= mix(0.70,1.0,smoothstep(0.05,0.38,abs(dot(n,normalize(_surface.view)))));
        """]
      }
    }

  }
  #if os(macOS)
  var legLengths: [Float] { limbs.prefix(4).map { $0.simdScale.y } }
  var armPoints: [V] {
    let elbow = limbs[4].simdPosition + limbs[4].simdOrientation.act(V(0,limbs[4].simdScale.y/2,0))
    return [elbow,palm.simdPosition,rim.simdPosition]
  }
  #endif
  func copyPoseHistory(from source: CourtPlayer) {
    history = source.history
    // These solved node positions feed the next frame’s continuity constraints.
    rim.simdPosition = source.rim.simdPosition
    palm.simdPosition = source.palm.simdPosition
    elbowJoint.simdPosition = source.elbowJoint.simdPosition
  }

  func contactSample(time: Double, corkCenter: V, corkRadius: Float) -> CourtContactSample? {
    guard let hoop = rim.geometry as? SCNTorus else { return nil }
    let radius = Float(hoop.ringRadius - hoop.pipeRadius)
    let shoulder = limbs[4].simdConvertPosition(V(0,-0.5,0), to:nil)
    return CourtContactSample(time:time, shoulder:shoulder, elbow:elbowJoint.simdWorldPosition,
      wrist:wristJoint.simdWorldPosition, bedCenter:rim.simdWorldPosition,
      bedAcross:rim.simdConvertVector(V(radius,0,0),to:nil),
      bedAlong:rim.simdConvertVector(V(0,0,radius),to:nil),
      corkCenter:corkCenter, corkRadius:corkRadius)
  }
  // Holding the bed point fixed leaves two choices: the grip position around
  // the shaft cone and the elbow around the shoulder-to-grip line. Only search
  // these degrees of freedom when the ordinary rear swing enters the body.
  private func clearRearSwing(
    socket: V, tip: V, dir: V, wrist: V, elbow: V,
    head: V, hips: V, collar: V, lateral: V
  ) -> (dir: V, wrist: V, elbow: V) {
    let up = simd_normalize(collar - hips)
    let right = simd_normalize(lateral - up * simd_dot(lateral, up))
    let forward = simd_cross(right, up)
    let face = head + V(0, 0.015, 0)
    func segmentGap(_ a: V, _ b: V, _ point: V) -> Float {
      let span = b - a
      let t = min(1, max(0, simd_dot(point - a, span) / max(0.000001, simd_length_squared(span))))
      return simd_length(a + t * span - point)
    }
    func clearance(_ w: V, _ e: V) -> Float {
      let headGap = min(segmentGap(w, tip, face) - 0.224, segmentGap(e, w, face) - 0.248)
      func jerseyGap(_ point: V) -> Float {
        let delta = point - hips
        let height = simd_dot(delta, up)
        let horizontal = hypot(simd_dot(delta, right) * 0.72, simd_dot(delta, forward))
        return max(horizontal - 0.184, -0.09 - height, height - 0.537)
      }
      var gap = headGap
      for t: Float in [0, 0.25, 0.5, 0.75, 1] {
        gap = min(gap, jerseyGap(e + (w - e) * t), jerseyGap(w + (tip - w) * t))
      }
      // The narrow handle extends 65 mm behind the palm and needs less
      // shirt clearance than the forearm envelope.
      let gripEnd = w + (w - tip) * (0.065 / 0.49)
      return min(gap, jerseyGap(gripEnd) + 0.018)
    }
    var best = (dir: dir, wrist: wrist, elbow: elbow)
    let originalGap = clearance(wrist, elbow)
    guard originalGap < 0 else { return best }
    let reach = simd_distance(tip, socket)
    guard reach > 0.001 else { return best }
    let axis = (tip - socket) / reach
    var cross = dir - axis * simd_dot(dir, axis)
    if simd_length_squared(cross) < 0.001 {
      cross = simd_cross(axis, abs(axis.y) < 0.9 ? V(0, 1, 0) : V(1, 0, 0))
    }
    cross = simd_normalize(cross)
    let reachCos = min(
      1, max(-1, (reach * reach + 0.49 * 0.49 - 0.588 * 0.588) / (2 * reach * 0.49)))
    var score = originalGap
    let angles: [Float] = [0, 30, -30, 65, -65, 105, -105, 145, -145, 180]
    for cosine in [max(reachCos, simd_dot(dir, axis)), reachCos, (1 + reachCos) * 0.5, 1] {
      let sine = sqrt(max(0, 1 - cosine * cosine))
      for azimuth in angles {
        let shaft =
          axis * cosine + simd_quatf(angle: azimuth * .pi / 180, axis: axis).act(cross) * sine
        let grip = tip - shaft * 0.49
        let span = grip - socket
        let length = simd_length(span)
        guard length >= 0.065 && length <= 0.5881 else { continue }
        let ray = span / length
        let along = (0.31 * 0.31 - 0.28 * 0.28 + length * length) / (2 * length)
        let center = socket + ray * along
        let radius = sqrt(max(0, 0.31 * 0.31 - along * along))
        var pole = elbow - center
        pole -= ray * simd_dot(pole, ray)
        if simd_length_squared(pole) < 1e-8 {
          pole = simd_cross(ray, abs(ray.y) < 0.9 ? V(0, 1, 0) : V(1, 0, 0))
        }
        pole = simd_normalize(pole)
        for bend in angles {
          let joint = center + simd_quatf(angle: bend * .pi / 180, axis: ray).act(pole) * radius
          let deviation = simd_distance(grip, wrist) + simd_distance(joint, elbow)
          let merit = min(0.025, clearance(grip, joint)) - 0.09 * deviation
          if merit > score {
            score = merit
            best = (shaft, grip, joint)
          }
        }
      }
    }
    return best
  }
  // Project the posed figure onto a small translucent patch in court metres.
  // Computing the union in one fragment avoids dark overlaps at bone joints.
  private func poseShadow(feet:V, lift:Float, hips:V, collar:V, head:V, elbow:V,
                          wrist:V, freeElbow:V, freeHand:V, tip:V) {
    guard let node = groundShadow, let ink = node.geometry?.firstMaterial else { return }
    node.simdPosition = feet + V(-0.55,0.012,0.16)
    func projected(_ p:V) -> SIMD2<Float> {
      let h = max(0,p.y+lift)
      return SIMD2(p.x-0.71*h,p.z+0.28*h)
    }
    func segment(_ name:String,_ p:V,_ q:V) {
      let a = projected(p), b = projected(q)
      ink.setValue(NSValue(scnVector4:SCNVector4(a.x,a.y,b.x,b.y)),forKey:name)
    }
    segment("body",hips,collar)
    segment("feetPair",shoes[0].simdPosition,shoes[1].simdPosition)
    segment("headElbow",head,elbow)
    segment("armPair",wrist,tip)
    segment("freePair",freeElbow,freeHand)
  }
  var tipInWorld: V { root.simdPosition + rim.simdPosition }
  func pose(_ feet: V, side: Float, facing: Float, now: Double, elapsed: Double,
            stroke: Stroke, impact: SwingImpact?, incoming: Flight?, outgoing: Flight?, intercept: Position?, still: Bool, point: Int? = nil, attemptedAt: Double? = nil, rivalReadiness: Float = 0, serving: Bool = false) {
    let interval = now - (history.armTime ?? now)
    let continuous = history.armTime != nil && interval >= 0 && interval < 0.15 &&
      history.lastHand == side && !still && simd_distance(feet,history.previous ?? feet) < 0.6
    let previousBed = rim.simdWorldPosition
    history.armTime = now
    history.lastHand = side
    let frameTime = Float(max(0,interval))
    // The far receiver loads through the hips as its own shot approaches
    // the other player, then unfolds into the next interception.
    let response: Float = continuous ? 1-exp(-12*frameTime) : 1
    history.rivalLoad += (rivalReadiness-history.rivalLoad)*response
    history.serveSetup += ((serving ? 1 : 0)-history.serveSetup)*response
    let delta = feet - (history.previous ?? feet)
    let distance = simd_length(delta)
    history.previous = feet
    history.stridePhase += min(0.35,distance)*8
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
    var approachWeight: Float = 1
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
      // A late forecourt pickup can still be live below the original meeting
      // point. Keep the lunge loaded until the shuttle leaves the near reach.
      let descendingPickup = lead < -0.02 && lead > -0.18 && target.y < 1.15
      let lowForecourt = !rearCourt && !middleCourt && target.y < 1.30
      tracksArrival = rearCourt || middleCourt || descendingPickup || lowForecourt
      let stillReachable = tracksArrival && now <= f.start+f.duration &&
        simd_length(world(f.at(now))-feet-V(0,1,0)) < 1.8
      let horizontal = hypot(target.x,target.z)
      // Lower the racket as a running player approaches a low net feed.
      // At the old 1.55 m gate an already advanced arrival clock could jump
      // straight from guard to a loaded reaching pose in a single tick.
      if lowForecourt {
        let t = min(1,max(0,(2.20-horizontal)/0.65))
        approachWeight = t*t*(3-2*t)
      }
      if (lead >= -0.06 || stillReachable) && lead < 0.42 && horizontal < (lowForecourt ? 2.20 : 1.55) {
        interceptLead = lead
        if tracksArrival {
          // Intercept anchors the feet. As the shuttle enters arm's reach,
          // prepare at its actual height and depth instead of the nominal point.
          let anticipation = middleCourt || f.shot != .drive ? 0.86 : 0.50
          let ahead = min(1.0/30,Double(frameTime))*anticipation
          let arrival = now+Double(lead)
          let advance = lowForecourt ? 0.16 : middleCourt ? 0.10 : 0.09
          preparationPoint = f.at(max(now+ahead,arrival-advance))
        }
        readyHeight = preparationPoint.map { world($0).y } ?? target.y
        windup = approachWeight * min(1,max(0,(0.42-lead)/0.26))
        // Plan the jump from the first nearby descending overhead contact.
        // A short, early interception can be above shoulder reach even if
        // the later nominal meeting point would allow a grounded attack.
        var jumpLead = lead
        var jumpHeight = target.y
        if target.y > 2.0 {
          for advance in [0.065, 0.035] {
            let early = world(f.at(hi-advance))-feet
            guard early.y > max(2.32,target.y), early.y <= 2.98,
                  hypot(early.x,early.z) <= 1.20 else { continue }
            // Preserve a little elbow flexion at the upper edge of reach.
            jumpHeight = early.y + 0.035
            jumpLead -= Float(advance)
            break
          }
        }
        let height = min(0.34,max(0,jumpHeight-2.26))
        let v = sqrt(2*9.81*height)
        if height > 0.07, jumpLead >= 0, jumpLead <= v/9.81, history.jumpedFlight != f.start {
          history.launchSpeed = v; history.launchTime = now; history.jumpedFlight = f.start
        }
      }
    }
    let age = Float(now-history.launchTime)
    let airtime = 2*history.launchSpeed/9.81
    let airPhase = airtime > 0 ? min(1,max(0,age/airtime)) : 0
    let lift: Float = !still && age >= 0 && age < airtime ? age*(history.launchSpeed-4.905*age) : 0
    let amplitude = history.launchSpeed*history.launchSpeed/19.62
    let landingAge = age-airtime
    let contactAge = outgoing.map { now-$0.start }
    let confirmed = contactAge.map { $0 >= 0 && $0 < 0.55 } ?? false
    let supportPhase = confirmed ? max(0, 1 - max(0, Float(contactAge!) - 0.07)/0.28) : windup
    let crouch: Float = !still && landingAge >= 0 && landingAge < 0.18
      ? amplitude*0.35*sin(.pi*landingAge/0.18) : (lift == 0 ? 0.065*supportPhase : 0)
    root.simdPosition = feet + V(0,lift,0)
    let step = distance > 0.0001 && !still ? sin(history.stridePhase)*0.22 : 0
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
    // Direction and deficit in metres relative to the feet. A close tap and
    // an above-tape kill keep their ordinary posture. Only low, wide or short
    // feeds extend the chest beyond the weight-bearing hip.
    // The game may reject an unreachable press while the original feed keeps
    // flying. Preserve the attempted save towards the ball seen on that press.
    let missAge = attemptedAt.map { now-$0 } ?? .infinity
    let missedAttempt = incoming != nil && missAge >= 0 && missAge < 0.42
    let rescueSpot = missedAttempt ? incoming?.at(now-missAge) : spot
    let rescueContact = rescueSpot.map { world($0)-feet } ?? .zero
    let horizontalReach = V(rescueContact.x,0,rescueContact.z)
    let gap = simd_length(horizontalReach)
    let deficit = min(1,max(0,(gap-1.00)/0.65))
    let underTape = min(1,max(0,(1.50-rescueContact.y)/0.45))
    let onOurSide = rescueSpot.map { ($0.y-0.5)*Double(-facing) >= 0 } ?? false
    let rescue = grounded && onOurSide && gap > 0.001
      ? horizontalReach/gap * (deficit*underTape) : .zero
    var targetRescue = rescue * windup
    if confirmed || missedAttempt {
      let start = confirmed ? outgoing!.start : now-missAge
      if abs(history.rescueStart-start) > 0.001 {
        if missedAttempt, let rescueSpot {
          history.missStartTip = previousBed
          history.missedRescueTip = world(rescueSpot)
        }
        history.confirmedRescue = rescue
        history.rescueStart = start
      }
      let unwind = min(1,max(0,(Float(now-start)-0.13)/0.28))
      targetRescue = history.confirmedRescue * (1-unwind*unwind*(3-2*unwind))
    }
    history.rescueReach += (targetRescue-history.rescueReach)*(continuous ? 1-exp(-16*frameTime) : 1)
    let rescueLoad = simd_length(history.rescueReach)
    let lowSupport: Float = high ? 0.22 : 0.66+0.34*waistLoad
    let desiredShift = grounded ? min(1,max(-1,relativeContact.x/0.55))*lowSupport*supportPhase : 0
    history.supportShift += (desiredShift-history.supportShift)*(continuous ? 1-exp(-20*frameTime) : 1)
    let load = abs(history.supportShift)
    let pelvis = V(history.supportShift*0.17,0,load*facing*0.035) + history.rescueReach*0.19
    let reachDip: Float = max(0.21*waistLoad,atNet && grounded ? 0.09 : 0)
    let lunge = reachDip*supportPhase
    // A receiver settles into an open split stance between shots. Ease it away
    // through preparation so the measured contact remains the IK target.
    let guardWeight: Float = grounded ? (1-min(1,abs(step)/0.09))*(1-min(1,supportPhase*1.8))*(confirmed ? 0 : 1) : 0
    // The reference receiver opens toward the racket side and loads the outside hip.
    // Fade this pose as the interception takes over so it cannot move the impact.
    let openGuard = guardWeight*(1-history.serveSetup)
    let dip = 0.065*guardWeight + 0.055*openGuard + crouch + lunge + load*0.055 + 0.22*rescueLoad + 0.17*history.rivalLoad
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
    history.rearTurn += (desiredRearTurn-history.rearTurn)*(continuous ? 1-exp(-18*frameTime) : 1)
    let shoulderTurn = history.rearTurn
    let sideDrive = !frontSpot && !high && (confirmed ? outgoing?.shot == .drive : incoming?.shot == .drive)
    let crossBody = sideDrive && backhand ? 0.68*supportPhase : 0
    history.crossBodyTurn += (crossBody-history.crossBodyTurn)*(continuous ? 1-exp(-20*frameTime) : 1)
    // Enter the confirmed rotation from the prepared shoulder angle. A
    // discrete phase change otherwise adds a second wrist displacement at
    // the button, on top of the distance the incoming shuttle just travelled.
    let entry = confirmed && rearCourt ? min(1,Float(contactAge!)/0.085) : 1
    let turn = side*facing*(0.25*guardWeight + 0.31*openGuard + swingTurn*entry + shoulderTurn + history.crossBodyTurn)
    let netReach: Float = frontSpot && grounded ? 0.11*supportPhase : 0
    // Leave room in front of the chest for a descending rear-court shot.
    // Load the rear hip during the approach and unload it through recovery.
    // The tracked shuttle can still be in midcourt while the receiver is
    // already preparing at the rear intercept. Keep avoidance active for both.
    let rearApproach = rearCourt || (incoming != nil && (intercept.map { abs($0.y-0.5) > 0.30 } ?? false))
    let rearLoad = facing < 0 && rearApproach
      ? (confirmed ? min(1,max(0,1-Float(contactAge!)/0.50)) : windup) : 0
    history.rearLean += (rearLoad-history.rearLean)*(continuous ? 1-exp(-14*frameTime) : 1)
    let outside = min(1,max(-1,-relativeContact.x/0.25))*rearLoad
    history.rearLateral += (outside-history.rearLateral)*(continuous ? 1-exp(-14*frameTime) : 1)
    let upperShift = pelvis + V(history.supportShift*0.07+0.2*history.rearLateral+side*0.183*openGuard,-0.12*rescueLoad,
      facing*(0.065*guardWeight+0.11*openGuard+load*0.08+netReach-0.3*history.rearLean)) + 0.28*history.rescueReach
    let shoulder = upperShift + V(side*0.20*cos(turn),1.37-dip,-side*0.20*sin(turn))
    let guardPose = V(side*(0.35+0.26*guardWeight+0.14*openGuard-0.23*history.rivalLoad),1.62-0.25*guardWeight-0.05*openGuard-dip-0.84*history.serveSetup,
                      facing*(0.48+0.27*history.rivalLoad+0.07*history.serveSetup))
    let swingSide = backhand ? -side : side
    var back = V(swingSide*(high ? 0.47 : 0.80),high ? 1.98 : low || stroke == .lift ? 0.75 : 1.30,-facing*0.32)
    var strike = V(swingSide*0.38,high ? 2.05 : low ? 0.72 : 1.38,facing*0.83)
    if confirmed, let outgoing {
      if history.latestContact != outgoing.start || !continuous {
        history.localContact = world(outgoing.from)-root.simdPosition
      }
      // At impact the string bed meets the shuttle in world space. After
      // release the arm moves with the player recovering toward court centre.
      strike = outgoing.returnStyle == nil ? world(outgoing.from)-root.simdPosition : history.localContact
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
        let near = approachWeight * max(byTime,1 - min(1,simd_length(approach)/0.62))
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
    // A contacted backhand rolls through the line, then draws the head up into
    // guard. Start beyond the sampled impact window so interception is unchanged.
    // A low backhand clear stays outside the near hip during the follow-through.
    if confirmed, outgoing?.returnStyle == .backClear, strike.y < 1.75 {
      let age = Float(contactAge!)
      let arc = blend(.zero,V(-side*0.42,0,facing*0.16),(age-0.01)/0.10)
      tip += blend(arc,.zero,(age-0.20)/0.18)
    }
    if confirmed, outgoing?.returnStyle == .backDrive {
      let age = Float(contactAge!)
      let carry = blend(.zero, V(side*0.055, 0.025, facing*0.055), (age-0.020)/0.095)
      tip += blend(carry, .zero, (age-0.115)/0.20)
    }
    if missedAttempt {
      // Continue from the prepared racket instead of snapping back to guard
      // on a rejected press. Both endpoints belong to the original press.
      var attempt = blend(history.missStartTip, history.missedRescueTip, Float(missAge)/0.12)
      if stroke == .drive {
        // A missed drive continues across the body after the player commits;
        // holding the extended hoop still lets the approaching cork pass through it.
        let sweep = min(1,Float(missAge)/0.10)
        attempt.x += swingSide * (0.28 * sin(.pi * sweep/2))
      }
      var recoverAt: Float = 0.13
      if stroke == .drive && impact?.probableBackhand == true {
        // Empty air offers no contact to brake against. Carry the hoop outward
        // and below the flight before folding the elbow back towards guard.
        let carry = V(side*0.52, -0.14, -facing*0.06)
        attempt += blend(.zero, carry, (Float(missAge)-0.020)/0.095)
        recoverAt = 0.165
      }
      tip = blend(attempt-root.simdPosition, guardPose, (Float(missAge)-recoverAt)/(0.41-recoverAt))
    }
    // After the follow-through, adjacent states can choose different guards
    // (a new feed, a landing, or expiry of the previous shot). Carry the
    // previous rendered racket position through these transitions.
    if !continuous { history.latestContact = -.infinity }
    if confirmed, let outgoing { history.latestContact = outgoing.start }
    let sinceContact = now-history.latestContact
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
    // A low reach is shared between hips and chest. Solve the loaded hip
    // before both legs so the jersey and thigh sockets stay connected.
    let lowReach = grounded ? max(0,min(1,(1.30-tip.y)/0.65))*supportPhase : 0
    let suggestedHip = pelvis + V(lean.x*0.52,min(0,lean.y)*0.62,lean.z*0.42)*lowReach + V(0,0.88-dip,0)
    let offShoulder = upperShift + V(-side*0.18*cos(turn),1.37-dip,side*0.18*sin(turn))+lean
    let collar = (shoulder+lean+offShoulder)*0.5
    // Preserve the racket solution. Let the pelvis follow the rib cage around
    // a rigid spine, then solve both legs from these same hip sockets.
    let hips = collar - simd_normalize(collar-suggestedHip)*0.49
    // Brace for a high receive and renew the base after landing. Keep
    // close blocks, low feeds and airborne leg trajectories unchanged.
    let highReceive = facing < 0 && grounded && !compact && (incoming != nil || confirmed)
    let brace = highReceive ? max(0,min(1,(preparationHeight-1.65)/0.45)) : 0
    if !continuous || history.bracePoint != point {
      history.braceOffset = [0,0]
    }
    history.bracePoint = point
    let after = Float(contactAge ?? -1)
    let readyBase = confirmed ? min(1,max(0,(after-0.12)/0.17),max(0,(0.55-after)/0.12)) : 0
    for i in 0..<2 {
      let sign: Float = i == 0 ? -1 : 1
      var ankle = V(sign*0.20,0.05 + lift*(sign > 0 ? 0.32 : 0.12),facing*(sign*side*lunge*1.7-sign*lift*0.22)) + travel*(sign*step)
      let loaded = max(0,sign*history.supportShift)
      ankle.x += sign*(0.125*guardWeight + 0.16*openGuard + 0.07*load + 0.21*loaded)
      // Receiver's racket foot trails toward the camera in the reference;
      // the lead shoe points into court. Service and supported reaches retain their own step.
      ankle.z += sign*side*facing*(0.095*guardWeight-0.38*openGuard)
      let extra = brace * max(0.15*supportPhase,0.14*readyBase)
      // The leading shoe catches the reach; the trailing leg counterbalances.
      let leadSide: Float = abs(history.rescueReach.x) > 0.18 ? (history.rescueReach.x > 0 ? 1 : -1) : side
      if sign != leadSide {
        ankle -= history.rescueReach*0.16
        ankle.y += rescueLoad*0.10
      }
      // Exchange lead and trailing legs during the overhead scissor jump.
      ankle.z += facing*sign*side*lift*1.25*cos(.pi*airPhase)
      // Land the racket foot before a grounded forecourt lunge. Blend out the
      // running stride before pinning the shoe; release it as the player recovers.
      let lowNetReach = grounded && low && spot.map { abs($0.y-0.5) <= 0.15 } == true
      let plantPhase = max(lowNetReach && sign == side ? min(1,supportPhase*1.35) : 0, sign == leadSide ? min(1,rescueLoad*1.55) : 0)
      if plantPhase >= 1, continuous {
        if history.planted[i] == nil { history.planted[i] = feet+ankle }
        ankle = history.planted[i]! - feet
        ankle.y = 0.05
      } else if !still, lift < 0.005, distance < 0.35, distance > 0.0001 {
        let stance = sign*cos(history.stridePhase) < 0
        if stance {
          if history.planted[i] == nil { history.planted[i] = feet+ankle }
          ankle = history.planted[i]! - feet
        } else {
          history.planted[i] = nil
          ankle.y += 0.105 * max(0,sign*cos(history.stridePhase)) * (1-plantPhase)
        }
      } else { history.planted[i] = nil }
      // Plant on the floor and solve a two-link leg. If a stride overshoots,
      // move the foot along the ground instead of lengthening the shin.
      let hip = hips + V(sign*0.12,0,0)
      let thigh: Float = 0.445, shin: Float = 0.445
      let limit = thigh+shin-0.001
      ankle.y = max(ankle.y, hip.y-limit)
      let dy = ankle.y-hip.y
      let horizontal = V(ankle.x-hip.x,0,ankle.z-hip.z)
      let available = sqrt(max(0,limit*limit-dy*dy))
      if simd_length(horizontal) > available {
        ankle = hip + horizontal*(available/max(0.001,simd_length(horizontal))) + V(0,dy,0)
      }
      // Apply the extra stance after the unmodified foot-plant solve. It
      // must never get captured by the anchor or disappear on its release.
      let room = sqrt(max(0,available*available-pow(ankle.z-hip.z,2)))
      // Withdraw the brace before the running hip reaches its leg limit.
      // A pinned shoe must not spread while the player is chasing a feed.
      let reachRoom = max(0,room-sign*(ankle.x-hip.x))
      let target = distance < 0.002 ? min(extra,max(0,0.37-sign*ankle.x),max(0,reachRoom-0.16)) : 0
      let previous = history.braceOffset[i]
      let stepLimit = min(frameTime,1.0/30)*0.18
      let next = previous + max(-stepLimit,min(stepLimit,target-previous))
      history.braceOffset[i] = min(next,reachRoom)
      ankle.x += sign*history.braceOffset[i]
      let axis = simd_normalize(ankle-hip)
      let length = simd_distance(ankle,hip)
      let guide = V(sign*(0.10+loaded*0.12),0,facing)
      let pole = simd_normalize(guide-axis*simd_dot(guide,axis))
      let along = (thigh*thigh-shin*shin+length*length)/(2*length)
      let knee = hip+axis*along+pole*sqrt(max(0,thigh*thigh-along*along))
      let toeYaw = (facing > 0 ? Float.pi : 0) + sign*facing*openGuard*0.28
      shoes[i].simdEulerAngles.y = toeYaw
      shoes[i].simdPosition = ankle + V(0,-0.007,facing*0.045)
      link(limbs[2*i],hip,knee)
      link(limbs[2*i+1],knee,ankle)
      if !limbSkins.isEmpty { limbSkins[i].pose(hip,knee,ankle) }
    }
    let duck = side*0.56*history.rearLean
    let headRoll = simd_quatf(angle: duck, axis: V(0,0,1))
    head.simdPosition = collar + headRoll.act(V(0,0.216,0))

    let socket = shoulder + lean
    // Fixed upper arm and forearm. Out-of-reach button hits must not stretch the arm.
    // In guard the head sits above the grip, with the hand in front of the elbow.
    // At full reach gradually align the shaft with the arm to keep contact attainable.
    let serveGrip = impact?.label.flatMap { ServeTraining(rawValue:$0) } != nil && confirmed
    let shaftPose = serveGrip ? simd_normalize(V(-side*0.50,-0.72,facing*0.55))
      : simd_normalize(V(swingSide*((backhand ? 0.52 : 0.38)+0.30*openGuard),
                                     low && active ? 0.24 : 0.85, facing*0.43))
    var preferred = shaftPose
    if continuous, let old = history.gripAxis {
      let recovering = incoming == nil && sinceContact > 0.20 && sinceContact < 1.20
      let alpha = 1-exp(-frameTime*(recovering ? 8 : compact ? 17 : 23))
      let mixed = old*(1-alpha)+shaftPose*alpha
      if simd_length_squared(mixed)>0.0001 { preferred = simd_normalize(mixed) }
    }
    // Multiple grip positions can put the string bed at the same contact. In the
    // first few frames use the closest feasible grip, then release into follow-through.
    let handoffAge = confirmed ? contactAge! : missAge
    let handoff: Float = continuous ? max(0,1-Float(handoffAge)/0.085) : 0
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
    var dir = simd_length(transverse) > 0.001
      ? reachDirection*cosAngle + simd_normalize(transverse)*sqrt(max(0,1-cosAngle*cosAngle))
      : reachDirection
    let deltaWrist = tip - dir*shaft - socket
    let ray = simd_length(deltaWrist) > 0.001 ? simd_normalize(deltaWrist) : dir
    let length = min(0.588,max(0.065,simd_length(deltaWrist)))
    var wrist = socket + ray*length
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
    if continuous, let old = history.elbowPlane {
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
    var elbow = center + bend*radius
    if facing < 0 && (rearApproach || history.rearLean > 0.02) {
      let adjusted = clearRearSwing(socket:socket, tip:wrist+dir*shaft, dir:dir, wrist:wrist, elbow:elbow,
                                    head:head.simdPosition, hips:hips, collar:collar, lateral:socket-offShoulder)
      dir = adjusted.dir
      wrist = adjusted.wrist
      elbow = adjusted.elbow
      let wristRay = simd_normalize(wrist-socket)
      let radial = elbow-socket-wristRay*simd_dot(elbow-socket,wristRay)
      if simd_length_squared(radial)>1e-7 { bend = simd_normalize(radial) }
    }
    history.elbowPlane = bend
    history.gripAxis = dir
    tip = wrist + dir*0.49
    if facing < 0 {
      var neckAxis = headRoll.act(V(0,1,0))
      if rearApproach || history.rearLean > 0.02 {
        let arm = wrist-elbow
        let face = head.simdPosition + V(0,0.02,0)
        let t = min(1,max(0,simd_dot(face-elbow,arm)/simd_length_squared(arm)))
        let away = face-(elbow+arm*t)
        let tangent = away-neckAxis*simd_dot(away,neckAxis)
        let clearance = max(0,0.235-simd_length(away))
        if simd_length_squared(tangent)>0.00001 {
          neckAxis = simd_normalize(neckAxis+simd_normalize(tangent)*min(0.48,clearance/0.205))
        }
      }
      let tilt = simd_quatf(from:V(0,1,0),to:neckAxis)
      let aim = incoming.map { world($0.at(now))-feet } ?? V(-feet.x,0, -4)
      let lookAngle = min(0.38,max(-0.38,atan2(-aim.x,max(1,-aim.z))))
      let gaze = tilt * simd_quatf(angle:lookAngle,axis:V(0,1,0))
      head.simdPosition = collar+neckAxis*0.216
      head.simdOrientation = gaze
      hair.simdOrientation = gaze
      hair.simdPosition = head.simdPosition+tilt.act(V(0,0.045,0.015))
    } else {
      hair.simdPosition = head.simdPosition+V(0,0.045,0.015)
    }
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
    history.gripRoll += (desiredRoll-history.gripRoll)*(continuous ? 1-exp(-24*frameTime) : 1)
    let forearmRoll = simd_quatf(angle:history.gripRoll,axis:handAxis)
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
    // Counterbalance the planted leg and the reach. The free arm opens back and
    // out on a lunge, guides an overhead preparation and folds away on contact.
    // The free hand sights an overhead feed during preparation and folds back
    // before the racket reaches the shuttle. Use time remaining to interception
    // so that confirming the stroke does not suddenly lower the guiding arm.
    let guideLead = confirmed ? -Float(contactAge ?? 0) : (interceptLead ?? 0.20)
    let releaseGuide = min(1,max(0,(guideLead+0.035)/0.18))
    let guide: Float = high && !frontSpot
      ? (confirmed ? 1 : windup)*releaseGuide*releaseGuide*(3-2*releaseGuide) : 0
    // Open the balance elbow on a flat feed; keep the racket side free to
    // intercept wherever the eventual button press falls.
    let flatBalance = sideDrive ? 0.22*supportPhase : 0
    let spread = min(1, load*1.4 + netReach*4.8 + 0.29*history.rivalLoad + (confirmed ? history.crossBodyTurn*0.5 : 0))
    let recoil = confirmed ? min(1,max(0,Float(contactAge!)/0.15))*supportPhase : 0
    let upperArm = V(-side*(0.16+0.25*guardWeight+0.51*spread+0.16*guide),
                     -0.59+1.04*guide-0.08*recoil, facing*(0.20-0.74*spread+0.18*guide))
    let lowerArm = V(-side*(0.12+0.44*spread), 0.17+0.64*guide-0.60*spread-0.28*recoil,
                     facing*(0.70-1.40*spread+0.10*guide))
    // Bend the free forearm towards the waist as the racket extends low.
    // Its elbow can still open backwards to balance the supported lunge.
    let fold = lowReach
    // In a settled split step the free elbow is behind the ribs; its hand
    // returns to the hip. Open the arm again to guide an incoming overhead.
    let waitingArm = openGuard*(1-guide)*(1-fold)
    let tuckedUpper = blend(upperArm,V(-side*0.38,-0.58,-facing*0.48),waitingArm)
    let tuckedLower = blend(lowerArm,V(side*0.29,-0.16,facing*0.52),waitingArm)
    let balanceUpper = tuckedUpper*(1-fold) + V(-side*0.32,-0.57,-facing*0.30)*fold
    let balanceLower = tuckedLower*(1-fold) + V(side*0.26,0.42,facing*0.36)*fold
    let balanceDirection = simd_normalize(balanceUpper) + V(-side, 0.20, -facing*0.35)*flatBalance
    let offElbow = offShoulder + simd_normalize(balanceDirection)*0.31
    let offHand = offElbow + simd_normalize(balanceLower)*0.28
    // Fit the shirt and neck to the existing rig sockets after the arm solve.
    // Rendering the torso never feeds back into reach, timing or racket IK.
    let spine = collar-hips
    let up = simd_normalize(spine)
    let lateral = (socket-offShoulder)*side
    let right = simd_normalize(lateral - up*simd_dot(up,lateral))
    torso.simdPosition = hips
    torso.simdOrientation = simd_quatf(simd_float3x3(columns:(right,up,simd_cross(right,up))))
    // Overlap both ends inside their adjacent meshes, including on a high
    // stretch. A world-up offset would expose a seam during a sideways lean.
    link(neck,collar-up*0.025,head.simdPosition)
    for (node,shoulderJoint,elbowPoint) in [(sleeve,socket,elbow),(offSleeve,offShoulder,offElbow)] {
      let arm = simd_normalize(elbowPoint-shoulderJoint)
      node.simdPosition = shoulderJoint+arm*0.035
      node.simdOrientation = simd_quatf(from:V(0,1,0),to:arm)
    }
    link(limbs[7],offShoulder,offElbow)
    link(limbs[8],offElbow,offHand)
    if !limbSkins.isEmpty {
      limbSkins[2].pose(socket,elbow,crease)
      limbSkins[3].pose(offShoulder,offElbow,offHand)
    }
    hands?.pose(wrist:wrist,crease:crease,shaft:dir,knuckles:knuckleSide,freeHand:offHand,freeElbow:offElbow,side:side,continuous:continuous,frameTime:frameTime)
    poseShadow(feet:feet,lift:lift,hips:hips,collar:collar,head:head.simdPosition,elbow:elbow,
               wrist:wrist,freeElbow:offElbow,freeHand:offHand,tip:tip)
    rim.simdPosition = tip
    // Local Z follows the long axis of the hoop. Roll its string bed with the forearm.
    let face = simd_normalize(V((backhand ? -side : side)*0.32,low ? 0.52 : 0.12,facing))
    var across = simd_cross(face,dir)
    if simd_length(across) < 0.04 { across = simd_cross(V(0,1,0),dir) }
    across = simd_quatf(angle:history.gripRoll,axis:dir).act(simd_normalize(across))
    rim.simdOrientation = simd_quatf(simd_float3x3(columns:(across,simd_cross(dir,across),dir)))
  }

}

// The parquet tile repeats at a physical scale. Seams and grain use one texture
// so the number of draw calls does not depend on the size of the playing hall.
private func parquetTile() -> CGImage? {
  let side = 512
  guard let context = CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,
    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
  context.setFillColor(red:0.56,green:0.40,blue:0.29,alpha:1)
  context.fill(CGRect(x:0,y:0,width:side,height:side))
  for row in 0..<16 {
    let offset = (row*47)%128
    for plank in -1..<5 {
      let seed = (row*13 + (plank+4)%4*7)%11
      let tint = CGFloat(seed)*0.006
      let x = 128*plank+offset, y = row*32
      context.setFillColor(red:0.77+tint,green:0.60+tint,blue:0.44+tint,alpha:1)
      context.fill(CGRect(x:x+1,y:y+1,width:127,height:31))
      for line in 0..<5 {
        let gx = x+(seed*3+line*17)%65, gy = y+3+(seed+line*7)%25
        context.setFillColor(red:0.61,green:0.44,blue:0.30,alpha:0.16)
        context.fill(CGRect(x:gx,y:gy,width:19+(line*11)%35,height:1))
      }
    }
  }
  return context.makeImage()
}

private func pavilionRoofFinish(fallback: SCNMaterial) -> SCNMaterial {
  var url = Bundle.main.url(forResource: "PavilionRoofGrain", withExtension: "jpg")
  #if os(macOS)
  if url == nil {
    url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("code/Clients/iOS/Resources/PavilionRoofGrain.jpg")
  }
  #endif
  guard let url, FileManager.default.fileExists(atPath:url.path) else { return fallback }
  let paint = fallback.copy() as! SCNMaterial
  paint.diffuse.contents = url
  paint.diffuse.wrapS = .repeat
  paint.diffuse.wrapT = .repeat
  paint.diffuse.mipFilter = .linear
  paint.diffuse.contentsTransform = SCNMatrix4MakeScale(4,1,1)
  return paint
}

private func pavilionFinish(_ color: UInt32) -> SCNMaterial {
  let material = SCNMaterial()
  material.lightingModel = .lambert
  material.diffuse.contents = UIColor(red:CGFloat((color >> 16) & 255)/255,
    green:CGFloat((color >> 8) & 255)/255,blue:CGFloat(color & 255)/255,alpha:1)
  return material
}

private func addPavilionJoinery(_ group:SCNNode, bays:[Float],curve:(Float,Float)->V) {
  guard bays.count >= 2 else { return }
  let bronze = pavilionFinish(0x554D44)
  let palette = [0x397C76,0xEDB950,0xD58A5D,0xEDCF84].map { pavilionFinish(UInt32($0)) }
  palette.forEach { $0.isDoubleSided = true }
  let cord = SCNCylinder(radius:0.012,height:1)
  cord.radialSegmentCount = 5
  cord.materials = [bronze]
  let collar = SCNBox(width:0.38,height:0.105,length:0.45,chamferRadius:0.016)
  collar.materials = [bronze]
  for side:Float in [-1,1] {
    for z in bays {
      let joint = SCNNode(geometry:collar)
      joint.simdPosition = curve(side * Float.pi/2,z)
      group.addChildNode(joint)
    }
    for bay in 1..<bays.count {
      // The flags hang along the galleries and remain outside the flight corridor.
      func anchor(_ t:Float) -> V {
        let z = bays[bay-1] + (bays[bay]-bays[bay-1])*t
        var p = curve(side*1.28,z)
        p.y -= 0.2 + 0.68*4*t*(1-t)
        p.x -= side*(0.10 + 0.22*sin(Float.pi*t))
        return p
      }
      for index in 0..<8 {
        let t = Float(index)/8
        let start = anchor(t), end = anchor(t+1/8)
        let line = SCNNode(geometry:cord)
        link(line,start,end)
        group.addChildNode(line)
        let a = anchor(t+0.025), b = anchor(t+0.10)
        let tip = (a+b)*0.5 + V(-side*0.095,-0.42,0.09)
        let fold = (a+b+tip)/3 + V(-side*0.075,0,0)
        let vertices = [a,b,tip,fold].map { SCNVector3($0) }
        let fabric = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],
          elements:[SCNGeometryElement(indices:[Int32(0),1,3,1,2,3,2,0,3],primitiveType:.triangles)])
        fabric.materials = [palette[(index+bay)%palette.count]]
        group.addChildNode(SCNNode(geometry:fabric))
      }
    }
  }
}

private func addPavilionFlowerBox(_ group:SCNNode,center:V,length:Float,alongZ:Bool) {
  let trough = SCNNode()
  trough.simdPosition = center
  if alongZ { trough.simdEulerAngles.y = .pi/2 }
  group.addChildNode(trough)
  let crate = pavilionFinish(0xAE7954), rim = pavilionFinish(0xD2A575)
  let soil = pavilionFinish(0x504A40)
  func board(_ size:V,_ at:V,_ material:SCNMaterial) {
    let geo = SCNBox(width:CGFloat(size.x),height:CGFloat(size.y),length:CGFloat(size.z),chamferRadius:0.012)
    geo.materials = [material]
    let node = SCNNode(geometry:geo)
    node.simdPosition = at
    trough.addChildNode(node)
  }
  board(V(length,0.42,0.56),V(0,0.21,0),crate)
  board(V(length+0.06,0.05,0.61),V(0,0.44,0),rim)
  board(V(length-0.05,0.02,0.48),V(0,0.47,0),soil)
  let leaf = [0x597546,0x75934E,0x496E55,0x9BA14F].map { pavilionFinish(UInt32($0)) }
  let blossom = [0xF0C16B,0xDC7E65,0xEBDDB1].map { pavilionFinish(UInt32($0)) }
  let count = max(3,Int(length*8))
  for i in 0..<count {
    let t = Float(i)*2.39996
    let p = V((Float(i)+0.5)/Float(count)*length-length/2,0.50,0.14*sin(t))
    for j in 0..<4 {
      let a = t+Float(j)*1.57
      let reach = V(cos(a)*0.14,0.14+0.08*sin(t+1),sin(a)*0.14)
      let width = V(-sin(a)*0.042,0,cos(a)*0.042)
      let mid = p+reach*0.55
      let points = [p,mid-width,p+reach,mid+width,mid+V(0,0.022,0)]
      let blade = SCNGeometry(sources:[SCNGeometrySource(vertices:points.map {SCNVector3($0)})],
        elements:[SCNGeometryElement(indices:[Int32(0),1,4,1,2,4,2,3,4,3,0,4],primitiveType:.triangles)])
      let material = leaf[(j+i)%leaf.count]
      material.isDoubleSided = true
      blade.materials = [material]
      trough.addChildNode(SCNNode(geometry:blade))
    }
    if i.isMultiple(of:2) {
      let flower = SCNSphere(radius:0.047)
      flower.segmentCount = 6
      flower.materials = [blossom[(i/2)%blossom.count]]
      for j in 0..<3 {
        let node = SCNNode(geometry:flower)
        node.simdPosition = p+V(0.047*cos(t+Float(j)*2.1),0.16,0.047*sin(t+Float(j)*2.1))
        trough.addChildNode(node)
      }
    }
  }
}

// The artist's calibrated view is used only to unwrap the venue. Every island
// occupies a separate world-space depth; the live camera uses normal projection.
private func paintedRiversideHall() -> SCNNode? {
  struct Surface: Decodable { let name:String; let rect:[Float] }
  let folder = "RiversideHall.scnassets"
  var url = Bundle.main.url(forResource:"Layout",withExtension:"json",subdirectory:folder)
  #if os(macOS)
  if url == nil {
    url = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
      .appendingPathComponent("code/Clients/iOS/Resources/\(folder)/Layout.json")
  }
  #endif
  guard let url, let data = try? Data(contentsOf:url),
        let surfaces = try? JSONDecoder().decode([Surface].self,from:data) else { return nil }
  let hall = SCNNode()
  hall.name = "RiversidePaintedArchitecture"
  let pitch:Float = 2.35 * .pi / 180
  let focal:Float = 225/tan(33.5 * Float.pi/360)
  let eye = V(0,1.90,12.61)
  func vertex(_ u:Float,_ v:Float) -> SCNVector3 {
    let x = (u-400)/focal, y = (225-v)/focal
    let ray = V(x,cos(pitch)*y-sin(pitch),-cos(pitch)-sin(pitch)*y)
    func groundDepth(_ row:Float) -> Float {
      let dy = cos(pitch)*(225-row)/focal-sin(pitch)
      return 1.925/max(0.015,-dy)
    }
    // Adjacent islands must agree where they meet. Giving the quay, gallery
    // and roof separate constant plane distances opens holes on a high clear.
    // Intersect each ray with one continuous vault, two galleries and the deck.
    let side = u < 390 ? (264-u)/264 : (u-502)/298
    let sideRow = 253+max(0,side)*(u<390 ? 90 : 95)
    let rx = (u-385)/132, ry = max(0,191-v)/66
    let endDepth = groundDepth(253)
    let barrel = endDepth/max(0.22,sqrt(rx*rx+ry*ry))
    let shell = max(10.5,min(endDepth,groundDepth(sideRow),barrel))
    // Recess the side window smoothly into its wall to preserve motion
    // parallax without pulling open the outline of a distant spectator.
    let riverX = max(0,1-pow((u-743)/142,2))
    let riverY = max(0,1-pow((v-178)/64,2))
    let reveal = 3.8*riverX*riverX*riverY*riverY
    let depth = min(shell+reveal,groundDepth(v))
    return SCNVector3(eye+ray*depth)
  }
  for surface in surfaces {
    guard surface.rect.count == 4 else { return nil }
    let bounds = surface.rect
    let file = url.deletingLastPathComponent().appendingPathComponent(surface.name+".png")
    guard FileManager.default.fileExists(atPath:file.path) else { return nil }
    let cols = max(2,Int(ceil((bounds[2]-bounds[0])/9)))
    let rows = max(2,Int(ceil((bounds[3]-bounds[1])/8)))
    var pos:[SCNVector3] = [], uv:[CGPoint] = [], indices:[Int32] = []
    for j in 0...rows {
      let t = Float(j)/Float(rows)
      for i in 0...cols {
        let s = Float(i)/Float(cols)
        pos.append(vertex(bounds[0]+s*(bounds[2]-bounds[0]),bounds[1]+t*(bounds[3]-bounds[1])))
        uv.append(CGPoint(x:CGFloat(s),y:CGFloat(t)))
        if i<cols && j<rows {
          let a = Int32(j*(cols+1)+i), b = a+Int32(cols+1)
          indices += [a,b,a+1,a+1,b,b+1]
        }
      }
    }
    let geo = SCNGeometry(sources:[SCNGeometrySource(vertices:pos),SCNGeometrySource(textureCoordinates:uv)],
                          elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
    let paint = SCNMaterial()
    paint.diffuse.contents = file
    paint.lightingModel = .constant
    paint.isDoubleSided = true
    paint.diffuse.mipFilter = .linear
    paint.diffuse.maxAnisotropy = 8
    paint.shaderModifiers = [.fragment:"if (_output.color.a < 0.5) { discard_fragment(); }"]
    geo.materials = [paint]
    let mesh = SCNNode(geometry:geo)
    mesh.name=surface.name
    mesh.castsShadow=false
    hall.addChildNode(mesh)
  }
  return hall
}

private func addRiversideHall(to root:SCNNode) {
  let architecture = SCNNode()
  func finish(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat) -> SCNMaterial {
    let material = SCNMaterial()
    material.diffuse.contents = UIColor(red:r,green:g,blue:b,alpha:1)
    material.lightingModel = .lambert
    return material
  }
  let oak = finish(0.59,0.35,0.21), honey = finish(0.78,0.54,0.32)
  let timber = finish(0.36,0.26,0.22), metal = finish(0.31,0.36,0.36)
  let coral = finish(0.80,0.34,0.24), cream = finish(0.96,0.86,0.66)
  func illustration(_ name:String, fallback:SCNMaterial) -> SCNMaterial {
    var url = Bundle.main.url(forResource:name, withExtension:"jpg")
    #if os(macOS)
    if url == nil {
      url = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        .appendingPathComponent("code/Clients/iOS/Resources/\(name).jpg")
    }
    #endif
    guard let url, FileManager.default.fileExists(atPath:url.path) else { return fallback }
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = url
    material.diffuse.mipFilter = .linear
    material.isDoubleSided = true
    return material
  }
  @discardableResult func block(_ size:V,_ at:V,_ material:SCNMaterial) -> SCNNode {
    let geometry = SCNBox(width:CGFloat(size.x),height:CGFloat(size.y),length:CGFloat(size.z),chamferRadius:0)
    geometry.materials = [material]
    let node = SCNNode(geometry:geometry)
    node.simdPosition = at
    architecture.addChildNode(node)
    return node
  }
  func beam(_ a:V,_ b:V,width:Float,depth:Float,material:SCNMaterial) {
    let node = block(V(width,1,depth),.zero,material)
    link(node,a,b)
  }

  let floor = SCNPlane(width:46,height:56)
  let boards = finish(0.82,0.65,0.49)
  if let tile = parquetTile() {
    boards.diffuse.contents = tile
    boards.diffuse.wrapS = .repeat
    boards.diffuse.wrapT = .repeat
    boards.diffuse.contentsTransform = SCNMatrix4MakeScale(11.5,14,1)
    boards.diffuse.mipFilter = .linear
  }
  floor.materials = [boards]
  let deck = SCNNode(geometry:floor)
  deck.name = "PerimeterFloor"
  deck.simdPosition = V(0,-0.055,-1)
  deck.simdEulerAngles.x = -.pi/2
  root.addChildNode(deck)

  // Glulam portal frames and boarded roof wings leave a broad glazed lantern
  // over centre court. Open sides and the far gable look through to the river.
  let bays:[Float] = [-15,-10,-5,0,5,10,15]
  func curve(_ angle:Float,_ z:Float) -> V {
    V(6.85*sin(angle),3.85+3.25*cos(angle),z)
  }
  addPavilionJoinery(architecture,bays:bays,curve:curve)
  let roofFinish = pavilionRoofFinish(fallback:honey)
  let sections = 24
  for z in bays {
    for side:Float in [-1,1] {
      block(V(0.26,3.85,0.31),V(side*6.85,1.90,z),timber)
      block(V(0.41,0.29,0.47),V(side*6.85,0.12,z),metal)
      beam(V(side*6.85,2.35,z),curve(side*1.04,z),width:0.17,depth:0.23,material:oak)
    }
    for i in 0..<sections {
      let a = (Float(i)/Float(sections)-0.5)*Float.pi
      let b = a+Float.pi/Float(sections)
      beam(curve(a,z),curve(b,z),width:0.28,depth:0.35,material:oak)
    }
  }
  let zMid:Float = 0
  for i in 0..<sections {
    let a = (Float(i)/Float(sections)-0.5)*Float.pi
    let b = a+Float.pi/Float(sections)
    let p = curve(a,zMid)+V(0,0.17,0), q = curve(b,zMid)+V(0,0.17,0)
    if abs((a+b)*0.5)>0.48 {
      beam(p,q,width:0.10,depth:30.4,material:roofFinish)
    }
    block(V(0.085,0.095,30.35),p,abs(a)<0.5 ? metal : timber)
  }
  for z in stride(from:Float(-14.5),through:14,by:1.5) {
    for side:Float in [-1,1] {
      beam(curve(0,z),curve(side*0.46,z),width:0.035,depth:0.05,material:metal)
    }
  }

  // Thin beveled glazing sections share the curved timber lantern. Sparse
  // diagonal ties reveal the section of the roof against the open sky.
  let glass = finish(0.82,0.91,0.93)
  glass.isDoubleSided = true
  glass.transparency = 0.15
  glass.writesToDepthBuffer = false
  for z:Float in [-12.5,-7.5,-2.5,2.5,7.5,12.5] {
    for side:Float in [-1,1] {
      let a = curve(0,z)+V(0,0.11,0), b = curve(side*0.46,z)+V(0,0.11,0)
      beam(a,b,width:0.025,depth:4.94,material:glass)
      beam(curve(0,z-2.4),curve(side*0.45,z+2.4),width:0.042,depth:0.047,material:metal)
    }
  }

  // The arched terminal window sits in the far portal. The mesh follows the
  // arch instead of drawing a rectangular image across the open river sides.
  var wallVertices:[SCNVector3] = [], wallUV:[CGPoint] = [], wallIndices:[Int32] = []
  for i in 0...sections {
    let point = curve((Float(i)/Float(sections)-0.5) * .pi,-15.19)
    for y:Float in [0,point.y] {
      wallVertices.append(SCNVector3(V(point.x,y,point.z)))
      wallUV.append(CGPoint(x:CGFloat((point.x+6.85)/13.7),y:CGFloat(1-y/7.1)))
    }
    if i > 0 {
      let c = Int32(i*2)
      wallIndices += [c-2,c,c-1,c,c+1,c-1]
    }
  }
  let glazing = SCNGeometry(sources:[SCNGeometrySource(vertices:wallVertices),
    SCNGeometrySource(textureCoordinates:wallUV)],
    elements:[SCNGeometryElement(indices:wallIndices,primitiveType:.triangles)])
  glazing.materials = [illustration("RiversideGable",fallback:metal)]
  let gable = SCNNode(geometry:glazing)
  gable.name = "TerminalWindow"
  architecture.addChildNode(gable)

  // Build the cafe around its own axes. Its active facade and canopy face
  // into the court; the entrance remains visible from the baseline camera.
  let cafe = SCNNode()
  cafe.simdPosition = V(-6.05,0,1.6)
  cafe.simdEulerAngles.y = 1.07
  architecture.addChildNode(cafe)
  @discardableResult func kioskPart(_ size:V,_ offset:V,_ material:SCNMaterial) -> SCNNode {
    let n = block(size,offset,material)
    cafe.addChildNode(n)
    return n
  }
  kioskPart(V(5.5,3.02,1.25),V(0,1.47,-0.63),coral)
  kioskPart(V(0.38,0.12,1.38),V(0,3.05,-0.61),oak)
  let front = SCNPlane(width:5.50,height:3.02)
  front.materials = [illustration("RiversideCafe",fallback:coral)]
  let shopfront = SCNNode(geometry:front)
  shopfront.name = "PaintedCafeFront"
  shopfront.simdPosition = V(0,1.47,0.012)
  cafe.addChildNode(shopfront)
  kioskPart(V(3.03,0.085,0.31),V(0.93,1.07,0.12),honey)
  for i in 0..<11 {
    let x = -0.68+Float(i)*0.304, fabric = i.isMultiple(of:2) ? cream : coral
    let panel = kioskPart(V(0.304,0.035,0.82),V(x,2.47,0.38),fabric)
    panel.simdEulerAngles.x = 0.34
    kioskPart(V(0.304,0.13,0.035),V(x,2.27,0.76),fabric)
  }
  // Paint-coloured sculpted ivy on the ledge. The vines are anchored to the
  // cafe coordinates so the canopy and hanging tips have separate parallax.
  let ivy = [0x52664A,0x677B45,0x82904B,0xA5A756,0x698561].map { pavilionFinish(UInt32($0)) }
  let stems = pavilionFinish(0x74684F)
  ivy.forEach { $0.isDoubleSided = true }
  func ivyLeaf(_ origin:V,_ axis:V,_ width:Float,_ material:SCNMaterial, on parent:SCNNode) {
    let direction = simd_normalize(axis)
    var across = simd_cross(direction,V(0,0,1))
    if simd_length_squared(across) < 0.05 { across = simd_cross(direction,V(1,0,0)) }
    across = simd_normalize(across)*width
    let mid = origin + axis*0.47, p = [origin,mid+across,origin+axis,mid-across,mid+V(0,0,0.015)]
    let mesh = SCNGeometry(sources:[SCNGeometrySource(vertices:p.map { SCNVector3($0) })],
      elements:[SCNGeometryElement(indices:[Int32(0),1,4,1,2,4,2,3,4,3,0,4],primitiveType:.triangles)])
    mesh.materials = [material]
    parent.addChildNode(SCNNode(geometry:mesh))
  }
  for vine in 0..<22 {
    let cluster = vine%3, seed = Float(vine)*2.39996
    var last = V([-1.62,0.08,2.17][cluster]+0.52*sin(seed),3.12,0.015)
    let count = 3+vine%7
    for step in 0..<count {
      let t = seed+Float(step)*0.73, next = last+V(0.072*cos(t),-0.082,0.026+0.021*sin(t))
      let stem = SCNCylinder(radius:0.009,height:1)
      stem.radialSegmentCount = 4
      stem.materials = [stems]
      let part = SCNNode(geometry:stem)
      cafe.addChildNode(part)
      link(part,last,next)
      let side:Float = step.isMultiple(of:2) ? -1 : 1
      ivyLeaf(next,V(side*0.105,-0.087,0.043*cos(t)),0.047,ivy[(vine+step)%ivy.count],on:cafe)
      last = next
    }
  }
  let celadon = finish(0.43,0.62,0.56)
  addPavilionFlowerBox(architecture,center:V(-4.51,-0.04,-1.18),length:1.50,alongZ:true)
  addPavilionFlowerBox(architecture,center:V(4.36,-0.04,4.5),length:2.1,alongZ:true)
  addPavilionFlowerBox(architecture,center:V(4.41,-0.04,-5.6),length:1.75,alongZ:true)

  // Low quay rail, with the top rail below the far player's shoulders.
  block(V(22.6,0.085,0.11),V(0,0.85,-17.2),honey)
  block(V(22.6,0.025,0.025),V(0,0.46,-17.2),metal)
  for x in stride(from:Float(-11),through:11,by:2.2) {
    block(V(0.065,0.86,0.065),V(x,0.40,-17.2),metal)
  }

  // Bell-shaped enamel pendants are lit by the hall lights; the diffusers
  // use emission without adding any per-pixel light sources.
  let diffuser = finish(1,0.89,0.67)
  diffuser.emission.contents = UIColor(red:0.46,green:0.34,blue:0.18,alpha:1)
  for z:Float in [-13,-8,-3,2,7] {
    for x:Float in [-2.55,2.55] {
      block(V(0.025,0.62,0.025),V(x,6.52,z),metal)
      let shade = SCNCone(topRadius:0.085,bottomRadius:0.30,height:0.19)
      shade.radialSegmentCount = 14
      shade.materials = [metal,metal,diffuser]
      let fixture = SCNNode(geometry:shade)
      fixture.simdPosition = V(x,6.14,z)
      architecture.addChildNode(fixture)
    }
  }

  // Terracotta containers and layered palm fronds on the far edges of the hall.
  let terracotta = finish(0.68,0.48,0.32)
  for (index,at) in [V(-4.65,0,-8.9),V(-4.88,0,3.7),V(6.35,0,-8.7),V(-5.5,0,-12.8)].enumerated() {
    let pot = SCNCone(topRadius:0.31,bottomRadius:0.22,height:0.48)
    pot.radialSegmentCount = 16
    pot.materials = [terracotta]
    let node = SCNNode(geometry:pot)
    node.simdPosition = at+V(0,0.20,0)
    architecture.addChildNode(node)
    for i in 0..<13 {
      let angle = Float(i)*2.39996+Float(index)
      let axis = V(cos(angle),0,sin(angle)), start = at+V(0,0.40,0)
      let slope:Float = 0.40+0.25*cos(Float(i)*2)
      let bend = start+V(0,slope,0)+axis*0.18
      ivyLeaf(start,bend-start,0.063,ivy[i%ivy.count],on:architecture)
      ivyLeaf(bend,axis*0.24+V(0,-0.105,0),0.070,ivy[(i+1)%ivy.count],on:architecture)
    }
  }

  // Two short banks open onto a central aisle on the river-facing side.
  for z:Float in [-5.0,1.5] {
    for row in 0..<3 {
      let x = 4.79+Float(row)*0.73, height = 0.25+Float(row)*0.31
      block(V(0.73,height,5.8),V(x,height/2-0.05,z),oak)
      for slat in 0..<3 {
        block(V(0.258,0.084,5.94),V(x+Float(slat-1)*0.27,height-0.005,z),honey)
      }
      block(V(0.028,0.032,5.91),V(x-0.387,height-0.056,z),timber)
    }
  }
  // Seated spectators are static scenery, with their feet on the lower tier.
  let hair = finish(0.20,0.16,0.16), denim = finish(0.24,0.34,0.38)
  let skin = [finish(0.84,0.62,0.46),finish(0.68,0.46,0.34)]
  func oval(_ at:V,_ radii:V,_ material:SCNMaterial) -> SCNNode {
    let geometry = SCNSphere(radius:1)
    geometry.segmentCount = 12
    geometry.materials = [material]
    let node = SCNNode(geometry:geometry)
    node.simdPosition = at
    node.simdScale = radii
    architecture.addChildNode(node)
    return node
  }
  func limb(_ a:V,_ b:V,_ radius:Float,_ material:SCNMaterial) {
    let segment = oval((a+b)*0.5,V(radius,simd_distance(a,b)/2+radius*0.35,radius),material)
    segment.simdOrientation = simd_quatf(from:V(0,1,0),to:simd_normalize(b-a))
  }
  let guests:[(x:Float,z:Float,row:Int)] = [(5.52,-4.3,1),(6.25,2.5,2),(5.52,0.65,1)]
  for (i,guest) in guests.enumerated() {
    let hip = V(guest.x-0.12,0.25+Float(guest.row)*0.31+0.14,guest.z)
    let complexion = skin[i%2], shirt = [cream,denim,celadon][i]
    let shoulder = hip+V(i == 1 ? -0.20 : -0.10,0.46,0)
    let head = shoulder+V(-0.055,0.21,0)
    limb(hip,shoulder,0.17,shirt)
    _ = oval(head,V(0.105,0.14,0.104),complexion)
    _ = oval(head+V(0.016,0.061,0),V(0.111,0.097,0.111),hair)
    _ = oval(head+V(-0.098,0.003,-0.014),V(0.028,0.030,0.027),complexion)
    if i == 0 {
      // Straw brim and crown are separate so the profile reads from the court.
      _ = oval(head+V(-0.018,0.096,0),V(0.185,0.018,0.16),honey)
      _ = oval(head+V(0,0.12,0),V(0.108,0.074,0.109),honey)
    } else if i == 2 {
      _ = oval(head+V(0.10,0.066,0),V(0.082,0.087,0.079),hair)
    }
    _ = oval(hip+V(-0.025,0.024,0),V(0.151,0.102,0.167),denim)
    for sign:Float in [-1,1] {
      let thigh = hip+V(0,0,0.09*sign)
      let knee = thigh+V(-0.37,-0.035,0.038*sign)
      let ankle = knee+V(i == 2 ? -0.095 : -0.035,-0.31,sign*0.033)
      limb(thigh,knee,0.102,denim)
      limb(knee,ankle,i == 1 ? 0.056 : 0.075,i == 1 ? complexion : denim)
      _ = oval(ankle+V(-0.041,-0.046,0),V(0.12,0.055,0.062),cream)
      let sleeve = shoulder+V(0,-0.055,0.12*sign)
      let elbow = sleeve+V(-0.13,-0.22,0.04*sign)
      let hand:V
      switch i {
      case 0: hand = hip+V(-0.25,0.12,0.045*sign)
      case 1: hand = sign > 0 ? head+V(-0.074,-0.10,0.049) : knee+V(-0.02,0.085,0)
      default: hand = shoulder+V(-0.25,-0.11,0.045*sign)
      }
      limb(sleeve,elbow,0.060,shirt)
      limb(elbow,hand,0.043,complexion)
      _ = oval(hand,V(0.041,0.052,0.037),complexion)
    }
  }
  // Bake the local transforms of nested shop and planter parts before batching.
  // SceneKit can drop the pure transform nodes inside a flattened clone.
  var leaves:[(SCNNode,simd_float4x4)] = []
  architecture.enumerateChildNodes { part,_ in
    if part.geometry != nil && part.parent !== architecture {
      leaves.append((part,part.simdWorldTransform))
    }
  }
  for (part,placement) in leaves {
    architecture.addChildNode(part)
    part.simdTransform = placement
  }
  root.addChildNode(architecture.flattenedClone())
}

final class CourtScene {
  let scene = SCNScene(), camera = SCNNode()
  private let traditionalHall = SCNNode()
  private let paintedHall = paintedRiversideHall()
  private var cameraTime: Double?
  private var overheadFraming: Float = 0
  private var baselineRetreat: Float = 0
  // Calibrated to the centre 16:9 framing in the painted court elevation.
  // Wider displays reveal the side galleries through the same projection.
  private static let referenceAspect: Float = 16.0/9.0
  private static let openingEye = V(0,1.90,12.61)
  private static let openingPitch: Float = 2.35
  private static let openingField: CGFloat = 33.5
  var cameraAspect: Float = CourtScene.referenceAspect
  private var tracking = V.zero
  private let players: [CourtPlayer]
  private let trail: [SCNNode]
  private let racketTrail: [SCNNode]
  private var tipHistory: [(time: Double, point: V)] = []
  private var trailContact: Double?
  private let shuttle = SCNNode()
  private let cork: SCNNode
  private lazy var contactProbe = CourtPlayer(SCNNode(),.white)
  private let shadow, landing, intercept, service: SCNNode
  private static func courtTexture(_ name: String, _ ext: String) -> URL? {
    if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
    #if os(macOS)
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("code/Clients/iOS/Resources/\(name).\(ext)")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    #endif
    return nil
  }

  private static func addNet(to root: SCNNode) {
    let vertices: [SCNVector3] = [-3.05, 0.0, 3.05].flatMap { (x: Float) -> [SCNVector3] in
      let top: Float = x == 0 ? 1.524 : 1.55
      return [SCNVector3(V(x,top-0.76,0)), SCNVector3(V(x,top-0.026,0))]
    }
    let uv: [CGPoint] = [0.0,0.5,1.0].flatMap { [CGPoint(x:$0,y:0), CGPoint(x:$0,y:1)] }
    let triangles: [Int32] = [0,2,1,1,2,3,2,4,3,3,4,5]
    let net = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices), SCNGeometrySource(textureCoordinates:uv)],
                          elements:[SCNGeometryElement(indices:triangles,primitiveType:.triangles)])
    let weave = SCNMaterial()
    weave.isDoubleSided = true
    weave.lightingModel = .constant
    weave.blendMode = .alpha
    weave.writesToDepthBuffer = false
    weave.diffuse.contents = courtTexture("RiversideNetWeave","png") as Any?
      ?? UIColor(white:0.24,alpha:0.19)
    weave.diffuse.contentsTransform = SCNMatrix4MakeScale(12,6,1)
    weave.diffuse.wrapS = .repeat
    weave.diffuse.wrapT = .repeat
    weave.diffuse.mipFilter = .linear
    net.materials = [weave]
    let node = SCNNode(geometry:net)
    node.name = "WovenMatchNet"
    root.addChildNode(node)
  }

  private static func addRiverPanorama(to root: SCNNode) {
    var texture = Bundle.main.url(forResource: "RiversidePanorama", withExtension: "jpg")
    #if os(macOS)
    // Standalone court review tools run from the repository root without an app bundle.
    if texture == nil {
      texture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("code/Clients/iOS/Resources/RiversidePanorama.jpg")
    }
    #endif
    guard let texture, FileManager.default.fileExists(atPath: texture.path) else { return }
    let panel = SCNPlane(width: 84, height: 35)
    let paint = SCNMaterial()
    paint.lightingModel = .constant
    paint.diffuse.contents = texture
    paint.diffuse.mipFilter = .linear
    panel.materials = [paint]
    // Mirror the riverbank beyond either edge for wide displays and overhead clears.
    // Put the waterline below the deck so the lower edge never floats above it.
    paint.isDoubleSided = true
    for section in -1...1 {
      let node = SCNNode(geometry: panel)
      node.name = "RiverPanorama"
      node.castsShadow = false
      node.simdPosition = V(Float(section) * 84, 8.9, -42)
      if section != 0 { node.simdScale.x = -1 }
      root.addChildNode(node)
    }
  }

  init() {
    let root = scene.rootNode
    Self.addRiverPanorama(to: root)
    scene.background.contents = UIColor(red: 0.44,green: 0.67,blue: 0.78,alpha: 1)
    func box(_ x: CGFloat,_ y: CGFloat,_ z: CGFloat,_ at: V,_ color: UIColor) -> SCNNode {
      mesh(SCNBox(width:x,height:y,length:z,chamferRadius:0),color,root,at)
    }
    addRiversideHall(to:traditionalHall)
    root.addChildNode(traditionalHall)
    if let deck = traditionalHall.childNode(withName:"PerimeterFloor",recursively:false) { root.addChildNode(deck) }
    if let paintedHall { root.addChildNode(paintedHall); traditionalHall.isHidden = true }
    let mat = SCNPlane(width:6.65,height:13.85)
    let coating = SCNMaterial()
    coating.lightingModel = .constant
    coating.diffuse.contents = Self.courtTexture("RiversideGouacheMat","jpg") as Any?
      ?? UIColor(red:0.40,green:0.54,blue:0.62,alpha:1)
    coating.diffuse.mipFilter = .linear
    coating.diffuse.maxAnisotropy = 16
    // Compensate for the loss of gouache contrast at grazing incidence. SceneKit
    // samples the colour plate in linear light; keep the quiet mid-blue anchored.
    coating.shaderModifiers = [.surface: """
      #pragma body
      _surface.diffuse.rgb = max(float3(0.0), (_surface.diffuse.rgb - float3(0.138, 0.238, 0.332))
        * 1.60 + float3(0.173, 0.274, 0.371));
      """]
    mat.materials = [coating]
    let surface = SCNNode(geometry:mat)
    surface.name = "WatercolourCourtMat"
    surface.simdEulerAngles.x = -.pi/2
    surface.simdPosition.y = -0.002
    root.addChildNode(surface)
    let chalk = UIColor(red:0.91,green:0.89,blue:0.81,alpha:1)
    for z: Float in [-6.7,-5.94,-1.98,1.98,5.94,6.7] { _ = box(6.1,0.008,0.04,V(0,0,z),chalk) }
    for x: Float in [-3.05,-2.59,2.59,3.05] { _ = box(0.04,0.008,13.4,V(x,0,0),chalk) }
    for sign: Float in [-1,1] { _ = box(0.04,0.008,4.72,V(0,0,sign*4.34),chalk) }
    let postColor = UIColor(red:0.26,green:0.24,blue:0.23,alpha:1)
    for x: Float in [-3.06,3.06] {
      _ = box(0.052,1.55,0.052,V(x,0.775,0),postColor)
      _ = box(0.18,0.034,0.14,V(x,0.017,0),postColor)
    }
    for side: Float in [-1,1] {
      let band = box(3.05,0.035,0.022,V(side*1.525,1.537-0.0175,0),chalk)
      band.simdEulerAngles.z = side*atan2(0.026,3.05)
    }
    Self.addNet(to:root)
    racketTrail = (0..<10).map { _ in
      let node = mesh(SCNCylinder(radius:0.025,height:1),.systemPink,root)
      node.geometry?.firstMaterial?.lightingModel = .constant
      node.geometry?.firstMaterial?.writesToDepthBuffer = false
      node.isHidden = true
      return node
    }
    trail = (0..<14).map { i in
      let fade = CGFloat(i+1)/14
      let node = mesh(SCNCylinder(radius:0.006 + 0.036*fade,height:1),.white,root)
      node.geometry?.firstMaterial?.lightingModel = .constant
      node.opacity = fade*0.88
      return node
    }
    players = [CourtPlayer(root,UIColor(red:0.96,green:0.31,blue:0.29,alpha:1),heroine:true),CourtPlayer(root,.systemCyan,rival:true),CourtPlayer(root,.systemOrange),CourtPlayer(root,.systemCyan)]
    for player in players {
      let shadow = mesh(SCNPlane(width:5.2,height:4.0),.white,root)
      shadow.name = "AthleteContactShadow"
      shadow.simdEulerAngles = V(-.pi/2,0,0)
      if let paint = shadow.geometry?.firstMaterial {
        paint.lightingModel = .constant
        paint.diffuse.contents = UIColor.white
        paint.blendMode = .alpha
        paint.shaderModifiers = [.surface: """
          #pragma arguments
          float4 body;
          float4 feetPair;
          float4 headElbow;
          float4 armPair;
          float4 freePair;
          #pragma transparent
          #pragma body
          float2 p = (_surface.diffuseTexcoord - 0.5) * float2(5.2,4.0) + float2(-0.55,0.16);
          #define SEG(A,B,R) (length(p-((A)+clamp(dot(p-(A),(B)-(A))/max(dot((B)-(A),(B)-(A)),0.0001),0.0,1.0)*((B)-(A))))-(R))
          float d = SEG(body.xy,body.zw,0.137);
          d = min(d,length(p-headElbow.xy)-0.122);
          d = min(d,SEG(feetPair.xy,body.xy,0.055));
          d = min(d,SEG(feetPair.zw,body.xy,0.060));
          d = min(d,SEG(headElbow.zw,body.zw,0.052));
          d = min(d,SEG(headElbow.zw,armPair.xy,0.043));
          d = min(d,SEG(armPair.xy,armPair.zw,0.021));
          d = min(d,SEG(body.zw,freePair.xy,0.047));
          d = min(d,SEG(freePair.xy,freePair.zw,0.040));
          _surface.diffuse = float4(0.092,0.11,0.15,0.31*(1.0-smoothstep(-0.018,0.032,d)));
          #undef SEG
          """, .fragment: """
          #pragma body
          if (_surface.diffuse.a < 0.002) { discard_fragment(); }
          _output.color = float4(float3(0.015, 0.022, 0.031) * _surface.diffuse.a, _surface.diffuse.a);
          """]
        for key in ["body","feetPair","headElbow","armPair","freePair"] {
          paint.setValue(NSValue(scnVector4:SCNVector4Zero),forKey:key)
        }
        paint.writesToDepthBuffer = false
      }
      player.groundShadow = shadow
    }
    root.addChildNode(shuttle)
    cork = mesh(SCNSphere(radius:0.065),.systemYellow,shuttle)
    _ = mesh(SCNCone(topRadius:0.1,bottomRadius:0.04,height:0.17),.white,shuttle,V(0,0.1,0))
    shadow = mesh(SCNCylinder(radius:0.11,height:0.008),.black,root)
    landing = mesh(SCNTorus(ringRadius:0.22,pipeRadius:0.016),.white,root)
    intercept = mesh(SCNTorus(ringRadius:0.12,pipeRadius:0.025),.systemMint,root)
    service = box(2.59,0.005,4.72,.zero,UIColor(red:0.54,green:0.77,blue:0.72,alpha:0.11))
    camera.camera = SCNCamera()
    camera.camera?.projectionDirection = .vertical
    camera.camera?.fieldOfView = Self.openingField
    camera.simdPosition = Self.openingEye
    camera.simdEulerAngles = V(-Self.openingPitch * .pi/180,0,0)
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
  #if DEBUG
  func hideReplayAids() {
    for node in trail + racketTrail { node.isHidden = true }
    landing.isHidden = true
    intercept.isHidden = true
  }
  #endif

  func nearContactSample() -> CourtContactSample? {
    guard let time = cameraTime, !shuttle.isHidden else { return nil }
    return players[0].contactSample(time:time, corkCenter:cork.simdWorldPosition, corkRadius:corkRadius)
  }

  private var corkRadius: Float {
    guard let sphere = cork.geometry as? SCNSphere else { return 0 }
    return simd_length(cork.simdConvertVector(V(Float(sphere.radius),0,0),to:nil))
  }

  func canContact(_ candidate: Rally, left: Bool) -> Bool {
    guard let flight = candidate.flight, !flight.incoming else { return false }
    contactProbe.copyPoseHistory(from:players[0])
    poseNear(contactProbe, game:candidate, left:left)
    let sample = contactProbe.contactSample(time:candidate.now, corkCenter:world(flight.from), corkRadius:corkRadius)
    return sample?.touchesBed == true
  }

  // The playable athlete has the same reach under Reduce Motion; camera
  // tracking and racket/shuttle trails are controlled separately below.
  private func poseNear(_ player: CourtPlayer, game: Rally, left: Bool) {
    let flight = game.flight
    player.pose(world(Position(x:game.playerX,y:game.playerY)), side:left ? -1 : 1, facing:-1,
      now:game.now, elapsed:game.now-game.swingTime, stroke:game.stroke, impact:game.animationImpact,
      incoming:flight?.incoming == true ? flight : nil, outgoing:flight?.incoming == false ? flight : nil,
      intercept:game.predictedIntercept, still:false, point:game.pointCount,
      attemptedAt:flight?.incoming == true && (game.judgedContactTime ?? -.infinity) >= (flight?.start ?? .infinity)
        ? game.judgedContactTime : nil)
  }

  func nearRacketError(to contact: Position) -> Float {
    simd_distance(players[0].tipInWorld, world(contact))
  }
  func update(_ game: Rally,reduced: Bool,left: Bool) {
    traditionalHall.isHidden = paintedHall != nil && !reduced
    paintedHall?.isHidden = reduced
    poseNear(players[0], game:game, left:left)
    let f = game.flight
    for i in players.indices.dropFirst() {
      let near = i.isMultiple(of:2), main = i<2
      players[i].root.isHidden = !main && game.format != .doubles
      players[i].groundShadow?.isHidden = players[i].root.isHidden
      if players[i].root.isHidden { continue }
      let x = main ? (near ? game.playerX : game.opponentX) : (near ? -game.nearServiceX : game.nearServiceX)
      let y = main ? (near ? game.playerY : game.opponentY) : (near ? 0.92 : 0.11)
      let contact = main && f?.incoming == !near ? f : nil
      let incoming = main && f?.incoming == near ? f : nil
      var receiveLoad: Float = 0
      if main {
        if game.phase == .serve && game.playerServes {
          receiveLoad = 0.72
        } else if let f, f.incoming {
          let progress = Float((game.now-f.start)/f.duration)
          let t = min(1,max(0,(progress-0.25)/0.35))
          receiveLoad = t*t*(3-2*t)
        } else if let f {
          receiveLoad = max(0,1-Float((game.now-f.start)/0.26))
        }
      }
      players[i].pose(world(Position(x:x,y:y)),side:near ? (left ? -1 : 1) : -1,facing:near ? -1 : 1,
                      now:game.now,elapsed:main ? game.now-(near ? game.swingTime : game.rivalSwing) : 1,
                      stroke:near ? game.stroke : f?.shot == .power ? .smash : .drive,
                      impact:near && main ? game.animationImpact : nil,incoming:incoming,outgoing:contact,intercept:main ? (near ? game.predictedIntercept : game.opponentIntercept) : nil,still:reduced,
                      rivalReadiness:receiveLoad,serving:main && game.phase == .serve && !game.playerServes)
    }
    // The racket accent samples the rendered near player's string bed. It has
    // its own history, separate from the shuttle's ballistic trail.
    let attack = f.flatMap { flight -> Double? in
      let age = game.now-flight.start
      guard !reduced, !flight.incoming, flight.shot == .smash || flight.shot == .power,
            world(flight.from).y > 1.75, age >= 0, age < 0.17 else { return nil }
      return flight.start
    }
    if attack != trailContact { tipHistory.removeAll(keepingCapacity:true) }
    trailContact = attack
    if attack != nil {
      tipHistory.removeAll { game.now-$0.time > 0.083 || $0.time >= game.now }
      tipHistory.append((game.now, players[0].tipInWorld))
    }
    for (i,node) in racketTrail.enumerated() {
      let end = tipHistory.count-1-i
      node.isHidden = end < 1
      guard end >= 1 else { continue }
      let a = tipHistory[end-1], b = tipHistory[end]
      let span = simd_distance(a.point,b.point)
      node.isHidden = span < 0.008 || span > 0.45
      if !node.isHidden {
        node.opacity = CGFloat(0.68*max(0,1-(game.now-a.time)/0.083))
        link(node,a.point,b.point)
      }
    }
    let target = f.map { $0.netCollision ?? $0.to } ?? game.landing
    landing.isHidden = target == nil
    if let target { landing.simdPosition = world(Position(x:target.x,y:target.y)) + V(0,0.015,0) }
    // Track with translation only. Fixed pitch and court-aligned yaw/roll
    // keep the posts and painted cross-court lines level throughout a rally.
    let feet = world(Position(x:game.playerX,y:game.playerY))
    let cameraTarget = V(feet.x*0.09,0,(feet.z-3.7)*0.18)
    let dt = game.now - (cameraTime ?? game.now)
    if reduced { tracking = .zero }
    else if cameraTime == nil || dt < 0 { tracking = cameraTarget }
    else { tracking += (cameraTarget-tracking)*Float(1-exp(-5*min(0.2,dt))) }
    let resetCamera = cameraTime == nil || dt < 0
    cameraTime = game.now
    // The artwork establishes eye position from the two net posts and baselines.
    // A small lateral slide preserves that vanishing point through footwork.
    let verticalField = reduced ? CGFloat(43) : Self.openingField
    let aspectCompensation = max(1,Self.referenceAspect/max(cameraAspect,0.1))
    camera.camera?.fieldOfView = 360 / CGFloat.pi * atan(tan(verticalField * .pi/360) * CGFloat(aspectCompensation))
    let base = reduced ? V(0,4.50,13.2) : Self.openingEye + tracking
    camera.simdEulerAngles = V((reduced ? -20 : -Self.openingPitch) * .pi/180,0,0)
    // Lift and retreat together: a high clear gains headroom while the feet
    // stay inside the lower edge. Forecast the actual flight before its apex.
    let retreat = reduced ? V(0,1,1.4) : V(0,0.65,1.8)
    var framing: Float = 0
    if reduced {
      framing = 1.6  // Fixed wider court view, with no tracking.
    } else if let f {
      let up = camera.simdWorldUp, forward = camera.simdWorldFront
      let slope = tan(Float(camera.camera!.fieldOfView) * .pi / 360) * 0.88
      let relief = simd_dot(retreat,up) - slope*simd_dot(retreat,forward)
      let window = max(0,min(0.9,f.start+f.duration-game.now))
      for sample in 0...12 {
        let t = game.now + window*Double(sample)/12
        let delta = world(f.at(t)) - base
        let excess = simd_dot(delta,up) + 0.20 - slope*simd_dot(delta,forward)
        framing = max(framing, excess/relief)
      }
    }
    let response = framing > overheadFraming ? 8.0 : 2.4
    let blend: Float = reduced || resetCamera ? 1 : Float(1-exp(-response*min(0.2,max(0,dt))))
    overheadFraming += (framing-overheadFraming)*blend
    camera.simdPosition = base + retreat*overheadFraming
    // A missed return can land behind the receiver. Slide straight back only
    // as far as needed to keep the shoes and the approaching cork in frame.
    if !reduced {
      let halfFOV = Float(camera.camera!.fieldOfView) * .pi/360
      let bottomAngle = -camera.simdEulerAngles.x + atan(0.91 * tan(halfFOV))
      let cotangent = 1/tan(bottomAngle)
      let eyeHeight = camera.simdPosition.y
      var requiredZ = feet.z + 0.52 + eyeHeight*cotangent
      if let f {
        let cork = world(f.at(game.now))
        requiredZ = max(requiredZ, cork.z + 0.16 + (eyeHeight-cork.y+0.12)*cotangent)
      }
      if !landing.isHidden {
        let nearEdge = landing.simdPosition.z + Float(landing.boundingBox.max.z)
        let ringBottom = landing.simdPosition.y + Float(landing.boundingBox.min.y)
        let ringAngle = -camera.simdEulerAngles.x + atan(0.97 * tan(halfFOV))
        requiredZ = max(requiredZ,nearEdge + (eyeHeight-ringBottom)/tan(ringAngle))
        let sideExtent = abs(landing.simdPosition.x-camera.simdPosition.x) + Float(landing.boundingBox.max.x)
        let ringTop = landing.simdPosition.y + Float(landing.boundingBox.max.y)
        let depth = sideExtent/(0.97 * cameraAspect * tan(halfFOV))
        let pitch = -camera.simdEulerAngles.x
        requiredZ = max(requiredZ,nearEdge + (depth - (eyeHeight-ringTop)*sin(pitch))/cos(pitch))
      }
      let requiredRetreat = max(0,requiredZ-camera.simdPosition.z)
      let decay: Float = resetCamera ? 0 : Float(exp(-4 * min(0.2,max(0,dt))))
      baselineRetreat = max(requiredRetreat,baselineRetreat*decay)
      camera.simdPosition.z += baselineRetreat
    } else {
      baselineRetreat = 0
    }
    service.isHidden = game.phase != .serve || game.practice
    let half = Float(game.format.halfWidth)*3.05, near = !game.playerServes
    let sign: Float = (near ? game.nearServiceX : -game.nearServiceX) >= 0 ? 1 : -1
    let end = Float(6.7-game.format.backLine*13.4)
    service.simdScale = V(half/2.59,1,(end-1.98)/4.72)
    service.simdPosition = V(sign*half/2,0.009,(near ? 1 : -1)*(end+1.98)/2)
    shuttle.isHidden = f == nil; shadow.isHidden = f == nil
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


// Profiles are in metres, from a shoulder/hip along the bind-pose +Y axis.
// Two deforming bones share rings around the elbow/knee. A third bind at
// the joint bisects the bend, retaining volume in deep receiving poses.
private final class PlayerLimbSkin {
  private let upper = SCNNode(), joint = SCNNode(), lower = SCNNode()
  private let upperLength: Float
  private let lowerLength: Float
  typealias Ring = (y: Float, width: Float, depth: Float)

  init(parent: SCNNode, name: String, leg: Bool, skin: UIColor, cloth: UIColor) {
    upperLength = leg ? 0.445 : 0.31
    lowerLength = leg ? 0.445 : 0.28
    // The cloth has its own hem ring. The topology continues under it to the ankle.
    let rings: [Ring] = leg ? [
      (0.015,0.066,0.074),(0.046,0.090,0.097),(0.077,0.102,0.109),
      (0.150,0.102,0.109),(0.192,0.100,0.104),(0.195,0.091,0.094),
      (0.252,0.083,0.089),(0.325,0.070,0.078),(0.396,0.058,0.064),
      (0.445,0.055,0.059),(0.486,0.052,0.055),(0.550,0.058,0.062),
      (0.607,0.060,0.066),(0.682,0.053,0.061),(0.767,0.039,0.047),
      (0.776,0.041,0.047),(0.786,0.040,0.046),(0.841,0.031,0.037),(0.894,0.030,0.032)
    ] : [
      (-0.040,0.044,0.049),(-0.015,0.066,0.072),(0.032,0.077,0.079),
      (0.092,0.071,0.074),(0.124,0.069,0.071),(0.126,0.054,0.058),
      (0.176,0.053,0.059),(0.226,0.047,0.053),(0.272,0.040,0.044),
      (0.310,0.038,0.040),(0.346,0.039,0.042),(0.392,0.043,0.048),
      (0.445,0.039,0.042),(0.502,0.029,0.035),(0.550,0.023,0.026),
      (0.590,0.021,0.024)
    ]
    let sides = 20
    var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
    var weights: [SIMD4<Float>] = [], indices: [SIMD4<UInt16>] = []
    var skinFaces: [Int32] = [], clothFaces: [Int32] = [], accessoryFaces: [Int32] = []
    for (i,ring) in rings.enumerated() {
      let prev = rings[max(0,i-1)], next = rings[min(rings.count-1,i+1)]
      let t = min(1,max(-1,(ring.y-upperLength)/(leg ? 0.085 : 0.060)))
      for j in 0..<sides {
        let angle = 2 * Float.pi * Float(j) / Float(sides)
        let x = cos(angle), z = sin(angle)
        let p = V(ring.width*x,ring.y,ring.depth*z)
        let tangent = V(-ring.width*z,0,ring.depth*x)
        let axial = V((next.width-prev.width)*x,next.y-prev.y,(next.depth-prev.depth)*z)
        vertices.append(SCNVector3(p))
        normals.append(SCNVector3(simd_normalize(simd_cross(axial,tangent))))
        weights.append(SIMD4(max(0,-t),1-abs(t),max(0,t),0))
        indices.append(SIMD4(0,1,2,0))
        if i+1 < rings.count {
          let a = Int32(i*sides+j), b = Int32(i*sides+(j+1)%sides), n = Int32(sides)
          let pair = [a,a+n,b,b,a+n,b+n]
          if i < 5 { clothFaces += pair }
          else if (leg && ring.y >= 0.767) || (name == "RacketArm" && (0.502..<0.550).contains(ring.y)) {
            accessoryFaces += pair
          } else { skinFaces += pair }
        }
      }
    }
    for j in 1..<(sides-1) {
      let n = Int32(j), top = Int32((rings.count-1)*sides)
      clothFaces += [0,n,n+1]
      skinFaces += [top,top+n+1,top+n]
    }
    var sections = [skinFaces,clothFaces]
    var colors = [skin,cloth]
    if !accessoryFaces.isEmpty {
      sections.append(accessoryFaces)
      colors.append(leg ? UIColor(red:0.96,green:0.92,blue:0.82,alpha:1) : UIColor(red:0.20,green:0.47,blue:0.47,alpha:1))
    }
    let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices), SCNGeometrySource(normals:normals)],
                               elements:sections.map { SCNGeometryElement(indices:$0,primitiveType:.triangles) })
    geometry.materials = colors.map { color in
      let material = SCNMaterial()
      material.diffuse.contents = color
      return material
    }
    let bones = [upper,joint,lower]
    let rig = SCNNode()
    rig.name = name + "Rig"
    parent.addChildNode(rig)
    for (i,bone) in bones.enumerated() {
      bone.name = name + ["Proximal","Bend","Distal"][i]
      bone.simdPosition.y = i == 0 ? 0 : upperLength
      rig.addChildNode(bone)
    }
    let inverseBind = bones.map { NSValue(scnMatrix4:SCNMatrix4Invert($0.transform)) }
    let weightSource = SCNGeometrySource(data:weights.withUnsafeBytes { Data($0) },semantic:.boneWeights,
      vectorCount:weights.count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
    let indexSource = SCNGeometrySource(data:indices.withUnsafeBytes { Data($0) },semantic:.boneIndices,
      vectorCount:indices.count,usesFloatComponents:false,componentsPerVector:4,bytesPerComponent:2,dataOffset:0,dataStride:8)
    let deform = SCNSkinner(baseGeometry:geometry,bones:bones,boneInverseBindTransforms:inverseBind,
                            boneWeights:weightSource,boneIndices:indexSource)
    deform.skeleton = rig
    let node = SCNNode(geometry:geometry)
    node.name = name + "Skin"
    node.skinner = deform
    parent.addChildNode(node)
  }

  func pose(_ start: V, _ hinge: V, _ end: V) {
    let first = simd_normalize(hinge-start)
    let second = simd_normalize(end-hinge)
    // Carry the same cross section through the bend. Two independent shortest
    // rotations from the bind axis can otherwise twist in opposite directions.
    let rotation = simd_quatf(from:V(0,1,0),to:first)
    let secondRotation = simd_quatf(from:first,to:second)*rotation
    upper.simdPosition = start
    upper.simdOrientation = rotation
    joint.simdPosition = hinge
    joint.simdOrientation = simd_slerp(rotation,secondRotation,0.5)
    lower.simdPosition = hinge
    lower.simdOrientation = secondRotation
    lower.simdScale.y = simd_distance(end,hinge)/lowerLength
  }
}

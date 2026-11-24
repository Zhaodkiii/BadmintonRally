import SwiftUI

private typealias P = CGPoint
private func pt(_ x: Double, _ y: Double) -> P { P(x: x, y: y) }
private func mix(_ a: Double, _ b: Double, _ u: Double) -> Double { a + (b-a)*u }
private func between(_ a: P, _ b: P, _ u: Double) -> P { pt(mix(a.x,b.x,u), mix(a.y,b.y,u)) }

private struct AthletePose {
  var wrist: P
  var angle: Double
  var load: Double
  var reach: Double
  var head: P { pt(wrist.x + 31*cos(angle), wrist.y + 31*sin(angle)) }
  init(_ stroke: StandardStroke, _ time: Double) {
    let phase = StandardStroke.phase(time)
    let q = min(1,max(0,(time-StandardStroke.bounds[phase])/(StandardStroke.bounds[phase+1]-StandardStroke.bounds[phase])))
    let i = phase == 3 && q > 0.42 ? 4 : phase
    var v = phase == 3 ? (i == 3 ? q/0.42 : (q-0.42)/0.58) : q
    if i == 2 {
      switch stroke {
      case .smash, .backhandFlickServe, .netKill, .counterDrive: v = pow(v, 2.3)
      case .drop, .net, .netBlock: v = pow(v, 0.85)
      default: v = pow(v, 1.4)
      }
    }
    let u = v*v*(3-2*v)
    let poses = stroke.poses, a = poses[i], b = poses[i+1]
    wrist = pt(mix(a.0,b.0,u),mix(a.1,b.1,u))
    angle = mix(a.2,b.2,u)*Double.pi/180
    let loads = [0.0,0,1,0,0,0], reaches = [0.0,0,0.18,1,0.75,0]
    load = mix(loads[i],loads[i+1],u)
    reach = mix(reaches[i],reaches[i+1],u)
  }
}

struct StrokeCourt: View {
  let stroke: StandardStroke
  let left: Bool
  let time: Double

  var body: some View {
    Canvas { ctx, size in
      let field = CGRect(origin:.zero,size:size)
      ctx.fill(Path(field), with:.linearGradient(Gradient(colors:[
        Color(red:0.22,green:0.36,blue:0.38),Color(red:0.10,green:0.23,blue:0.25)]),
        startPoint:.zero,endPoint:pt(size.width,size.height)))
      let scale = min(size.width/205,size.height/168)
      ctx.translateBy(x:size.width/2,y:size.height/2)
      ctx.scaleBy(x:left ? -scale : scale,y:scale)
      ctx.translateBy(x:-113,y:-51)
      func line(_ points: [P], _ c: Color, _ width: Double) {
        var path = Path(); path.addLines(points)
        ctx.stroke(path,with:.color(c),style:StrokeStyle(lineWidth:width,lineCap:.round,lineJoin:.round))
      }
      func fill(_ points:[P], _ c:Color) {
        var path = Path(); path.addLines(points); path.closeSubpath()
        ctx.fill(path,with:.color(c))
      }
      func oval(_ center:P, _ w:Double, _ h:Double, _ c:Color) {
        ctx.fill(Path(ellipseIn:CGRect(x:center.x-w/2,y:center.y-h/2,width:w,height:h)),with:.color(c))
      }
      let court = Color(red:0.17,green:0.44,blue:0.40)
      fill([pt(-500,108),pt(700,108),pt(700,460),pt(-500,460)],court)
      line([pt(-500,108),pt(700,108)],.white.opacity(0.38),0.9)
      for x in stride(from:-240,through:480,by:44) {
        line([pt(Double(x),108),pt(Double(x)*1.65-58,162)],.white.opacity(0.22),0.7)
      }
      line([pt(-500,130),pt(700,130)],.white.opacity(0.36),0.8)
      let pose = AthletePose(stroke,time), reach = pose.reach, load = pose.load
      let lunge = stroke.lunge ? reach : 0, twist = stroke.overhead ? load : 0
      let transfer = stroke.overhead ? reach : 0
      let serveShift = stroke.isForehandServe ? 5 * (reach - load) : 0
      let hip = pt(80+9*lunge+5*transfer-4*twist+serveShift,87+7*lunge+2*load)
      let shoulder = pt(84+13*lunge+6*transfer-5*twist+serveShift,58+6*lunge-3*transfer+2*load)
      let neck = pt(shoulder.x-2,shoulder.y-6)
      let skin = Color(red:0.88,green:0.61,blue:0.42)
      let shadowSkin = Color(red:0.68,green:0.43,blue:0.33)
      let navy = Color(red:0.09,green:0.16,blue:0.22)
      let cloth = Color(red:0.98,green:0.39,blue:0.25)
      oval(pt(83+4*lunge,125),64+10*lunge,5,.black.opacity(0.20))
      func leg(_ knee:P,_ foot:P,_ far:Bool) {
        line([hip,knee,pt(foot.x,foot.y-3)],far ? shadowSkin : skin,6)
        line([hip,between(hip,knee,0.59)],far ? navy : Color(red:0.14,green:0.23,blue:0.29),11)
        line([between(knee,foot,0.68),pt(foot.x,foot.y-2)],.white.opacity(far ? 0.74 : 1),5.8)
        fill([pt(foot.x-3,foot.y-4),pt(foot.x+2,foot.y-4),pt(foot.x+5,foot.y-1),
              pt(foot.x+10,foot.y),pt(foot.x+10,foot.y+2),pt(foot.x-4,foot.y+2)],far ? navy : .white)
        line([pt(foot.x-3,foot.y+2),pt(foot.x+9,foot.y+2)],far ? .white.opacity(0.6) : cloth,1.4)
      }
      leg(pt(70+8*transfer,102+4*load),pt((stroke.isForehandServe ? 53 : 58)+33*transfer-3*lunge,122-5*sin(transfer * .pi)),true)
      leg(pt(96+16*lunge+3*transfer,101+5*lunge),pt(100+17*lunge-6*transfer,123),false)
      // Non-racket arm leads overhead; it balances a lunge or presents the shuttle on a serve.
      let off = stroke.overhead ? pt(103+4*load,34+39*reach) :
        stroke.isServe ? pt(107-12*reach,77+7*reach) : pt(69-19*lunge,70+4*lunge)
      line([pt(shoulder.x-6,shoulder.y),pt((off.x+shoulder.x)/2-6,(off.y+shoulder.y)/2+4),off],shadowSkin,4.6)
      line([pt(neck.x,neck.y-2),shoulder],skin,6)
      var jersey = Path()
      jersey.move(to:pt(shoulder.x-7,shoulder.y-3))
      jersey.addQuadCurve(to:pt(shoulder.x+7,shoulder.y),control:pt(shoulder.x,shoulder.y-7))
      jersey.addQuadCurve(to:pt(hip.x+7,hip.y+1),control:pt(shoulder.x+7,shoulder.y+12))
      jersey.addLine(to:pt(hip.x-8,hip.y))
      jersey.addQuadCurve(to:pt(shoulder.x-7,shoulder.y-3),control:pt(hip.x-7,shoulder.y+7))
      ctx.fill(jersey,with:.linearGradient(Gradient(colors:[cloth,.orange]),startPoint:shoulder,endPoint:hip))
      line([pt(shoulder.x-5,shoulder.y+3),pt(hip.x-5,hip.y-2)],.white.opacity(0.70),1.4)
      let face = pt(neck.x+1,neck.y-8)
      oval(face,13,17,skin)
      fill([pt(face.x+4,face.y-2),pt(face.x+8,face.y+1),pt(face.x+4,face.y+2)],skin)
      oval(pt(face.x-1,face.y-5),14,10,navy)
      line([pt(face.x-6,face.y-4),pt(face.x-5,face.y+1)],navy,3.2)
      line([pt(face.x-6,face.y-5),pt(face.x+4,face.y-6)],.white.opacity(0.86),1.7)
      oval(pt(face.x+4,face.y-1),1.3,1.3,navy)
      let wrist = pose.wrist, dx=wrist.x-shoulder.x, dy=wrist.y-shoulder.y
      let d=max(1,hypot(dx,dy)), h=sqrt(max(0,21*21-d*d/4))
      let bend = stroke.overhead ? -1.0 : 1
      let elbow=pt((shoulder.x+wrist.x)/2-bend*dy/d*h,(shoulder.y+wrist.y)/2+bend*dx/d*h)
      line([shoulder,elbow,wrist],skin,5.4)
      line([shoulder,between(shoulder,elbow,0.36)],cloth,8.5)
      if stroke == .background || stroke == .down {
        var phone = ctx
        phone.translateBy(x:wrist.x,y:wrist.y)
        phone.rotate(by:.radians(pose.angle))
        phone.fill(Path(roundedRect:CGRect(x:-4,y:-3,width:13,height:6),cornerRadius:1.5),with:.color(.mint))
        if stroke == .down && time > 2.2 && time < 3.45 {
          line((0...12).map { AthletePose(stroke,max(2.2,time-Double(12-$0)*0.02)).wrist }, .white.opacity(0.65),1)
        }
      } else {
        let contact = AthletePose(stroke,2.9).head
        if time > 2.2 && time < 3.45 {
          let points = (0...12).map { AthletePose(stroke,max(2.2,time-Double(12-$0)*0.013)).head }
          line(points,.mint.opacity(0.55),1.8)
        }
        var racket = ctx
        racket.translateBy(x:wrist.x,y:wrist.y)
        racket.rotate(by:.radians(pose.angle))
        func shaft(_ a:Double,_ b:Double,_ width:Double,_ c:Color) {
          var path=Path(); path.move(to:pt(a,0)); path.addLine(to:pt(b,0))
          racket.stroke(path,with:.color(c),lineWidth:width)
        }
        shaft(-3,6,3.4,navy); shaft(6,25,1.25,.white)
        let faceWidth = stroke.overhead || stroke == .drive ? 3.2 + 6.8*max(0.18,reach) :
          stroke == .net || stroke.isServe ? 5.5 : 8.0
        let hoop=Path(ellipseIn:CGRect(x:23,y:-faceWidth/2,width:16,height:faceWidth))
        racket.fill(hoop,with:.color(.white.opacity(0.22)))
        racket.stroke(hoop,with:.color(.mint),lineWidth:1.5)
        racket.clip(to:hoop)
        for x in [26,29,32,35] {
          var string=Path(); string.move(to:pt(Double(x),-6)); string.addLine(to:pt(Double(x),6))
          racket.stroke(string,with:.color(.white.opacity(0.72)),lineWidth:0.5)
        }
        let flightDuration: Double
        switch stroke {
        case .smash, .drive, .counterDrive, .netKill: flightDuration = 0.47
        default: flightDuration = 1
        }
        let flight = min(1, max(0, (time - 2.9) / flightDuration))
        let end:P, arc:Double
        switch stroke {
        case .lift,.backLift: (end,arc)=(pt(228,55),52)
        case .clear: (end,arc)=(pt(222,12),19)
        case .smash,.down: (end,arc)=(pt(214,84),1)
        case .drive: (end,arc)=(pt(226,64),3)
        case .drop: (end,arc)=(pt(174,79),4)
        case .net: (end,arc)=(pt(185,87),13)
        case .shortServe, .forehandShortServe: (end,arc)=(pt(174,108),24)
        case .forehandHighServe: (end,arc)=(pt(210,108),72)
        case .backhandFlickServe: (end,arc)=(pt(209,108),47)
        case .netBlock: (end,arc)=(pt(176,104),13)
        case .netPush: (end,arc)=(pt(219,91),8)
        case .netKill: (end,arc)=(pt(176,108),0)
        case .counterDrive: (end,arc)=(pt(222,60),2)
        case .background: return
        }
        func route(_ f:Double)->P { pt(mix(contact.x,end.x,f),mix(contact.y,end.y,f)-4*arc*f*(1-f)) }
        if time >= 2.89 {
          var path=Path()
          path.addLines((0...30).map {route(Double($0)/30)})
          ctx.stroke(path,with:.color(.white.opacity(0.48)),style:StrokeStyle(lineWidth:0.9,dash:[2,3]))
        }
        if time >= 1.7 && time < 4.15 {
          let approach = min(1,max(0,(2.9-time)/1.2))
          let serve = stroke.isServe
          let ball: P
          if time >= 2.9 { ball = route(flight) }
          else if serve { ball = between(off, contact, min(1,max(0,(time-2.48)/0.42))) }
          else {
            let defendingSmash = stroke == .netBlock || stroke == .counterDrive
            ball = pt(contact.x+(defendingSmash ? 60 : 28)*approach,
                      contact.y-(defendingSmash ? 39 : 18)*approach)
          }
          let direction = time < 2.9 ? Double.pi*0.76 : atan2(end.y-contact.y-4*arc*(1-2*flight),end.x-contact.x)
          var shuttle = ctx
          shuttle.translateBy(x:ball.x,y:ball.y); shuttle.rotate(by:.radians(direction))
          var feathers=Path(); feathers.addLines([pt(0,0),pt(-6,-2.6),pt(-6,2.6)]); feathers.closeSubpath()
          shuttle.fill(feathers,with:.color(.white))
          oval(ball,2.7,2.7,.yellow)
          if abs(time-2.9) < 0.15 {
            ctx.stroke(Path(ellipseIn:CGRect(x:contact.x-8,y:contact.y-8,width:16,height:16)),with:.color(.yellow),lineWidth:0.85)
          }
        }
      }
    }.accessibilityHidden(true)
  }
}

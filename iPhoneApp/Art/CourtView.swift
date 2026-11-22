import SwiftUI

struct CourtView: View {
  let game: Rally
  let reduced: Bool
  let leftHanded: Bool
  private let teal = Color(red: 0.13, green: 0.44, blue: 0.42)
  private let coral = Color(red: 0.94, green: 0.41, blue: 0.29)
  var body: some View {
    Canvas { original, size in
      var c = original
      c.scaleBy(x: size.width / 960, y: size.height / 540)
      func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
      func court(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint {
        p(480 + x * (154 + 208 * y), 155 + 327 * y - z * (122 + 93 * y))
      }
      func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: Double) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
      }
      func poly(_ points: [CGPoint], _ color: Color) {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        c.fill(path, with: .color(color))
      }
      func oval(_ a: CGPoint, _ w: Double, _ h: Double, _ color: Color) {
        c.fill(
          Path(ellipseIn: CGRect(x: a.x - w / 2, y: a.y - h / 2, width: w, height: h)),
          with: .color(color))
      }
      // Only the upper timber beams and windows from the original club illustration.
      var wall = c
      wall.clip(to: Path(CGRect(x: 0, y: 0, width: 960, height: 134)))
      wall.draw(Image("clubhouse"), in: CGRect(x: 0, y: 0, width: 960, height: 640))
      poly(
        [p(0, 134), p(960, 134), p(960, 540), p(0, 540)], Color(red: 0.12, green: 0.26, blue: 0.27))
      poly([court(-1, 0), court(1, 0), court(1, 1), court(-1, 1)], teal)
      for y in [0.0, 0.07, 0.32, 0.68, 0.93, 1.0] {
        line(court(-1, y), court(1, y), .white.opacity(0.76), 1.7)
      }
      for x in [-1.0, -0.86, 0.86, 1.0] { line(court(x, 0), court(x, 1), .white.opacity(0.8), 1.8) }
      line(court(0, 0), court(0, 0.32), .white.opacity(0.7), 1.5)
      line(court(0, 0.68), court(0, 1), .white.opacity(0.7), 1.5)
      func athlete(_ x: Double, _ y: Double, near: Bool) {
        let foot = court(x, y)
        let s = near ? 1.10 : 0.71
        let elapsed = game.now - (near ? game.swingTime : game.rivalSwing)
        let motion = near ? game.stroke : (game.flight?.shot == .power ? Stroke.smash : .lift)
        let phase = min(1, max(0, elapsed / (motion == .smash ? 0.42 : 0.31)))
        let wave = sin(phase * Double.pi)
        let contactWeight = elapsed >= 0 ? max(0, 1 - elapsed / 0.13) : 0
        let jump = motion == .smash ? 14 * wave : 0
        let dominantSide = near && leftHanded ? -1.0 : 1.0
        let moving = game.phase == .flight && game.flight?.incoming == near
        let step = moving ? sin(game.now * 15) * 3 : 0
        func joint(_ dx: Double, _ dy: Double) -> CGPoint {
          p(foot.x + dx * s * dominantSide, foot.y + (dy - jump) * s)
        }
        let ink = Color(red: 0.11, green: 0.16, blue: 0.19)
        let skin = Color(red: 0.87, green: 0.63, blue: 0.47)
        let shirt = near ? coral : Color.cyan
        oval(foot, 48 * s, 10 * s, .black.opacity(0.24))
        for side in [-1.0, 1.0] {
          let knee = joint(side * 12, -16 + step * side)
          let shoe = joint(side * 15, step * side)
          line(joint(side * 6, -31), knee, ink, 10 * s)
          line(knee, shoe, skin, 6 * s)
          line(shoe, p(shoe.x + side * 6 * s, shoe.y), .white, 6 * s)
        }
        poly(
          [
            joint(-12, -61), joint(10, -62), joint(14, -39), joint(8, -29), joint(-10, -30),
            joint(-14, -46),
          ], shirt)
        line(joint(-10, -51), joint(9, -56), .white.opacity(0.75), 2 * s)
        line(joint(-10, -57), joint(-21, -45 - 4 * wave), skin, 6 * s)
        let shoulder = joint(10, -56)
        let reach = (wave + contactWeight * (1 - wave))
        let arm: (x: Double, y: Double, angle: Double)
        switch motion {
        case .lift:
          arm = (
            25 + 8 * wave, -44 + 22 * reach - 46 * wave * phase,
            -0.6 + 1.1 * reach - 3.1 * wave * phase
          )
        case .smash:
          arm = (
            25 - 31 * wave * phase, -44 - 32 * reach + 55 * wave * phase,
            -0.6 - 1.2 * reach + 3.2 * wave * phase
          )
        case .drive: arm = (25 + (17 - 36 * phase) * reach, -44 - 8 * reach, -0.6 + 0.9 * reach)
        }
        let turn = dominantSide > 0 ? arm.angle : .pi - arm.angle
        let rest = joint(arm.x, arm.y)
        var head = p(rest.x + cos(turn) * 28 * s, rest.y + sin(turn) * 28 * s)
        if let flight = game.flight, flight.incoming != near,
          abs(elapsed - (game.now - flight.start)) < 0.001, contactWeight > 0
        {
          let contact = court(flight.from.x, flight.from.y, flight.from.z)
          let dx = min(50 * s, max(-50 * s, contact.x - head.x))
          let dy = min(52 * s, max(-52 * s, contact.y - head.y))
          head.x += dx * contactWeight
          head.y += dy * contactWeight
        }
        let wrist = p(head.x - cos(turn) * 28 * s, head.y - sin(turn) * 28 * s)
        let elbow = p((shoulder.x + wrist.x) / 2, (shoulder.y + wrist.y) / 2 + 8 * s)
        line(shoulder, elbow, skin, 7 * s)
        line(elbow, wrist, skin, 6 * s)
        line(wrist, head, ink, 2.6 * s)
        var racket = c
        racket.translateBy(x: head.x, y: head.y)
        racket.rotate(by: .radians(turn))
        let rim = Path(ellipseIn: CGRect(x: -11 * s, y: -7 * s, width: 22 * s, height: 14 * s))
        racket.fill(rim, with: .color(.white.opacity(0.24)))
        racket.stroke(rim, with: .color(.mint), lineWidth: 2 * s)
        oval(joint(0, -71), 21 * s, 24 * s, skin)
        oval(joint(-1, -77), 23 * s, near ? 19 * s : 13 * s, ink)
        if near { oval(joint(-10, -73), 12 * s, 15 * s, ink) }
      }
      func shuttle(_ f: Flight) {
        let pos = f.at(game.now)
        let loc = court(pos.x, pos.y, pos.z)
        let old = f.at(max(f.start, game.now - 0.07))
        let tail = court(old.x, old.y, old.z)
        let tint: Color
        switch f.shot {
        case .weak, .power: tint = .purple
        case .clear: tint = .cyan
        case .net: tint = .mint
        default: tint = .yellow
        }
        oval(court(pos.x, pos.y), 13, 4, .black.opacity(0.35))
        if !reduced {
          line(tail, loc, tint.opacity(0.8), 3.5)
          let age = game.now - f.start
          if age < 0.095 {
            let contact = court(f.from.x, f.from.y, f.from.z)
            let radius = 5 + 85 * age
            let ring = Path(
              ellipseIn: CGRect(
                x: contact.x - radius, y: contact.y - radius, width: radius * 2, height: radius * 2)
            )
            c.stroke(ring, with: .color(.white.opacity(max(0, 1 - age / 0.095))), lineWidth: 2)
          }
        }
        let dx = loc.x - tail.x
        let dy = loc.y - tail.y
        let n = max(1, hypot(dx, dy))
        poly(
          [
            loc, p(loc.x - 8 * dx / n + 4 * dy / n, loc.y - 8 * dy / n - 4 * dx / n),
            p(loc.x - 8 * dx / n - 4 * dy / n, loc.y - 8 * dy / n + 4 * dx / n),
          ], .white)
        oval(loc, 5, 5, .yellow)
      }
      if let landing = game.landing {
        let center = court(landing.x, landing.y)
        let ring = Path(ellipseIn: CGRect(x: center.x - 16, y: center.y - 6, width: 32, height: 12))
        c.stroke(ring, with: .color(.yellow), lineWidth: 1.7)
      }
      athlete(game.opponentX, game.opponentY, near: false)
      if let f = game.flight, f.at(game.now).y < 0.5 { shuttle(f) }
      let left = court(-1.09, 0.5)
      let right = court(1.09, 0.5)
      let top = court(0, 0.5, Flight.netHeight).y
      c.fill(
        Path(CGRect(x: left.x, y: top, width: right.x - left.x, height: 37)),
        with: .color(.black.opacity(0.15)))
      for x in stride(from: left.x, through: right.x, by: 9) {
        line(p(x, top), p(x, top + 37), .white.opacity(0.35), 0.7)
      }
      for i in 0...4 {
        line(
          p(left.x, top + Double(i) * 9), p(right.x, top + Double(i) * 9), .white.opacity(0.42), 0.7
        )
      }
      for post in [left, right] { line(post, p(post.x, top - 2), .black.opacity(0.8), 4) }
      line(p(left.x, top), p(right.x, top), .white, 2.5)
      athlete(game.playerX, game.playerY, near: true)
      if let f = game.flight, f.at(game.now).y >= 0.5 { shuttle(f) }
    }.accessibilityHidden(true)
  }
}

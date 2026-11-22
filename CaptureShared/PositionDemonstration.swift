import SwiftUI
import simd

/// A front-facing rehearsal. The athlete uses the same hand selected for collection.
struct PositionDemonstration: View {
  let step: Int
  let left: Bool
  var feedback = ""
  var phoneOnly = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var still = false
  @State private var origin = Date()

  private struct Pose {
    let hand, elbow: CGPoint
    let turn, tilt: Double
    func interpolated(to other: Self, by u: Double) -> Self {
      func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * u }
      func point(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: mix(a.x, b.x), y: mix(a.y, b.y))
      }
      return Self(
        hand: point(hand, other.hand), elbow: point(elbow, other.elbow),
        turn: mix(turn, other.turn), tilt: mix(tilt, other.tilt))
    }
  }

  private static let chest = Pose(
    hand: CGPoint(x: 125, y: 91),
    elbow: CGPoint(x: 83, y: 124), turn: 0, tilt: 0)
  private static let poses = [
    chest,
    Pose(hand: CGPoint(x: 29, y: 72), elbow: CGPoint(x: 66, y: 79), turn: .pi / 2, tilt: 0),
    Pose(hand: CGPoint(x: 99, y: 28), elbow: CGPoint(x: 78, y: 64), turn: 0, tilt: .pi / 4),
    chest,
  ]
  private static let resting = Pose(
    hand: CGPoint(x: 72, y: 133),
    elbow: CGPoint(x: 81, y: 106), turn: 0, tilt: 0)
  private var target: Pose { Self.poses[step] }
  private var start: Pose {
    if step == 0 { return Self.resting }
    return Self.poses[step - 1]
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: still || reduceMotion)) { clock in
      let seconds = max(0, clock.date.timeIntervalSince(origin)).truncatingRemainder(
        dividingBy: 3.8)
      let u = min(1, seconds / 1.15)
      let pose = start.interpolated(to: target, by: still || reduceMotion ? 1 : u * u * (3 - 2 * u))
      HStack(spacing: 10) {
        Canvas { context, size in
          let scale = min(size.width / 225, size.height / 158)
          var ctx = context
          ctx.translateBy(x: size.width / 2, y: size.height / 2)
          ctx.scaleBy(x: left ? -scale : scale, y: scale)
          ctx.translateBy(x: -112.5, y: -79)
          drawAthlete(ctx, pose: pose)
          if step == 0 || step == 2 {
            var detail = ctx
            detail.translateBy(x: 177, y: 65)
            detail.scaleBy(x: 1.8, y: 1.8)
            let skin = Color(red: 0.91, green: 0.68, blue: 0.49)
            detail.fill(
              Path(roundedRect: CGRect(x: -13, y: -1, width: 25, height: 16), cornerRadius: 6),
              with: .color(skin))
            if step == 2 { detail.rotate(by: .degrees(-35)) }
            drawPhone(
              detail, pose: Pose(hand: .zero, elbow: .zero, turn: -0.35, tilt: 0.2), skin: skin)
          }
        }.accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text(left ? "左手持机 · 正面示意" : "右手持机 · 正面示意")
            .font(.caption.bold()).foregroundStyle(.mint)
          Text(TrialPanel.positions[step]).font(.title3.bold())
          Text(TrialPanel.instructions[step]).font(.callout).fixedSize(
            horizontal: false, vertical: true)
          if !feedback.isEmpty {
            Text(feedback).font(.caption.bold()).foregroundStyle(.yellow)
              .fixedSize(horizontal: false, vertical: true)
          }
          if phoneOnly { Text("单机校验手机朝向").font(.caption2).foregroundStyle(.white.opacity(0.78)) }
          if !reduceMotion {
            Button(still ? "重播动作" : "停在目标姿势") {
              still.toggle()
              origin = Date()
            }.font(.caption).buttonStyle(.borderless).tint(.mint)
          }
        }.frame(minWidth: 160, idealWidth: 235, maxWidth: 260, alignment: .leading)
      }.padding(10).foregroundStyle(.white)
        .background(
          Color(red: 0.07, green: 0.20, blue: 0.21), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private func drawAthlete(_ ctx: GraphicsContext, pose: Pose) {
    func fill(_ rect: CGRect, _ color: Color, radius: Double) {
      ctx.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
    }
    func line(_ points: [CGPoint], _ color: Color, width: Double, dash: [CGFloat] = []) {
      var path = Path()
      path.addLines(points)
      ctx.stroke(
        path, with: .color(color),
        style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
    }
    let skin = Color(red: 0.91, green: 0.68, blue: 0.49)
    let shirt = Color(red: 0.14, green: 0.46, blue: 0.46)
    line(
      [CGPoint(x: 112, y: 63), CGPoint(x: 112, y: 150)], .white.opacity(0.2), width: 1,
      dash: [3, 4])
    fill(CGRect(x: 84, y: 66, width: 57, height: 79), shirt, radius: 17)
    fill(CGRect(x: 99, y: 28, width: 27, height: 36), skin, radius: 13)
    fill(CGRect(x: 98, y: 26, width: 29, height: 12), .black.opacity(0.85), radius: 6)
    fill(CGRect(x: 103, y: 44, width: 4, height: 2), .black, radius: 1)
    fill(CGRect(x: 118, y: 44, width: 4, height: 2), .black, radius: 1)
    line(
      [CGPoint(x: 136, y: 77), CGPoint(x: 151, y: 111), CGPoint(x: 143, y: 137)],
      skin.opacity(0.55), width: 11)
    line([start.hand, target.hand], .mint.opacity(0.65), width: 1.5, dash: [4, 4])
    ctx.stroke(
      Path(ellipseIn: CGRect(x: target.hand.x - 13, y: target.hand.y - 13, width: 26, height: 26)),
      with: .color(.mint), lineWidth: 1.6)
    line([CGPoint(x: 89, y: 76), pose.elbow, pose.hand], skin, width: 12)
    line(
      [CGPoint(x: 89, y: 76), CGPoint(x: (89 + pose.elbow.x) / 2, y: (76 + pose.elbow.y) / 2)],
      shirt, width: 16)
    drawPhone(ctx, pose: pose, skin: skin)
  }

  private func drawPhone(_ ctx: GraphicsContext, pose: Pose, skin: Color) {
    // Tilt and turn describe the actual phone, projected from slightly above the athlete.
    let forward = SIMD3(
      -sin(pose.turn) * cos(pose.tilt), cos(pose.turn) * cos(pose.tilt), sin(pose.tilt))
    let side = SIMD3(cos(pose.turn), sin(pose.turn), 0.0)
    func point(_ x: Double, _ y: Double) -> CGPoint {
      let p = side * x + forward * y
      return CGPoint(x: pose.hand.x + p.x, y: pose.hand.y + p.y * 0.62 - p.z * 0.79)
    }
    func polygon(_ points: [CGPoint], color: Color) {
      var p = Path()
      p.addLines(points)
      p.closeSubpath()
      ctx.fill(p, with: .color(color))
    }
    polygon([point(-9, -15), point(9, -15), point(9, 18), point(-9, 18)], color: .white)
    polygon(
      [point(-7.5, -13), point(7.5, -13), point(7.5, 16), point(-7.5, 16)],
      color: Color(red: 0.10, green: 0.32, blue: 0.35))
    polygon([point(-4, 12), point(4, 12), point(0, 16)], color: .mint)
    // Thumb rests on the edge. The top marker remains visible through the movement.
    let thumb = point(-7, -4)
    ctx.fill(
      Path(ellipseIn: CGRect(x: thumb.x - 4, y: thumb.y - 3, width: 8, height: 6)),
      with: .color(skin))
  }
}

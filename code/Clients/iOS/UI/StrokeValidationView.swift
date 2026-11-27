import Combine
import SceneKit
import SwiftUI

private typealias CourtVector = SIMD3<Float>

private enum FeedLane: String, CaseIterable {
  case left = "左路", middle = "中路", right = "右路"
  var sign: Double { self == .left ? -1 : self == .right ? 1 : 0 }
}

private struct ValidationServe {
  let kind: ServeTraining
  let releaseFrame: Int
  let releaseCork, impactCork, holdPoint: CourtVector
  let featherReach: Float
  var handBone = "hand_L"

  var isBackhand: Bool { kind == .backhandShort || kind == .flick }
  var isShort: Bool { kind == .forehandShort || kind == .backhandShort }
  var holdOffset: CourtVector { .init(0, -featherReach, 0) }
  var featherTurn: CourtVector {
    // The approved Blender preview points the skirt toward the bed on descent.
    switch kind {
    case .forehandHigh: .init(0.373491764, 0.772498965, -0.513565183)
    case .forehandShort: .init(0.408832103, 0.743176401, -0.529665053)
    default: simd_normalize(.init(0, 1, -0.6))
    }
  }
  func fallingOrientation(at progress: Float) -> simd_quatf {
    let up = CourtVector(0, 1, 0)
    let tilt = isBackhand ? progress * (2 - progress) : 0.8 * max(0, 2 * progress - 1)
    return simd_slerp(simd_quatf(angle: 0, axis: up), simd_quatf(from: up, to: featherTurn), tilt)
  }

  var swing: SwingImpact {
    switch kind {
    case .forehandHigh: .init(power: 0.91, sweep: 0.79, label: kind.rawValue, verticalSweep: 0.68)
    case .forehandShort: .init(power: 0.14, sweep: 0.09, label: kind.rawValue, verticalSweep: 0.18)
    case .backhandShort: .init(power: 0.11, sweep: 0.08, label: kind.rawValue, verticalSweep: 0.27)
    case .flick: .init(power: 0.76, sweep: 0.63, label: kind.rawValue, verticalSweep: 0.44)
    case .free: .init(power: 0, sweep: 0)
    }
  }
}

private struct ValidationClip {
  let resource, title, gripBone: String
  let shot: Shot
  let impactFrame, frameCount: Int
  let fps: Double
  let sweetSpot, gripToCentre: CourtVector
  var surfaceCacheRequired = false
  var serve: ValidationServe?
  var impact: Double { Double(impactFrame - 1) / fps }
  var duration: Double { Double(frameCount - 1) / fps }

  // Positions are metres, Y-up, before court placement. Keys match CollectionScene.replies.
  static let catalog: [CollectionScene: [String: ValidationClip]] = [
    .serve: [
      "正手高远发球": serving("LinChengForehandHighServe", .forehandHigh,
          centre: .init(-0.145622134, 0.911696613, 0.445372522),
          release: .init(-0.146614000, 0.998799324, 0.448366344),
          cork: .init(-0.145622149, 0.911696494, 0.445372701)),
      "正手短发球": serving("LinChengForehandShortServe", .forehandShort,
          centre: .init(-0.143338740, 0.912249625, 0.444539756),
          release: .init(-0.142346144, 1.003673196, 0.449335396),
          cork: .init(-0.143338740, 0.912249744, 0.444539666)),
      "反手短发球": serving("LinChengBackhandShortServe", .backhandShort,
          centre: .init(0.432994306, 0.921442389, 0.446039081),
          release: .init(0.417955339, 0.983463049, 0.428899854),
          cork: .init(0.430477381, 0.921897292, 0.454668015)),
      "反手偷后场": serving("LinChengBackhandFlickServe", .flick,
          centre: .init(0.433402568, 0.919697285, 0.446594745),
          release: .init(0.417955339, 0.983463049, 0.428899854),
          cork: .init(0.431133062, 0.921380281, 0.455139607))
    ],
    .high: [
      "高远球": ValidationClip(resource: "LinChengForehandClear", title: "林澄正手高远球",
                            gripBone: "racket_grip_R", shot: .clear, impactFrame: 24, frameCount: 52, fps: 30,
                            sweetSpot: CourtVector(-0.398252, 2.354539, 0.115947), gripToCentre: CourtVector(0, 0.53, 0)),
      "吊球": ValidationClip(resource: "LinChengForehandDrop", title: "林澄正手吊球",
                          gripBone: "racket_grip_R", shot: .net, impactFrame: 25, frameCount: 52, fps: 30,
                          sweetSpot: CourtVector(-0.41281274, 2.40130854, 0.18334980), gripToCentre: CourtVector(0, 0.53, 0)),
      "扣杀": ValidationClip(resource: "LinChengForehandSmash", title: "林澄正手扣杀",
                          gripBone: "racket_grip_R", shot: .smash, impactFrame: 24, frameCount: 52, fps: 30,
                          sweetSpot: CourtVector(-0.49001426, 2.48155785, 0.37846956), gripToCentre: CourtVector(0, 0.53, 0),
                          surfaceCacheRequired: true)
    ],
    .netHigh: [
      "扑球": ValidationClip(resource: "LinChengForehandNetKill", title: "林澄正手扑球",
                          gripBone: "racket_grip_R", shot: .smash, impactFrame: 19, frameCount: 46, fps: 30,
                          sweetSpot: CourtVector(-0.67062515, 1.85701191, 1.13459146), gripToCentre: CourtVector(0, 0.53, 0)),
      "推球": ValidationClip(resource: "LinChengForehandNetPush", title: "林澄正手推球",
                           gripBone: "racket_grip_R", shot: .drive, impactFrame: 19, frameCount: 46, fps: 30,
                           sweetSpot: CourtVector(-0.670575798, 1.857018471, 1.134606481), gripToCentre: CourtVector(0, 0.53, 0)),
      "轻放网": ValidationClip(resource: "LinChengForehandSoftNet", title: "林澄正手轻放网",
                            gripBone: "racket_grip_R", shot: .net, impactFrame: 19, frameCount: 46, fps: 30,
                            sweetSpot: CourtVector(-0.671013117, 1.856777191, 1.134684563), gripToCentre: CourtVector(0, 0.53, 0))
    ],
    .flat: [
      "正手平抽": ValidationClip(resource: "LinChengForehandDrive", title: "林澄正手平抽",
                             gripBone: "racket_grip_R", shot: .drive, impactFrame: 16, frameCount: 40, fps: 30,
                             sweetSpot: CourtVector(-1.003642082, 1.508746624, 0.764384389), gripToCentre: CourtVector(0, 0.53, 0),
                             surfaceCacheRequired: true),
      "反手平抽": ValidationClip(resource: "LinChengBackhandDrive", title: "林澄反手平抽",
                             gripBone: "racket_grip_R", shot: .drive, impactFrame: 17, frameCount: 42, fps: 30,
                             sweetSpot: CourtVector(0.722107768, 1.481477141, 0.591576874), gripToCentre: CourtVector(0, 0.53, 0)),
      "减力挡网": ValidationClip(resource: "LinChengForehandSoftBlock", title: "林澄减力挡网",
                             gripBone: "racket_grip_R", shot: .net, impactFrame: 16, frameCount: 37, fps: 30,
                             sweetSpot: CourtVector(-0.970910132, 1.510209918, 0.675673425), gripToCentre: CourtVector(0, 0.53, 0))
    ]
  ]
  private static func serving(_ resource: String, _ kind: ServeTraining,
                              centre: CourtVector, release: CourtVector, cork: CourtVector) -> Self {
    let backhand = kind == .backhandShort || kind == .flick
    let serve = ValidationServe(kind: kind, releaseFrame: backhand ? 15 : 20,
                                releaseCork: release, impactCork: cork,
                                holdPoint: .init(-0.006, backhand ? 0.103 : 0.099, -0.044),
                                featherReach: backhand ? 0.049 : 0.045)
    return Self(resource: resource, title: "林澄" + kind.rawValue, gripBone: "racket_grip_R",
                shot: serve.isShort ? .net : .clear, impactFrame: backhand ? 18 : 24,
                frameCount: backhand ? 38 : 44, fps: 30, sweetSpot: centre,
                gripToCentre: .init(0, 0.53, 0), surfaceCacheRequired: true, serve: serve)
  }

}

private struct StrokeFixture {
  var scene = CollectionScene.high
  var lane = FeedLane.right
  var diagonal = false
  var reply = "高远球"
  var clip: ValidationClip? { ValidationClip.catalog[scene]?[reply] }
  var hasClip: Bool { clip != nil }
  var replies: [String] { scene == .serve ? ServeTraining.allCases.filter { $0 != .free }.map(\.rawValue) : scene.replies }
  var isServe: Bool { scene == .serve }

  // Near-right service court. All four clips share the same standing placement.
  static let serveStand = CourtVector(1.22, 0, 2.85)
  static func serveWorld(_ point: CourtVector) -> CourtVector {
    serveStand + CourtVector(-point.x, point.y, -point.z)
  }
  var releaseTime: Double? {
    guard let clip, let serve = clip.serve else { return nil }
    return Double(serve.releaseFrame - 1) / clip.fps
  }

  func fallingCork(at time: Double) -> CourtVector? {
    guard let serve = clip?.serve, let releaseTime else { return nil }
    let t = Float(max(0, min(receiveTime, time) - releaseTime))
    let duration = Float(receiveTime - releaseTime)
    let acceleration = CourtVector(0, -9.81, 0)
    let origin = Self.serveWorld(serve.releaseCork)
    let hit = Self.serveWorld(serve.impactCork)
    let velocity = (hit - origin) / duration - acceleration * (duration * 0.5)
    return origin + velocity * t + acceleration * (t * t * 0.5)
  }

  var contactPosition: CourtVector {
    if let serve = clip?.serve { return Self.serveWorld(serve.impactCork) }
    return isServe ? .zero : Self.metres(flight.at(receiveTime))
  }

  static func courtPosition(_ world: CourtVector) -> Position {
    Position(x: Double(world.x) / 3.05, y: 0.5 + Double(world.z) / 13.4,
             z: Double(world.y) * Flight.netHeight / 1.524)
  }

  var flight: Flight {
    let feed = scene.feed!
    let width = scene == .backhand ? 0.79 : 0.49
    let target = lane.sign * width
    let origin = diagonal ? (lane == .middle ? -0.65 : -target) : target
    return Flight(from: Position(x: origin, y: feed.originY, z: feed.height),
                  to: Position(x: target, y: feed.depth), start: 0,
                  duration: feed.seconds, arc: feed.arc, incoming: true, shot: feed.shot)
  }

  static func metres(_ p: Position) -> CourtVector {
    CourtVector(Float(p.x * 3.05), Float(p.z * 1.524 / Flight.netHeight), Float((p.y - 0.5) * 13.4))
  }

  var receiveTime: Double {
    if isServe { return clip?.impact ?? 0 }
    let path = flight
    var low = hasClip ? path.duration / 2 : 0
    var high = path.duration
    for _ in 0..<32 {
      let t = (low + high) / 2
      let p = path.at(t)
      let before = clip.map { Self.metres(p).y > $0.sweetSpot.y } ?? (p.y < scene.feed!.receiveY)
      if before { low = t } else { high = t }
    }
    return (low + high) / 2
  }

  func returnFlight(at time: Double) -> Flight {
    if let serve = clip?.serve {
      return Rally.serviceFlight(format: .singles, near: true, serverX: Double(Self.serveStand.x) / 3.05,
                                 launch: Self.courtPosition(contactPosition), time: time,
                                 short: serve.isShort, aim: 0, impact: serve.swing)
    }
    let origin = flight.at(time)
    if scene == .flat, let clip {
      return midcourtReturn(clip.shot, from: origin, at: time)
    }
    if scene == .netHigh, let shot = clip?.shot, shot == .drive || shot == .net {
      return netHighTouch(shot, from: origin, at: time)
    }
    switch clip?.shot {
    case .net:
      // Fixed rear-court drop from Rally.send at half strength, with no stretch or braking.
      let landing = Position(x: origin.x, y: 0.385)
      let crossing = (0.5 - origin.y) / (landing.y - origin.y)
      let arc = (Flight.netHeight + 0.04 - origin.z * (1 - crossing)) / Flight.arch(crossing, shot: .net)
      return Flight(from: origin, to: landing, start: time, duration: 1.03, arc: max(0, arc),
                    incoming: false, shot: .net)
    case .smash where scene == .netHigh:
      // Rally.send's button-confirmed net attack at half strength, without stretch.
      // This contact is above the tape and inside the full net-play blend (y <= 0.625).
      let strength = 0.50, verticalSweep = -0.30
      let landing = Position(x: origin.x, y: 0.34 - 0.12 * strength)
      let duration = 0.70 - 0.22 * strength
      let span = (origin.y - landing.y) * 13.4
      let tangent = -0.13 - 0.19 * abs(verticalSweep)
      let arc = (origin.z + tangent * span * Flight.netHeight / 1.524) / 3.12 * (1 + 0.30 * verticalSweep)
      return Flight(from: origin, to: landing, start: time, duration: duration, arc: arc,
                    incoming: false, shot: .smash, measured: true)
    case .smash:
      // Match Rally.send for a straight rear-court attack with no stretch.
      let strength = 0.50, sweep = 0.50, power = 0.50, verticalSweep = -0.30
      let placementJitter = 0.002 * sin(time * 53.941)
      let depth = 0.26 - 0.25 * strength + 0.16 * (1 - sweep) - 0.06 * verticalSweep + placementJitter
      let duration = 0.72 * (1.18 - 0.39 * strength) * (0.94 + 0.10 * (1 - power))
      let arc = (0.09 + 0.11 * strength) * (1 + 0.42 * verticalSweep) * (1 + 0.30 * verticalSweep)
      return Flight(from: origin, to: Position(x: origin.x, y: depth),
                    start: time, duration: duration, arc: arc, incoming: false, shot: .smash, measured: true)
    default:
      return Flight(from: origin, to: Position(x: lane.sign * -0.52, y: 0.06),
                    start: time, duration: 1.65, arc: 0.72, incoming: false, shot: .clear)
    }
  }

  private func netHighTouch(_ shot: Shot, from origin: Position, at time: Double) -> Flight {
    // Rally.send's straight button returns at this fixed high contact (full net-play blend).
    let push = shot == .drive
    let input = push ? SwingImpact(power: 0.57, sweep: 0.50, label: "网前推球")
      : SwingImpact(power: 0.24, sweep: 0.18, label: "网前放网", verticalSweep: 0.18)
    let strength = input.strength
    let depth = push ? 0.30 - 0.12 * strength : 0.43 - 0.06 * strength
    let duration = (push ? 0.85 * 1.08 : 0.92) * (1.18 - 0.39 * strength)
    let tangent = push ? -0.045 + 0.12 * input.verticalSweep : -0.06 + 0.18 * input.verticalSweep
    let span = (origin.y - depth) * 13.4
    let arc = (origin.z + tangent * span * Flight.netHeight / 1.524) / 3.12 * (1 + 0.30 * input.verticalSweep)
    return Flight(from: origin, to: Position(x: origin.x, y: depth), start: time,
                  duration: duration, arc: arc, incoming: false, shot: shot, measured: true)
  }

  private func midcourtReturn(_ shot: Shot, from origin: Position, at time: Double) -> Flight {
    // Fixed, straight inputs with zero stretch, following Rally.send's flat-feed branches.
    let block = shot == .net
    let input = block ? SwingImpact(power: 0.24, sweep: 0.18, verticalSweep: 0.04, braking: 0.65)
      : SwingImpact(power: 0.60, sweep: 0.60)
    let strength = input.strength
    var depth = block ? 0.40 - 0.13 * strength : 0.26 - 0.25 * strength
    var arc = block ? 0.13 + 0.17 * strength : 0.12 + 0.16 * strength

    func arcForNet(height: Double, landing: Double) -> Double {
      let crossing = (0.5 - origin.y) / (landing - origin.y)
      return (height - origin.z * (1 - crossing)) / Flight.arch(crossing, shot: shot)
    }

    if origin.y <= 0.69 {
      let shortDepth = block ? 0.43 - 0.06 * strength : 0.30 - 0.12 * strength
      let shortArc = arcForNet(height: max(Flight.netHeight + 0.055, block ? origin.z : 0), landing: shortDepth)
      let blend = min(1, max(0, (0.69 - origin.y) / 0.065))
      depth += blend * (shortDepth - depth)
      arc += blend * (shortArc - arc)
    } else if block {
      depth += 0.025 * (input.braking ?? 0)
    }
    arc *= 1 + 0.30 * input.verticalSweep
    if block {
      let progress = min(1, max(0, (origin.y - 0.625) / 0.065))
      let blend = progress * progress * (3 - 2 * progress)
      depth += blend * (0.413 - 0.12 * strength - depth)
      let clearance = (0.095 + 0.18 * strength + 0.12 * input.verticalSweep) * Flight.netHeight / 1.524
      arc += blend * max(0, arcForNet(height: Flight.netHeight + clearance, landing: depth) - arc)
    }
    return Flight(from: origin, to: Position(x: origin.x, y: depth), start: time,
                  duration: (block ? 0.92 : 0.85) * (1.18 - 0.39 * strength), arc: arc,
                  incoming: false, shot: shot, measured: true)
  }
}

struct StrokeValidationView: View {
  let close: () -> Void
  @State private var fixture = StrokeFixture()
  @State private var time = 0.0
  @State private var started: TimeInterval?
  @State private var pauseAtContact = true
  @State private var fullCourt = false
  @State private var loadResult: (resource: String, ready: Bool)?
  @State private var playbackGeneration = 0
  private var assetReady: Bool? {
    guard let result = loadResult, result.resource == fixture.clip?.resource else { return nil }
    return result.ready
  }
  @State private var contactError: Float?
  @State private var releaseError: Float?
  private let clock = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

  private var playable: Bool { fixture.hasClip && assetReady == true }
  private var impact: Double { fixture.receiveTime }
  private var end: Double {
    guard playable, let clip = fixture.clip else { return fixture.isServe ? 0 : fixture.flight.duration }
    return impact + max(fixture.returnFlight(at: impact).duration, clip.duration - clip.impact)
  }
  private var atContact: Bool { abs(time - impact) < 0.0001 }
  private var atRelease: Bool { fixture.releaseTime == time }
  private var status: String {
    if atRelease && started == nil, let serve = fixture.clip?.serve { return "放球暂停 · F\(serve.releaseFrame)" }
    if atContact && started == nil { return playable ? "触球暂停 · F\(fixture.clip!.impactFrame)" : "接球点暂停" }
    if end > 0 && time >= end { return "回放结束" }
    if started == nil { return time == 0 ? "准备回放" : "已暂停" }
    if let release = fixture.releaseTime {
      return time < release ? "左手持球" : time < impact ? "球托下落" : "发球飞行中"
    }
    return playable && time > impact ? "\(fixture.reply)回场" : "来球飞行中"
  }

  var body: some View {
    GeometryReader { bounds in
      let wide = bounds.size.width > bounds.size.height
      let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
      layout {
        ZStack(alignment: .topLeading) {
          let generation = playbackGeneration
          ValidationCourt(fixture: fixture, time: time, impact: impact, wide: fullCourt,
                          contactGeneration: time == impact && started == nil && contactError == nil ? generation : nil,
                          releaseGeneration: atRelease && started == nil && releaseError == nil ? generation : nil,
                          loaded: { resource, ready in
                            if fixture.clip?.resource == resource { loadResult = (resource, ready) }
                          }, measured: { error in
                            if playbackGeneration == generation { contactError = error }
                          }, released: { error in
                            if playbackGeneration == generation { releaseError = error }
                          })
          HStack {
            Button(action: close) { Label("球社", systemImage: "chevron.left") }
            Spacer()
            Button(fullCourt ? "动作近景" : "全场球路") { fullCourt.toggle() }
              .accessibilityIdentifier("validation.camera")
          }.buttonStyle(.borderedProminent).tint(.black.opacity(0.65)).padding(8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            Text("动作验证").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Picker("场景", selection: Binding(get: { fixture.scene }, set: { scene in
              fixture.scene = scene
              fixture.reply = fixture.replies[0]
              reset()
            })) {
              ForEach(CollectionScene.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("validation.scene")
            if fixture.isServe {
              Text("右发球区 · 对角发球").font(.caption).foregroundStyle(.secondary)
              Picker("发球动作", selection: $fixture.reply) {
                ForEach(fixture.replies, id: \.self) { Text($0).tag($0) }
              }.pickerStyle(.menu).accessibilityIdentifier("validation.serve")
            } else {
              Picker("来球位置", selection: $fixture.lane) {
                ForEach(FeedLane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
              }.pickerStyle(.segmented).accessibilityIdentifier("validation.lane")
              Picker("来球方向", selection: $fixture.diagonal) {
                Text("直线").tag(false); Text("斜线").tag(true)
              }.pickerStyle(.segmented).accessibilityIdentifier("validation.direction")
              Text("建议回法").font(.caption).foregroundStyle(.secondary)
              Picker("建议回法", selection: $fixture.reply) {
                ForEach(fixture.scene.replies, id: \.self) { Text($0).tag($0) }
              }.pickerStyle(.segmented).accessibilityIdentifier("validation.reply")
            }
            Text(fixture.hasClip ? (assetReady == false ? "林澄动作载入失败" : assetReady == nil ? "正在载入林澄动作" : "已载入 · \(fixture.clip!.title)") : "当前回法尚无角色动作")
              .font(.subheadline).accessibilityIdentifier("validation.asset")
            Toggle(fixture.isServe ? "到触球点自动暂停" : "到接球点自动暂停", isOn: $pauseAtContact).font(.subheadline)
            HStack {
              Button("重放") { reset(); play() }.accessibilityIdentifier("validation.replay")
              Button(started == nil ? "播放" : "暂停") { if started == nil { play() } else { started = nil } }
              if !fixture.isServe {
                Button(playable ? "触球帧" : "接球点") { seek(impact) }
                  .accessibilityIdentifier("validation.contact")
              }
            }.buttonStyle(.bordered)
            if let release = fixture.releaseTime {
              HStack {
                Button("放球帧") { seek(release) }.accessibilityIdentifier("validation.release")
                Button("下落帧") { seek(release + 1 / (fixture.clip?.fps ?? 30)) }
                  .accessibilityIdentifier("validation.drop")
                Button("触球帧") { seek(impact) }.accessibilityIdentifier("validation.contact")
              }.buttonStyle(.bordered).disabled(!playable)
            }
            Text(status).font(.subheadline.bold()).accessibilityIdentifier("validation.status")
            if playable && atContact {
              let ball = fixture.contactPosition
              Text(String(format: "球高 %.2f m　拍心偏差 %@", ball.y,
                          contactError.map { String(format: "%.1f mm", $0 * 1000) } ?? "测量中"))
                .font(.caption.monospacedDigit()).accessibilityIdentifier("validation.measurement")
            }
            if playable, let release = fixture.releaseTime, let cork = fixture.fallingCork(at: time) {
              if atRelease {
                Text(String(format: "放球高度 %.3f m　球托偏差 %@", cork.y,
                            releaseError.map { String(format: "%.1f mm", $0 * 1000) } ?? "测量中"))
                  .font(.caption.monospacedDigit()).accessibilityIdentifier("validation.releaseMeasurement")
              } else if time > release && time < impact {
                Text(String(format: "下落中 · 球托高 %.3f m", cork.y))
                  .font(.caption.monospacedDigit()).accessibilityIdentifier("validation.dropMeasurement")
              }
              if time >= impact {
                let path = fixture.returnFlight(at: impact)
                let u = (0.5 - path.from.y) / (path.to.y - path.from.y)
                let height = path.from.z * (1 - u) + path.to.z * u + path.arc * Flight.arch(u, shot: path.shot)
                let clearance = (height - Flight.netHeight) * 1.524 / Flight.netHeight
                let landed = time >= path.start + path.duration
                let legal = CourtFormat.singles.legalLanding(path.to, serverNear: true,
                                                            serverX: Double(StrokeFixture.serveStand.x))
                Text(String(format: "%@ · 网顶余量 %.3f m · 距网 %.2f m · 横向 %.2f m",
                            landed ? (legal && path.netCollision == nil ? "合法对角落地" : "发球违例") : "对角出球",
                            clearance, (0.5 - path.to.y) * 13.4, path.to.x * 3.05))
                  .font(.caption.monospacedDigit()).accessibilityIdentifier("validation.serveRoute")
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(width: wide ? min(315, bounds.size.width * 0.43) : nil,
                height: wide ? nil : bounds.size.height * 0.48)
      }
    }
    .onChange(of: fixture.lane) { _, _ in reset() }
    .onChange(of: fixture.diagonal) { _, _ in reset() }
    .onChange(of: fixture.reply) { _, _ in reset() }
    .onReceive(clock) { _ in
      guard let started else { return }
      let next = ProcessInfo.processInfo.systemUptime - started
      if pauseAtContact && time < impact && next >= impact {
        self.started = nil; time = impact
      } else {
        time = min(end, next)
        if time >= end { self.started = nil }
      }
    }
    .onDisappear { started = nil }
  }

  private func reset() { seek(0) }
  private func seek(_ seconds: Double) {
    started = nil
    time = seconds
    invalidateMeasurement()
  }
  private func invalidateMeasurement() {
    playbackGeneration += 1
    contactError = nil
    releaseError = nil
  }
  private func play() {
    guard !fixture.isServe || playable else { return }
    invalidateMeasurement()
    if time >= end { time = 0 }
    started = ProcessInfo.processInfo.systemUptime - time
  }
}

private struct ValidationCourt: UIViewRepresentable {
  let fixture: StrokeFixture
  let time, impact: Double
  let wide: Bool
  let contactGeneration, releaseGeneration: Int?
  let loaded: (String, Bool) -> Void
  let measured, released: (Float) -> Void

  func makeCoordinator() -> ValidationStage { ValidationStage() }
  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    context.coordinator.install(in: view)
    return view
  }
  func updateUIView(_ view: SCNView, context: Context) {
    if let clip = fixture.clip, context.coordinator.currentResource != clip.resource {
      context.coordinator.load(clip)
      let ready = context.coordinator.ready
      DispatchQueue.main.async { loaded(clip.resource, ready) }
    }
    context.coordinator.show(fixture, time: time, impact: impact, wide: wide, in: view,
                             contactGeneration: contactGeneration, releaseGeneration: releaseGeneration,
                             measured: measured, released: released)
  }
}

private final class ValidationStage: NSObject, SCNSceneRendererDelegate {
  let stage = SCNScene(), character = SCNNode(), camera = SCNNode(), shuttle = SCNNode()
  var grip: SCNNode?
  private var holdHand: SCNNode?
  private let feathers = SCNNode()
  private var shuttleServe: Bool?
  private var heldInRender: (hand: SCNNode, serve: ValidationServe)?
  var currentResource: String?
  var ready = false
  private var surfaceAnimation: StrokeSurfaceAnimation?
  private struct ContactRequest {
    let generation: Int
    let anchor: SCNNode
    let offset, correction: CourtVector
    let report: (Float) -> Void
  }
  private struct FrameRequest {
    let fixture: StrokeFixture
    let time, impact: Double
    let wide, active: Bool
    let surface: StrokeSurfaceAnimation?
    let contact: ContactRequest?
    let holdHand: SCNNode?
  }
  // The main thread publishes a frame, and the renderer owns the applied scene clock.
  private let lock = NSLock()
  private var pendingFrame: FrameRequest?
  private var contactInRender: (renderTime: TimeInterval, request: ContactRequest)?
  private var measuredGeneration: Int?
  private var routeMarkers: [SCNNode] = []

  private func box(_ size: CourtVector, at p: CourtVector, color: UIColor) {
    let shape = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
    shape.firstMaterial?.diffuse.contents = color
    let node = SCNNode(geometry: shape)
    node.simdPosition = p
    stage.rootNode.addChildNode(node)
  }

  func install(in view: SCNView) {
    let root = stage.rootNode
    stage.background.contents = UIColor(red: 0.18, green: 0.26, blue: 0.30, alpha: 1)
    box(.init(8.5, 0.06, 15.5), at: .init(0,-0.04,0), color: UIColor(red: 0.14, green: 0.40, blue: 0.36, alpha: 1))
    for x: Float in [-2.59, 2.59] { box(.init(0.04,0.012,13.4), at: .init(x,0,0), color: .white) }
    for z: Float in [-6.7,-1.98,1.98,6.7] { box(.init(5.18,0.012,0.04), at: .init(0,0,z), color: .white) }
    for z: Float in [-4.34,4.34] { box(.init(0.04,0.012,4.72), at: .init(0,0,z), color: .white) }
    for x: Float in [-3.05,3.05] { box(.init(0.06,1.55,0.06), at: .init(x,0.775,0), color: .white) }
    box(.init(6.1,0.037,0.025), at: .init(0,1.524,0), color: .white)
    for n in 0...60 { box(.init(0.008,0.73,0.008), at: .init(-3.05 + Float(n) * 6.1 / 60,1.14,0), color: .darkGray) }
    for n in 0...7 { box(.init(6.1,0.008,0.008), at: .init(0,0.78 + Float(n)*0.10,0), color: .darkGray) }
    root.addChildNode(character)
    character.eulerAngles.y = .pi
    shuttle.addChildNode(feathers)
    root.addChildNode(shuttle)
    configureShuttle(forServe: false)
    let marker = SCNSphere(radius: 0.044)
    marker.firstMaterial?.lightingModel = .constant
    marker.firstMaterial?.diffuse.contents = UIColor.systemMint
    for _ in 0..<18 {
      let node = SCNNode(geometry: marker)
      root.addChildNode(node)
      routeMarkers.append(node)
    }
    for type in [SCNLight.LightType.ambient, .directional] {
      let node = SCNNode()
      node.light = SCNLight(); node.light?.type = type
      node.light?.intensity = type == .ambient ? 620 : 900
      node.position = SCNVector3(-4,7,4); node.look(at: SCNVector3Zero)
      root.addChildNode(node)
    }
    camera.camera = SCNCamera(); camera.camera?.fieldOfView = 39
    root.addChildNode(camera)
    view.scene = stage; view.pointOfView = camera; view.delegate = self
    view.antialiasingMode = .multisampling2X
    view.isPlaying = false
  }

  private func configureShuttle(forServe: Bool) {
    guard shuttleServe != forServe else { return }
    shuttleServe = forServe
    let cork = SCNSphere(radius: forServe ? 0.013 : 0.026)
    cork.firstMaterial?.diffuse.contents = UIColor.systemYellow
    shuttle.geometry = cork
    shuttle.simdScale = .init(1, 1, 1)
    let skirt = SCNCone(topRadius: forServe ? 0.029 : 0.042,
                        bottomRadius: forServe ? 0.012 : 0.014,
                        height: forServe ? 0.047 : 0.075)
    skirt.firstMaterial?.diffuse.contents = UIColor.white
    feathers.geometry = skirt
    feathers.position.y = forServe ? 0.033 : 0.045
  }

  func load(_ clip: ValidationClip) {
    lock.lock(); pendingFrame = nil; lock.unlock()
    character.childNodes.forEach { $0.removeFromParentNode() }
    grip = nil
    holdHand = nil
    surfaceAnimation = nil
    ready = false
    currentResource = clip.resource
    if let url = Bundle.main.url(forResource: clip.resource, withExtension: "usdz"),
       let imported = try? SCNScene(url: url) {
      let model = imported.rootNode
      if clip.surfaceCacheRequired {
        guard let cache = Bundle.main.url(forResource: clip.resource, withExtension: "brmesh"),
              let surface = try? StrokeSurfaceAnimation(url: cache, assetURL: url,
                                                         model: model, duration: clip.duration) else { return }
        surfaceAnimation = surface
      }
      var animations = 0
      func configure(_ node: SCNNode) {
        for key in node.animationKeys {
          guard let player = node.animationPlayer(forKey: key) else { continue }
          player.animation.usesSceneTimeBase = true
          player.animation.isRemovedOnCompletion = false
          if clip.serve != nil {
            player.animation.repeatCount = 0
            player.animation.fillsForward = true
          }
          player.play()
          animations += 1
        }
        if grip == nil { grip = node.skinner?.bones.first { $0.name == clip.gripBone } }
        if holdHand == nil, let name = clip.serve?.handBone {
          holdHand = node.skinner?.bones.first { $0.name == name }
        }
      }
      configure(model)
      model.enumerateChildNodes { node, _ in configure(node) }
      character.addChildNode(model)
      SCNTransaction.flush()
      ready = animations > 0 && grip != nil && (clip.serve == nil || holdHand != nil)
    }
  }

  func show(_ fixture: StrokeFixture, time: Double, impact: Double, wide: Bool, in view: SCNView,
            contactGeneration: Int?, releaseGeneration: Int?,
            measured: @escaping (Float) -> Void, released: @escaping (Float) -> Void) {
    let active = ready && fixture.hasClip
    var contact: ContactRequest?
    if active, let clip = fixture.clip {
      if let generation = contactGeneration, let grip {
        // The backhand source places the cork centre 9 mm off the bed: compare the
        // touching surface, not the centre, against the rendered string-bed anchor.
        let correction = clip.serve.map {
          StrokeFixture.serveWorld($0.impactCork) - StrokeFixture.serveWorld(clip.sweetSpot)
        } ?? .zero
        contact = ContactRequest(generation: generation, anchor: grip, offset: clip.gripToCentre,
                                 correction: correction, report: measured)
      } else if let generation = releaseGeneration, let serve = clip.serve, let holdHand {
        contact = ContactRequest(generation: generation, anchor: holdHand, offset: serve.holdPoint,
                                 correction: serve.holdOffset, report: released)
      }
    }
    let frame = FrameRequest(fixture: fixture, time: time, impact: impact, wide: wide, active: active,
                             surface: surfaceAnimation, contact: contact, holdHand: holdHand)
    lock.lock()
    pendingFrame = frame
    lock.unlock()
    // If the view is already drawing, guarantee a follow-up frame for the pending measurement.
    view.rendersContinuously = contact != nil
    view.setNeedsDisplay()
  }

  func renderer(_ renderer: SCNSceneRenderer, updateAtTime renderTime: TimeInterval) {
    lock.lock()
    let frame = pendingFrame
    pendingFrame = nil
    lock.unlock()
    contactInRender = nil
    heldInRender = nil
    guard let frame else { return }

    let fixture = frame.fixture
    let (time, impact, wide, active) = (frame.time, frame.impact, frame.wide, frame.active)
    let local = fixture.clip?.sweetSpot ?? .zero
    let ballAtContact = fixture.contactPosition
    let stand = fixture.isServe ? StrokeFixture.serveStand
      : CourtVector(ballAtContact.x + local.x, 0, ballAtContact.z + local.z)
    character.simdPosition = stand
    character.isHidden = !active
    shuttle.isHidden = fixture.isServe && !active
    configureShuttle(forServe: fixture.isServe)

    let sending = active && time >= impact
    let route: Flight?
    if fixture.isServe, let release = fixture.releaseTime, let serve = fixture.clip?.serve, active {
      route = sending ? fixture.returnFlight(at: impact) : nil
      if time > impact, let route {
        placeShuttle(along: route, time: time, departing: serve.fallingOrientation(at: 1))
      } else if let cork = fixture.fallingCork(at: time) {
        shuttle.simdPosition = cork
        let u = Float(max(0, (time - release) / (impact - release)))
        shuttle.simdOrientation = serve.fallingOrientation(at: u)
        if time < release, let hand = frame.holdHand { heldInRender = (hand, serve) }
      }
    } else if fixture.isServe {
      route = nil
    } else {
      let path = active && time > impact ? fixture.returnFlight(at: impact) : fixture.flight
      placeShuttle(along: path, time: time)
      route = sending ? fixture.returnFlight(at: impact) : fixture.flight
    }

    if wide {
      camera.simdPosition = CourtVector(-4.2,9.2,12.8)
      if fixture.isServe {
        lookLevel(at: CourtVector(0, 1.35, 0))
      } else {
        camera.simdLook(at: CourtVector(0,1.35,0))
      }
    } else if fixture.isServe {
      // Stay on the server's side of the net so the shoes and arm remain visible.
      camera.simdPosition = stand + CourtVector(3.28, 1.65, -2.45)
      lookLevel(at: stand + CourtVector(0, 1.0, -0.30))
    } else {
      // Look from the side of contact so the grip is visible beside the ponytail.
      let contactOnRight = fixture.scene == .netHigh || (fixture.scene == .flat && local.x < 0)
      let offset: Float = active && contactOnRight ? 2.4 : -2.4
      camera.simdPosition = stand + CourtVector(offset,2.55,4.8)
      camera.simdLook(at: stand + CourtVector(0,1.14,-0.45))
    }
    for (index, marker) in routeMarkers.enumerated() {
      marker.isHidden = !wide || route == nil
      if wide, let route {
        let until = active && !sending ? impact : route.duration
        marker.simdPosition = StrokeFixture.metres(route.at(route.start + until * Double(index) / Double(routeMarkers.count - 1)))
      }
    }

    let sceneTime = fixture.clip.map { min($0.duration, max(0, $0.impact + (time - impact))) } ?? 0
    frame.surface?.show(at: sceneTime)
    renderer.sceneTime = sceneTime
    if let contact = frame.contact, measuredGeneration != contact.generation {
      contactInRender = (renderTime, contact)
    }
  }

  private func lookLevel(at target: CourtVector) {
    camera.simdLook(at: target, up: CourtVector(0, 1, 0), localFront: CourtVector(0, 0, -1))
  }

  private func placeShuttle(along path: Flight, time: Double, departing: simd_quatf? = nil) {
    shuttle.simdPosition = StrokeFixture.metres(path.at(time))
    let tangent = StrokeFixture.metres(path.at(min(path.start + path.duration, time + 0.001)))
      - StrokeFixture.metres(path.at(max(path.start, time - 0.001)))
    if simd_length(tangent) > 0.0001 {
      let flightOrientation = simd_quatf(from: CourtVector(0, 1, 0), to: -simd_normalize(tangent))
      shuttle.simdOrientation = departing.map {
        simd_slerp($0, flightOrientation, Float(min(1, (time - path.start) / 0.05)))
      } ?? flightOrientation
    }
  }

  func renderer(_ renderer: SCNSceneRenderer, didApplyAnimationsAtTime time: TimeInterval) {
    guard let (hand, serve) = heldInRender else { return }
    shuttle.simdPosition = hand.presentation.simdConvertPosition(serve.holdPoint, to: nil) + serve.holdOffset
  }

  func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime renderTime: TimeInterval) {
    guard let (sampleTime, request) = contactInRender, sampleTime == renderTime else { return }
    contactInRender = nil
    measuredGeneration = request.generation
    let centre = request.anchor.presentation.simdConvertPosition(request.offset, to: nil) + request.correction
    let error = simd_distance(centre, shuttle.presentation.simdWorldPosition)
    DispatchQueue.main.async { request.report(error) }
  }
}

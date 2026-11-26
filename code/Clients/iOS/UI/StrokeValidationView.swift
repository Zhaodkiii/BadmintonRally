import Combine
import SceneKit
import SwiftUI

private typealias CourtVector = SIMD3<Float>

private enum FeedLane: String, CaseIterable {
  case left = "左路", middle = "中路", right = "右路"
  var sign: Double { self == .left ? -1 : self == .right ? 1 : 0 }
}

private struct ValidationClip {
  let resource, title, gripBone: String
  let impactFrame, frameCount: Int
  let fps: Double
  let sweetSpot, gripToCentre: CourtVector
  var impact: Double { Double(impactFrame - 1) / fps }
  var duration: Double { Double(frameCount - 1) / fps }

  // Positions are metres, Y-up, before court placement. Keys match CollectionScene.replies.
  static let catalog: [CollectionScene: [String: ValidationClip]] = [
    .high: ["高远球": ValidationClip(resource: "LinChengForehandClear", title: "林澄正手高远球",
                                gripBone: "racket_grip_R", impactFrame: 24, frameCount: 52, fps: 30,
                                sweetSpot: CourtVector(-0.398252, 2.354539, 0.115947),
                                gripToCentre: CourtVector(0, 0.53, 0))]
  ]
}

private struct StrokeFixture {
  var scene = CollectionScene.high
  var lane = FeedLane.right
  var diagonal = false
  var reply = "高远球"
  var clip: ValidationClip? { ValidationClip.catalog[scene]?[reply] }
  var hasClip: Bool { clip != nil }

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
    Flight(from: flight.at(time), to: Position(x: lane.sign * -0.52, y: 0.06),
           start: time, duration: 1.65, arc: 0.72, incoming: false, shot: .clear)
  }
}

struct StrokeValidationView: View {
  let close: () -> Void
  @State private var fixture = StrokeFixture()
  @State private var time = 0.0
  @State private var started: TimeInterval?
  @State private var pauseAtContact = true
  @State private var fullCourt = false
  @State private var assetReady: Bool?
  @State private var contactError: Float?
  private let clock = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

  private var playable: Bool { fixture.hasClip && assetReady == true }
  private var impact: Double { fixture.receiveTime }
  private var end: Double { playable ? impact + fixture.returnFlight(at: impact).duration : fixture.flight.duration }
  private var atContact: Bool { abs(time - impact) < 0.0001 }
  private var status: String {
    if atContact && started == nil { return playable ? "触球暂停 · F\(fixture.clip!.impactFrame)" : "接球点暂停" }
    if time >= end { return "回放结束" }
    if started == nil { return time == 0 ? "准备回放" : "已暂停" }
    return time <= impact ? "来球飞行中" : playable ? "高远球回场" : "来球飞行中"
  }

  var body: some View {
    GeometryReader { bounds in
      let wide = bounds.size.width > bounds.size.height
      let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
      layout {
        ZStack(alignment: .topLeading) {
          ValidationCourt(fixture: fixture, time: time, impact: impact, wide: fullCourt,
                          loaded: { assetReady = $0 }, measured: { contactError = $0 })
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
            Picker("来球", selection: Binding(get: { fixture.scene }, set: { scene in
              fixture.scene = scene
              fixture.reply = scene.replies[0]
              reset()
            })) {
              ForEach(CollectionScene.allCases.filter { $0 != .serve }, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("validation.scene")
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
            Text(fixture.hasClip ? (assetReady == false ? "林澄动作载入失败" : assetReady == nil ? "正在载入林澄动作" : "已载入 · \(fixture.clip!.title)") : "当前回法尚无角色动作")
              .font(.subheadline).accessibilityIdentifier("validation.asset")
            Toggle("到接球点自动暂停", isOn: $pauseAtContact).font(.subheadline)
            HStack {
              Button("重放") { reset(); play() }.accessibilityIdentifier("validation.replay")
              Button(started == nil ? "播放" : "暂停") { if started == nil { play() } else { started = nil } }
              Button(playable ? "触球帧" : "接球点") { started = nil; time = impact }
                .accessibilityIdentifier("validation.contact")
            }.buttonStyle(.bordered)
            Text(status).font(.subheadline.bold()).accessibilityIdentifier("validation.status")
            if playable && atContact {
              let ball = StrokeFixture.metres(fixture.flight.at(impact))
              Text(String(format: "球高 %.2f m　拍心偏差 %@", ball.y,
                          contactError.map { String(format: "%.1f mm", $0 * 1000) } ?? "测量中"))
                .font(.caption.monospacedDigit()).accessibilityIdentifier("validation.measurement")
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

  private func reset() { started = nil; time = 0; contactError = nil }
  private func play() {
    if time >= end { time = 0 }
    started = ProcessInfo.processInfo.systemUptime - time
  }
}

private struct ValidationCourt: UIViewRepresentable {
  let fixture: StrokeFixture
  let time, impact: Double
  let wide: Bool
  let loaded: (Bool) -> Void
  let measured: (Float) -> Void

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
      DispatchQueue.main.async { loaded(ready) }
    }
    context.coordinator.show(fixture, time: time, impact: impact, wide: wide, in: view, measured: measured)
  }
}

private final class ValidationStage: NSObject, SCNSceneRendererDelegate {
  let stage = SCNScene(), character = SCNNode(), camera = SCNNode(), shuttle = SCNNode()
  var grip: SCNNode?
  var currentResource: String?
  var ready = false
  // The render callback samples the evaluated skeleton after animation; UI reads occur on main.
  private let lock = NSLock()
  private var sample: (CourtVector, CourtVector, Double, (Float) -> Void)?
  private var lastContact: CourtVector?
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
    let cork = SCNSphere(radius: 0.026)
    cork.firstMaterial?.diffuse.contents = UIColor.systemYellow
    shuttle.geometry = cork
    let skirt = SCNCone(topRadius: 0.042, bottomRadius: 0.014, height: 0.075)
    skirt.firstMaterial?.diffuse.contents = UIColor.white
    let feathers = SCNNode(geometry: skirt)
    feathers.position.y = 0.045
    shuttle.addChildNode(feathers)
    root.addChildNode(shuttle)
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

  func load(_ clip: ValidationClip) {
    character.childNodes.forEach { $0.removeFromParentNode() }
    grip = nil
    ready = false
    currentResource = clip.resource
    if let url = Bundle.main.url(forResource: clip.resource, withExtension: "usdz"),
       let imported = try? SCNScene(url: url, options: [.animationImportPolicy: SCNSceneSource.AnimationImportPolicy.playUsingSceneTimeBase]) {
      let model = imported.rootNode
      var animations = 0
      func configure(_ node: SCNNode) {
        for key in node.animationKeys {
          guard let player = node.animationPlayer(forKey: key) else { continue }
          player.animation.usesSceneTimeBase = true
          player.animation.isRemovedOnCompletion = false
          player.play()
          animations += 1
        }
        if grip == nil { grip = node.skinner?.bones.first { $0.name == clip.gripBone } }
      }
      configure(model)
      model.enumerateChildNodes { node, _ in configure(node) }
      character.addChildNode(model)
      ready = animations > 0 && grip != nil
    }
  }

  func show(_ fixture: StrokeFixture, time: Double, impact: Double, wide: Bool, in view: SCNView,
            measured: @escaping (Float) -> Void) {
    let active = ready && fixture.hasClip
    let ballAtContact = StrokeFixture.metres(fixture.flight.at(impact))
    let local = fixture.clip?.sweetSpot ?? .zero
    character.simdPosition = CourtVector(ballAtContact.x + local.x, 0, ballAtContact.z + local.z)
    character.isHidden = !active
    let path = active && time > impact ? fixture.returnFlight(at: impact) : fixture.flight
    let p = StrokeFixture.metres(path.at(time))
    shuttle.simdPosition = p
    let tangent = StrokeFixture.metres(path.at(min(path.start + path.duration, time + 0.001)))
      - StrokeFixture.metres(path.at(max(path.start, time - 0.001)))
    if simd_length(tangent) > 0.0001 {
      shuttle.simdOrientation = simd_quatf(from: CourtVector(0,1,0), to: -simd_normalize(tangent))
    }
    let stand = character.simdPosition
    if wide {
      camera.simdPosition = CourtVector(-4.2,9.2,12.8)
      camera.simdLook(at: CourtVector(0,1.35,0))
    } else {
      camera.simdPosition = stand + CourtVector(-2.4,2.55,4.8)
      camera.simdLook(at: stand + CourtVector(0,1.14,-0.45))
    }
    let route = fixture.flight
    let until = active ? impact : route.duration
    for (index, marker) in routeMarkers.enumerated() {
      marker.isHidden = !wide
      if wide { marker.simdPosition = StrokeFixture.metres(route.at(until * Double(index) / Double(routeMarkers.count - 1))) }
    }

    view.sceneTime = fixture.clip.map { min($0.duration, max(0, $0.impact + time - impact)) } ?? 0
    let contact = active && abs(time - impact) < 0.0001
    if contact, lastContact != ballAtContact, let clip = fixture.clip {
      lock.lock(); sample = (ballAtContact, clip.gripToCentre, clip.impact, measured); lock.unlock()
      lastContact = ballAtContact
    } else if !contact {
      lock.lock(); sample = nil; lock.unlock()
      lastContact = nil
    }
    view.setNeedsDisplay()
  }

  func renderer(_ renderer: SCNSceneRenderer, didApplyAnimationsAtTime time: TimeInterval) {
    lock.lock()
    guard let (ball, offset, impact, callback) = sample, abs(renderer.sceneTime - impact) < 0.001 else {
      lock.unlock()
      return
    }
    sample = nil
    lock.unlock()
    guard let grip else { return }
    let centre = grip.presentation.simdConvertPosition(offset, to: nil)
    let error = simd_distance(centre, ball)
    DispatchQueue.main.async { callback(error) }
  }
}

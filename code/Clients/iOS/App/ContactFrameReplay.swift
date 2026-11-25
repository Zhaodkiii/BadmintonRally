#if DEBUG
import SceneKit
import SwiftUI

/// Physical-device inspection of a fixed input through the match simulation and renderer.
struct ContactFrameReplay: View {
  @State private var blindFinished = false
  var body: some View {
    #if targetEnvironment(simulator)
    if ProcessInfo.processInfo.arguments.contains("-rearCourtReplay") {
      RearCourtReplay()
    } else {
      contactReplay
    }
    #else
    contactReplay
    #endif
  }

  @ViewBuilder private var contactReplay: some View {
    if ProcessInfo.processInfo.arguments.contains("-contactBlind") {
      ZStack {
        BlindReplaySurface { blindFinished = true }
        if blindFinished { Text("播放结束").foregroundStyle(.white) }
      }
      .background(.black).ignoresSafeArea().statusBarHidden().persistentSystemOverlays(.hidden)
    } else {
      DiagnosticContactReplay()
    }
  }
}

#if targetEnvironment(simulator)
private struct RearCourtReplay: View {
  @State private var court = CourtScene()
  @State private var caption = "后场复测"

  var body: some View {
    ZStack(alignment: .topLeading) {
      ReplaySurface(court: court).id(ObjectIdentifier(court)).ignoresSafeArea()
      Text(caption).font(.caption.monospaced()).padding(8)
        .foregroundStyle(.white).background(.black.opacity(0.78)).padding(.leading, 32)
    }
    .task {
      do {
        try await run()
      } catch is CancellationError {
        return
      } catch {
        caption = error.localizedDescription
      }
    }
  }

  @MainActor private func run() async throws {
    let output = URL.documentsDirectory.appendingPathComponent("P007-后场.tsv")
    let scenes: [(CollectionScene, String, Bool)] = [
      (.high, "正手侧", false), (.backhand, "反手侧", true),
      (.deepDrive, "正手侧", false), (.deepDrive, "反手侧", true)
    ]
    let timings: [(Double, String)] = ProcessInfo.processInfo.arguments.contains("-rearLate")
      ? [(0.10, "延后 100 ms")]
      : [(0, "拦截时刻"), (-0.35, "提前 350 ms")]
    var rows = ["case\tframe\tseconds\tplayerX\tplayerY\tballHeightM\tballX\tballY\tinterceptX\tinterceptY\tresult\ttouchesBed"]
    for left in [false, true] {
      for (scene, lane, backhand) in scenes {
        for (offset, timing) in timings {
          court = CourtScene()
          var game = Rally()
          game.leftHanded = left
          game.collectionScene = scene
          game.receiveSide = lane
          game.distantReceiveStart = true
          game.readyToServe()
          let label = "\(left ? "左手" : "右手") · \(scene.rawValue) · \(lane) · \(timing)"
          var pressAt: Double?
          var pressedFrame: Int?
          var result = "等待来球"
          for frame in 1...270 {
            game.tick(1.0 / 60)
            if pressAt == nil, let f = game.flight, f.incoming, let target = game.predictedIntercept {
              var low = f.start, high = f.start + f.duration
              for _ in 0..<24 {
                let mid = (low + high) / 2
                if f.at(mid).y < target.y { low = mid } else { high = mid }
              }
              pressAt = (low + high) / 2 + offset
            }
            if let pressAt, pressedFrame == nil, game.now + 1.0 / 120 >= pressAt {
              pressedFrame = frame
              let aim = left ? -0.18 : 0.18
              let impact = SwingImpact(power: 0.83, sweep: 0.8, probableBackhand: backhand,
                                       verticalSweep: 0.78, lateralSweep: aim)
              result = game.swing(.lift, aim: aim, impact: impact, confirmedByButton: true) {
                court.canContact($0, left: left)
              }.rawValue
            }
            court.update(game, reduced: false, left: left)
            let ball = game.flight?.at(game.now)
            let target = game.predictedIntercept
            let ballHeight = ball.map { $0.z * 1.524 / Flight.netHeight }
            let touch = court.nearContactSample().map { String($0.touchesBed) } ?? ""
            let fields = [game.now, game.playerX, game.playerY, ballHeight, ball?.x, ball?.y, target?.x, target?.y]
            let coordinates = fields.map { $0.map { String($0) } ?? "" }
            rows.append(([label, String(frame)] + coordinates + [result, touch]).joined(separator: "\t"))
            caption = "\(label)   F\(frame)   \(result)"
            try await Task.sleep(for: .milliseconds(17))
            if let pressedFrame, frame - pressedFrame >= 35 { break }
          }
        }
      }
    }
    try (rows.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
    caption = "后场复测结束 · \(2 * scenes.count * timings.count) 组"
  }
}
#endif

private struct DiagnosticContactReplay: View {
  @State private var session = ContactReplaySession()
  @State private var caption = "准备录制固定来球"
  var body: some View {
    ZStack(alignment: .topLeading) {
      ReplaySurface(court: session.court).ignoresSafeArea()
      Text(caption).monospacedDigit().padding(8)
        .background(.black.opacity(0.8)).foregroundStyle(.white)
        .padding(.leading, 32)
    }
    .task {
      do {
        try await Task.sleep(for: .seconds(1))
        for left in [false, true] {
          for offset in [-100, -50, 0] {
            session.reset(left: left)
            var pressAt: Double?
            var pressFrame: Int?
            var decision = "来球"
            for frame in 1...280 {
              session.game.tick(1.0 / 60)
              let g = session.game
              if pressAt == nil, let flight = g.flight, flight.incoming, let point = g.predictedIntercept {
                var lo = flight.start, hi = lo + flight.duration
                for _ in 0..<24 {
                  let mid = (lo + hi) / 2
                  if flight.at(mid).y < point.y { lo = mid } else { hi = mid }
                }
                pressAt = (lo + hi) / 2 + Double(offset) / 1000
              }
              if let t = pressAt, pressFrame == nil, g.now + 1.0 / 120 >= t {
                pressFrame = frame
                let aim = left ? -0.18 : 0.18
                let impact = SwingImpact(power: 0.68, sweep: 0.70, probableBackhand: true,
                                         verticalSweep: 0.03, lateralSweep: aim)
                decision = session.game.swing(.drive, aim: aim, impact: impact, confirmedByButton: true) { candidate in
                  session.court.canContact(candidate, left: left)
                }.rawValue
              }
              session.court.update(session.game, reduced: false, left: left)
              if session.sideView {
                session.court.camera.simdPosition = SIMD3(5.5, 2.2, 4.3)
                session.court.camera.look(at: SCNVector3(0, 1.25, 2.5))
              }
              let label = left ? "左手" : "右手"
              caption = String(format: "%@ 反手平抽  %+d ms    帧 %d    %.3f s    %@",
                               label, offset, frame, session.game.now, decision)
              session.collect(frame: frame, left: left, offset: offset, decision: decision, time: pressAt)
              let inspecting = pressAt.map { abs(g.now - $0) < 0.034 } ?? false
              try await Task.sleep(for: .milliseconds(inspecting ? 330 : 17))
              if let hit = pressFrame, frame - hit >= 12 { break }
            }
          }
        }
        try session.save()
        caption = "六组固定输入回放结束"
      } catch is CancellationError { return } catch { caption = error.localizedDescription }
    }
  }
}

private final class ContactReplaySession {
  let court = CourtScene()
  let sideView = ProcessInfo.processInfo.arguments.contains("-contactSide")
  private var rows: [[String: Any]] = []
  var game = Rally()
  func collect(frame: Int, left: Bool, offset: Int, decision: String, time: Double?) {
    guard let time, abs(game.now - time) < 0.034, let sample = court.nearContactSample() else { return }
    func xyz(_ p: SIMD3<Float>) -> [Float] { [p.x, p.y, p.z] }
    rows.append(["frame": frame, "time": sample.time, "left": left, "offsetMs": offset,
                 "decision": decision, "incoming": game.flight?.incoming == true,
                 "shoulder": xyz(sample.shoulder), "elbow": xyz(sample.elbow), "wrist": xyz(sample.wrist),
                 "cork": xyz(sample.corkCenter), "radius": sample.corkRadius, "center": xyz(sample.bedCenter),
                 "across": xyz(sample.bedAcross), "along": xyz(sample.bedAlong), "touches": sample.touchesBed])
  }
  func save() throws {
    let url = URL.documentsDirectory.appendingPathComponent(sideView ? "P003-side.json" : "P003-back.json")
    try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]).write(to: url, options: .atomic)
  }
  func reset(left: Bool) {
    game = Rally()
    game.leftHanded = left
    game.collectionScene = .flat
    game.readyToServe()
    court.update(game, reduced: false, left: left)
  }
}

private struct ReplaySurface: UIViewRepresentable {
  let court: CourtScene
  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.scene = court.scene
    view.pointOfView = court.camera
    view.antialiasingMode = .multisampling2X
    view.rendersContinuously = true
    return view
  }
  func updateUIView(_ view: SCNView, context: Context) {}
}
// The blind surface contains only the match scene. The answer key is off-device.
private struct BlindReplaySurface: UIViewRepresentable {
  let onFinish: () -> Void
  func makeUIView(context: Context) -> BlindReplayView {
    let view = BlindReplayView(frame: .zero)
    view.onFinish = onFinish
    return view
  }
  func updateUIView(_ uiView: BlindReplayView, context: Context) {}
  static func dismantleUIView(_ uiView: BlindReplayView, coordinator: ()) { uiView.stop() }
}

private final class BlindReplayView: UIView {
  var onFinish: (() -> Void)?
  private let view = SCNView()
  private let side = ProcessInfo.processInfo.arguments.contains("-contactSide")
  private enum Mode {
    case original, masked, recovery
    var shots: [(left: Bool, offset: Int)] {
      switch self {
      case .original:
        return [(true,-50), (false,-100), (true,-100), (false,-50),
                (true,-100), (true,-50), (false,-50), (false,-100)]
      case .masked, .recovery:
        return [(false,-50), (true,-100), (false,-100), (true,-50)]
      }
    }
    var visibleFrames: Int {
      switch self {
      case .original: 128
      case .masked: 60
      case .recovery: 105
      }
    }
  }
  private let mode: Mode = {
    let flags = ProcessInfo.processInfo.arguments
    if flags.contains("-contactMasked") { return .masked }
    if flags.contains("-contactRecovery") { return .recovery }
    return .original
  }()
  private var shots: [(left: Bool, offset: Int)] { mode.shots }
  private var framesPerClip: Int { mode.visibleFrames }
  private var warmupSteps = 0
  private var shuttle: SCNNode?
  private var court: CourtScene?
  private var game = Rally()
  private var link: CADisplayLink?
  private var clip = -1
  private var clipFrame = 0
  private var pressAt: Double?
  private var pressed = false
  private var start: CFTimeInterval = 0
  private var missedPresentations = 0
  private var impactPresentationSkipped = false
  private var timing: [[String: Any]] = []
  private var pressFrame = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    view.backgroundColor = .black
    view.preferredFramesPerSecond = 60
    view.rendersContinuously = true
    view.antialiasingMode = .multisampling2X
    addSubview(view)
    isAccessibilityElement = true
    accessibilityIdentifier = "blindReplayRunning"
  }

  required init?(coder: NSCoder) { fatalError("Programmatic view") }

  override func layoutSubviews() {
    super.layoutSubviews()
    view.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { stop(); return }
    guard clip == -1 else { return }
    prepareClip()
    let display = CADisplayLink(target: self, selector: #selector(drawFrame(_:)))
    display.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
    display.add(to: .main, forMode: .common)
    link = display
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  private func prepareClip() {
    view.isHidden = true
    clip += 1
    guard clip < shots.count else {
      stop()
      do {
        let filename: String
        switch mode {
        case .original: filename = side ? "P004-side-timing.json" : "P004-back-timing.json"
        case .masked: filename = "P005-masked-timing.json"
        case .recovery: filename = "P005-recovery-timing.json"
        }
        try JSONSerialization.data(withJSONObject: timing, options: [.sortedKeys])
          .write(to: URL.documentsDirectory.appendingPathComponent(filename), options: .atomic)
        let plannedTrial = mode == .original || (timing.count == 4 && timing.allSatisfy {
          $0["pressVisibleFrame"] as? Int == 60 &&
            $0["postPressSteps"] as? Int == framesPerClip - 60 &&
            $0["frames"] as? Int == framesPerClip
        })
        if plannedTrial { onFinish?() }
      } catch {
        accessibilityIdentifier = "blindReplaySaveFailed"
      }
      return
    }
    let scene = CourtScene()
    court = scene
    view.scene = scene.scene
    view.pointOfView = scene.camera
    game = Rally()
    game.leftHanded = shots[clip].left
    game.collectionScene = .flat
    game.readyToServe()
    let shot = shots[clip]
    // V002 fixed flat feed presses on absolute 60 Hz tick 84 or 87. Start
    // both stimuli exactly 59 ticks before the press. Run the identical
    // simulation and pose history during the hidden lead-in.
    warmupSteps = mode == .original ? 0 : (shot.offset == -100 ? 24 : 27)
    shuttle = scene.scene.rootNode.childNodes.first { node in
      node.childNodes.contains { $0.geometry is SCNCone } &&
        node.childNodes.contains { $0.geometry is SCNSphere }
    }
    clipFrame = 0
    pressAt = nil
    pressed = false
    pressFrame = 0
    missedPresentations = 0
    impactPresentationSkipped = false
    for _ in 0..<warmupSteps { advance(court: scene, shot: shot) }
    start = CACurrentMediaTime() + 0.75
  }

  private func advance(court: CourtScene, shot: (left: Bool, offset: Int)) {
    game.tick(1.0 / 60)
    if pressAt == nil, let flight = game.flight, flight.incoming,
       let intercept = game.predictedIntercept {
      var lo = flight.start, hi = lo + flight.duration
      for _ in 0..<24 {
        let mid = (lo + hi) / 2
        if flight.at(mid).y < intercept.y { lo = mid } else { hi = mid }
      }
      pressAt = (lo + hi) / 2 + Double(shot.offset) / 1000
    }
    let previousOrientation = shuttle?.simdOrientation
    if !pressed, let t = pressAt, game.now + 1.0 / 120 >= t {
      let aim = shot.left ? -0.18 : 0.18
      let impact = SwingImpact(power: 0.68, sweep: 0.70, probableBackhand: true,
                               verticalSweep: 0.03, lateralSweep: aim)
      game.swing(.drive, aim: aim, impact: impact, confirmedByButton: true) {
        court.canContact($0, left: shot.left)
      }
      pressed = true
      pressFrame = clipFrame
    }
    court.update(game, reduced: false, left: shot.left)
    court.hideReplayAids()
    // Keep the incoming skirt direction on the masked decision frame. The
    // accepted candidate changes flight velocity at the same cork position.
    if mode == .masked, pressed, let previousOrientation {
      shuttle?.simdOrientation = previousOrientation
    }
    if side {
      court.camera.simdPosition = SIMD3(5.5, 2.2, 4.3)
      court.camera.look(at: SCNVector3(0, 1.25, 2.5))
    }
  }

  @objc private func drawFrame(_ link: CADisplayLink) {
    let elapsed = link.targetTimestamp - start
    guard elapsed >= 0, let court else { return }
    // Advance to the physical display deadline. Catch-up preserves normal
    // speed without extending the contact frames on slower hardware.
    let due = min(framesPerClip, 1 + Int(elapsed * 60))
    guard due > clipFrame else {
      if clipFrame == framesPerClip && elapsed >= Double(framesPerClip) / 60 { prepareClip() }
      return
    }
    let oldFrame = clipFrame
    while clipFrame < due {
      clipFrame += 1
      let shot = shots[clip]
      advance(court: court, shot: shot)
    }
    let skipped = due - oldFrame - 1
    missedPresentations += skipped
    if skipped > 0, let t = pressAt {
      let impactFrame = Int((t * 60).rounded()) - warmupSteps
      if oldFrame + 1 <= impactFrame + 1 && due - 1 >= impactFrame - 1 {
        impactPresentationSkipped = true
      }
    }
    view.isHidden = false
    if clipFrame == framesPerClip {
      timing.append(["clip": clip + 1, "frames": clipFrame, "pressExecuted": pressFrame > 0,
                     "pressVisibleFrame": pressFrame, "postPressSteps": clipFrame - pressFrame,
                     "skippedDisplaySteps": missedPresentations,
                     "skippedAtContact": impactPresentationSkipped,
                     "lastDisplayDeadline_s": elapsed])
    }
  }
}

#endif

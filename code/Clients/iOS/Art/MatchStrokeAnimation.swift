import Foundation
import SceneKit
import simd

#if os(iOS)
typealias MatchVector = SIMD3<Float>

final class MatchStrokeAnimation {
  private struct Track: Decodable {
    let model: String
    let impact: Double
    let release: Double?
    let cached: Bool
    let racket, releaseCork: [Float]
    let samples: [[Float]]

    var contact: Double { impact }
    var bed: MatchVector { MatchVector(racket[0], racket[1], racket[2]) }
    var released: MatchVector? {
      guard releaseCork.count == 3 else { return nil }
      return MatchVector(releaseCork[0], releaseCork[1], releaseCork[2])
    }
  }

  private struct Library: Decodable {
    let bones: [String]
    let rate: Double
    let tracks: [String: Track]

    static func load() -> Self? {
      guard let url = Bundle.main.url(forResource: "MatchStrokePoses", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let library = try? JSONDecoder().decode(Self.self, from: data),
            library.rate == 120, library.bones.count == 21,
            MatchStroke.allCases.allSatisfy({ key in
              guard let track = library.tracks[key.rawValue] else { return false }
              let duration = Double(track.samples.count - 1) / library.rate
              return track.racket.count == 3 && track.impact > 0 && track.impact < duration &&
                (track.release.map { $0 > 0 && $0 < track.impact && track.released != nil } ?? !key.isServe) &&
                track.samples.allSatisfy { $0.count == library.bones.count * 7 }
            }) else { return nil }
      return library
    }
  }

  private struct Joint {
    let position: MatchVector
    let orientation: simd_quatf

    static func blend(_ lhs: Self, _ rhs: Self, by t: Float) -> Self {
      Self(position: simd_mix(lhs.position, rhs.position, MatchVector(repeating: t)),
           orientation: simd_slerp(lhs.orientation, rhs.orientation, t))
    }
  }

  private final class Model {
    let root: SCNNode
    let nodes: [SCNNode]
    let bones: [String: SCNNode]
    let surface: StrokeSurfaceAnimation?

    init?(library: Library, track: Track) {
      guard let url = Bundle.main.url(forResource: track.model, withExtension: "usdz"),
            let scene = try? SCNScene(url: url) else { return nil }
      root = scene.rootNode
      var observed: [SCNNode] = []
      root.enumerateChildNodes { node, _ in
        node.removeAllAnimations()
        if observed.isEmpty, let skin = node.skinner { observed = skin.bones }
      }
      guard observed.compactMap(\.name) == library.bones else { return nil }
      nodes = observed
      bones = Dictionary(uniqueKeysWithValues: zip(library.bones, observed))
      if track.cached {
        guard let cache = Bundle.main.url(forResource: track.model, withExtension: "brmesh"),
              let surface = try? StrokeSurfaceAnimation(url: cache, assetURL: url, model: root,
                                                         duration: Double(track.samples.count - 1) / library.rate) else { return nil }
        self.surface = surface
      } else {
        surface = nil
      }
    }

    func applyPose(_ pose: [Joint]) {
      for (node, joint) in zip(nodes, pose) {
        node.simdPosition = joint.position
        node.simdOrientation = joint.orientation
      }
    }

    func update(_ pose: [Joint], sampleTime: Double) {
      applyPose(pose)
      surface?.show(at: sampleTime)
    }

    func point(_ name: String, offset: MatchVector = .zero) -> MatchVector {
      bones[name]?.simdConvertPosition(offset, to: nil) ?? .zero
    }
  }

  private static let assets = Library.load()
  private static let ready = MatchStroke.netKill
  private static let bedOffset = MatchVector(0, 0.53, 0)
  private static let ballHold = MatchVector(-0.006, 0.103, -0.044)
  private let root = SCNNode()
  private let library: Library
  private let base: Model
  private var cached: (key: String, model: Model)?
  private var failedCache: Set<String> = []
  private var current: Model
  private var recoveryAnchor: MatchVector?
  private var eventTime: Double?
  private var lastUpdate: Double?
  private var rootOffset = MatchVector.zero
  private var armOffset = MatchVector.zero
  private var serveEntryPose: [Joint]?
  private var servePreparationStart = 0.0
  private var servePlants: (left: MatchVector, right: MatchVector)?
  private var lastPose: [Joint]?
  private var transitionPose: [Joint]?
  private var transitionStart = -Double.infinity
  private var approachEntryPose: [Joint]?
  private var approachEntryTime = -Double.infinity
  private var approachBlendDuration = 0.16
  private var lastPhase: String?
  private var feetInWorld: (left: MatchVector, right: MatchVector)?
  private let readyPose: [Joint]
  private(set) var audit: MatchAnimationAudit?
  private(set) var heldShuttle: MatchVector?

  init?(parent: SCNNode) {
    guard let library = Self.assets, let track = library.tracks[Self.ready.rawValue],
          let model = Model(library: library, track: track) else { return nil }
    self.library = library
    self.base = model
    self.current = model
    self.readyPose = Self.unpack(track.samples[0])
    parent.addChildNode(root)
    root.addChildNode(model.root)
    root.name = "LinChengMatch"
    root.isHidden = true
  }

  private func track(_ key: MatchStroke) -> Track { library.tracks[key.rawValue]! }

  private static func unpack(_ values: [Float]) -> [Joint] {
    stride(from: 0, to: values.count, by: 7).map { offset in
      Joint(position: .init(values[offset], values[offset + 1], values[offset + 2]),
            orientation: simd_quatf(vector: .init(values[offset + 3], values[offset + 4],
                                                 values[offset + 5], values[offset + 6])))
    }
  }

  private func sample(_ track: Track, at time: Double) -> [Joint] {
    let frame = min(Double(track.samples.count - 1), max(0, time * library.rate))
    let lower = Int(frame), fraction = Float(frame - Double(lower))
    let first = Self.unpack(track.samples[lower])
    guard fraction > 0.00001, lower + 1 < track.samples.count else { return first }
    return zip(first, Self.unpack(track.samples[lower + 1])).map { Joint.blend($0, $1, by: fraction) }
  }

  private static func metres(_ p: Position) -> MatchVector {
    MatchVector(Float(p.x * 3.05), Float(p.z * 1.524 / Flight.netHeight), Float((p.y - 0.5) * 13.4))
  }

  private static func courtVector(_ point: MatchVector, left: Bool) -> MatchVector {
    MatchVector(left ? point.x : -point.x, point.y, -point.z)
  }

  private func correction(_ event: MatchStrokeEvent) -> MatchVector {
    Self.metres(event.contact) - Self.metres(event.feet) - Self.courtVector(track(event.stroke).bed, left: event.leftHanded)
  }

  func canContact(_ event: MatchStrokeEvent) -> Bool {
    let shift = correction(event)
    guard hypot(shift.x, shift.z) <= 0.32, (-0.28...0.14).contains(shift.y) else { return false }
    let landing = Self.metres(event.feet) + shift
    // The model may advance one running step before impact; the arm can supply
    // the remaining reach without relocating the rooted athlete.
    guard lastUpdate == nil || simd_distance(root.simdPosition, landing) <= 0.245 else { return false }
    let previous = lastUpdate ?? event.time
    let dt = max(0, min(0.05, event.time - previous))
    let placed = lastUpdate == nil ? landing : boundedFoot(root.simdPosition, toward: landing, maximum: Float(dt) * 4.8)
    let rootTransform = root.simdTransform
    let pose = base.nodes.map { Joint(position: $0.simdPosition, orientation: $0.simdOrientation) }
    let attached = base.root.parent != nil
    if !attached { root.addChildNode(base.root) }
    defer {
      base.applyPose(pose)
      root.simdTransform = rootTransform
      if !attached { base.root.removeFromParentNode() }
    }
    root.simdPosition = placed
    root.simdOrientation = simd_quatf(angle: .pi, axis: MatchVector(0, 1, 0))
    root.simdScale = MatchVector(event.leftHanded ? -1 : 1, 1, 1)
    let source = track(event.stroke)
    base.applyPose(sample(source, at: source.contact))
    let target = Self.metres(event.contact)
    fitRacket(base, to: target)
    return simd_distance(base.point("racket_grip_R", offset: Self.bedOffset), target) <= 0.013
  }

  private func fitRacket(_ model: Model, to target: MatchVector) {
    for _ in 0..<3 {
      let shift = target - model.point("racket_grip_R", offset: Self.bedOffset)
      if simd_length_squared(shift) <= 0.000025 { break }
      solve(model, chain: ["upper_arm_R", "forearm_R", "hand_R"], at: model.point("hand_R") + shift)
    }
  }

  func hide() {
    root.isHidden = true
    audit = nil
    heldShuttle = nil
  }

  private func show(_ source: Track, exact: Bool) -> Model {
    let key = source.model
    var next = base
    if source.cached {
      if cached?.key != key, !failedCache.contains(key) {
        if let candidate = Model(library: library, track: source) {
          cached = (key, candidate)
        } else {
          failedCache.insert(key)
        }
      }
      if exact, cached?.key == key, let candidate = cached?.model { next = candidate }
    }
    if next !== current {
      current.root.removeFromParentNode()
      root.addChildNode(next.root)
      current = next
    }
    return next
  }

  private func smooth(_ input: Double) -> Float {
    let t = Float(max(0, min(1, input)))
    return t * t * (3 - 2 * t)
  }

  func update(_ game: Rally, motionFeet: (left: MatchVector, right: MatchVector)) {
    let now = game.now
    let left = game.leftHanded
    let feet = Self.metres(Position(x: game.playerX, y: game.playerY))
    let event = game.matchStrokeEvent.flatMap { candidate in
      let length = Double(track(candidate.stroke).samples.count - 1) / library.rate
      let age = now - candidate.time
      return candidate.point == game.pointCount + 1 && age < length - track(candidate.stroke).contact + 0.22 ? candidate : nil
    }
    let preview = game.previewMatchStroke
    var key = Self.ready
    var phase = "ready"
    var time = 0.0
    var mix: Float = 0
    var poseTransition: Float = 1
    var anchor = feet
    var desiredOffset = MatchVector.zero
    var target: MatchVector?
    let previous = lastUpdate ?? now
    let dt = max(0, min(0.05, now - previous))
    let fresh = lastUpdate == nil || now < previous
    lastUpdate = now
    var exactContact = false
    var blendBase = readyPose
    var fallTrack: Track?
    if let fall = game.matchFallEvent, now - fall.time < MatchFallEvent.duration,
       let source = library.tracks[MatchFallEvent.animation] {
      fallTrack = source
      phase = "fall"
      time = max(0, now - fall.time)
      anchor = Self.metres(fall.feet)
      mix = 1
      if eventTime != fall.time || fresh {
        eventTime = fall.time
        transitionPose = lastPose
        armOffset = .zero
        servePlants = nil
      }
      if let entry = transitionPose {
        poseTransition = smooth(time / 0.12)
        blendBase = entry
      }
    }

    if fallTrack != nil {
      // The fall uses its own authored landing and support sequence.
    } else if let event {
      let source = track(event.stroke)
      exactContact = abs(now - event.time) < 0.000001 ||
        (event.stroke.isServe && previous < event.time && now >= event.time)
      let elapsed = exactContact ? 0 : now - event.time
      let duration = Double(source.samples.count - 1) / library.rate
      key = event.stroke
      time = max(0, min(duration, source.contact + elapsed))
      if eventTime != event.time || fresh {
        eventTime = event.time
        recoveryAnchor = Self.metres(event.feet)
        armOffset = .zero
        serveEntryPose = event.stroke.isServe ? lastPose : nil
        servePreparationStart = now
        servePlants = event.stroke.isServe && !fresh ? feetInWorld : nil
      }
      let recovery = smooth((elapsed - 0.15) / 0.28)
      anchor = simd_mix(recoveryAnchor ?? feet, feet, MatchVector(repeating: recovery))
      desiredOffset = correction(event) * (1 - recovery)
      mix = 1 - smooth((source.contact + elapsed - duration + 0.10) / 0.32)
      phase = elapsed < 0 ? "prepare" : elapsed < 0.05 ? "contact" : elapsed < 0.28 ? "followThrough" : "recover"
      target = Self.metres(event.contact)
      if let entry = serveEntryPose, let release = source.release, time < release {
        let deadline = event.time - (source.contact - release)
        blendBase = entry
        mix = smooth((now - servePreparationStart) / max(0.001, deadline - servePreparationStart))
      }
    } else if game.phase == .serve && game.playerServes {
      key = .backhandShortServe
      mix = 1
      phase = "hold"
    } else if let preview, let intercept = game.predictedIntercept, let arrival = game.predictedInterceptTime,
              (-0.08...0.48).contains(arrival - now), game.flight?.incoming == true {
      let source = track(preview)
      let lead = arrival - now
      key = preview
      time = max(0, source.contact - max(1.0 / library.rate, lead) * 1.02)
      mix = smooth((0.48 - lead) / 0.27)
      target = Self.metres(intercept)
      let gap = target! - anchor - Self.courtVector(source.bed, left: left)
      let horizontal = hypot(gap.x, gap.z)
      if horizontal <= 0.32 && (-0.28...0.14).contains(gap.y) { desiredOffset = gap * mix }
      phase = "approach"
    }

    if phase == "approach", lastPhase != phase {
      approachEntryPose = fresh ? nil : lastPose
      approachEntryTime = now
      approachBlendDuration = min(0.16, max(0.04, (game.predictedInterceptTime ?? now) - now))
    }
    if phase != "approach" { approachEntryPose = nil }
    if phase != lastPhase && (phase == "hold" || phase == "ready") {
      transitionPose = fresh ? nil : lastPose
      transitionStart = now
    }
    lastPhase = phase
    if let previousPose = transitionPose, phase == "hold" || phase == "ready" {
      poseTransition = smooth((now - transitionStart) / 0.22)
      if poseTransition < 1 { blendBase = previousPose }
      else { transitionPose = nil }
    }

    let desiredRoot = anchor + desiredOffset
    let speed: Float = phase == "recover" || phase == "followThrough" ? 4.15 : 4.8
    let difference = desiredRoot - root.simdPosition
    let budget = Float(dt) * speed
    let placed = fresh ? desiredRoot : root.simdPosition +
      difference * min(1, budget / max(0.00001, simd_length(difference)))
    rootOffset = placed - anchor
    root.isHidden = false
    root.simdPosition = anchor
    root.simdOrientation = simd_quatf(angle: .pi, axis: MatchVector(0, 1, 0))
    root.simdScale = MatchVector(left ? -1 : 1, 1, 1)

    let residual = exactContact ? desiredRoot - placed : armOffset
    let needsArm = simd_length_squared(residual) > 0.000025
    let source = fallTrack ?? track(key)
    let receivesNow = exactContact && event?.stroke.isServe == false
    let model = show(source, exact: !receivesNow && mix > 0.999 && !needsArm && poseTransition > 0.999 && approachEntryPose == nil)
    var pose = sample(source, at: time)
    if mix < 1 && poseTransition == 1 {
      pose = zip(blendBase, pose).map { Joint.blend($0, $1, by: mix) }
    }
    if poseTransition < 1 {
      pose = zip(blendBase, pose).map { Joint.blend($0, $1, by: poseTransition) }
    }
    if let entry = approachEntryPose {
      let weight = smooth((now - approachEntryTime) / approachBlendDuration)
      if weight < 1 {
        pose = zip(entry, pose).map { Joint.blend($0, $1, by: weight) }
      } else {
        approachEntryPose = nil
      }
    }
    lastPose = pose
    model.update(pose, sampleTime: time)

    let authoredLeft = model.point("foot_L"), authoredRight = model.point("foot_R")
    let movement = 1 - mix
    let gap = placed - feet
    let followingMotion = gap * smooth(Double(simd_length(gap) - 0.20) / 0.25)
    let leftMotion = (left ? motionFeet.right : motionFeet.left) + followingMotion
    let rightMotion = (left ? motionFeet.left : motionFeet.right) + followingMotion
    var targetLeft = simd_mix(authoredLeft, leftMotion, MatchVector(repeating: movement))
    var targetRight = simd_mix(authoredRight, rightMotion, MatchVector(repeating: movement))
    if let event, event.stroke.isServe, let plants = servePlants {
      let age = now - event.time
      // The selected serve may use a different stance. Hold each shoe at
      // its actual pre-input support point until after contact, then step out
      // one foot at a time instead of resetting both planted positions.
      targetLeft = releaseFoot(plants.left, toward: targetLeft, age: age, start: 0.09)
      targetRight = releaseFoot(plants.right, toward: targetRight, age: age, start: 0.23)
    }
    if fallTrack == nil, !fresh, let previous = feetInWorld {
      // Foot targets from the movement controller can change states before
      // the animated body settles. Keep both IK goals within a stride step
      // while preserving each serve's deliberate planted interval above.
      let maximum = Float(dt) * 4.8
      targetLeft = boundedFoot(previous.left, toward: targetLeft, maximum: maximum)
      targetRight = boundedFoot(previous.right, toward: targetRight, maximum: maximum)
    }
    root.simdPosition += rootOffset
    if fallTrack == nil {
      plant(model, side: "L", at: targetLeft)
      plant(model, side: "R", at: targetRight)
    }
    let modelFeet = (left: model.point("foot_L"), right: model.point("foot_R"))
    feetInWorld = modelFeet

    if receivesNow, let target {
      let handBeforeFit = model.point("hand_R")
      fitRacket(model, to: target)
      armOffset = (model.point("hand_R") - handBeforeFit) * Float(exp(-20 * dt))
    } else if exactContact, let target {
      // Backhand serves meet the cork surface, roughly .009 m forward
      // of the model's string-bed center.
      let backhandServe = key == .backhandShortServe || key == .backhandFlickServe
      let shift = target - model.point("racket_grip_R", offset: Self.bedOffset)
      let carry = backhandServe ? simd_length(residual) > 0.005 : simd_length(shift) > 0.005
      armOffset = carry ? shift : .zero
    }
    if !receivesNow, simd_length_squared(armOffset) > 0.000001 {
      let goal = model.point("hand_R") + armOffset
      solve(model, chain: ["upper_arm_R", "forearm_R", "hand_R"], at: goal)
      armOffset *= Float(exp(-20 * dt))
    }
    let bed = model.point("racket_grip_R", offset: Self.bedOffset)
    let wrist = model.point("hand_R")
    let contactError = target.map { simd_distance(bed, $0) }
    audit = MatchAnimationAudit(action: fallTrack != nil ? MatchFallEvent.animation : phase == "ready" ? "" : key.rawValue, phase: phase,
                                time: now, sampleTime: time, racketCenter: bed,
                                grip: model.point("racket_grip_R"), leftFoot: left ? modelFeet.right : modelFeet.left,
                                rightFoot: left ? modelFeet.left : modelFeet.right, elbow: model.point("forearm_R"),
                                wrist: wrist, root: root.simdWorldPosition, target: target,
                                racketError: contactError, surfaceContact: exactContact
                                  ? contactError.map { $0 <= 0.013 } : nil,
                                assetReady: !failedCache.contains(source.model),
                                surfaceMode: model.surface == nil ? "skinned" : "authoredCache")
    heldShuttle = nil
    if exactContact, event?.stroke.isServe == true {
      heldShuttle = target
    } else if phase == "hold" {
      heldShuttle = model.point("hand_L", offset: Self.ballHold) - MatchVector(0, 0.049, 0)
    } else if let event, event.stroke.isServe, now < event.time {
      let source = track(key)
      let back = key == .backhandShortServe || key == .backhandFlickServe
      let pin = MatchVector(-0.006, back ? 0.103 : 0.099, -0.044)
      let offset = MatchVector(0, back ? 0.049 : 0.045, 0)
      if let release = source.release, time >= release {
        // Anchored release from the authored left hand and a gravity segment
        // terminating at the same game event that starts the outgoing flight.
        let duration = Float(source.contact - release)
        let t = min(duration, Float(time - release))
        let run = t / duration
        if let origin = source.released {
          let start = anchor + rootOffset + Self.courtVector(origin, left: left)
          let end = Self.metres(event.contact)
          heldShuttle = simd_mix(start, end, MatchVector(repeating: run)) + MatchVector(0, 4.905 * t * (duration - t), 0)
        }
      } else {
        heldShuttle = model.point("hand_L", offset: pin) - offset
      }
    }
  }

  func contactSample(time: Double, cork: MatchVector, radius: Float) -> CourtContactSample? {
    guard let audit, let racket = current.bones["racket_grip_R"] else { return nil }
    return CourtContactSample(time: time, shoulder: current.point("upper_arm_R"),
                              elbow: audit.elbow, wrist: audit.wrist, bedCenter: audit.racketCenter,
                              bedAcross: racket.simdConvertVector(MatchVector(0, 0, 0.088), to: nil),
                              bedAlong: racket.simdConvertVector(MatchVector(0, 0.112, 0), to: nil),
                              corkCenter: cork, corkRadius: radius)
  }

  private func boundedFoot(_ from: MatchVector, toward target: MatchVector, maximum: Float) -> MatchVector {
    let offset = target - from
    return from + offset * min(1, maximum / max(0.00001, simd_length(offset)))
  }

  private func releaseFoot(_ from: MatchVector, toward target: MatchVector, age: Double, start: Double) -> MatchVector {
    let weight = smooth((age - start) / 0.17)
    if weight == 0 { return from }
    let lift = 0.10 * weight * (1 - weight)
    return simd_mix(from, target, MatchVector(repeating: weight)) + MatchVector(0, lift, 0)
  }

  private func plant(_ model: Model, side: String, at target: MatchVector) {
    solve(model, chain: ["thigh_" + side, "shin_" + side, "foot_" + side], at: target,
          fallbackBend: MatchVector(0, 0, 1))
  }

  private func solve(_ model: Model, chain: [String], at target: MatchVector, fallbackBend: MatchVector? = nil) {
    guard let thigh = model.bones[chain[0]], let shin = model.bones[chain[1]],
          let foot = model.bones[chain[2]] else { return }
    // Solve in the model parent space rather than the mirrored world space.
    // This preserves bone lengths and identical pole behavior for both hands.
    guard let stage = model.root.parent else { return }
    let hip = stage.simdConvertPosition(thigh.simdWorldPosition, from: nil)
    let knee = stage.simdConvertPosition(shin.simdWorldPosition, from: nil)
    let ankle = stage.simdConvertPosition(foot.simdWorldPosition, from: nil)
    let goal = stage.simdConvertPosition(target, from: nil)
    guard simd_distance(ankle, goal) > 0.0001 else { return }
    let upper = simd_distance(hip, knee), lower = simd_distance(knee, ankle)
    let path = goal - hip, length = simd_length(path)
    guard length > 0.001, upper > 0.001, lower > 0.001 else { return }
    let direction = path / length
    let distance = min(upper + lower - 0.001, max(abs(upper - lower) + 0.001, length))
    let along = (upper * upper - lower * lower + distance * distance) / (2 * distance)
    var pole = knee - hip - direction * simd_dot(knee - hip, direction)
    if let fallbackBend, simd_length_squared(pole) <= 0.000001 {
      // When an authored knee straightens, retain a valid foot goal and bend
      // toward the player's forward axis instead of dropping the plant.
      pole = fallbackBend - direction * simd_dot(fallbackBend, direction)
    }
    guard simd_length_squared(pole) > 0.000001 else { return }
    let bend = hip + direction * along + simd_normalize(pole) * sqrt(max(0, upper * upper - along * along))
    let toe = foot.simdWorldOrientation
    aim(thigh, child: shin, toward: stage.simdConvertPosition(bend, to: nil))
    aim(shin, child: foot, toward: stage.simdConvertPosition(hip + direction * distance, to: nil))
    foot.simdWorldOrientation = toe
  }

  private func aim(_ node: SCNNode, child: SCNNode, toward point: MatchVector) {
    guard let parent = node.parent else { return }
    let start = node.simdPosition
    let current = parent.simdConvertPosition(child.simdWorldPosition, from: nil) - start
    let desired = parent.simdConvertPosition(point, from: nil) - start
    guard simd_length_squared(current) > 0.000001, simd_length_squared(desired) > 0.000001 else { return }
    let rotation = simd_quatf(from: simd_normalize(current), to: simd_normalize(desired))
    node.simdOrientation = rotation * node.simdOrientation
  }
}
#endif

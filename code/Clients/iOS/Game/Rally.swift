import Foundation

enum Stroke: String, CaseIterable {
  case lift = "上挑"
  case smash = "下挥"
  case drive = "平抽"
}
enum Shot: String {
  case clear = "高远球"
  case smash = "扣杀"
  case drive = "平抽"
  case net = "放网"
  case weak = "机会球"
  case power = "强力扣杀"
}
enum Drill: String, CaseIterable {
  case netTiming = "网前时机"
  case mixed = "混合"
  case clears = "高球"
  case flat = "快球"
  case sides = "左右交替"
}
enum LessonStep: Int, CaseIterable {
  case lift, smash, drive, net

  var title: String {
    switch self {
    case .lift: return "低球 · 上挑到后场"
    case .smash: return "高球 · 向下扣杀"
    case .drive: return "中场 · 平抽"
    case .net: return "放网 · 先预选，再挥拍"
    }
  }

  var feed: Shot { self == .smash ? .clear : .drive }

  func accepts(_ shot: Shot) -> Bool {
    switch self {
    case .lift: return shot == .clear
    case .smash: return shot == .smash || shot == .power
    case .drive: return shot == .drive
    case .net: return shot == .net
    }
  }
}
enum SwingDecision: String {
  case accepted, locked, inactive, invalidServe, noIncoming, early, late, outOfReach, tooHigh
}

enum Phase { case countdown, serve, flight, point, finished }
struct Position {
  var x: Double
  var y: Double
  var z: Double = 0
}
extension Position {
  var contactArea: String {
    if y < 0.5 { return "对方半场" }
    if y <= 0.65 { return "网前" }
    return y < 0.80 ? "中场" : "后场"
  }
  var coordinates: [Double] { [x,y,z] }
}

struct SwingImpact {
  var cornerStyle: ReturnStyle? = nil
  let power, sweep: Double
  var serveIntentConfirmed = false
  var label: String?
  var probableBackhand = false
  var approachLoad: Double? = nil
  var verticalSweep: Double = 0
  var lateralSweep: Double = 0
  var followThrough: Double = 0
  var braking: Double? = nil // Relative loss of angular speed before the button.
  var strength: Double { 0.65 * power + 0.35 * sweep }
}

enum ReturnStyle: String, CaseIterable {
  case netKill = "扑球"
  case push = "推球"
  case feather = "轻放网"
  case straightNet = "放直线"
  case crossNet = "勾对角"
  case pushGap = "推空当"
  case straightLift = "挑直线"
  case crossLift = "挑对角"
  case lowNet = "轻托回网"
  case foreDrive = "正手平抽"
  case backDrive = "反手平抽"
  case cushion = "减力挡网"
  case block = "接杀挡网"
  case liftSmash = "接杀挑高"
  case counter = "接杀反抽"
  case tapAttack = "点杀"
  case steepAttack = "下压突击"
  case halfDrop = "轻吊"
  case clear = "高远球"
  case drop = "吊球"
  case smash = "扣杀"
  case flatClear = "平高球"
  case defensiveClear = "被动高远球"
  case escapeDrop = "过渡吊球"
  case backClear = "反手高远"
  case backDrop = "反手吊球"
  case roundHead = "头顶正手处理"
}

struct Flight {
  var returnStyle: ReturnStyle? = nil
  let from, to: Position
  let start, duration, arc: Double
  let incoming: Bool
  let shot: Shot
  var measured = false
  var returnedSmash = false
  var probableBackhand: Bool? = nil
  var overheadFromBackhandCorner = false
  var measuredRoundHead = false
  var compactAttack = false
  var invitesAttack = false
  var jumpHeightMeters = 0.0
  static func attackingJump(shot: Shot, contact: Position, feet: Position, strength: Double) -> Double {
    guard shot == .smash || shot == .power, strength >= 0.5,
          (contact.y - 0.5) * (feet.y - 0.5) > 0,
          hypot((contact.x-feet.x)*3.05, (contact.y-feet.y)*13.4) <= 1.12 else { return 0 }
    let height = contact.z * 1.524 / netHeight
    guard height > 2.32, height <= 2.9 else { return 0 }
    return min(0.40, (height - 2.32) * 0.8)
  }
  static let netHeight = 0.31

  static func arch(_ u: Double, shot: Shot) -> Double {
    if shot == .clear || shot == .weak {
      // Horizontal speed decays independently of the vertical phase.
      // Invert the horizontal drag curve to recover elapsed flight time.
      let t = -log1p(u * expm1(-1.25)) / 1.25
      return 4 * t * (1 - t)
    }
    // Apex farther downcourt and steeper descent in court coordinates.
    return 4 * u * (1 - u) * (0.78 + 0.44 * u)
  }

  private var playableArc: Double {
    if measured { return arc }
    let span = to.y - from.y
    guard abs(span) > 0.0001 else { return arc }
    let crossing = (0.5 - from.y) / span
    guard crossing > 0.02, crossing < 0.98 else { return arc }
    let baseHeight = from.z * (1 - crossing) + to.z * crossing
    return max(arc, (Self.netHeight + 0.025 - baseHeight) / Self.arch(crossing, shot: shot))
  }

  var netCollision: Position? {
    guard measured, abs(to.y - from.y) > 0.0001 else { return nil }
    let u = (0.5 - from.y) / (to.y - from.y)
    guard (0...1).contains(u) else { return nil }
    let height = from.z * (1 - u) + to.z * u + arc * Self.arch(u, shot: shot)
    guard height <= Self.netHeight else { return nil }
    return Position(x: from.x + u * (to.x - from.x), y: 0.5, z: height)
  }

  func at(_ time: Double) -> Position {
    let elapsed = min(1, max(0, (time - start) / duration))
    // Faster off the racket, slower on descent. Preserve the authored net clearance.
    let drag: Double
    switch shot {
    case .power, .smash: drag = 1.45
    case .drive: drag = 1.0
    case .clear, .weak: drag = 1.25
    case .net: drag = 0.52
    }
    let u = -expm1(-drag * elapsed) / -expm1(-drag)
    return Position(
      x: from.x + (to.x - from.x) * u, y: from.y + (to.y - from.y) * u,
      z: from.z * (1 - u) + to.z * u + playableArc * Self.arch(u, shot: shot))
  }
}
enum CourtFormat: String, CaseIterable {
  case singles = "单打", doubles = "双打"
  var halfWidth: Double { self == .singles ? 5.18 / 6.10 : 1 }
  var backLine: Double { self == .singles ? 0 : 0.76 / 13.40 }
  static let shortLine = 0.5 - 1.98 / 13.40
  func legalLanding(_ p: Position, serverNear: Bool, serverX: Double) -> Bool {
    let depth = serverNear ? p.y : 1 - p.y
    return depth >= backLine - 1e-9 && depth <= Self.shortLine + 1e-9
      && abs(p.x) <= halfWidth && p.x * serverX <= 0
  }
}
enum ServeTraining: String, CaseIterable {
  case free = "自由发球", forehandHigh = "正手高远发球", forehandShort = "正手短发球"
  case backhandShort = "反手短发球", flick = "反手偷后场"
}

enum CollectionArea: String, CaseIterable {
  case serve = "我方发球", front = "网前", middle = "中场", back = "后场"

  var scenes: [CollectionScene] { CollectionScene.allCases.filter { $0.area == self } }
}

enum CollectionScene: String, CaseIterable {
  case serve = "我方发球", netHigh = "网前高点机会球", netSlow = "贴网慢球", netLow = "网前低点下落球"
  case flat = "身体侧面平快球", defense = "接杀防守", halfHigh = "半场高球"
  case high = "后场到位高球", deepDrive = "平快压底线", backhand = "反手底角深球"

  var area: CollectionArea {
    switch self {
    case .serve: .serve
    case .netHigh, .netSlow, .netLow: .front
    case .flat, .defense, .halfHigh: .middle
    case .high, .deepDrive, .backhand: .back
    }
  }

  var replies: [String] {
    switch self {
    case .serve: []
    case .netHigh: ["扑球","推球","轻放网"]
    case .netSlow: ["放直线","勾对角","推空当"]
    case .netLow: ["挑直线","挑对角","轻托回网"]
    case .flat: ["正手平抽","反手平抽","减力挡网"]
    case .defense: ["接杀挡网","接杀挑高","接杀反抽"]
    case .halfHigh: ["点杀","下压突击","轻吊"]
    case .high: ["高远球","吊球","扣杀"]
    case .deepDrive: ["平高球","被动高远球","过渡吊球"]
    case .backhand: ["反手高远","反手吊球","头顶正手处理"]
    }
  }

  // Normalized longitudinal coordinates run from the far baseline (0) to the near baseline (1).
  typealias Feed = (shot: Shot, originY: Double, height: Double, depth: Double, arc: Double, seconds: Double, receiveY: Double)
  var feed: Feed? {
    switch self {
    case .serve: nil
    case .netHigh: (.weak, 0.18, 0.45, 0.69, 0.31, 1.40, 0.57)
    case .netSlow: (.net, 0.18, 0.43, 0.63, 0.31, 1.38, 0.54)
    case .netLow: (.net, 0.18, 0.42, 0.65, 0.25, 1.28, 0.59)
    case .flat: (.drive, 0.20, 0.36, 0.89, 0.22, 0.90, 0.73)
    case .defense: (.smash, 0.13, 0.59, 0.85, 0.09, 0.80, 0.70)
    case .halfHigh: (.weak, 0.25, 0.35, 0.87, 0.38, 1.28, 0.71)
    case .high: (.clear, 0.15, 0.46, 0.97, 0.78, 1.90, 0.85)
    case .deepDrive: (.drive, 0.19, 0.40, 0.98, 0.39, 1.12, 0.86)
    case .backhand: (.clear, 0.14, 0.42, 0.98, 0.63, 1.65, 0.87)
    }
  }
}

/// An unsupervised controller response profile. Signed direction stays in the player's control.
struct RearClearResponse: Decodable {
  let aimMedian, aimUpper, soft, strong: Double
  static let bundled: RearClearResponse? = {
    guard let url = Bundle.main.url(forResource: "RearClearResponse", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let model = try? JSONDecoder().decode(Self.self, from: data),
          model.aimMedian > 0, model.aimUpper > model.aimMedian, model.aimUpper < 1,
          model.strong > model.soft else { return nil }
    return model
  }()

  func widthFraction(_ aim: Double) -> Double {
    let magnitude = min(1,abs(aim))
    if magnitude <= aimMedian { return 0.50 * magnitude / aimMedian }
    if magnitude <= aimUpper { return 0.50 + 0.34 * (magnitude-aimMedian)/(aimUpper-aimMedian) }
    return 0.84 + 0.16 * (magnitude-aimUpper)/(1-aimUpper)
  }

  func carry(_ effort: Double) -> Double {
    let middle = (soft + strong) / 2
    let local = 0.5 + 0.5 * tanh((effort-middle)/max(0.12,strong-soft))
    return 0.55 * effort + 0.45 * local
  }
}

struct OverheadReturnModel: Decodable {
  let classes: [String], weights: [[Double]], bias: [Double]
  static let bundled: Self? = {
    guard let url = Bundle.main.url(forResource: "OverheadReturns", withExtension: "json"),
          let bytes = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(Self.self, from: bytes),
          m.classes.count == 3, m.bias.count == 3, m.weights.count == 3,
          m.weights.allSatisfy({ $0.count == 5 }) else { return nil }
    return m
  }()
  func refinement(_ impact: SwingImpact) -> Shot? {
    guard let load = impact.approachLoad, let braking = impact.braking, impact.strength >= 0.09 else { return nil }
    let x = [impact.power, impact.sweep, impact.verticalSweep, braking, load]
    let scores = zip(weights,bias).map { w,b in zip(w,x).reduce(b) { $0+$1.0*$1.1 } }
    guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
    let probability = 1 / scores.reduce(0) { $0 + exp($1-scores[best]) }
    guard probability >= (classes[best] == "扣杀" ? 0.60 : 0.75) else { return nil }
    switch classes[best] { case "扣杀": return .smash; case "吊球": return .net; case "高远球": return .clear; default: return nil }
  }
}

#if DEBUG && (targetEnvironment(simulator) || P006_OFFLINE)
private struct MatchRandom: RandomNumberGenerator {
  var seed: UInt64?
  mutating func next() -> UInt64 {
    guard var state = seed else {
      var system = SystemRandomNumberGenerator()
      return system.next()
    }
    state &+= 0x9E3779B97F4A7C15
    seed = state
    var z = (state ^ (state >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
  }
}
#else
private typealias MatchRandom = SystemRandomNumberGenerator
#endif

struct Rally {
  private var matchRandom = MatchRandom()
  #if DEBUG && (targetEnvironment(simulator) || P006_OFFLINE)
  mutating func seedSimulatorMatch(_ seed: UInt64) { matchRandom.seed = seed }
  #endif
  var format = CourtFormat.singles
  var gamesToWin = 1
  private(set) var gamesWon = [0, 0]
  private var nextGamePending = false
  // Index of the player occupying the right service court on each team.
  private(set) var rightPlayer = [0, 0]
  var evenServe: Bool { score[playerServes ? 0 : 1].isMultiple(of: 2) }
  var nearServiceX: Double { evenServe ? 0.43 : -0.43 }
  func servicePlayer(_ team: Int) -> Int { evenServe ? rightPlayer[team] : 1 - rightPlayer[team] }
  var servicePrompt: String {
    let owner = playerServes ? "我方" : "对方"
    let member = format == .doubles ? "\(servicePlayer(playerServes ? 0 : 1) + 1) 号" : ""
    return owner + member + (evenServe ? "右区" : "左区") + (playerServes ? " · 挥拍时按音量键发球" : "发球 · 准备接球")
  }
  private var serveOpened = -Double.infinity
  mutating func readyToServe() {
    if nextGamePending {
      nextGamePending = false
      score = [0, 0]
      rightPlayer = [0, 0]
    }
    phase = .serve
    serveOpened = now
    if collectionScene != nil {
      if collectionScene != .serve && sceneBlockSize > 0 && completedInGroup >= sceneBlockSize {
        if remainingScenes.isEmpty {
          let candidates = CollectionScene.allCases.filter {
            $0 != .serve && $0 != collectionScene && (randomAcrossAreas || $0.area == collectionScene?.area)
          }
          remainingScenes = candidates.shuffled()
        }
        collectionScene = remainingScenes.removeLast()
        sceneGroup += 1
        blockStart = pointCount
      }
      repetition += 1
      playerServes = collectionScene == .serve
      if playerServes { serveTrialCount += 1 }
      lockUntil = now
    }
    footVelocity = .zero; rivalVelocity = .zero
    if !practice {
      playerX = nearServiceX
      opponentX = -nearServiceX
      playerY = 0.77
      opponentY = 0.23
      targetX = playerX
      rivalTarget = opponentX
      targetY = playerY
      rivalY = opponentY
    }
    if let feed = collectionScene?.feed {
      // Mirror the feeder as well as the receiving lane in collection. A
      // straight feed for one hand should not become diagonal for the other.
      if leftHanded { opponentX = -opponentX }
      let feedDirection: Double = trialSide == "反手侧" ? -1 : 1
      playerX = distantReceiveStart ? (leftHanded ? 1 : -1)*feedDirection*0.72 : 0
      playerY = min(0.96, feed.receiveY + (distantReceiveStart ? 0.18 : 0.09))
      opponentY = feed.originY
      targetX = playerX; targetY = playerY
      rivalTarget = opponentX; rivalY = opponentY
    }
    message = servicePrompt
    nextAI = now + 0.9
  }
  var collectionScene: CollectionScene?
  var randomAcrossAreas = false
  var receiveSide = "正手侧"
  var distantReceiveStart = false
  var overheadReturns = OverheadReturnModel.bundled
  var rearClearResponse = RearClearResponse.bundled
  var leftHanded = false
  var intendedReply = "自由回球"
  var trialReply: String {
    if collectionScene == .flat && intendedReply == "平抽" { return intendedReply }
    return collectionScene?.replies.contains(intendedReply) == true ? intendedReply : "自由回球"
  }
  var trialSide: String { collectionScene == .backhand ? "反手侧" : receiveSide }
  var serveTraining = ServeTraining.free
  var targetLane = "自由"
  var targetDepth = "自由"
  var guidedServeTargets = false
  var targetEffort = "自由"
  private var serveTrialCount = 0
  var serveGoal: (lane: String, effort: String) {
    guard guidedServeTargets else { return (targetLane, targetEffort) }
    let i = max(0, serveTrialCount - 1) % 9
    return (["居中","偏左","偏右"][i % 3], ["轻","中","重"][(i / 3 + i % 3) % 3])
  }
  var sceneBlockSize = 0
  private(set) var sceneGroup = 1
  private var blockStart = 0
  private var remainingScenes: [CollectionScene] = []
  var completedInGroup: Int { pointCount - blockStart }
  var collectionMode: String? {
    guard let scene = collectionScene else { return nil }
    var fields = ["场景采集",scene.rawValue,String(repetition),String(sceneGroup),String(sceneBlockSize)]
    if scene == .serve { fields += [serveTraining.rawValue, serveGoal.lane, targetDepth, serveGoal.effort] }
    if scene != .serve { fields += [scene.area.rawValue, trialSide, trialReply, targetLane, targetDepth] }
    if scene != .serve && distantReceiveStart { fields.append("远位起步") }
    return fields.joined(separator: "/")
  }
  private(set) var repetition = 0
  var drill = Drill.mixed
  var lessonEnabled = false
  private(set) var lessonIndex = 0
  var lesson: LessonStep? { lessonEnabled ? LessonStep(rawValue: lessonIndex) : nil }
  var lessonComplete: Bool { lessonEnabled && lessonIndex == LessonStep.allCases.count }
  var hitWindowOpen: Bool {
    guard phase == .flight, let flight, flight.incoming else { return false }
    let ball = flight.at(now)
    let reach = lessonEnabled ? (0.38, 0.29) : (0.52, 0.35)
    let dx = abs(playerX - ball.x), dy = abs(playerY - ball.y)
    return canHit(flight, at: now) && dx < reach.0 && dy < reach.1
      && withinSwingReach(ball, dx: dx, dy: dy, sweep: 0)
  }
  var preparingToReceive: Bool {
    guard phase == .flight, let flight, flight.incoming, !hitWindowOpen else { return false }
    return (1...5).contains { step in
      let time = now + Double(step) * 0.05
      let ball = flight.at(time)
      return canHit(flight, at: time)
        && withinSwingReach(ball, dx: abs(playerX - ball.x), dy: abs(playerY - ball.y), sweep: 0)
    }
  }
  var stillApproachingLowFeed: Bool {
    guard phase == .flight, let flight, flight.incoming, let point = predictedIntercept,
          point.z * 1.524 / Flight.netHeight < 1.35,
          now < flight.start + flight.duration else { return false }
    // Measure the remaining run to the interception, not distance to the
    // landing marker. Stop the cue when the current shuttle is playable.
    let distance = hypot((playerX-point.x)*3.05,(playerY-point.y)*13.4)
    return distance > 1.35 && !hitWindowOpen
  }
  private(set) var predictedIntercept: Position?
  var receivingStandOff = 0.040
  private var adjustmentTime = Double.infinity
  static let overheadLimit = 2.9
  var waitingForDescent: Bool {
    guard !practice, phase == .flight, let flight, flight.incoming else { return false }
    let ball = flight.at(now)
    return ball.y > 0.5 && ball.z * 1.524 / Flight.netHeight > Self.overheadLimit
  }
  private func withinSwingReach(_ ball: Position, dx: Double, dy: Double, sweep: Double) -> Bool {
    guard dx < 0.52, dy < 0.35 else { return false }
    let height = ball.z * 1.524 / Flight.netHeight
    if !practice {
      let distance = hypot(dx * 3.05, dy * 13.4)
      guard height <= Self.overheadLimit, distance <= 1.65 - max(0, height - 2.1) * 0.65 else { return false }
    }
    guard ball.y < 0.75 else { return true }
    let lateral = 0.38 + 0.14 * min(1, max(0, sweep))
    return pow(dx / lateral, 2) + pow(dy / 0.35, 2) < 1
  }
  var landing: Position? { phase == .point ? lastLanding : nil }
  private var lastLanding: Position?

  // A slow swing can finish classification up to 320 ms after its angular-speed peak.
  static let maxRecognitionAge = 0.34
  var practice = false, difficulty = 1, offset = 0.0
  var phase = Phase.countdown, now = 0.0, deadline = 3.0
  var score = [0, 0], playerServes = true, playerX = 0.0, opponentX = 0.0
  var playerY = 0.83, opponentY = 0.16
  var flight: Flight?, message = "", hits = 0, longest = 0, returns = 0
  private var previewTime = -Double.infinity
  private(set) var judgedContactTime: Double?
  mutating func previewSwing(_ impact: SwingImpact) {
    guard phase == .serve || phase == .flight else { return }
    previewTime = now
    swingTime = now
    animationImpact = impact
    animationNeutral = true
    if abs(impact.verticalSweep) > max(0.44, abs(impact.lateralSweep)) {
      stroke = impact.verticalSweep > 0 ? .lift : .smash
    } else { stroke = .drive }
  }
  private mutating func showSwing(_ kind: Stroke, neutral: Bool, impact: SwingImpact?, age: Double) {
    let continuesPreview = impact != nil && previewTime >= now - age - 0.09 && now - previewTime <= 0.32
    if !continuesPreview { swingTime = now }
    previewTime = -.infinity
    animationImpact = impact
    animationNeutral = neutral
    stroke = kind
  }
  var animationImpact: SwingImpact?
  var animationNeutral = false
  var armedUntil = -1.0, swingTime = -2.0, rivalSwing = -2.0
  private var footVelocity = SIMD2<Double>.zero, rivalVelocity = SIMD2<Double>.zero
  var stroke = Stroke.lift, lastShot = Shot.clear, feedback = 0, pointCount = 0
  private var targetX = 0.0, targetY = 0.83, rivalTarget = 0.0, rivalY = 0.16
  var opponentIntercept: Position? {
    guard let flight, !flight.incoming, nextAI <= flight.start + flight.duration else { return nil }
    return flight.at(nextAI)
  }
  private var nextAI = 0.0, opponentDelay = 0.0, lockUntil = 0.0
  private var history: [(Double, Double, Double)] = []
  var armed: Bool { now < armedUntil }
  mutating func toggleNet() { if phase == .flight { armedUntil = armed ? -1 : now + 1.5 } }
  private func canHit(_ flight: Flight, at time: Double) -> Bool {
    time >= flight.start && flight.at(time).y > 0.5001
      && time <= flight.start + flight.duration
  }
  static func won(_ points: [Int]) -> Bool {
    let high = points.max() ?? 0
    return high >= 30 || (high >= 21 && abs(points[0] - points[1]) >= 2)
  }
  // Gameplay speeds in metres/second. The cap follows the direction of travel;
  // diagonal travel shares one speed budget with lateral and longitudinal travel.
  private static func footSpeed(_ dir: SIMD2<Double>, facing: Double) -> Double {
    let along = dir.y * facing
    return 4.45 + max(0,along)*0.65 + min(0,along)*0.85
  }
  private static func moveFeet(x: inout Double, y: inout Double, vxz: inout SIMD2<Double>,
                               toX: Double, toY: Double, facing: Double, pace: Double, dt: Double) {
    let delta = SIMD2((toX-x)*3.05,(toY-y)*13.4)
    let distance = hypot(delta.x,delta.y)
    guard distance > 0.002,dt > 0 else { vxz = .zero; return }
    let dir = delta / distance
    let desired = dir * min(footSpeed(dir,facing:facing)*pace, sqrt(2*12*distance))
    let change = desired - vxz
    vxz += change * min(1, 12*dt/max(0.0001,hypot(change.x,change.y)))
    let step = vxz * dt
    if step.x*dir.x + step.y*dir.y >= distance {
      x = toX; y = toY; vxz = .zero
    } else { x += step.x/3.05; y += step.y/13.4 }
  }
  mutating func tick(_ dt: Double) {
    now += dt
    if !practice, let f = flight, f.incoming, phase == .flight,
       now >= adjustmentTime, let contact = predictedIntercept {
      adjustmentTime = .infinity
      // The selected lateral stance stays fixed through the last depth adjustment.
      targetY = min(0.98, max(0.54, contact.y + receivingStandOff))
    }
    Self.moveFeet(x: &playerX, y: &playerY, vxz: &footVelocity, toX: targetX, toY: targetY,
                  facing: -1, pace: 1, dt: dt)
    if now >= opponentDelay {
      Self.moveFeet(x: &opponentX,y: &opponentY,vxz: &rivalVelocity,toX:rivalTarget,toY:rivalY,
                    facing: 1,pace: 0.83 + 0.085 * Double(difficulty),dt:dt)
    }
    history.append((now, playerX, playerY))
    history.removeAll { $0.0 < now - 0.75 }
    switch phase {
    case .countdown, .point:
      if now >= deadline {
        readyToServe()
      }
    case .serve:
      if !playerServes && now >= nextAI { feed() }
    case .flight:
      guard let f = flight else { return }
      let progress = (now - f.start) / f.duration
      if let collision = f.netCollision, f.at(now).y <= collision.y, !f.incoming {
        award(false, "击球下网")
        lastLanding = collision
        return
      }
      if f.incoming {
        if progress > 1 && now > f.start + f.duration + offset + Self.maxRecognitionAge {
          let reason = ["挥早了", "挥晚了", "离球太远", "球还太高 · 等下降"].contains(message) ? message : "来球落地"
          award(false, reason)
        }
      } else if collectionScene != nil {
        if progress >= 1 { award(true, "落地 · " + f.shot.rawValue) }
      } else if lessonEnabled {
        if progress >= 1 {
          if lessonComplete { phase = .finished } else { award(true, message) }
        }
      } else if practice && drill == .netTiming {
        if progress >= 1 { award(true, message) }
      } else if progress >= 0.80 {
        let ball = f.at(now)
        let reachable = abs(opponentX - ball.x) < 0.41 && abs(opponentY - ball.y) < 0.18
        if progress >= 1 { award(true, "空当得分") }
        else if reachable && ball.y < 0.5 && now >= nextAI { feed() }
      }
    case .finished: break
    }
  }
  /// Commit a button return only after the match racket reaches the shuttle.
  /// The candidate includes the chosen stroke and its pose at the press time.
  @discardableResult
  mutating func swing(_ kind: Stroke, aim: Double, impact: SwingImpact?,
                      confirmedByButton: Bool, validateContact: (Rally) -> Bool) -> SwingDecision {
    guard confirmedByButton, phase == .flight, flight?.incoming == true else {
      return swing(kind, aim: aim, impact: impact, confirmedByButton: confirmedByButton)
    }
    var candidate = self
    let decision = candidate.swing(kind, aim: aim, impact: impact, confirmedByButton: true)
    if decision == .accepted && !validateContact(candidate) {
      judgedContactTime = candidate.judgedContactTime
      showSwing(kind, neutral: false, impact: impact, age: 0)
      message = "拍面未触球"
      return .outOfReach
    }
    self = candidate
    return decision
  }

  @discardableResult
  mutating func swing(_ kind: Stroke, aim: Double, age: Double = 0, neutral: Bool = false, impact: SwingImpact? = nil, confirmedByButton: Bool = false) -> SwingDecision {
    judgedContactTime = nil
    guard confirmedByButton || now >= lockUntil else { return .locked }
    guard phase == .serve || phase == .flight else { return .inactive }
    if phase == .serve {
      guard now - max(0,age) >= serveOpened else { return .inactive }
      guard playerServes else { return .invalidServe }
      let serveLabel = impact?.label
      let longServe = serveLabel == "反手偷后场" || serveLabel == "正手高远发球"
      let shortServe = serveLabel == "反手短发球" || serveLabel == "反手短发" || serveLabel == "正手短发球"
      guard longServe || shortServe || neutral || impact?.serveIntentConfirmed == true || kind != .smash else {
        message = "从腰前向前轻推或上挑发球"
        return .invalidServe
      }
      hits = 0
      showSwing(kind, neutral: neutral, impact: impact, age: age)
      serve(short: !longServe && (shortServe || neutral || kind != .lift), aim: aim, impact: impact)
      return .accepted
    }
    guard let f = flight, f.incoming else { return .noIncoming }
    let peakTime = confirmedByButton ? now : now - offset - min(Self.maxRecognitionAge, max(0, age))
    let sweep = impact?.sweep ?? 1
    func positionAt(_ time: Double) -> (Double, Double) {
      let pos = history.last(where: { $0.0 <= time })
      return (pos?.1 ?? playerX, pos?.2 ?? playerY)
    }
    let tail = min(0.055, max(0, min(impact?.followThrough ?? 0, now - peakTime)))
    let offsets = Array(stride(from: 0.0, to: tail, by: 0.005)) + [tail]
    let at = confirmedByButton ? peakTime : offsets.lazy.map { peakTime + $0 }.first { time in
      let ball = f.at(time)
      let (x, y) = positionAt(time)
      return canHit(f, at: time) && withinSwingReach(ball, dx: abs(x - ball.x), dy: abs(y - ball.y), sweep: sweep)
    } ?? peakTime
    judgedContactTime = at
    let ball = f.at(at)
    let (x, y) = positionAt(at)
    showSwing(kind, neutral: neutral, impact: impact, age: age)
    let reachMeters = hypot((x-ball.x)*3.05,(y-ball.y)*13.4)
    if confirmedByButton {
      if at >= f.start + f.duration || ball.z <= 0 { message = "球已落地"; return .late }
      if ball.y < 0.5 { message = "挥早了"; return .early }
      if ball.z * 1.524 / Flight.netHeight > Self.overheadLimit + 0.30 {
        message = "球还太高 · 等下降"; return .tooHigh
      }
      if reachMeters > 2.40 { message = "离球太远"; return .outOfReach }
    }
    guard confirmedByButton || canHit(f, at: at) else {
      let early = at <= f.start + f.duration
      lockUntil = now + 0.18
      message = early ? "挥早了" : "挥晚了"
      return early ? .early : .late
    }
    let dx = abs(x - ball.x)
    let dy = abs(y - ball.y)
    guard confirmedByButton || withinSwingReach(ball, dx: dx, dy: dy, sweep: impact?.sweep ?? 1) else {
      lockUntil = now + 0.18
      if !practice, ball.z * 1.524 / Flight.netHeight > Self.overheadLimit {
        message = "球还太高 · 等下降"
        return .tooHigh
      }
      message = "离球太远"
      return .outOfReach
    }
    lockUntil = now + 0.18
    // A shuttle near the limit of reach leaves less room for a full return.
    let flightProgress = (at-f.start)/f.duration
    let latePressure = max(0,(flightProgress-0.88)/0.12)
    let radialStretch = max(0,(reachMeters-0.62)/0.70)
    // A shuttle behind the racket shoulder can be close to the feet yet
    // leave little room to accelerate. Keep ordinary side contacts playable.
    let behind = ball.contactArea == "后场" ? max(0, (ball.y-y)*13.4 - 0.09) : 0
    let stretch = confirmedByButton ? min(1,max(radialStretch,behind/0.85,latePressure))
      : max(dx / 0.52, dy / 0.35)
    let front = ball.y < 0.78 && ball.y <= y + 0.035
    let shortCourt = confirmedByButton ? (0.5...0.69).contains(ball.y) : front && ball.y < 0.75
    let strength = min(1, max(0, impact?.strength ?? 0.55))
    let softLift = !neutral && kind == .lift && impact != nil && strength < 0.35
    // Net interception: distinguish a turning phone from sustained downward drive.
    // The signed load is the mean gravity-axis projection over the last 150 ms (g).
    let netLoad = confirmedByButton && shortCourt ? impact?.approachLoad : nil
    let pressingDown = (netLoad ?? 0) < -1.65 && (impact?.verticalSweep ?? 0) < 0.18 && strength > 0.38
    let forwardPush = (netLoad ?? 0) < -0.30 && (impact?.verticalSweep ?? 0) < 0.55 && strength > 0.19
    let downward = pressingDown || !neutral && (kind == .smash || impact?.label == "网前扑球")
    let yielding = confirmedByButton && kind == .drive && (impact?.braking ?? 0) > 0.55
      && (impact?.sweep ?? 1) < 0.42 && strength < 0.52
    var shot: Shot
    if armed || (confirmedByButton && strength < 0.04) {
      shot = .net
    } else if yielding {
      shot = .net
    } else if pressingDown {
      shot = .smash
    } else if forwardPush && !downward && ball.z >= Flight.netHeight && kind != .smash {
      shot = .drive
    } else if confirmedByButton, let impact, impact.label == nil,
              strength < (kind == .lift && ball.z < Flight.netHeight ? 0.20 : 0.32), !downward || ball.z >= Flight.netHeight {
      shot = .net
    } else if shortCourt && downward {
      shot = .smash
    } else if shortCourt && (impact?.label == "网前放网" || (softLift && ball.z >= Flight.netHeight)) {
      shot = .net
    } else if shortCourt && !neutral && kind == .lift && ball.z < Flight.netHeight {
      shot = .clear
    } else if let special = specialistShot(impact?.label, incoming: f, ball: ball) {
      shot = special
    } else if neutral || (!confirmedByButton && stretch > 0.82 && !shortCourt) {
      shot = .weak
    } else if kind == .smash {
      shot = f.shot == .weak ? .power : .smash
    } else {
      shot = kind == .lift ? .clear : .drive
    }
    if confirmedByButton, !armed, !leftHanded, ball.contactArea == "后场",
       f.shot == .clear || f.shot == .weak, shot == .clear || shot == .net || shot == .drive || shot == .smash,
       let impact, !impact.probableBackhand, let refined = overheadReturns?.refinement(impact) {
      shot = refined
    }
    let cornerStyle = confirmedByButton && !armed && !leftHanded && ball.contactArea == "后场" && ball.x < -0.20
      ? impact?.cornerStyle : nil
    var launchImpact = impact
    if cornerStyle == .backClear || cornerStyle == .backDrop {
      shot = cornerStyle == .backClear ? .clear : .net
      launchImpact?.probableBackhand = true
    }
    hits += 1
    returns += 1
    longest = max(longest, hits)
    send(shot, aim: aim, from: ball, impact: launchImpact, netPlay: shortCourt, stretch: stretch, defendingSmash: f.shot == .smash || f.shot == .power, button: confirmedByButton)
    let relativeSide = (ball.x-x) * (leftHanded ? -1 : 1) * 3.05
    let handLabel = impact?.label ?? ""
    let backhandCorner = ball.contactArea == "后场" && ball.x * (leftHanded ? -1 : 1) < -0.20
    let overhead = backhandCorner && ball.z > 2.02 * Flight.netHeight / 1.524
      && stretch < 0.55 && relativeSide > -0.34
    // Court position can suggest a side but cannot prove a player's actual grip.
    if cornerStyle == .roundHead {
      flight?.probableBackhand = false
      flight?.measuredRoundHead = true
    } else if launchImpact?.probableBackhand == true || handLabel.contains("反手") {
      flight?.probableBackhand = true
    } else if handLabel.contains("正手") {
      flight?.probableBackhand = false
    } else if !backhandCorner && abs(relativeSide) > 0.15 {
      flight?.probableBackhand = relativeSide < 0
    }
    let roundHead = cornerStyle == .roundHead || (overhead && flight?.probableBackhand != true)
    flight?.overheadFromBackhandCorner = roundHead
    flight?.compactAttack = (impact?.sweep ?? 1) < 0.42
    flight?.jumpHeightMeters = Flight.attackingJump(shot: shot, contact: ball, feet: Position(x: x,y: y), strength: strength)
    if let result = flight {
      let style = observedStyle(incoming: f,outgoing: result)
      flight?.returnStyle = cornerStyle ?? style
    }
    if let step = lesson, flight?.netCollision == nil {
      if step.accepts(shot) {
        lessonIndex += 1
        message = "\(shot.rawValue)成功"
      } else {
        message = "已回球 · 再试一次指定球路"
      }
    }
    return .accepted
  }
  mutating func replayPoint() {
    if collectionScene == .serve { serveTrialCount = max(0, serveTrialCount - 1) }
    flight = nil
    phase = lessonComplete ? .finished : .countdown
    deadline = now + 0.8
    armedUntil = -1
    lockUntil = now
    hits = 0
    targetX = 0
    targetY = 0.83
    rivalTarget = 0
    rivalY = 0.16
  }
  private func specialistShot(_ label: String?, incoming: Flight, ball: Position) -> Shot? {
    let attack = [.smash, Shot.power].contains(incoming.shot)
    switch label {
    case "头顶高远", "上挑": return .clear
    case "正手扣杀" where ball.z > 0.23: return .smash
    case "吊球", "网前放网": return .net
    case "网前扑球" where ball.y < 0.77 && ball.z > Flight.netHeight: return .smash
    case "网前推球" where ball.y < 0.79: return .drive
    case "接杀挡网" where attack: return .net
    case "接杀反抽" where attack: return .drive
    case "平抽": return .drive
    default: return nil
    }
  }

  func returnDescription(incoming: Flight, outgoing: Flight) -> String {
    if let style = outgoing.returnStyle ?? observedStyle(incoming:incoming,outgoing:outgoing) {
      return style == .roundHead && !outgoing.measuredRoundHead ? "头顶正手处理（站位推定）" : style.rawValue
    }
    switch (outgoing.from.contactArea, outgoing.shot) {
    case ("网前", .smash), ("网前", .power): return "低点下压"
    case ("中场", .drive): return "平抽（持拍侧待核）"
    case ("后场", .drive): return "平快回球"
    default: return outgoing.shot.rawValue
    }
  }

  private func observedStyle(incoming: Flight, outgoing: Flight) -> ReturnStyle? {
    let p = outgoing.from
    let crossed = p.x * outgoing.to.x < 0 && abs(p.x - outgoing.to.x) > 0.4
    let attack = incoming.shot == .smash || incoming.shot == .power
    let nearTape = abs(p.z - Flight.netHeight) <= 0.055
    switch (p.contactArea, outgoing.shot) {
    case ("网前", .net):
      if crossed { return .crossNet }
      if p.z < Flight.netHeight - 0.045 { return .lowNet }
      return nearTape ? .straightNet : .feather
    case ("网前", .drive): return nearTape ? .pushGap : .push
    case ("网前", .clear): return crossed ? .crossLift : .straightLift
    case ("网前", .smash), ("网前", .power): return p.z > Flight.netHeight ? .netKill : nil
    case ("中场", .drive):
      if attack { return .counter }
      return outgoing.probableBackhand.map { $0 ? .backDrive : .foreDrive }
    case ("中场", .net): return attack ? .block : (p.z > Flight.netHeight ? .halfDrop : .cushion)
    case ("中场", .clear) where attack: return .liftSmash
    case ("中场", .smash), ("中场", .power): return outgoing.compactAttack ? .tapAttack : .steepAttack
    case ("后场", .clear), ("后场", .net):
      if outgoing.probableBackhand == true { return outgoing.shot == .clear ? .backClear : .backDrop }
      if outgoing.overheadFromBackhandCorner { return .roundHead }
      if incoming.shot == .drive { return outgoing.shot == .clear ? .defensiveClear : .escapeDrop }
      return outgoing.shot == .clear ? .clear : .drop
    case ("后场", .drive): return outgoing.to.y < 0.19 ? .flatClear : nil
    case ("后场", .smash), ("后场", .power): return .smash
    default: return nil
    }
  }

  private mutating func send(_ shot: Shot, aim: Double, from: Position, impact: SwingImpact?, netPlay: Bool, stretch: Double, defendingSmash: Bool, button: Bool) {
    phase = .flight
    armedUntil = -1
    feedback += 1
    lastShot = shot
    message = shot.rawValue
    var far = Position(x: max(-format.halfWidth, min(format.halfWidth, aim)), y: shot == .net ? 0.35 : 0.08)
    var speed: Double
    switch shot {
    case .clear, .weak: speed = 1.4
    case .net: speed = 0.92
    case .drive: speed = 0.85
    case .smash: speed = 0.72
    case .power: speed = 0.56
    }
    var arc = shot == .clear || shot == .weak ? 0.53 : 0.19
    let clearResponse = button && shot == .clear && from.contactArea == "后场" && !leftHanded
      && impact?.probableBackhand != true && impact?.label?.contains("反手") != true ? rearClearResponse : nil
    if let impact {
      let strength = clearResponse?.carry(impact.strength) ?? impact.strength
      speed *= 1.18 - 0.39 * strength
      let short = shot == .net
      far.y = short ? 0.40 - 0.13 * strength : 0.26 - 0.25 * strength
      switch shot {
      case .clear, .weak: arc = 0.19 + strength * 0.56
      case .drive: arc = 0.12 + 0.16 * strength
      case .net: arc = 0.13 + 0.17 * strength
      case .power, .smash: arc = 0.09 + 0.11 * strength
      }
      switch (impact.label, shot) {
      case ("吊球", .net): far.y = 0.32 - 0.09 * strength; arc *= 0.84
      case ("接杀挡网", .net): speed *= 1.1; arc += 0.035
      case ("网前推球", .drive): far.y = 0.25 - 0.13 * strength; speed *= 1.08
      case ("接杀反抽", .drive): speed *= 0.84
      case ("网前扑球", .smash): far.y = 0.31 - 0.15 * strength; speed *= 0.80
      default: break
      }
    }
    if let impact, from.contactArea == "后场", shot == .net {
      // A rear-court drop still travels the length of the court before falling short.
      far.y = 0.445 - 0.12 * impact.strength + 0.025 * (impact.braking ?? 0) - 0.10 * stretch
      speed = 1.13 - 0.20 * impact.strength
      let crossing = (0.5 - from.y) / (far.y - from.y)
      if crossing > 0 && crossing < 1 {
        let clearance = 0.028 + 0.024*impact.strength + 0.065*stretch
        arc = max(0,(Flight.netHeight + clearance - from.z*(1-crossing)) / Flight.arch(crossing,shot:shot))

      }
    }
    if defendingSmash, shot == .drive, impact?.label != "接杀反抽" {
      speed *= 0.90
    }
    if netPlay {
      let baseline = (far.y, speed, arc)
      let effort = min(1, max(0, impact?.strength ?? 0.55))
      let extensionLoss = min(1, max(0, (stretch - 0.65) / 0.35))
      let effective = effort * (1 - 0.55 * extensionLoss)
      // Choose the height at the net first, then solve the same parabola used by Flight.
      var crossingHeight = Flight.netHeight + 0.055
      switch shot {
      case .smash, .power:
        far.y = 0.34 - 0.12 * effective
        let metresToNet = max(0, (from.y - 0.5) * 13.4)
        let descent = 0.075 + 0.16 * abs(min(0, impact?.verticalSweep ?? 0)) + 0.035 * effective
        crossingHeight = from.z - metresToNet * descent * Flight.netHeight / 1.524
        speed = 0.70 - 0.22 * effective
        message = from.z > Flight.netHeight ? "网前下压" : "低点击球 · 下压"
      case .net:
        far.y = 0.43 - 0.06 * effective
        crossingHeight = max(crossingHeight, from.z)
      case .drive:
        far.y = 0.30 - 0.12 * effective + 0.10 * extensionLoss
        message = extensionLoss > 0.4 ? "伸拍推球 · 回球偏浅" : "网前推球"
      case .clear:
        far.y = 0.28 - 0.26 * effective
        crossingHeight += 0.15 + 0.27 * effective
        message = effective > 0.65 ? "挑向后场" : "挑向中场"
      case .weak: break
      }
      let u = (from.y - 0.5) / (from.y - far.y)
      if u > 0 && u < 1 { arc = min(0.95, (crossingHeight - from.z * (1 - u)) / Flight.arch(u, shot: shot)) }
      // Above tape, set an outgoing tangent. Solving only for net height
      // made a high push dive more steeply than a kill and a touch pop upward.
      if button, from.z > Flight.netHeight + 0.040, let impact {
        let span = abs(from.y-far.y)*13.4
        let tangent: Double?
        switch shot {
        case .smash, .power: tangent = -0.13 - 0.19*max(0,-impact.verticalSweep)
        case .drive: tangent = -0.045 + 0.12*impact.verticalSweep
        case .net: tangent = -0.06 + 0.18*impact.verticalSweep
        default: tangent = nil
        }
        if let tangent {
          // arch'(0) = 4 * 0.78 for these three shot families.
          arc = (from.z+tangent*span*Flight.netHeight/1.524)/3.12
        }
      }
      if button {
        let blend = min(1, max(0, (0.69 - from.y) / 0.065))
        far.y = baseline.0 + blend * (far.y - baseline.0)
        speed = baseline.1 + blend * (speed - baseline.1)
        arc = baseline.2 + blend * (arc - baseline.2)
      }
    }
    if button, let impact, !netPlay {
      let rise = min(1,max(-1,impact.verticalSweep))
      let braking = impact.braking ?? 0
      if shot == .clear {
        arc += 0.16 * max(0,rise)
        far.y += 0.09 * stretch
        speed += 0.14 * max(0,rise)
      } else if shot == .drive {
        // Rear flat clears travel flatter and faster than lifted defensive clears.
        arc += 0.09 * max(0,rise)
        far.y += 0.10 * stretch + 0.04 * braking
      } else if shot == .smash || shot == .power {
        // A short accelerating tap lands earlier than a long penetrating attack.
        let extensionAmount = min(1,max(0,impact.sweep))
        far.y += 0.16 * (1-extensionAmount) + 0.06 * max(0,-rise)
        speed *= 0.94 + 0.10 * (1-impact.power)
        arc *= 1 - 0.42 * max(0,-rise)
      } else if shot == .net {
        far.y += 0.025 * braking
      }
    }
    if let impact { arc *= 1 + 0.30 * impact.verticalSweep }
    // A yielding block blends continuously from a net touch to a midcourt
    // defensive return as the contact moves through the short-court overlap.
    let flatFeed = flight?.incoming == true && flight?.shot == .drive && from.y < 0.80
    if defendingSmash || flatFeed, shot == .net, let impact, impact.strength >= 0.09,
       impact.verticalSweep > -0.32 {
      let progress = min(1,max(0,(from.y - 0.625)/0.065))
      let defenseWeight = progress * progress * (3 - 2*progress)
      let carry = min(1,max(0,impact.strength))
      let blockDepth = (defendingSmash ? 0.435 : 0.413) - 0.12*carry
      far.y += defenseWeight * (blockDepth-far.y)
      let crossing = (0.5-from.y)/(far.y-from.y)
      if crossing > 0 && crossing < 1 {
        let clearance = (0.095 + 0.18*carry + 0.12*max(0,impact.verticalSweep)) * Flight.netHeight/1.524
        let blockArc = (Flight.netHeight+clearance-from.z*(1-crossing))/Flight.arch(crossing,shot:shot)
        arc += defenseWeight * max(0,blockArc-arc)
      }
    }
    if button {
      // Heading is relative to a straight shot from the contact, in court metres.
      // A cross-net touch needs a much wider launch cone than a deep drive.
      let steering = from.contactArea == "网前" && shot == .net ? 1.10 : 0.55
      let angle = min(1,max(-1,aim)) * steering
      let displacement = abs(from.y-far.y)*13.4*tan(angle)/3.05
      let room = max(0.001, format.halfWidth - (displacement >= 0 ? from.x : -from.x))
      if shot == .net && from.contactArea == "后场", let impact {
        let angleFraction = 0.8 * abs(aim) + 0.2 * abs(aim) * impact.sweep
        far.x = from.x + (aim < 0 ? -1 : 1) * room * angleFraction
      } else if let clearResponse {
        // Allocate lateral room once. A long flight should not saturate sooner than a short one.
        let fraction = clearResponse.widthFraction(aim)
        far.x = from.x + (aim < 0 ? -1 : 1) * room * fraction
      } else {
        far.x = from.x + room * tanh(displacement / room)
      }
    }
    if button, from.contactArea == "后场", [.net, .clear, .smash].contains(shot) {
      // Seed small placement variation from game time so a replay is reproducible.
      let jitter = sin(now * 53.941 + aim * 9.31)
      let dx = far.x - from.x
      far.x = min(format.halfWidth,max(-format.halfWidth,far.x + dx * 0.025 * jitter))
      far.y = min(0.48,max(0.005,far.y + (0.002 + 0.004 * min(1,stretch)) * jitter))
    }
    if button, from.contactArea == "中场", shot == .smash || shot == .power,
       let impact, impact.sweep < 0.42, impact.verticalSweep > -0.78,
       from.z > Flight.netHeight + 0.11 {
      // A compact attack from a high interception has room to skim the tape.
      // Keep low or excessively steep attacks eligible for net collisions.
      let crossing = (0.5-from.y)/(far.y-from.y)
      if crossing > 0 && crossing < 1 {
        let required = Flight.netHeight + 0.015 - from.z*(1-crossing)
        arc = max(arc,required/Flight.arch(crossing,shot:shot))
      }
    }
    if (shot == .smash || shot == .power) && from.z <= Flight.netHeight {
      arc = 0
    }
    flight = Flight(
      from: from, to: far, start: now, duration: speed,
      arc: arc, incoming: false, shot: shot, measured: impact != nil || netPlay || (shot == .smash && from.z <= Flight.netHeight))
    flight?.returnedSmash = defendingSmash
    flight?.invitesAttack = stretch > 0.65 && (shot == .clear || shot == .net || shot == .drive)
    rivalTarget = far.x
    rivalY = far.y
    opponentDelay = now + [0.42, 0.30, 0.16][difficulty]
    nextAI = now + speed * (Double.random(in: 0...1, using: &matchRandom) < [0.23, 0.12, 0.05][difficulty] ? 1.1 : 0.8)
    targetX = 0
    targetY = 0.80
  }
  private mutating func serve(short: Bool, aim: Double, impact: SwingImpact? = nil) {
    let near = playerServes
    let x = near ? playerX : opponentX
    var depth = short ? CourtFormat.shortLine - 0.025 : format.backLine + 0.042
    let measuredHigh = !short && impact?.label == "正手高远发球" ? impact : nil
    let diagonal = x > 0 ? -1.0 : 1.0
    var landingX = diagonal * (0.41 + 0.26 * abs(aim))
    if let impact {
      // The stroke changes loft. Carry spans the entire legal service box for every stroke.
      let carry = min(1, max(0, impact.strength * (1 + 0.10 * impact.verticalSweep)))
      let front = CourtFormat.shortLine - 0.005
      depth = front + (format.backLine + 0.012 - front) * carry
      // Convert signed horizontal swing into displacement from the diagonal centre line.
      // A deeper shot travels farther at the same azimuth.
      let halfBox = format.halfWidth / 2
      let range = min(0.99, 0.80 + 0.18 * carry)
      landingX = halfBox * (diagonal + range * max(-1, min(1, aim)))
    }
    let landing = Position(x: landingX,
                           y: near ? depth : 1 - depth)
    // The net centre is 1.524 m. Launch the virtual cork at 0.90 m.
    let handSide: Double = near ? (leftHanded ? -1 : 1) : -1
    let launch = Position(x: x + handSide * 0.29 / 3.05,
                          y: near ? playerY - 0.41 / 13.4 : opponentY + 0.41 / 13.4,
                          z: 0.90 * Flight.netHeight / 1.524)
    var shot: Shot = short ? .net : .clear
    let flick = impact?.label == "反手偷后场"
    var duration = (short ? 1.05 : flick ? 1.25 : 1.65) * (1.12 - 0.24 * (impact?.strength ?? 0.5))
    var arc = impact.map { short ? 0.21 + 0.20 * $0.strength : 0.23 + (flick ? 0.30 : 0.56) * $0.strength } ?? (short ? 0.18 : 0.65)
    if let impact, impact.serveIntentConfirmed, impact.label == nil {
      // Combine upward sweep and energy before blending the two flight envelopes.
      let lift = min(1, max(0, (impact.verticalSweep - 0.10) / 0.45))
      let loft = lift * impact.strength
      arc = 0.21 + 0.20 * impact.strength + loft * (0.02 + 0.36 * impact.strength)
      duration = (1.05 + 0.60 * loft) * (1.12 - 0.24 * impact.strength)
      shot = !short && loft >= 0.40 ? .clear : .net
    }
    if let high = measuredHigh {
      // Carry comes from stroke energy; a larger sweep adds loft and hang time.
      arc = 0.26 + 0.58 * high.strength + 0.16 * high.sweep
      duration = 1.20 + 0.66 * high.strength + 0.20 * high.sweep
    }
    if let impact { arc *= 1 + 0.25 * impact.verticalSweep }
    flight = Flight(from: launch, to: landing, start: now, duration: duration,
                    arc: arc, incoming: !near, shot: shot, measured: impact != nil)
    guard format.legalLanding(landing, serverNear: near, serverX: x) else {
      award(!near, "发球落点违例")
      return
    }
    phase = .flight
    lastShot = shot
    message = near ? "已发球" : "准备接球"
    if near {
      feedback += 1
      rivalTarget = landing.x
      rivalY = landing.y
      nextAI = now + duration * 0.80
      opponentDelay = now
    } else {
      rivalSwing = now
      approachIncoming()
    }
  }

  private mutating func feed() {
    if let recipe = collectionScene?.feed {
      let width = collectionScene == .backhand ? 0.79 : 0.49
      let side = trialSide == "追身" ? 0 : trialSide == "反手侧" ? -width : width
      flight = Flight(from: Position(x: opponentX, y: opponentY, z: recipe.height),
                      to: Position(x: leftHanded ? -side : side, y: recipe.depth),
                      start: now, duration: recipe.seconds, arc: recipe.arc, incoming: true, shot: recipe.shot)
      if let feed = flight {
        flight?.jumpHeightMeters = Flight.attackingJump(shot: feed.shot, contact: feed.from,
          feet: Position(x: opponentX,y: opponentY), strength: 1)
      }
      phase = .flight
      rivalSwing = now
      approachIncoming()
      message = "准备接球"
      return
    }
    if phase == .serve && !practice { serve(short: Bool.random(using: &matchRandom), aim: 0); return }
    let previous = flight
    let origin = previous?.at(now) ?? Position(x: opponentX, y: opponentY, z: 0.18)
    var shot: Shot =
      (previous?.shot == .weak || previous?.invitesAttack == true) ? .power : [Shot.clear, .clear, .drive, .net, .weak].randomElement(using: &matchRandom)!
    if practice && drill == .clears { shot = .clear }
    if practice && drill == .flat { shot = .drive }
    let repeatNet = practice && !lessonEnabled && drill == .netTiming
    if repeatNet { shot = .net }
    if let lesson { shot = lesson.feed }
    let destination =
      practice && drill == .sides ? (playerX >= 0 ? -0.85 : 0.85) : Double.random(in: -format.halfWidth...format.halfWidth, using: &matchRandom)
    let to = Position(x: lessonEnabled || repeatNet ? 0 : destination, y: shot == .net ? 0.67 : 0.91)
    let duration = (shot == .power ? 0.83 : shot == .drive ? 1.03 : 1.38) * (practice ? 1.23 : 1.0)
    flight = Flight(
      from: repeatNet ? Position(x: opponentX, y: opponentY, z: 0.43) : origin, to: to, start: now, duration: duration,
      arc: shot == .clear || shot == .weak ? 0.58 : 0.24, incoming: true, shot: shot)
    if let feed = flight {
      flight?.jumpHeightMeters = Flight.attackingJump(shot: feed.shot, contact: feed.from,
        feet: Position(x: opponentX,y: opponentY), strength: 1)
    }
    phase = .flight
    rivalSwing = now
    if practice { targetX = to.x; targetY = to.y; predictedIntercept = flight?.at(now + duration * 0.75) } else { approachIncoming() }
    rivalTarget = 0
    rivalY = 0.16
    message = shot == .weak ? "机会球 · 向下挥" : "准备接球"
  }
  private mutating func approachIncoming() {
    guard let flight else { return }
    // Choose a receiving stance once, allowing time to stop before contact.
    let preferredHeight: Double
    switch flight.shot {
    case .clear, .weak: preferredHeight = 2.05
    case .drive, .net: preferredHeight = 1.20
    case .power, .smash: preferredHeight = 0.95
    }
    func travelTime(toX x: Double, y: Double) -> Double {
      let displacement = SIMD2((x-playerX)*3.05,(y-playerY)*13.4)
      let distance = hypot(displacement.x, displacement.y)
      let cap = Self.footSpeed(displacement/max(0.001,distance),facing:-1)
      return distance < cap*cap/12 ? 2*sqrt(distance/12) : distance/cap + cap/12
    }
    func stanceX(_ ball: Position, y: Double, at time: Double) -> Double {
      let hand = leftHanded ? -1.0 : 1.0
      let width = format.halfWidth
      func behindLane(_ offsetMetres: Double) -> Double {
        max(-width,min(width,ball.x-offsetMetres/3.05))
      }
      if ball.contactArea == "后场", flight.shot != .smash && flight.shot != .power {
        // Arrive behind the striking shoulder. A hurried non-racket-side
        // reception stays inside the corner instead of chasing an overhead stance.
        if ball.x*hand < -0.20 {
          let overhead = behindLane(-0.12*hand)
          if ball.z*1.524/Flight.netHeight > 2.02 &&
               now+travelTime(toX:overhead,y:y)+0.20 <= time { return overhead }
          return behindLane(-0.34*hand)
        }
        return behindLane(0.24*hand)
      }
      let dx = ball.x-playerX
      let side = abs(dx) < 0.06 ? hand : (dx < 0 ? -1.0 : 1.0)
      return behindLane(side*0.34)
    }
    var bestScore = Double.infinity
    var intercept = flight.to
    var interceptAt = flight.start + flight.duration
    for index in 1..<60 {
      let t = flight.start + flight.duration * Double(index) / 60
      let ball = flight.at(t)
      guard t >= now, canHit(flight, at:t) else { continue }
      let height = ball.z * 1.524 / Flight.netHeight
      guard height <= Self.overheadLimit else { continue }
      let y = min(0.98, max(0.54, ball.y + receivingStandOff))
      let travel = travelTime(toX:stanceX(ball,y:y,at:t),y:y)
      let positionCost = collectionScene?.feed.map { 45 * abs(ball.y - $0.receiveY) } ?? abs(height-preferredHeight)
      let score = positionCost + 6*max(0,now+travel+0.20-t)
        + 1.2*abs(flight.to.y-ball.y)
      if score < bestScore { bestScore = score; intercept = ball; interceptAt = t }
    }
    predictedIntercept = intercept
    let depth = min(0.98,max(0.54,intercept.y + receivingStandOff))
    targetX = stanceX(intercept,y:depth,at:interceptAt)
    if intercept.contactArea == "后场" {
      // Keeping a single rear receiving mark lets the player brake there.
      // A second depth target 140 ms before impact used to restart both feet.
      targetY = depth
      adjustmentTime = .infinity
    } else {
      targetY = min(0.98,max(0.54,intercept.y + receivingStandOff + 0.02))
      adjustmentTime = interceptAt - 0.14
    }
  }
  private mutating func award(_ player: Bool, _ reason: String) {
    lastLanding = flight?.to
    flight = nil
    armedUntil = -1
    message = reason
    hits = 0
    pointCount += 1
    if collectionScene == nil && !lessonEnabled { score[player ? 0 : 1] += 1 }
    if format == .doubles && !practice && playerServes == player { rightPlayer[player ? 0 : 1] ^= 1 }
    playerServes = practice ? false : player
    phase = .point
    if collectionScene == nil && !practice && Self.won(score) {
      let winner = player ? 0 : 1
      gamesWon[winner] += 1
      if gamesWon[winner] == gamesToWin { phase = .finished }
      else {
        message = "本局结束 · " + score.map(String.init).joined(separator: " 比 ")
        nextGamePending = true
      }
    }
    deadline = now + 1.25
    targetX = 0
    rivalTarget = 0
    targetY = 0.83
    rivalY = 0.16
  }
}

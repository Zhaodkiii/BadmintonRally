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
struct SwingImpact {
  let power, sweep: Double
  var serveIntentConfirmed = false
  var label: String?
  var verticalSweep: Double = 0
  var lateralSweep: Double = 0
  var followThrough: Double = 0
  var strength: Double { 0.65 * power + 0.35 * sweep }
}

struct Flight {
  let from, to: Position
  let start, duration, arc: Double
  let incoming: Bool
  let shot: Shot
  var measured = false
  var invitesAttack = false
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

enum CollectionScene: String, CaseIterable {
  case serve = "我方发球", high = "后场高球", net = "网前来球", flat = "中场平球", defense = "接杀防守"

  var feed: Shot? {
    switch self {
    case .serve: nil
    case .high: .clear
    case .net: .net
    case .flat: .drive
    case .defense: .power
    }
  }
}

struct Rally {
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
      if sceneBlockSize > 0 && completedInGroup >= sceneBlockSize {
        if remainingScenes.isEmpty {
          remainingScenes = CollectionScene.allCases.filter { $0 != collectionScene }.shuffled()
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
    message = servicePrompt
    nextAI = now + 0.9
  }
  var collectionScene: CollectionScene?
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
  private(set) var predictedIntercept: Position?
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
  var stroke = Stroke.lift, lastShot = Shot.clear, feedback = 0, pointCount = 0
  private var targetX = 0.0, targetY = 0.83, rivalTarget = 0.0, rivalY = 0.16
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
  mutating func tick(_ dt: Double) {
    now += dt
    func approach(_ a: Double, _ b: Double, _ speed: Double) -> Double {
      a + max(-speed * dt, min(speed * dt, b - a))
    }
    if !practice, let f = flight, f.incoming, phase == .flight,
       now >= adjustmentTime, let contact = predictedIntercept {
      adjustmentTime = .infinity
      targetX = contact.x
      targetY = min(0.98, max(0.54, contact.y + 0.045))
    }
    playerX = approach(playerX, targetX, 1.75)
    playerY = approach(playerY, targetY, 0.75)
    if now >= opponentDelay {
      opponentX = approach(opponentX, rivalTarget, 0.95 + 0.38 * Double(difficulty))
      opponentY = approach(opponentY, rivalY, 0.68)
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
        if reachable && ball.y < 0.5 && now >= nextAI { feed() } else if progress >= 1 { award(true, "空当得分") }
      }
    case .finished: break
    }
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
      let shortServe = serveLabel == "反手短发" || serveLabel == "正手短发球"
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
    let stretch = confirmedByButton ? 0 : max(dx / 0.52, dy / 0.35)
    let front = ball.y < 0.78 && ball.y <= y + 0.035
    let shortCourt = front && ball.y < 0.75
    let strength = min(1, max(0, impact?.strength ?? 0.55))
    let softLift = !neutral && kind == .lift && impact != nil && strength < 0.35
    let downward = !neutral && (kind == .smash || impact?.label == "网前扑球")
    let shot: Shot
    if armed || (confirmedByButton && strength < 0.04) {
      shot = .net
    } else if shortCourt && downward {
      shot = .smash
    } else if shortCourt && (impact?.label == "网前放网" || (softLift && ball.z >= Flight.netHeight)) {
      shot = .net
    } else if shortCourt && !neutral && kind == .lift && ball.z < Flight.netHeight {
      shot = .clear
    } else if let special = specialistShot(impact?.label, incoming: f, ball: ball) {
      shot = special
    } else if neutral || (stretch > 0.82 && !shortCourt) {
      shot = .weak
    } else if kind == .smash {
      shot = f.shot == .weak ? .power : .smash
    } else {
      shot = kind == .lift ? .clear : .drive
    }
    hits += 1
    returns += 1
    longest = max(longest, hits)
    send(shot, aim: aim, from: ball, impact: impact, netPlay: shortCourt, stretch: stretch)
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

  private mutating func send(_ shot: Shot, aim: Double, from: Position, impact: SwingImpact?, netPlay: Bool, stretch: Double) {
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
    if let impact {
      let strength = impact.strength
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
    if netPlay {
      let effort = min(1, max(0, impact?.strength ?? 0.55))
      let extensionLoss = min(1, max(0, (stretch - 0.65) / 0.35))
      let effective = effort * (1 - 0.55 * extensionLoss)
      // Choose the height at the net first, then solve the same parabola used by Flight.
      var crossingHeight = Flight.netHeight + 0.055
      switch shot {
      case .smash, .power:
        far.y = 0.34 - 0.12 * effective
        crossingHeight = from.z * (1 - (from.y - 0.5) / (from.y - far.y))
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
    }
    if let impact { arc *= 1 + 0.30 * impact.verticalSweep }
    if (shot == .smash || shot == .power) && from.z <= Flight.netHeight {
      arc = 0
    }
    flight = Flight(
      from: from, to: far, start: now, duration: speed,
      arc: arc, incoming: false, shot: shot, measured: impact != nil || netPlay || (shot == .smash && from.z <= Flight.netHeight))
    flight?.invitesAttack = netPlay && shot == .drive && stretch > 0.80
    rivalTarget = far.x
    rivalY = far.y
    opponentDelay = now + [0.42, 0.30, 0.16][difficulty]
    nextAI = now + speed * (Double.random(in: 0...1) < [0.23, 0.12, 0.05][difficulty] ? 1.1 : 0.8)
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
    let launch = Position(x: x, y: near ? playerY : opponentY, z: 0.90 * Flight.netHeight / 1.524)
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
      shot = loft >= 0.5 ? .clear : .net
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
    if let shot = collectionScene?.feed {
      let nearNet = shot == .net
      let from = Position(x: opponentX, y: opponentY, z: shot == .power ? 0.53 : 0.31)
      let to = Position(x: 0.27, y: nearNet ? 0.68 : shot == .drive ? 0.80 : 0.91)
      flight = Flight(from: from, to: to, start: now,
                      duration: shot == .power ? 0.83 : shot == .drive ? 1.03 : 1.38,
                      arc: shot == .clear ? 0.58 : 0.24, incoming: true, shot: shot)
      phase = .flight
      rivalSwing = now
      approachIncoming()
      message = "准备接球"
      return
    }
    if phase == .serve && !practice { serve(short: Bool.random(), aim: 0); return }
    let previous = flight
    let origin = previous?.at(now) ?? Position(x: opponentX, y: opponentY, z: 0.18)
    var shot: Shot =
      (previous?.shot == .weak || previous?.invitesAttack == true) ? .power : [Shot.clear, .clear, .drive, .net, .weak].randomElement()!
    if practice && drill == .clears { shot = .clear }
    if practice && drill == .flat { shot = .drive }
    let repeatNet = practice && !lessonEnabled && drill == .netTiming
    if repeatNet { shot = .net }
    if let lesson { shot = lesson.feed }
    let destination =
      practice && drill == .sides ? (playerX >= 0 ? -0.85 : 0.85) : Double.random(in: -format.halfWidth...format.halfWidth)
    let to = Position(x: lessonEnabled || repeatNet ? 0 : destination, y: shot == .net ? 0.67 : 0.91)
    let duration = (shot == .power ? 0.83 : shot == .drive ? 1.03 : 1.38) * (practice ? 1.23 : 1.0)
    flight = Flight(
      from: repeatNet ? Position(x: 0, y: 0.29, z: 0.35) : origin, to: to, start: now, duration: duration,
      arc: shot == .clear || shot == .weak ? 0.58 : 0.24, incoming: true, shot: shot)
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
    var bestScore = Double.infinity
    var intercept = flight.to
    var interceptAt = flight.start + flight.duration
    for index in 1..<60 {
      let t = flight.start + flight.duration * Double(index) / 60
      let ball = flight.at(t)
      guard t >= now, canHit(flight, at:t) else { continue }
      let height = ball.z * 1.524 / Flight.netHeight
      guard height <= Self.overheadLimit else { continue }
      let y = min(0.98, max(0.54, ball.y + 0.045))
      let travel = max(abs(ball.x-playerX)/1.75, abs(y-playerY)/0.75)
      let score = abs(height-preferredHeight) + 6*max(0,now+travel+0.20-t)
        + 1.2*abs(flight.to.y-ball.y)
      if score < bestScore { bestScore = score; intercept = ball; interceptAt = t }
    }
    predictedIntercept = intercept
    // Stage one short step behind contact, then plant the feet for the swing.
    targetX = intercept.x
    targetY = min(0.98, max(0.54, intercept.y + 0.065))
    adjustmentTime = interceptAt - 0.14
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

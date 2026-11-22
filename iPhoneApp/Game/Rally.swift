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
enum Phase { case countdown, serve, flight, point, finished }
struct Position {
  var x: Double
  var y: Double
  var z: Double = 0
}
struct Flight {
  let from, to: Position
  let start, duration, arc: Double
  let incoming: Bool
  let shot: Shot
  static let netHeight = 0.31

  private var playableArc: Double {
    let span = to.y - from.y
    guard abs(span) > 0.0001 else { return arc }
    let crossing = (0.5 - from.y) / span
    guard crossing > 0.02, crossing < 0.98 else { return arc }
    let baseHeight = from.z * (1 - crossing) + to.z * crossing
    return max(arc, (Self.netHeight + 0.025 - baseHeight) / (4 * crossing * (1 - crossing)))
  }

  func at(_ time: Double) -> Position {
    let u = min(1, max(0, (time - start) / duration))
    return Position(
      x: from.x + (to.x - from.x) * u, y: from.y + (to.y - from.y) * u,
      z: from.z * (1 - u) + to.z * u + 4 * playableArc * u * (1 - u))
  }
}
struct Rally {
  var drill = Drill.mixed
  var lessonEnabled = false
  private(set) var lessonIndex = 0
  var lesson: LessonStep? { lessonEnabled ? LessonStep(rawValue: lessonIndex) : nil }
  var lessonComplete: Bool { lessonEnabled && lessonIndex == LessonStep.allCases.count }
  var hitWindowOpen: Bool {
    guard phase == .flight, let flight, flight.incoming else { return false }
    let ball = flight.at(now)
    return canHit(flight, at: now) && abs(playerX - ball.x) < 0.38 && abs(playerY - ball.y) < 0.29
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
  var armedUntil = -1.0, swingTime = -2.0, rivalSwing = -2.0
  var stroke = Stroke.lift, lastShot = Shot.clear, feedback = 0, pointCount = 0
  private var targetX = 0.0, targetY = 0.83, rivalTarget = 0.0, rivalY = 0.16
  private var nextAI = 0.0, opponentDelay = 0.0, lockUntil = 0.0
  private var history: [(Double, Double, Double)] = []
  var armed: Bool { now < armedUntil }
  mutating func toggleNet() { if phase == .flight { armedUntil = armed ? -1 : now + 1.5 } }
  private func canHit(_ flight: Flight, at time: Double) -> Bool {
    time >= flight.start + flight.duration * (practice ? 0.51 : 0.60)
      && time <= flight.start + flight.duration
  }
  static func won(_ points: [Int]) -> Bool {
    let high = points.max() ?? 0
    return high >= 10 || (high >= 7 && abs(points[0] - points[1]) >= 2)
  }
  mutating func tick(_ dt: Double) {
    now += dt
    func approach(_ a: Double, _ b: Double, _ speed: Double) -> Double {
      a + max(-speed * dt, min(speed * dt, b - a))
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
        phase = .serve
        message = playerServes ? "轻轻上挑发球" : "准备接发球"
        nextAI = now + 0.9
      }
    case .serve:
      if !playerServes && now >= nextAI { feed() }
    case .flight:
      guard let f = flight else { return }
      let progress = (now - f.start) / f.duration
      if f.incoming {
        if progress > 1 && now > f.start + f.duration + offset + Self.maxRecognitionAge {
          let reason = ["挥早了", "挥晚了", "离球太远"].contains(message) ? message : "来球落地"
          award(false, reason)
        }
      } else if lessonEnabled {
        if progress >= 1 {
          if lessonComplete { phase = .finished } else { award(true, message) }
        }
      } else if progress >= 0.80 {
        let ball = f.at(now)
        let reachable = abs(opponentX - ball.x) < 0.41 && abs(opponentY - ball.y) < 0.18
        if reachable && now >= nextAI { feed() } else if progress >= 1 { award(true, "空当得分") }
      }
    case .finished: break
    }
  }
  mutating func swing(_ kind: Stroke, aim: Double, age: Double = 0) {
    guard now >= lockUntil, phase == .serve || phase == .flight else { return }
    if phase == .serve {
      guard playerServes, kind == .lift else { return }
      hits = 0
      stroke = kind
      swingTime = now
      send(.clear, aim: aim, from: Position(x: playerX, y: playerY, z: 0.16))
      return
    }
    guard let f = flight, f.incoming else { return }
    let at = now - offset - min(Self.maxRecognitionAge, max(0, age))
    let ball = f.at(at)
    let pos = history.last(where: { $0.0 <= at })
    stroke = kind
    swingTime = now
    lockUntil = now + 0.22
    guard canHit(f, at: at) else {
      message = at <= f.start + f.duration ? "挥早了" : "挥晚了"
      return
    }
    let dx = abs((pos?.1 ?? playerX) - ball.x)
    let dy = abs((pos?.2 ?? playerY) - ball.y)
    guard dx < 0.52, dy < 0.35 else {
      message = "离球太远"
      return
    }
    let shot: Shot
    if dx > 0.38 || dy > 0.29 {
      shot = .weak
    } else if armed {
      shot = .net
    } else if kind == .smash {
      shot = ball.z < 0.13 ? .weak : (f.shot == .weak ? .power : .smash)
    } else {
      shot = kind == .lift ? .clear : .drive
    }
    hits += 1
    returns += 1
    longest = max(longest, hits)
    send(shot, aim: aim, from: ball)
    if let step = lesson {
      if step.accepts(shot) {
        lessonIndex += 1
        message = "\(shot.rawValue)成功"
      } else {
        message = "已回球 · 再试一次指定球路"
      }
    }
  }
  mutating func replayPoint() {
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
  private mutating func send(_ shot: Shot, aim: Double, from: Position) {
    phase = .flight
    armedUntil = -1
    feedback += 1
    lastShot = shot
    message = shot.rawValue
    let far = Position(x: max(-0.91, min(0.91, aim)), y: shot == .net ? 0.35 : 0.08)
    let speed: Double
    switch shot {
    case .clear, .weak: speed = 1.4
    case .net: speed = 0.92
    case .drive: speed = 0.85
    case .smash: speed = 0.72
    case .power: speed = 0.56
    }
    flight = Flight(
      from: from, to: far, start: now, duration: speed,
      arc: shot == .clear || shot == .weak ? 0.53 : 0.19, incoming: false, shot: shot)
    rivalTarget = far.x
    rivalY = far.y
    opponentDelay = now + [0.42, 0.30, 0.16][difficulty]
    nextAI = now + speed * (Double.random(in: 0...1) < [0.23, 0.12, 0.05][difficulty] ? 1.1 : 0.8)
    targetX = 0
    targetY = 0.80
  }
  private mutating func feed() {
    let previous = flight
    let origin = previous?.at(now) ?? Position(x: opponentX, y: opponentY, z: 0.18)
    var shot: Shot =
      previous?.shot == .weak ? .power : [Shot.clear, .clear, .drive, .net, .weak].randomElement()!
    if practice && drill == .clears { shot = .clear }
    if practice && drill == .flat { shot = .drive }
    if let lesson { shot = lesson.feed }
    let destination =
      practice && drill == .sides ? (playerX >= 0 ? -0.85 : 0.85) : Double.random(in: -0.88...0.88)
    let to = Position(x: lessonEnabled ? 0 : destination, y: shot == .net ? 0.67 : 0.91)
    let duration = (shot == .power ? 0.83 : shot == .drive ? 1.03 : 1.38) * (practice ? 1.23 : 1.0)
    flight = Flight(
      from: origin, to: to, start: now, duration: duration,
      arc: shot == .clear || shot == .weak ? 0.58 : 0.24, incoming: true, shot: shot)
    phase = .flight
    rivalSwing = now
    targetX = to.x
    targetY = to.y
    rivalTarget = 0
    rivalY = 0.16
    message = shot == .weak ? "机会球 · 向下挥" : "准备接球"
  }
  private mutating func award(_ player: Bool, _ reason: String) {
    lastLanding = flight?.to
    flight = nil
    armedUntil = -1
    message = reason
    hits = 0
    pointCount += 1
    if !lessonEnabled { score[player ? 0 : 1] += 1 }
    playerServes = practice ? false : player
    phase = !practice && Self.won(score) ? .finished : .point
    deadline = now + 1.25
    targetX = 0
    rivalTarget = 0
    targetY = 0.83
    rivalY = 0.16
  }
}

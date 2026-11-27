#if DEBUG && targetEnvironment(simulator)
import Foundation

/// The game clock schedules only when to replay a recording. Its label is never passed to recognition.
final class RawSwingReplay {
  private struct Bank: Decodable { let clips: [Clip] }
  enum FixtureMode { case recorded, cued }
  private struct Fixture: Decodable {
    let from, to, feet, velocity: [Double]
    let shot: String
    let duration, arc, buttonOffset: Double
    let service: Bool?
    var valid: Bool {
      from.count == 3 && to.count == 3 && feet.count == 2 && velocity.count == 2 &&
        Shot(rawValue: shot) != nil && duration > 0 && buttonOffset > 0
    }
  }
  private struct Clip: Decodable {
    let id, role: String
    let press: Double
    let frames: [[Double]]
    let fixture: Fixture?
    var valid: Bool {
      guard !id.isEmpty, ["serve","return"].contains(role), let first = frames.first, let last = frames.last,
            frames.count >= 5, frames.allSatisfy({ $0.count == 10 && $0.allSatisfy(\.isFinite) }),
            first[0] <= press, last[0] >= press - 0.055 else { return false }
      return zip(frames, frames.dropFirst()).allSatisfy { $0[0] < $1[0] }
    }
  }
  private struct Swing {
    let clip: Clip
    let zero, button: Double
    var cursor = 0
  }

  private let serves, returns: [Clip]
  let model: ButtonSwing.ServeReadout?
  let oneBall: Bool
  private var serveIndex = 0, returnIndex = 0
  private var servingPoint: Int?
  private var returnFlight: Double?
  private var swing: Swing?
  private(set) var firstServeRelease: Double?
  private(set) var proofReady = false

  private let fixtureMode: FixtureMode?
  private let recordedTimingMatch: Bool
  private var returnIndexByShot: [String:Int] = [:]
  private var fixtureIndex = 0
  private var nextFixtureTime = 0.75
  private(set) var recordedReturnsDone = false

  init(oneBall: Bool, trained: Bool, fixtureMode: FixtureMode? = nil, recordedTimingMatch: Bool = false) throws {
    self.recordedTimingMatch = recordedTimingMatch
    self.fixtureMode = fixtureMode
    self.oneBall = oneBall
    let fileName = recordedTimingMatch ? "P040-replay.json" : fixtureMode == nil ? "P038-replay.json" : "P039-replay.json"
    let container = URL.documentsDirectory.appendingPathComponent(fileName)
    func resource(_ name: String) throws -> URL {
      guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
        throw CocoaError(.fileNoSuchFile)
      }
      return url
    }
    let source = try recordedTimingMatch || fixtureMode != nil || FileManager.default.fileExists(atPath: container.path) ? container : resource("RawSwingReplay")
    let clips = try JSONDecoder().decode(Bank.self, from: Data(contentsOf: source)).clips
    serves = clips.filter { $0.role == "serve" }
    returns = clips.filter { $0.role == "return" }
    let hasInputs = fixtureMode == nil ? !serves.isEmpty && (oneBall || !returns.isEmpty)
        : !returns.isEmpty && returns.count == clips.count && returns.allSatisfy { $0.fixture?.valid == true }
    guard clips.allSatisfy(\.valid), hasInputs else {
      throw CocoaError(.fileReadCorruptFile)
    }
    if recordedTimingMatch, !returns.allSatisfy({ $0.fixture?.valid == true }) {
      throw CocoaError(.fileReadCorruptFile)
    }
    model = trained ? try JSONDecoder().decode(ButtonSwing.ServeReadout.self, from: Data(contentsOf: resource("RawSwingButtonServes"))) : nil
    if let model {
      guard model.labels.count == 4, Set(model.labels).count == 4, model.bias.count == 4,
            model.weights.count == 4, model.weights.allSatisfy({ $0.count == 27 }) else {
        throw CocoaError(.fileReadCorruptFile)
      }
    }
  }

  func prepare(_ game: inout Rally, audit: SimulatorSinglesInput) {
    guard let fixtureMode, game.now >= nextFixtureTime, swing == nil, !recordedReturnsDone else { return }
    guard fixtureIndex < returns.count else { recordedReturnsDone = true; return }
    let clip = returns[fixtureIndex]
    fixtureIndex += 1
    guard let f = clip.fixture, let shot = Shot(rawValue: f.shot) else { return }
    func point(_ v: [Double]) -> Position { Position(x: v[0], y: v[1], z: v[2]) }
    let flight = Flight(from: point(f.from), to: point(f.to), start: game.now, duration: f.duration,
                        arc: f.arc, incoming: true, shot: shot, measured: true)
    game.replayRecordedIncoming(flight, feet: Position(x: f.feet[0], y: f.feet[1]),
                                velocity: SIMD2(f.velocity[0], f.velocity[1]), opponentServe: f.service == true)
    returnFlight = flight.start
    let original = flight.start + f.buttonOffset
    let predicted = game.predictedInterceptTime
    let button = fixtureMode == .recorded ? original : predicted
    nextFixtureTime = flight.start + max(game.flight?.duration ?? f.duration, f.buttonOffset) + 1.1
    audit.record("recordedFlight", game: game, detail: "\(clip.id) | original=\(original) | predicted=\(predicted.map { String($0) } ?? "-")")
    if let button { schedule(clip, button: button, game: game, audit: audit) }
  }

  private func schedule(_ clip: Clip, button: Double, game: Rally, audit: SimulatorSinglesInput) {
    let zero = button - clip.press
    let cursor = clip.frames.firstIndex { zero + $0[0] >= game.now - 0.000001 } ?? clip.frames.count
    swing = Swing(clip: clip, zero: zero, button: button, cursor: cursor)
    audit.record("rawStart", game: game, detail: "\(clip.id) | role=\(clip.role) | zero=\(zero) | button=\(button) | firstRow=\(cursor)")
  }

  func input(_ game: Rally, motion: MotionInput, audit: SimulatorSinglesInput) -> ButtonSwing.Hit? {
    if oneBall, let release = firstServeRelease {
      proofReady = game.now >= release + 0.55
      return nil
    }
    if swing == nil {
      guard fixtureMode == nil else { return nil }
      let clip: Clip
      let button: Double
      if game.phase == .serve, game.playerServes, servingPoint != game.pointCount, game.matchServeReady {
        clip = serves[serveIndex % serves.count]
        serveIndex += 1
        servingPoint = game.pointCount
        button = game.now + clip.press - clip.frames[0][0]
      } else if !oneBall, game.phase == .flight, let flight = game.flight, flight.incoming,
                returnFlight != flight.start {
        if recordedTimingMatch {
          // Select by visible incoming flight family, without reading the intercept,
          // racket, reach window or result. Normalize time to the archived flight;
          // assistance lengthens the live opponent serve after the reference tempo.
          let matching = returns.filter { $0.fixture?.shot == flight.shot.rawValue }
          let options = matching.isEmpty ? returns : matching
          let index = returnIndexByShot[flight.shot.rawValue, default: 0]
          clip = options[index % options.count]
          returnIndexByShot[flight.shot.rawValue] = index + 1
          guard let f = clip.fixture else { return nil }
          let referenceDuration = flight.duration - flight.receiveTempoDelay
          button = flight.start + f.buttonOffset * referenceDuration / f.duration
        } else {
          guard let intercept = game.predictedInterceptTime else { return nil }
          clip = returns[returnIndex % returns.count]
          returnIndex += 1
          button = intercept
        }
        returnFlight = flight.start
      } else { return nil }
      schedule(clip, button: button, game: game, audit: audit)
    }
    guard var active = swing else { return nil }
    let serving = game.phase == .serve && game.playerServes
    if (active.clip.role == "serve" && !serving) ||
        (active.clip.role == "return" && (game.phase != .flight || game.flight?.incoming != true || game.flight?.start != returnFlight)) {
      swing = nil
      return nil
    }
    while active.cursor < active.clip.frames.count {
      let row = active.clip.frames[active.cursor]
      let time = active.zero + row[0]
      guard time <= min(game.now, active.button) + 1e-9 else { break }
      motion.appendButtonSample(time, rotation: .init(row[1],row[2],row[3]),
                                acceleration: .init(row[4],row[5],row[6]), gravity: .init(row[7],row[8],row[9]))
      active.cursor += 1
    }
    swing = active
    guard game.now + 1e-9 >= active.button else { return nil }
    swing = nil
    let hit = motion.buttonHit(active.button, left: game.leftHanded, serving: serving)
    audit.record("rawButton", game: game, detail: "\(active.clip.id) | nextRow=\(active.cursor) | button=\(active.button) | peak=\(hit.peakTime) | recognizedServe=\(hit.recognizedServe ?? "-") | stroke=\(hit.stroke.rawValue)")
    return hit
  }

  func observe(_ game: Rally) {
    if firstServeRelease == nil, let flight = game.flight, !flight.incoming,
       flight.matchStroke?.isServe == true { firstServeRelease = flight.start }
  }
}
#endif

#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Records the same simulation steps sent to the official court renderer.
final class MatchFrameLog {
  struct Frame: Encodable {
    let frame: Int
    let hostTime, wallTime, gameTime: Double
    let receivingCueLead: Double?
    let hitWindowOpen: Bool
    let point: Int
    let score: [Int]
    let phase: String
    let ball: [Double]?
    let player, opponent: [Double]
    let stroke: String?
    let flightStart: Double?
    let flightIncoming: Bool?
    let flightOrigin, flightTarget: [Double]?
    let contact: Contact?
    let animation: Animation?
  }

  struct Animation: Encodable {
    let action, phase, surfaceMode: String
    let time, sampleTime: Double
    let racket, grip, leftFoot, rightFoot, elbow, wrist, root: [Float]
    let target: [Float]?
    let racketError: Float?
    let surfaceContact: Bool?
    let assetReady: Bool
  }

  struct Contact: Encodable {
    let racket, cork, shoulder, elbow, wrist: [Float]
    let touchesBed: Bool
  }

  static func metres(_ p: Position) -> [Double] {
    [p.x * 3.05, p.z * 1.524 / Flight.netHeight, (p.y - 0.5) * 13.4]
  }

  private let url: URL
  private let encoder = JSONEncoder()
  private var handle: FileHandle?
  private var buffer = Data()
  private(set) var frame = 0

  init(url: URL) { self.url = url }

  func start() {
    finish()
    frame = 0
    do {
      try Data().write(to: url, options: .atomic)
      handle = try FileHandle(forWritingTo: url)
    } catch {
      NSLog("Match frame log could not open: %@", error.localizedDescription)
    }
  }

  func append(_ game: Rally, sample: CourtContactSample?, animation: MatchAnimationAudit?, hostTime: Double) {
    guard handle != nil else { return }
    frame += 1
    let flight = game.flight
    let contact = sample.map {
      Contact(racket: Self.components($0.bedCenter), cork: Self.components($0.corkCenter),
              shoulder: Self.components($0.shoulder), elbow: Self.components($0.elbow),
              wrist: Self.components($0.wrist), touchesBed: $0.touchesBed)
    }
    let pose = animation.map {
      Animation(action: $0.action, phase: $0.phase, surfaceMode: $0.surfaceMode,
                time: $0.time, sampleTime: $0.sampleTime,
                racket: Self.components($0.racketCenter), grip: Self.components($0.grip),
                leftFoot: Self.components($0.leftFoot), rightFoot: Self.components($0.rightFoot),
                elbow: Self.components($0.elbow), wrist: Self.components($0.wrist),
                root: Self.components($0.root), target: $0.target.map(Self.components),
                racketError: $0.racketError, surfaceContact: $0.surfaceContact, assetReady: $0.assetReady)
    }
    let row = Frame(frame: frame, hostTime: hostTime, wallTime: Date().timeIntervalSince1970,
                    gameTime: game.now, receivingCueLead: game.receivingCueLead, hitWindowOpen: game.hitWindowOpen,
                    point: game.pointCount, score: game.score,
                    phase: String(describing: game.phase),
                    ball: flight.map { Self.metres($0.at(game.now)) },
                    player: Self.metres(Position(x: game.playerX, y: game.playerY)),
                    opponent: Self.metres(Position(x: game.opponentX, y: game.opponentY)),
                    stroke: flight?.matchStroke?.rawValue, flightStart: flight?.start,
                    flightIncoming: flight?.incoming, flightOrigin: flight.map { Self.metres($0.from) },
                    flightTarget: flight.map { Self.metres($0.to) }, contact: contact, animation: pose)
    if let data = try? encoder.encode(row) {
      buffer.append(data)
      buffer.append(10)
    }
    if frame.isMultiple(of: 60) { flush() }
  }

  func finish() {
    flush()
    try? handle?.close()
    handle = nil
  }

  private static func components(_ value: SIMD3<Float>) -> [Float] {
    [value.x, value.y, value.z]
  }

  private func flush() {
    guard let handle, !buffer.isEmpty else { return }
    do {
      try handle.write(contentsOf: buffer)
    } catch {
      NSLog("Match frame log could not write: %@", error.localizedDescription)
    }
    buffer.removeAll(keepingCapacity: true)
  }
}
#endif

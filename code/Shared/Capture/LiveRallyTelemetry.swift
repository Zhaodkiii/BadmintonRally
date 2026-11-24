import Foundation

struct LiveRallyTelemetry: Codable {
  struct State: Codable {
    let gameTime: Double
    let phase: String
    let score: [Int]
    let playerX, playerY, opponentX, opponentY: Double
    let flight: Flight?
    let hitWindowOpen: Bool
    let displayOffset: Double
    let message: String
    let input: String
    let mode: String
    let difficulty: Int
    let leftHand: Bool
    let lightSwing: Bool
    let curveVersion: String
  }

  struct Flight: Codable {
    let shot: String
    let incoming: Bool
    let start, duration, arc: Double
    let from, to, position: [Double]
  }

  struct Contact: Codable {
    let trial: Int
    let scenario, intendedReply, targetLane, targetDepth: String
    let incoming: Flight
    let ball, player, incomingVelocity: [Double]
    let area: String
    let heightAboveNetMeters, strength, vertical, lateral: Double
    let beforeNet, outsideReach: Bool
    let outgoing: Flight
    var observedReply: String? = nil
    var power, sweep, braking: Double?
    var onBackhandSide, overheadByPosition, estimatedBackhand: Bool?
    var predictedNetHit: Bool?
  }

  struct Event: Codable {
    let time: Double
    let kind: String
    let text: String
    var aim: Double? = nil
    var peakTime: Double? = nil
    var recognizedAt: Double? = nil
    var gameTime: Double? = nil
    var judgedAt: Double? = nil
    var accepted: Bool? = nil
    var candidateGame: String? = nil
    var curve: String? = nil
    var curveScore: Double? = nil
    var curveMargin: Double? = nil
    var contact: Contact? = nil
  }

  struct Tick: Codable {
    let time, gameTime, delta: Double
    let playerX, playerY, opponentX, opponentY: Double
    let ball: [Double]?
  }
  var ticks: [Tick]?
  let schema = 1
  let match: UUID
  let sequence: Int
  let phoneTime: Double
  let state: State
  let frames: [MotionRow]
  let events: [Event]

  private enum CodingKeys: String, CodingKey {
    case match, sequence, phoneTime, state, frames, events, schema, ticks
  }

  init(match: UUID, sequence: Int, phoneTime: Double, state: State, frames: [MotionRow], events: [Event]) {
    self.match = match
    self.sequence = sequence
    self.phoneTime = phoneTime
    self.state = state
    self.frames = frames
    self.events = events
  }

  init(from decoder: Decoder) throws {
    let data = try decoder.container(keyedBy: CodingKeys.self)
    guard try data.decode(Int.self, forKey: .schema) == schema else {
      throw DecodingError.dataCorruptedError(forKey: .schema, in: data, debugDescription: "Unsupported live rally schema")
    }
    match = try data.decode(UUID.self, forKey: .match)
    sequence = try data.decode(Int.self, forKey: .sequence)
    phoneTime = try data.decode(Double.self, forKey: .phoneTime)
    ticks = try data.decodeIfPresent([Tick].self, forKey: .ticks)
    state = try data.decode(State.self, forKey: .state)
    frames = try data.decode([MotionRow].self, forKey: .frames)
    events = try data.decode([Event].self, forKey: .events)
  }
}

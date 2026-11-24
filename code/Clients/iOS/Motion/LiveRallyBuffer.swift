#if DEBUG
import UIKit

// Both sensor delivery and simulation callbacks run on the main thread.
final class LiveRallyBuffer {
  var active = false
  private(set) var sentAt = 0.0
  private(set) var match = UUID()
  let screen = CourtStream()
  private var sequence = 0
  private var frames: [MotionRow] = []
  var simulation: [LiveRallyTelemetry.Tick] = []
  private var events: [LiveRallyTelemetry.Event] = []

  func reset() {
    active = false
    match = UUID()
    sentAt = 0
    sequence = 0
    simulation.removeAll(keepingCapacity: true)
    frames.removeAll(keepingCapacity: true)
    events.removeAll(keepingCapacity: true)
  }

  func add(_ frame: MotionRow) {
    if frames.count == 150 { frames.removeFirst() }
    frames.append(frame)
  }

  func add(_ event: LiveRallyTelemetry.Event) {
    if events.count == 100 { events.removeFirst() }
    events.append(event)
  }

  func take(at time: Double, state: LiveRallyTelemetry.State) -> LiveRallyTelemetry {
    var packet = LiveRallyTelemetry(match: match, sequence: sequence, phoneTime: time,
      state: state, frames: frames, events: events)
    packet.ticks = simulation
    sequence += 1
    sentAt = time
    simulation.removeAll(keepingCapacity: true)
    frames.removeAll(keepingCapacity: true)
    events.removeAll(keepingCapacity: true)
    return packet
  }
}
#endif

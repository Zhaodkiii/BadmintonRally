import CoreMotion

/// Configure subscriptions on main; deliver every sample on a serial sensor queue.
final class DeviceMotionSource {
  static let shared = DeviceMotionSource()
  private let manager = CMMotionManager()
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    return q
  }()
  typealias Sink = (CMDeviceMotion?, Error?) -> Void
  private let lock = NSLock()
  private var sinks: [String: Sink] = [:]
  var available: Bool { manager.isDeviceMotionAvailable }
  func subscribe(_ key: String, _ sink: @escaping Sink) {
    lock.lock()
    let first = sinks.isEmpty
    sinks[key] = sink
    lock.unlock()
    guard first else { return }
    manager.deviceMotionUpdateInterval = 0.01
    manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) {
      [weak self] data, error in
      guard let self else { return }
      self.lock.lock()
      let callbacks = Array(self.sinks.values)
      self.lock.unlock()
      callbacks.forEach { $0(data, error) }
    }
  }
  func remove(_ key: String) {
    lock.lock()
    sinks[key] = nil
    let empty = sinks.isEmpty
    lock.unlock()
    if empty { manager.stopDeviceMotionUpdates() }
  }
}

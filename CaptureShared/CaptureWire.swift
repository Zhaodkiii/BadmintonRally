import CryptoKit
import Foundation
import Network
import Security

enum CaptureMessage: Codable {
  case hello(device: String, system: String, build: String, pending: UUID?)
  case panel(TrialPanel), command(UUID,TrialCommand), notice(String)
  case ping(Double)
  case pong(Double, Double, Double)
  case start(UUID)
  case stop(UUID)
  case resume(UUID, Int)
  case batch(UUID, Int, [MotionRow])
  case ack(UUID, Int)
  case end(UUID, Int, String)
  case finished(UUID)
  case cue(UUID, String)
  case event(UUID, Double, String)
  case error(String)
}
struct PhoneEvent: Codable { let t: Double, name: String }
struct MotionRow: Codable {
  var events: [PhoneEvent]? = nil
  let t: Double
  let v: [Double]  // rotation, user acceleration, gravity, quaternion xyzw
}

final class CaptureWire {
  static let service = "_brcapture._tcp"
  static func parameters(_ secret: String) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    let key = SHA256.hash(data: Data(("BadmintonRally capture v1/" + secret).utf8))
    let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = Data("br-capture-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(
      options, psk as __DispatchData, identity as __DispatchData)
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_append_tls_ciphersuite(
      options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWParameters(tls: tls, tcp: tcp)
  }
  private let connection: NWConnection
  private let queue: DispatchQueue
  var message: (CaptureMessage) -> Void = { _ in }
  var state: (Bool) -> Void = { _ in }
  private var stopped = false
  init(_ connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }
  func start() {
    connection.stateUpdateHandler = { [weak self] value in
      guard let self, !self.stopped else { return }
      switch value {
      case .ready:
        self.state(true)
        self.read(4, header: true)
      case .failed, .cancelled: self.close()
      default: break
      }
    }
    connection.start(queue: queue)
  }
  func close() {
    guard !stopped else { return }
    stopped = true
    connection.cancel()
    state(false)
  }
  func send(_ packet: CaptureMessage) {
    guard !stopped, let data = try? JSONEncoder().encode(packet) else { return }
    var n = UInt32(data.count).bigEndian
    var framed = withUnsafeBytes(of: &n) { Data($0) }
    framed.append(data)
    connection.send(
      content: framed,
      completion: .contentProcessed { [weak self] err in if err != nil { self?.close() } })
  }
  private func read(_ size: Int, header: Bool) {
    connection.receive(minimumIncompleteLength: size, maximumLength: size) {
      [weak self] data, _, _, _ in
      guard let self, !self.stopped else { return }
      guard let data, data.count == size else {
        self.close()
        return
      }
      if header {
        let n = data.reduce(0) { $0 * 256 + Int($1) }
        guard (1...262144).contains(n) else {
          self.close()
          return
        }
        self.read(n, header: false)
      } else if let packet = try? JSONDecoder().decode(CaptureMessage.self, from: data) {
        self.message(packet)
        self.read(4, header: true)
      } else {
        self.close()
      }
    }
  }
}

import CoreBluetooth
import CryptoKit
import SwiftUI

final class NearbyPhone: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate
{
  @Published var status = ""
  @Published var names: [UUID: String] = [:]
  private var central: CBCentralManager?, found: [UUID: CBPeripheral] = [:], peer: CBPeripheral?,
    reply: CBCharacteristic?
  private var mine = Curve25519.KeyAgreement.PrivateKey(), deadline = Date.distantPast
  private var expected: Data?
  func browse() {
    if central == nil {
      central = CBCentralManager(delegate: self, queue: .main)
    } else if let central {
      centralManagerDidUpdateState(central)
    }
  }
  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    guard c.state == .poweredOn else {
      status = "蓝牙不可用，可手输密钥连接"
      return
    }
    c.scanForPeripherals(withServices: [NearbyPairing.service])
    status = "查找附近的采集工作台"
  }
  func centralManager(
    _ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    found[p.identifier] = p
    names[p.identifier] = p.name ?? "RallyCapture"
  }
  func pair(_ id: UUID) {
    guard let p = found[id] else { return }
    if let peer { central?.cancelPeripheralConnection(peer) }
    central?.stopScan()
    peer = p
    reply = nil
    expected = nil
    mine = .init()
    deadline = Date().addingTimeInterval(90)
    p.delegate = self
    central?.connect(p)
  }
  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    p.discoverServices([NearbyPairing.service])
  }
  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    status = "蓝牙连接失败，请重新查找"
  }
  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    if let s = p.services?.first {
      p.discoverCharacteristics([NearbyPairing.hello, NearbyPairing.reply], for: s)
    }
  }
  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    reply = s.characteristics?.first { $0.uuid == NearbyPairing.reply }
    if let c = s.characteristics?.first(where: { $0.uuid == NearbyPairing.hello }) {
      p.writeValue(mine.publicKey.rawRepresentation, for: c, type: .withResponse)
    }
  }
  func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
    if let error {
      status = error.localizedDescription
      return
    }
    if let reply { p.readValue(for: reply) }
  }
  func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    guard p === peer, c.uuid == NearbyPairing.reply else { return }
    do {
      guard let d = c.value, d.count >= 32, error == nil, Date() < deadline else {
        throw PairFailure.expired
      }
      let pub = Data(d.prefix(32))
      if let expected, expected != pub { throw PairFailure.expired }
      expected = pub
      let key = try NearbyPairing.key(mine, pub)
      if d.count == 32 {
        status = "核对码 " + NearbyPairing.code(key) + " · 请在 Mac 确认"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
          if self?.peer === p, p.state == .connected { p.readValue(for: c) }
        }
      } else {
        let raw = try ChaChaPoly.open(.init(combined: d.dropFirst(32)), using: key)
        let ticket = try JSONDecoder().decode(NearbyPairing.Ticket.self, from: raw)
        StudioSender.shared.browse()
        StudioSender.shared.connect(ticket.host, code: ticket.secret)
        status = "已交换本次密钥"
        central?.cancelPeripheralConnection(p)
        peer = nil
      }
    } catch {
      status = "配对已过期或被拒绝，请重试"
      central?.cancelPeripheralConnection(p)
      peer = nil
    }
  }
  enum PairFailure: Error { case expired }
}

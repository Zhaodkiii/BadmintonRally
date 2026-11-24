import CoreBluetooth
import CryptoKit
import SwiftUI

final class NearbyHost: NSObject, ObservableObject, CBPeripheralManagerDelegate {
  @Published var message = ""
  @Published var code: String?
  private var peripheral: CBPeripheralManager?
  private var ticket: NearbyPairing.Ticket?
  private var client: UUID?, publicKey = Data(), sealed = Data()
  private var key: SymmetricKey?, expires = Date.distantPast
  func enable(host: String, secret: String) {
    ticket = .init(host: host, secret: secret)
    if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: .main) }
  }
  func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
    guard p.state == .poweredOn else {
      reset()
      message = "蓝牙不可用，可使用局域网密钥连接"
      return
    }
    let s = CBMutableService(type: NearbyPairing.service, primary: true)
    s.characteristics = [
      CBMutableCharacteristic(
        type: NearbyPairing.hello, properties: .write, value: nil, permissions: .writeable),
      CBMutableCharacteristic(
        type: NearbyPairing.reply, properties: .read, value: nil, permissions: .readable),
    ]
    p.add(s)
  }
  func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    if let error {
      message = error.localizedDescription
      return
    }
    p.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [NearbyPairing.service],
      CBAdvertisementDataLocalNameKey: "RallyCapture",
    ])
    message = "请在 iPhone 点蓝牙查找"
  }
  func reset() {
    code = nil
    client = nil
    key = nil
    publicKey = Data()
    sealed = Data()
  }
  func approve() {
    guard let key, let ticket, Date() < expires else {
      reset()
      return
    }
    do {
      sealed = try ChaChaPoly.seal(JSONEncoder().encode(ticket), using: key).combined
      code = nil
      message = "已允许手机获取本次连接信息"
    } catch { message = error.localizedDescription }
  }
  func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let r = requests.first else { return }
    guard requests.count == 1, r.characteristic.uuid == NearbyPairing.hello, r.offset == 0,
      let remote = r.value, remote.count == 32
    else {
      p.respond(to: r, withResult: .invalidPdu)
      return
    }
    if code != nil, client != r.central.identifier, Date() < expires {
      p.respond(to: r, withResult: .insufficientAuthorization)
      return
    }
    do {
      let mine = Curve25519.KeyAgreement.PrivateKey()
      let k = try NearbyPairing.key(mine, remote)
      client = r.central.identifier
      key = k
      publicKey = mine.publicKey.rawRepresentation
      sealed = Data()
      code = NearbyPairing.code(k)
      expires = Date().addingTimeInterval(90)
      message = "核对两端数字后一致才允许"
      p.respond(to: r, withResult: .success)
    } catch { p.respond(to: r, withResult: .invalidPdu) }
  }
  func peripheralManager(_ p: CBPeripheralManager, didReceiveRead r: CBATTRequest) {
    guard r.central.identifier == client, Date() < expires,
      r.characteristic.uuid == NearbyPairing.reply
    else {
      p.respond(to: r, withResult: .insufficientAuthorization)
      return
    }
    let data = publicKey + sealed
    guard r.offset <= data.count else {
      p.respond(to: r, withResult: .invalidOffset)
      return
    }
    r.value = data.subdata(in: r.offset..<data.count)
    p.respond(to: r, withResult: .success)
  }
}

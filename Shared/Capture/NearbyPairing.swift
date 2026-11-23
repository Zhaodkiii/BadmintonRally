import CoreBluetooth
import CryptoKit
import Foundation

enum NearbyPairing {
  static let service = CBUUID(string: "760B173A-DA6B-4E07-A37C-70EDCC195730")
  static let hello = CBUUID(string: "760B173B-DA6B-4E07-A37C-70EDCC195730")
  static let reply = CBUUID(string: "760B173C-DA6B-4E07-A37C-70EDCC195730")
  struct Ticket: Codable { let host: String, secret: String }
  static func key(_ mine: Curve25519.KeyAgreement.PrivateKey, _ peer: Data) throws -> SymmetricKey {
    let shared = try mine.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peer))
    return shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: Data("RallyCapture BLE 1".utf8), sharedInfo: Data(),
      outputByteCount: 32)
  }
  static func code(_ key: SymmetricKey) -> String {
    let hash = HMAC<SHA256>.authenticationCode(for: Data("compare".utf8), using: key)
    return String(
      format: "%06u", hash.prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) } % 1_000_000)
  }
}

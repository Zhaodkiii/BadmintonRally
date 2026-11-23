import CryptoKit
import Foundation
import Security

struct DiagnosticChunk: Codable {
  static let chunkSize = 96 * 1024
  static let maximumSize = 16 * 1024 * 1024
  let id: UUID
  let offset, total: Int
  let digest: String
  let bytes: Data

  static func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

enum CaptureTrust {
  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "com.daokaihua.badmintonrally.capture",
     kSecAttrAccount as String: account]
  }

  static func read(_ account: String) -> Data? {
    var request = query(account)
    request[kSecReturnData as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  @discardableResult
  static func save(_ data: Data, as account: String) -> Bool {
    let request = query(account)
    let values = [kSecValueData as String: data]
    let updated = SecItemUpdate(request as CFDictionary, values as CFDictionary)
    if updated == errSecSuccess { return true }
    guard updated == errSecItemNotFound else { return false }
    return SecItemAdd(request.merging(values) { _, value in value } as CFDictionary, nil) == errSecSuccess
  }

  static func forget(_ account: String) {
    SecItemDelete(query(account) as CFDictionary)
  }
}

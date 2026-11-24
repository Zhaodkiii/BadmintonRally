import CryptoKit
import Foundation

struct ServeValidation: Codable {
  struct Trial: Codable {
    let number: Int
    let contactTime: Double
    let prediction: String
    var actual: String?
    var outcome: String?
    var discarded = false
  }

  let id: UUID
  let started: Date
  let model: String
  var trials: [Trial] = []
  static let strokes = ServeTraining.allCases.filter { $0 != .free }.map(\.rawValue)
  init() {
    id = UUID()
    started = Date()
    if let url = Bundle.main.url(forResource: "ButtonServes", withExtension: "json"),
       let bytes = try? Data(contentsOf: url) {
      model = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    } else { model = "unavailable" }
  }
  var pending: Bool { trials.last.map { $0.actual == nil && !$0.discarded } ?? false }
  var complete: Bool { Self.strokes.allSatisfy { counts($0).count >= 5 } }
  func counts(_ stroke: String) -> [Trial] { trials.filter { $0.actual == stroke } }
  func save() throws {
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("发球识别验证")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONEncoder().encode(self).write(to: folder.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
  }
}

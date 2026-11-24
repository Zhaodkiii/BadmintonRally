import Foundation

struct MotionTestTrace: Codable {
  struct Frame: Codable {
    let time: Double
    let rotation, acceleration, gravity, quaternion: [Double]
    let armed, tracking: Bool
    let trigger, gripSimilarity: Double?
  }

  struct Event: Codable {
    let time: Double
    let kind, text: String
    var round: Int? = nil
    var end: Double? = nil
    var outputTime: Double? = nil
    var game: String? = nil
    var curve: String? = nil
    var score: Double? = nil
    var margin: Double? = nil
    var directionScore: Double? = nil
    var directionMargin: Double? = nil
  }

  var schema = 1
  var id = UUID().uuidString
  var started = Date()
  let target, hand, curveVersion: String
  let light, assist: Bool
  var appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
  var state = "in_progress"
  var frames: [Frame] = []
  var events: [Event] = []

  static func directory() throws -> URL {
    try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appendingPathComponent("MotionTestDiagnostics", isDirectory: true)
  }

  static func archived() -> [URL] {
    guard let folder = try? directory() else { return [] }
    return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  func save() throws -> URL {
    let folder = try Self.directory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "-")
    let url = folder.appendingPathComponent("\(stamp)-\(target)-\(id).json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(self).write(to: url, options: .atomic)
    return url
  }
}

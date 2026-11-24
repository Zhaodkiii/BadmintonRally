import Foundation

struct SavedDiagnostic: Decodable, Identifiable {
  let id: UUID
  let target, state: String
  let started: Date
  let events: [DiagnosticEvent]

  struct DiagnosticEvent: Decodable {
    let kind, text: String
  }

  var result: String {
    let rounds = events.filter { $0.kind == "result" }
    let matches = rounds.filter { $0.text.hasPrefix("识别一致 ·") }.count
    return rounds.isEmpty ? "无已评分挥拍" : "\(matches)/\(rounds.count) 拍识别一致"
  }

  static func read(_ data: Data) throws -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Self.self, from: data)
  }
}

final class DiagnosticInbox {
  private var pending: DiagnosticChunk?
  private var data = Data()

  func reset() { pending = nil; data = Data() }

  func receive(_ chunk: DiagnosticChunk, directory: URL) throws -> SavedDiagnostic? {
    guard (1...DiagnosticChunk.maximumSize).contains(chunk.total),
          (0..<chunk.total).contains(chunk.offset),
          (1...DiagnosticChunk.chunkSize).contains(chunk.bytes.count),
          chunk.bytes.count <= chunk.total - chunk.offset else { throw corrupt() }
    if chunk.offset == 0 { reset(); pending = chunk }
    guard let pending, pending.id == chunk.id, pending.total == chunk.total,
          pending.digest == chunk.digest, chunk.offset == data.count else { throw corrupt() }
    data.append(chunk.bytes)
    guard data.count == chunk.total else { return nil }
    defer { reset() }
    guard DiagnosticChunk.checksum(data) == chunk.digest else { throw corrupt() }
    let summary = try SavedDiagnostic.read(data)
    guard summary.id == chunk.id,
          ["complete", "interrupted", "in_progress"].contains(summary.state) else { throw corrupt() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(chunk.id.uuidString).appendingPathExtension("json")
    if FileManager.default.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url) == data else {
        throw NSError(domain: "RallyCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "相同场次已有不同内容，请保留手机原文件"])
      }
    } else {
      try data.write(to: url, options: .atomic)
    }
    return summary
  }

  private func corrupt() -> NSError {
    NSError(domain: "RallyCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试文件校验失败"])
  }
}

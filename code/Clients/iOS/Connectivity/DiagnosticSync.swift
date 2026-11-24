import Foundation

/// Owned by StudioSender and used only on its serial network queue.
final class DiagnosticSync {
  private struct Checkpoint: Decodable { let state: String }
  private var urls: [URL] = []
  private(set) var active: (id: UUID, url: URL, digest: String, attempt: UUID)?

  var count: Int { urls.count }

  func enqueueArchived(_ url: URL) {
    guard !FileManager.default.fileExists(atPath: receipt(for: url).path),
          let data = try? Data(contentsOf: url),
          let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
          checkpoint.state == "complete" || checkpoint.state == "interrupted" else { return }
    enqueue(url)
  }

  func enqueue(_ url: URL) {
    guard !FileManager.default.fileExists(atPath: receipt(for: url).path), !urls.contains(url) else { return }
    urls.append(url)
  }

  func disconnected() { active = nil }

  func pump(send: (CaptureMessage) -> Void) throws -> UUID? {
    guard active == nil, let url = urls.first else { return nil }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= DiagnosticChunk.maximumSize,
          let id = UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.suffix(36))) else {
      urls.removeFirst()
      throw CocoaError(.fileReadCorruptFile)
    }
    let data = try Data(contentsOf: url)
    let digest = DiagnosticChunk.checksum(data)
    let attempt = UUID()
    active = (id, url, digest, attempt)
    for offset in stride(from: 0, to: data.count, by: DiagnosticChunk.chunkSize) {
      let end = min(data.count, offset + DiagnosticChunk.chunkSize)
      send(.diagnostic(.init(id: id, offset: offset, total: data.count, digest: digest,
                             bytes: data.subdata(in: offset..<end))))
    }
    return attempt
  }

  func acknowledge(_ id: UUID, digest: String, error: String?) throws -> Bool {
    guard let active, active.id == id, active.digest == digest else { return false }
    self.active = nil
    if let error { throw NSError(domain: "RallyCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
    try Data(digest.utf8).write(to: receipt(for: active.url), options: .atomic)
    urls.removeAll { $0 == active.url }
    return true
  }

  private func receipt(for url: URL) -> URL { url.appendingPathExtension("synced") }
}

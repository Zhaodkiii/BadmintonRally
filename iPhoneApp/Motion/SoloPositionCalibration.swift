import Foundation

/// Single-phone captures have orientation evidence, without a camera observing the wrist.
final class SoloPositionCalibration {
  let id = UUID()
  private let file: FileHandle
  private let folder: URL
  private var rows: [MotionRow] = [], baseline: PositionRecord?, lastCheck = -Double.infinity
  private(set) var step = 0
  private var records: [PositionRecord] = []
  private var batch = ""
  let prompt: String, hand: String
  let speed: CaptureSpeed
  init(folder: URL, prompt: String, hand: String, speed: CaptureSpeed = .normal) throws {
    self.folder = folder
    self.prompt = prompt
    self.hand = hand
    self.speed = speed
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let raw = folder.appendingPathComponent(id.uuidString + ".calibration.csv")
    try Data("t_phone,step,rx,ry,rz,ax_g,ay_g,az_g,gx,gy,gz,qx,qy,qz,qw\n".utf8).write(to: raw)
    file = try FileHandle(forWritingTo: raw)
    try file.seekToEnd()
  }
  func feed(_ row: MotionRow) throws -> String? {
    rows.append(row)
    rows.removeAll { $0.t < row.t - 1.1 }
    batch +=
      ([String(row.t), String(step)] + row.v.map { String($0) }).joined(separator: ",") + "\n"
    guard row.t - lastCheck >= 0.12 else { return nil }
    lastCheck = row.t
    try flush()
    do {
      let r = try PositionGate.evaluate(
        step: step, rows: rows, base: baseline, wrist: nil, manual: true)
      let measured = PositionRecord(
        version: r.version, step: r.step, target: r.target, start: r.start, end: r.end,
        gravity: r.gravity, quaternion: r.quaternion, reference: r.reference,
        evidence: "phone_orientation_only", wrist: nil, baseWrist: nil)
      if step == 0 { baseline = measured }
      records.append(measured)
      step += 1
      rows = []
      return ""
    } catch { return error.localizedDescription }
  }
  private func flush() throws {
    try file.write(contentsOf: Data(batch.utf8))
    batch = ""
  }
  func finish(_ reason: String) throws {
    try flush()
    try file.close()
    struct Summary: Codable {
      let speed: CaptureSpeed
      let session: UUID, prompt: String, hand: String, reason: String, targets: [PositionTarget],
        records: [PositionRecord]
    }
    try JSONEncoder().encode(
      Summary(
        speed: speed, session: id, prompt: prompt, hand: hand, reason: reason,
        targets: PositionTarget.all,
        records: records)
    )
    .write(to: folder.appendingPathComponent(id.uuidString + ".calibration.json"), options: .atomic)
  }
}

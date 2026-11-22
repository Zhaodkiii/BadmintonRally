import CryptoKit
import Foundation

struct CaptureFailure: LocalizedError {
  let text: String
  init(_ text: String) { self.text = text }
  var errorDescription: String? { text }
}
struct ClockPoint: Codable {
  let m0, p1, p2, m3: Double
  var phone: Double { (p1 + p2) / 2 }
  var host: Double { (m0 + m3) / 2 }
  var rtt: Double { m3 - m0 - (p2 - p1) }
}
struct ClockMap {
  let points: [ClockPoint]
  func host(_ phone: Double) -> Double? {
    // Lowest-RTT observation in each 10 s window limits queueing bias.
    let valid = points.filter { $0.rtt >= 0 && $0.rtt < 0.25 }
    let anchors = Dictionary(grouping: valid, by: { Int($0.host / 10) }).compactMap {
      $0.value.min(by: { $0.rtt < $1.rtt })
    }.sorted { $0.phone < $1.phone }
    guard let first = anchors.first else { return nil }
    guard let last = anchors.last, last.phone - first.phone > 10 else {
      return phone + (first.host - first.phone)
    }
    let meanX = anchors.map { $0.phone - first.phone }.reduce(0, +) / Double(anchors.count)
    let meanY = anchors.map { $0.host - first.host }.reduce(0, +) / Double(anchors.count)
    var xx = 0.0
    var xy = 0.0
    for a in anchors {
      let x = a.phone - first.phone - meanX
      xx += x * x
      xy += x * (a.host - first.host - meanY)
    }
    let slope = xy / xx
    guard (0.998...1.002).contains(slope) else { return nil }
    return first.host + meanY + slope * (phone - first.phone - meanX)
  }
}
struct SessionInfo: Codable, Sendable {
  var schema = 1
  let id: UUID, participant: String, hand: String, grip: String, prompt: String, device: String,
    system: String, build: String, created: Date
  var state = "partial", reason = "open"
  var speed: CaptureSpeed?
}
struct StudioEvent: Codable { let text: String, time: Double, clock: String }
struct TrialLabel: Codable {
  let id: UUID, label: String, start: Double, end: Double, created: Date
}
struct ActionWindow: Codable {
  let session_id: UUID, prompt: String, mac_begin: Double, mac_end: Double,
    video_begin_s: Double?, video_end_s: Double?, label_status: String
  var speed: CaptureSpeed?
}

final class CaptureArchive {
  let dir: URL
  let readOnly: Bool
  var info: SessionInfo
  private(set) var next = 0
  private(set) var samples = 0
  private(set) var clocks: [ClockPoint] = []
  var labels: [TrialLabel] { (try? readLines("labels.jsonl", TrialLabel.self)) ?? [] }
  static func csv(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
  init(root: URL, info: SessionInfo) throws {
    self.info = info
    readOnly = false
    dir = root.appendingPathComponent(info.id.uuidString)
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("batches"), withIntermediateDirectories: true)
    try saveInfo()
  }
  init(open dir: URL, readOnly: Bool = false) throws {
    self.dir = dir
    let snapshot = FileManager.default.fileExists(atPath: dir.appendingPathComponent("checksums.json").path)
    self.readOnly = readOnly || snapshot
    info = try JSONDecoder().decode(
      SessionInfo.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
    clocks = try readLines("clocks.jsonl", ClockPoint.self)
    if self.readOnly {
      if let data = try? Data(contentsOf: target("quality.json")),
        let quality = try? JSONDecoder().decode([String: Int].self, from: data) { samples = quality["samples"] ?? 0 }
      return
    }
    let files = try FileManager.default.contentsOfDirectory(
      atPath: dir.appendingPathComponent("batches").path)
    for i in 0..<files.count {
      let block = try block(at: i)
      samples += block.count
      next += 1
    }
  }
  private func target(_ name: String) -> URL { dir.appendingPathComponent(name) }
  func saveInfo() throws {
    try JSONEncoder().encode(info).write(to: target("manifest.json"), options: .atomic)
  }
  func appendLine<T: Encodable>(_ name: String, _ obj: T) throws {
    var data = try JSONEncoder().encode(obj)
    data.append(10)
    let url = target(name)
    if !FileManager.default.fileExists(atPath: url.path) {
      try data.write(to: url, options: .atomic)
      return
    }
    let f = try FileHandle(forWritingTo: url)
    defer { try? f.close() }
    try f.seekToEnd()
    try f.write(contentsOf: data)
  }
  private func readLines<T: Decodable>(_ name: String, _ type: T.Type) throws -> [T] {
    guard FileManager.default.fileExists(atPath: target(name).path) else { return [] }
    return try Data(contentsOf: target(name)).split(separator: 10).map {
      try JSONDecoder().decode(type, from: Data($0))
    }
  }
  func clock(_ point: ClockPoint) throws {
    try appendLine("clocks.jsonl", point)
    clocks.append(point)
  }
  func event(_ text: String, at t: Double, domain: String) throws {
    try appendLine("events.jsonl", StudioEvent(text: text, time: t, clock: domain))
  }
  func allEvents() throws -> [StudioEvent] {
    if readOnly, FileManager.default.fileExists(atPath: target("all_events.json").path) {
      return try JSONDecoder().decode([StudioEvent].self, from: Data(contentsOf: target("all_events.json")))
    }
    var result = try readLines("events.jsonl", StudioEvent.self)
    for i in 0..<next {
      for row in try block(at: i) {
        for e in row.events ?? [] {
          result.append(StudioEvent(text: e.name, time: e.t, clock: "phone"))
        }
      }
    }
    return result
  }
  private func block(at i: Int) throws -> [MotionRow] {
    try JSONDecoder().decode([MotionRow].self, from: Data(contentsOf: target("batches/\(i).json")))
  }
  func accept(_ index: Int, _ rows: [MotionRow]) throws {
    guard index >= 0 else { throw CaptureFailure("无效批次序号") }
    if index < next { return }
    guard index == next, !rows.isEmpty, rows.count <= 100,
      rows.allSatisfy({ $0.v.count == 13 && $0.t.isFinite })
    else { throw CaptureFailure("无效运动批次") }
    try JSONEncoder().encode(rows).write(to: target("batches/\(index).json"), options: .atomic)
    next += 1
    samples += rows.count
  }
  func annotate(_ label: String, start: Double, end: Double, id: UUID = UUID()) throws {
    guard !readOnly else { throw CaptureFailure("训练包可查看。请在原始场次修订标注。") }
    guard start >= 0, end > start, !label.isEmpty else { throw CaptureFailure("请选择有效的视频区间和实际动作") }
    try appendLine(
      "labels.jsonl", TrialLabel(id: id, label: label, start: start, end: end, created: Date()))
    try exportIndex()
  }
  private var videoOrigin: Double? {
    guard let f = try? FileHandle(forReadingFrom: target("frames.csv")) else { return nil }
    defer { try? f.close() }
    guard let data = try? f.read(upToCount: 2048), let text = String(data: data, encoding: .utf8),
      let row = text.split(separator: "\n").dropFirst().first
    else { return nil }
    let v = row.split(separator: ",")
    guard v.count == 5, let t = Double(v[4]), let s = Double(v[3]) else { return nil }
    return t - s
  }
  func exportIndex() throws {
    let origin = videoOrigin
    let map = ClockMap(points: clocks)
    // The fitted mapping is affine. Evaluate once for this dataset, then apply per sample.
    let first = clocks.first?.phone ?? 0
    let base = map.host(first)
    let delta = map.host(first + 1)
    var times: [Double] = []
    if let base, let delta, let origin {
      for i in 0..<next {
        times += try block(at: i).map { base + ($0.t - first) * (delta - base) - origin }
      }
    }
    var text =
      "participant_id,session_id,trial_id,prompt,hand,grip,actual_label,imu_file,seq_first,seq_last,video_file,video_start_s,video_end_s,quality,speed\n"
    let revisions = try readLines("labels.jsonl", TrialLabel.self)
    for l in Dictionary(grouping: revisions, by: { $0.id }).compactMap({ $0.value.last }).sorted(
      by: { $0.start < $1.start })
    {
      let a = times.firstIndex(where: { $0 >= l.start })
      let b = times.lastIndex(where: { $0 <= l.end })
      let ok = a != nil && b != nil && a! <= b!
      let fields = [
        info.participant, info.id.uuidString, l.id.uuidString, info.prompt, info.hand, info.grip,
        l.label, "samples.csv", ok ? String(a!) : "", ok ? String(b!) : "",
        "camera.mov", String(l.start), String(l.end), ok ? info.state : "unaligned",
        info.speed?.rawValue ?? "",
      ]
      text += fields.map(Self.csv).joined(separator: ",") + "\n"
    }
    try text.write(to: target("trials_index.csv"), atomically: true, encoding: .utf8)
  }
  func export(to parent: URL) throws -> URL {
    let fm = FileManager.default
    let staging = parent.appendingPathComponent(".export-" + UUID().uuidString)
    let dest = parent.appendingPathComponent(
      info.id.uuidString + "-dataset-" + String(UUID().uuidString.prefix(8)))
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staging) }
    var sums: [String: String] = [:]
    for name in [
      "manifest.json", "samples.csv", "camera.mov", "frames.csv", "trials_index.csv",
      "quality.json", "video_quality.json", "clocks.jsonl", "labels.jsonl", "events.jsonl",
      "all_events.json", "calibration.jsonl", "action_window.json", "position_targets.json",
      "legacy.csv", "legacy.accepted.csv",
      "legacy.review.json", "legacy.calibration.csv", "legacy.calibration.json",
    ] {
      let src = target(name)
      if !fm.fileExists(atPath: src.path) {
        if ["manifest.json", "samples.csv", "trials_index.csv"].contains(name) {
          throw CaptureFailure("场次尚未封装：" + name)
        }
        continue
      }
      let dst = staging.appendingPathComponent(name)
      try fm.copyItem(at: src, to: dst)
      let f = try FileHandle(forReadingFrom: dst)
      defer { try? f.close() }
      var hash = SHA256()
      while let bytes = try f.read(upToCount: 1024 * 1024), !bytes.isEmpty {
        hash.update(data: bytes)
      }
      sums[name] = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    try JSONEncoder().encode(sums).write(to: staging.appendingPathComponent("checksums.json"))
    try fm.moveItem(at: staging, to: dest)
    return dest
  }
  func writeWindow(start: Double, end: Double) throws {
    let origin = videoOrigin
    let window = ActionWindow(
      session_id: info.id, prompt: info.prompt, mac_begin: start, mac_end: end,
      video_begin_s: origin.map { start - $0 }, video_end_s: origin.map { end - $0 },
      label_status: "prompt_only", speed: info.speed)
    try JSONEncoder().encode(window).write(to: target("action_window.json"), options: .atomic)
  }
  func close(reason: String) throws {
    let tmp = target("samples.tmp")
    try Data("seq,t_phone,rx,ry,rz,ax_g,ay_g,az_g,gx,gy,gz,qx,qy,qz,qw\n".utf8).write(to: tmp)
    let f = try FileHandle(forWritingTo: tmp)
    try f.seekToEnd()
    var seq = 0
    var gaps = 0
    var last: Double?
    do {
      for i in 0..<next {
        var text = ""
        for row in try block(at: i) {
          if let last, row.t - last > 0.1 || row.t <= last { gaps += 1 }
          text +=
            String(seq) + "," + ([row.t] + row.v).map { String($0) }.joined(separator: ",") + "\n"
          seq += 1
          last = row.t
        }
        try f.write(contentsOf: Data(text.utf8))
      }
      try f.close()
    } catch {
      try? f.close()
      throw error
    }
    let out = target("samples.csv")
    if FileManager.default.fileExists(atPath: out.path) {
      _ = try FileManager.default.replaceItemAt(out, withItemAt: tmp)
    } else {
      try FileManager.default.moveItem(at: tmp, to: out)
    }
    let complete =
      reason == "complete" && seq > 0 && videoOrigin != nil
      && ClockMap(points: clocks).host(last ?? 0) != nil
      && FileManager.default.fileExists(atPath: target("camera.mov").path)
    info.state = complete ? "complete" : "partial"
    info.reason = reason
    try JSONEncoder().encode([
      "samples": seq, "time_gaps_over_100ms": gaps, "clock_probes": clocks.count,
    ]).write(to: target("quality.json"), options: .atomic)
    try JSONEncoder().encode(allEvents()).write(to: target("all_events.json"), options: .atomic)
    try exportIndex()
    try saveInfo()
  }
}

import Foundation

extension CaptureArchive {
  /// MotionInput exports numeric channels before the optional device metadata.
  /// A hardware ID can contain a quoted comma, so parse CSV quotes before column lookup.
  static func importPhoneCSV(_ url: URL, root: URL) throws -> CaptureArchive {
    func fields(_ line: Substring) -> [String] {
      var cells: [String] = []
      var cell = ""
      var quoted = false
      var pos = line.startIndex
      while pos < line.endIndex {
        let c = line[pos]
        pos = line.index(after: pos)
        if c == "\"" {
          if quoted, pos < line.endIndex, line[pos] == "\"" {
            cell.append(c)
            pos = line.index(after: pos)
          } else {
            quoted.toggle()
          }
        } else if c == "," && !quoted {
          cells.append(cell)
          cell = ""
        } else {
          cell.append(c)
        }
      }
      cells.append(cell)
      return cells
    }
    let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: { $0.isNewline })
    guard let header = lines.first, lines.count > 1 else { throw CaptureFailure("空的采集 CSV") }
    let names = fields(header)
    let required = [
      "t_s", "rx", "ry", "rz", "ax_g", "ay_g", "az_g", "gx", "gy", "gz", "qx", "qy", "qz", "qw",
    ]
    let cols = try required.map { name in
      guard let i = names.firstIndex(of: name) else { throw CaptureFailure("缺少原始运动列：" + name) }
      return i
    }
    let first = fields(lines[1])
    func value(_ name: String) -> String {
      guard let i = names.firstIndex(of: name), first.indices.contains(i) else { return "" }
      return first[i]
    }
    let rows = try lines.dropFirst().map { line in
      let data = fields(line)
      let values = try cols.map { i in
        guard data.indices.contains(i), let n = Double(data[i]), n.isFinite else {
          throw CaptureFailure("运动数据格式错误")
        }
        return n
      }
      return MotionRow(t: values[0], v: Array(values.dropFirst()))
    }
    let a = try CaptureArchive(
      root: root,
      info: SessionInfo(
        id: UUID(), participant: value("participant"), hand: value("hand"), grip: "未记录",
        prompt: value("prompt"), device: value("hardware"), system: value("ios"), build: "legacy",
        created: Date(), speed: CaptureSpeed(rawValue: value("speed"))))
    for start in stride(from: 0, to: rows.count, by: 100) {
      try a.accept(a.next, Array(rows[start..<min(start + 100, rows.count)]))
    }
    let fm = FileManager.default
    try fm.copyItem(at: url, to: a.dir.appendingPathComponent("legacy.csv"))
    for ext in ["review.json", "accepted.csv"] {
      let file = url.deletingPathExtension().appendingPathExtension(ext)
      if fm.fileExists(atPath: file.path) {
        try fm.copyItem(at: file, to: a.dir.appendingPathComponent("legacy." + ext))
      }
    }
    if let id = UUID(uuidString: value("session")) {
      for ext in ["calibration.csv", "calibration.json"] {
        let file = url.deletingLastPathComponent().appendingPathComponent(id.uuidString + "." + ext)
        if fm.fileExists(atPath: file.path) {
          try fm.copyItem(at: file, to: a.dir.appendingPathComponent("legacy." + ext))
        }
      }
    }
    try a.close(reason: "legacy_relative_time_only")
    return a
  }
}

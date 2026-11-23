import Foundation
import SwiftUI

enum ReviewStatus: String, CaseIterable, Identifiable {
  case pending = "待复核"
  case reviewed = "已复核"
  case partial = "部分记录"
  var id: Self { self }
}

struct CaptureHistoryEntry: Identifiable, Sendable {
  let dir: URL
  let info: SessionInfo
  let hasVideo: Bool
  let hasMotion: Bool
  let hasIndex: Bool
  let calibratedPositions: Int
  let actualLabels: [String]
  var id: URL { dir }
  var action: String { StandardStroke(rawValue: info.prompt)?.displayName ?? info.prompt }
  var status: ReviewStatus {
    if info.state != "complete" || !hasVideo || !hasMotion { return .partial }
    return actualLabels.isEmpty ? .pending : .reviewed
  }
  var canExport: Bool { hasMotion && hasIndex }
  var dataSummary: String {
    let video = hasVideo ? "视频" : "缺视频"
    let motion = hasMotion ? "IMU" : "缺 IMU"
    return "\(video) · \(motion) · 校准 \(calibratedPositions)/4"
  }

  static func scan(_ root: URL) throws -> (entries: [Self], invalid: Int) {
    let fm = FileManager.default
    let candidates: [URL]
    if fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) {
      candidates = [root]
    } else {
      candidates = try fm.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
    }
    let decoder = JSONDecoder()
    var entries: [Self] = []
    var invalid = 0
    for dir in candidates {
      let manifest = dir.appendingPathComponent("manifest.json")
      guard fm.fileExists(atPath: manifest.path) else { continue }
      guard let data = try? Data(contentsOf: manifest),
        let info = try? decoder.decode(SessionInfo.self, from: data)
      else {
        invalid += 1
        continue
      }
      func exists(_ name: String) -> Bool {
        let url = dir.appendingPathComponent(name)
        return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
      }
      let calibration =
        (try? Data(contentsOf: dir.appendingPathComponent("calibration.jsonl"))) ?? Data()
      let steps = Set(
        calibration.split(separator: 10).compactMap { line -> Int? in
          guard let record = try? decoder.decode(PositionRecord.self, from: Data(line)),
            (0..<4).contains(record.step)
          else { return nil }
          return record.step
        })
      let labelData = (try? Data(contentsOf: dir.appendingPathComponent("labels.jsonl"))) ?? Data()
      var latest: [UUID: String] = [:]
      for line in labelData.split(separator: 10) {
        if let label = try? decoder.decode(TrialLabel.self, from: Data(line)) {
          latest[label.id] = StandardStroke(rawValue: label.label)?.displayName ?? label.label
        }
      }
      entries.append(
        Self(
          dir: dir, info: info, hasVideo: exists("camera.mov"),
          hasMotion: exists("samples.csv"), hasIndex: exists("trials_index.csv"),
          calibratedPositions: steps.count, actualLabels: Set(latest.values).sorted()))
    }
    return (
      entries.sorted {
        if $0.info.created == $1.info.created { return $0.dir.path < $1.dir.path }
        return $0.info.created > $1.info.created
      }, invalid
    )
  }

  static func export(_ entries: [Self], to parent: URL) -> (saved: Int, errors: [String]) {
    var saved = 0
    var errors: [String] = []
    for entry in entries {
      do {
        let archive = try CaptureArchive(open: entry.dir, readOnly: true)
        _ = try archive.export(to: parent)
        saved += 1
      } catch {
        errors.append(
          entry.action + " · " + entry.info.created.formatted() + " · " + error.localizedDescription
        )
      }
    }
    return (saved, errors)
  }
}

struct CaptureHistory: View {
  @State var root: URL?
  let close: () -> Void
  @State private var entries: [CaptureHistoryEntry] = []
  @State private var search = ""
  @State private var action = ""
  @State private var speed = ""
  @State private var status: ReviewStatus?
  @State private var selected: Set<URL> = []
  @State private var review: URL?
  @State private var revision = 0
  @State private var loading = false
  @State private var exporting = false
  @State private var message = ""
  @State private var failures: [String] = []
  @State private var showFailures = false

  private var filtered: [CaptureHistoryEntry] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return entries.filter { entry in
      let matchesAction =
        action.isEmpty || entry.action == action || entry.actualLabels.contains(action)
      return matchesAction && (speed.isEmpty || (entry.info.speed?.rawValue ?? "unknown") == speed)
        && (status == nil || entry.status == status)
        && (query.isEmpty
          || ([entry.action, entry.info.participant, entry.info.id.uuidString] + entry.actualLabels)
            .contains { $0.localizedStandardContains(query) })
    }
  }
  private var chosen: [CaptureHistoryEntry] { filtered.filter { selected.contains($0.id) } }
  private var exportable: [CaptureHistoryEntry] { chosen.filter(\.canExport) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("采集历史").font(.title2.bold())
        Spacer()
        Button("打开其他目录") {
          if let url = pickDirectory("选择采集根目录或场次目录") {
            root = url
            selected = []
            refresh()
          }
        }
        Button {
          refresh()
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .disabled(root == nil)
        Button("关闭", action: close)
      }
      if let root {
        Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.middle).textSelection(.enabled)
      }
      HStack {
        TextField("搜索参与者、动作或场次 ID", text: $search).textFieldStyle(.roundedBorder)
        Picker("动作", selection: $action) {
          Text("全部动作").tag("")
          ForEach(Set(entries.flatMap { [$0.action] + $0.actualLabels }).sorted(), id: \.self) {
            Text($0).tag($0)
          }
        }.labelsHidden().fixedSize()
        Picker("速度", selection: $speed) {
          Text("全部速度").tag("")
          ForEach(CaptureSpeed.allCases) { Text($0.title).tag($0.rawValue) }
          Text("速度未记录").tag("unknown")
        }.labelsHidden().fixedSize()
        Picker("复核状态", selection: $status) {
          Text("全部状态").tag(nil as ReviewStatus?)
          ForEach(ReviewStatus.allCases) { Text($0.rawValue).tag(Optional($0)) }
        }.labelsHidden().fixedSize()
      }
      if loading {
        ProgressView("正在读取采集目录").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if filtered.isEmpty {
        ContentUnavailableView(
          root == nil ? "选择采集目录" : "没有符合条件的场次",
          systemImage: "folder",
          description: Text(entries.isEmpty ? "可打开已有采集目录查看记录。" : "调整搜索或筛选条件。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Table(filtered, selection: $selected) {
          TableColumn("采集时间") {
            Text($0.info.created, format: .dateTime.month().day().hour().minute())
          }
          .width(min: 100, ideal: 135)
          TableColumn("参与者") { Text($0.info.participant) }.width(min: 55, ideal: 70)
          TableColumn("动作") { entry in
            VStack(alignment: .leading) {
              Text(entry.action)
              if !entry.actualLabels.isEmpty {
                Text("实际 " + entry.actualLabels.joined(separator: "、")).font(.caption)
                  .foregroundStyle(.secondary).lineLimit(1)
              }
            }
          }.width(min: 95, ideal: 140)
          TableColumn("速度") { Text($0.info.speed?.title ?? "未记录") }.width(min: 68, ideal: 88)
          TableColumn("状态") { Text($0.status.rawValue) }.width(min: 72, ideal: 85)
          TableColumn("数据") { Text($0.dataSummary) }.width(min: 145, ideal: 180)
        }
        .contextMenu(forSelectionType: URL.self) { ids in
          if ids.count == 1, let url = ids.first {
            Button("打开复核") { review = url }
            Button("在 Finder 显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          }
        } primaryAction: { ids in
          if ids.count == 1 { review = ids.first }
        }
      }
      Text(
        "\(filtered.count) / \(entries.count) 场 · 慢速 \(filtered.filter { $0.info.speed == .slow }.count) · 正常 \(filtered.filter { $0.info.speed == .normal }.count) · 快速 \(filtered.filter { $0.info.speed == .fast }.count)"
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Text(message.isEmpty ? "已选 \(chosen.count) 场 · 可导出 \(exportable.count) 场" : message)
          .font(.callout).lineLimit(2)
        if !failures.isEmpty {
          Button("失败详情") { showFailures = true }
        }
        Spacer()
        if let entry = chosen.first, chosen.count == 1 {
          Menu("查看文件") {
            Button("场次目录") { NSWorkspace.shared.activateFileViewerSelecting([entry.dir]) }
            if entry.hasMotion {
              Button("运动数据 CSV") {
                NSWorkspace.shared.open(entry.dir.appendingPathComponent("samples.csv"))
              }
            }
            if entry.hasVideo {
              Button("原始录像") {
                NSWorkspace.shared.open(entry.dir.appendingPathComponent("camera.mov"))
              }
            }
          }.fixedSize()
        }
        Button("打开复核") { review = chosen.first?.dir }.disabled(chosen.count != 1)
        Button("导出所选训练包") { exportSelection() }.buttonStyle(.borderedProminent)
          .disabled(exportable.isEmpty)
      }
    }.padding(18).frame(minWidth: 800, minHeight: 475)
      .disabled(exporting)
      .interactiveDismissDisabled(exporting)
      .task(id: revision) { await scan() }
      .onChange(of: selected) { _, _ in
        if !exporting {
          message = ""
          failures = []
        }
      }
      .alert("训练包导出详情", isPresented: $showFailures) {
        Button("完成", role: .cancel) {}
      } message: {
        Text(failures.joined(separator: "\n"))
      }
      .sheet(
        isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } }),
        onDismiss: { refresh() }
      ) {
        if let review { SessionReview(dir: review, close: { self.review = nil }) }
      }
  }

  private func refresh() { revision += 1 }

  @MainActor private func scan() async {
    guard let root else { return }
    loading = true
    defer { if !Task.isCancelled { loading = false } }
    do {
      let scan = try await Task.detached { try CaptureHistoryEntry.scan(root) }.value
      guard !Task.isCancelled else { return }
      entries = scan.entries
      selected.formIntersection(Set(entries.map(\.id)))
      if !entries.contains(where: { $0.action == action || $0.actualLabels.contains(action) }) {
        action = ""
      }
      message = scan.invalid == 0 ? "" : "有 \(scan.invalid) 个场次的清单无法读取"
    } catch {
      guard !Task.isCancelled else { return }
      entries = []
      selected = []
      message = error.localizedDescription
    }
  }

  private func exportSelection() {
    guard let parent = pickDirectory("选择批量训练包输出目录") else { return }
    let targets = exportable
    let skipped = chosen.count - targets.count
    exporting = true
    failures = []
    message = "正在复制并校验 \(targets.count) 个训练包"
    Task {
      let result = await Task.detached { CaptureHistoryEntry.export(targets, to: parent) }.value
      exporting = false
      failures = result.errors
      message = "已导出 \(result.saved) 场 · 失败 \(failures.count) 场 · 跳过 \(skipped) 场"
    }
  }
}

import AVKit
import SwiftUI

struct RallyReviewPoint: Identifiable {
  let id: Int
  var scene: String
  var goal: String
  var time: Double
  var marked = false
  var contact: LiveRallyTelemetry.Contact?
  var result = "未记录结局"
  var actual = ""
  var samples: [(time: Double, ball: [Double])] = []
}

struct RallyReviewMovie {
  let url: URL
  let frames: [(clock: Double, pts: Double)]
  let cameraClock: ClockMap?

  func seconds(_ phone: Double) -> Double? {
    let clock: Double
    if let cameraClock {
      guard let host = cameraClock.host(phone) else { return nil }
      clock = host
    } else { clock = phone }
    guard let first = frames.first, let last = frames.last,
          clock >= first.clock, clock <= last.clock else { return nil }
    guard let near = frames.min(by: { abs($0.clock-clock) < abs($1.clock-clock) }),
          abs(near.clock-clock) < 0.12 else { return nil }
    return near.pts
  }
}

struct RallyPointIndex {
  let points: [RallyReviewPoint]
  let movies: [RallyReviewMovie]
  let unreadable: Int

  init(folder: URL) throws {
    let fm = FileManager.default
    let decoder = JSONDecoder()
    let files = try fm.contentsOfDirectory(at: folder.appendingPathComponent("batches"), includingPropertiesForKeys: nil)
    var grouped: [Int: RallyReviewPoint] = [:]
    var skipped = 0
    for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard let bytes = try? Data(contentsOf: file),
            let batch = try? decoder.decode(LiveRallyTelemetry.self, from: bytes) else { skipped += 1; continue }
      let fields = batch.state.mode.components(separatedBy: "/")
      guard fields.count >= 5, fields[0] == "场景采集", let n = Int(fields[2]), n > 0 else { continue }
      let goal = fields.count > 5 ? fields.dropFirst(5).joined(separator: " · ") : "未记录目标"
      var row = grouped[n] ?? RallyReviewPoint(id: n, scene: fields[1], goal: goal, time: batch.phoneTime)
      for tick in batch.ticks ?? [] {
        if let ball = tick.ball, ball.count == 3 { row.samples.append((tick.time,ball)) }
      }
      for event in batch.events {
        if let c = event.contact {
          row.contact = c; row.time = event.time; row.marked = true
          row.goal = [c.intendedReply,c.targetLane,c.targetDepth].joined(separator: " · ")
          row.actual = c.observedReply ?? c.outgoing.shot
        } else if event.kind == "judgment", event.accepted == true, row.contact == nil {
          row.time = event.peakTime ?? event.time; row.marked = true
        }
        if event.kind == "incomingFeed", !row.marked { row.time = event.time }
      }
      if row.contact == nil, let f = batch.state.flight, !f.incoming { row.actual = f.shot }
      if batch.state.phase == "point" { row.result = batch.state.message }
      grouped[n] = row
    }
    points = grouped.values.sorted { $0.id < $1.id }
    unreadable = skipped
    var clips: [RallyReviewMovie] = []
    let segments = (try? fm.contentsOfDirectory(at: folder.appendingPathComponent("视频"), includingPropertiesForKeys: nil)) ?? []
    for segment in segments {
      let text = try? String(contentsOf: segment.appendingPathComponent("clocks.jsonl"), encoding: .utf8)
      let clocks = (text ?? "").split(separator: "\n").compactMap { try? decoder.decode(ClockPoint.self, from: Data($0.utf8)) }
      for camera in [true,false] {
        let url = segment.appendingPathComponent(camera ? "camera.mov" : "game.mov")
        guard fm.fileExists(atPath: url.path), let csv = try? String(contentsOf: segment.appendingPathComponent(camera ? "frames.csv" : "screen_frames.csv"), encoding: .utf8) else { continue }
        let frames: [(Double,Double)] = csv.split(separator: "\n").dropFirst().compactMap {
          let cells = $0.split(separator: ",")
          guard cells.count >= (camera ? 5 : 2), let clock = Double(cells[camera ? 4 : 1]), let pts = Double(cells[camera ? 3 : 0]) else { return nil }
          return (clock,pts)
        }
        clips.append(.init(url: url, frames: frames, cameraClock: camera ? ClockMap(points: clocks) : nil))
      }
    }
    movies = clips
  }
}

struct RallyPointReview: View {
  let folder: URL
  @Environment(\.dismiss) private var dismiss
  @State private var index: RallyPointIndex?
  @State private var error = ""
  @State private var selected: Int?
  @State private var reviewLabel = ""
  @State private var noteStatus = ""
  @State private var camera = true
  @State private var player = AVPlayer()
  @State private var hasVideo = false
  private var row: RallyReviewPoint? { index?.points.first { $0.id == selected } }

  var body: some View {
    VStack(alignment: .leading) {
      HStack { Text("逐球复盘").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
      if let index {
        if index.unreadable > 0 { Text("有 \\(index.unreadable) 个数据批次读取失败") }
        if index.points.isEmpty { Text("此目录没有场景采集球次") }
        HStack {
          List(index.points, selection: $selected) { r in Text("第 \\(r.id) 球 · \\(r.scene)").tag(r.id) }.frame(width: 210)
          if let row {
            VStack(alignment: .leading) {
              Text("来球　" + row.scene + "　　目标　" + row.goal)
              Text("实际　" + (row.actual.isEmpty ? "无回球记录" : row.actual) + "　　" + row.result)
              if let c = row.contact {
                Text(String(format: "%@ · 相对网带 %+.2f m · 力度 %.2f · 横向 %+.2f · 上下 %+.2f",c.area,c.heightAboveNetMeters,c.strength,c.lateral,c.vertical))
                if c.beforeNet || c.outsideReach { Text(c.beforeNet ? "按键时球还在对面" : "按键时超出建议接球范围").foregroundStyle(.orange) }
              }
              HStack {
                TextField("录像复核回法（可填方向待定）", text: $reviewLabel)
                Button("保存复核") {
                  do {
                    let file = folder.appendingPathComponent("逐球复核-\(row.id).txt")
                    try reviewLabel.write(to: file, atomically: true, encoding: .utf8)
                    noteStatus = "已保存"
                  } catch { noteStatus = error.localizedDescription }
                }
                Text(noteStatus).font(.caption)
              }
              HStack {
                Picker("录像", selection: $camera) { Text("真人").tag(true); Text("游戏").tag(false) }.pickerStyle(.segmented)
                Button("定位" + (row.marked ? "击球点" : "来球")) { seek() }
                Button("回看前半秒") { seek(lead: 0.5, play: true) }
              }
              if hasVideo { VideoPlayer(player: player) } else { Text("该时刻没有可对齐的录像").frame(maxHeight: .infinity) }
              Canvas { ctx, size in
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 6)
                ctx.stroke(Path(bounds), with: .color(.secondary))
                func xy(_ b: [Double]) -> CGPoint {
                  CGPoint(x: bounds.minX + (b[0]+1)*0.5*bounds.width, y: bounds.minY + b[1]*bounds.height)
                }
                var net = Path(); net.move(to: CGPoint(x: bounds.minX,y: bounds.midY)); net.addLine(to: CGPoint(x: bounds.maxX,y: bounds.midY))
                ctx.stroke(net,with: .color(.secondary))
                var previous: CGPoint?
                for sample in row.samples {
                  let p = xy(sample.ball)
                  if let previous {
                    var line = Path(); line.move(to: previous); line.addLine(to: p)
                    ctx.stroke(line,with: .color(row.marked && sample.time >= row.time ? .orange : .teal),lineWidth: 2)
                  }
                  previous = p
                }
                if let b = row.contact?.ball, b.count == 3 {
                  let p = xy(b); ctx.fill(Path(ellipseIn: CGRect(x:p.x-4,y:p.y-4,width:8,height:8)),with:.color(.primary))
                }
              }.frame(height: 115)
              Text("俯视轨迹　青色来球　橙色回球　圆点为按键位置").font(.caption)
            }
          }
        }
      } else if error.isEmpty { ProgressView("正在读取逐球数据") } else { Text(error) }
    }
    .padding().frame(minWidth: 880,minHeight: 620)
    .task {
      do {
        let snapshot = try await Task.detached { try RallyPointIndex(folder: folder) }.value
        index = snapshot; selected = snapshot.points.first?.id; seek()
      } catch { self.error = error.localizedDescription }
    }
    .onChange(of: selected) { _,n in
      noteStatus = ""
      reviewLabel = n.flatMap { try? String(contentsOf: folder.appendingPathComponent("逐球复核-\($0).txt"),encoding:.utf8) } ?? ""
      seek()
    }
    .onChange(of: camera) { _,_ in seek() }
    .onDisappear { player.pause() }
  }

  private func seek(lead: Double = 0, play: Bool = false) {
    player.pause(); hasVideo = false
    guard let row else { return }
    for movie in index?.movies ?? [] where (movie.cameraClock != nil) == camera {
      guard let time = movie.seconds(row.time) else { continue }
      if (player.currentItem?.asset as? AVURLAsset)?.url != movie.url {
        player.replaceCurrentItem(with: AVPlayerItem(url: movie.url))
      }
      hasVideo = true
      player.seek(to: CMTime(seconds:max(0,time-lead),preferredTimescale:60000), toleranceBefore:.zero,toleranceAfter:.zero)
      if play { player.play() }
      return
    }
    player.replaceCurrentItem(with: nil)
  }
}

import AVKit
import Combine
import SwiftUI

func pickDirectory(_ title: String) -> URL? {
  let panel = NSOpenPanel()
  panel.title = title
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.canCreateDirectories = true
  panel.allowsMultipleSelection = false
  return panel.runModal() == .OK ? panel.url : nil
}
@main struct RallyCaptureApp: App {
  var body: some Scene {
    Window("羽球动作采集", id: "capture") { StudioView().frame(minWidth: 800, minHeight: 580) }
  }
}
struct StudioView: View {
  @StateObject private var host = StudioHost()
  @StateObject private var nearby = NearbyHost()
  @State private var cameraID = ""
  @State private var review: URL?
  @State private var cancel = false
  @State private var history = false
  @State private var pairing = false
  @State private var manual = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("羽球采集工作台").font(.title2.bold())
        Spacer()
        Button {
          pairing = true
          if !host.online {
            host.listen()
            nearby.enable(host: host.serviceName, secret: host.secret)
          }
        } label: {
          Label(
            host.online ? "iPhone 已连接" : "连接 iPhone",
            systemImage: host.online ? "checkmark.circle.fill" : "iphone")
        }
        .tint(host.online ? .green : .accentColor)
        Button { history = true } label: { Label("采集历史", systemImage: "clock") }.disabled(host.busy)
        Menu("记录") {
          Button("导入手机 CSV") {
            guard let root = host.root else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            if panel.runModal() == .OK, let file = panel.url {
              do {
                let a = try CaptureArchive.importPhoneCSV(file, root: root)
                host.latest = a.dir
                host.message = "已导入旧记录（仅运动数据）"
                review = a.dir
              } catch { host.message = error.localizedDescription }
            }
          }.disabled(host.root == nil || host.busy)
          Button("打开场次复核") { review = pickDirectory("选择含 manifest.json 的场次目录") }.disabled(host.busy)
          if let u = host.latest { Button("复核最近一次") { review = u }.disabled(host.busy) }
        }.fixedSize()
      }
      Divider()
      HStack(alignment: .top, spacing: 18) {
        VStack(alignment: .leading, spacing: 12) {
          Label("采集准备", systemImage: "slider.horizontal.3").font(.headline)
          Button(host.root == nil ? "选择保存目录" : "更改保存目录") {
            if let u = pickDirectory("选择采集根目录") { host.selectRoot(u) }
          }
          if let root = host.root {
            Text(root.path).font(.caption).lineLimit(2).textSelection(.enabled)
          }
          Picker("摄像头", selection: $cameraID) {
            ForEach(CameraRecorder.cameras, id: \.uniqueID) { d in
              Text(d.localizedName).tag(d.uniqueID)
            }
          }.labelsHidden()
          Button(host.cameraReady ? "重新预览" : "开启摄像头预览") { host.preview(id: cameraID) }.disabled(
            cameraID.isEmpty)
          if host.guide.phase != .calibrating {
            CameraPreview(session: host.camera.session).frame(height: 110).background(.black)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          TextField("匿名参与者编号", text: $host.participant)
          Picker("持机手", selection: $host.hand) {
            Text("右手").tag("右手")
            Text("左手").tag("左手")
          }.pickerStyle(.segmented)
          TextField("握持方式", text: $host.grip)
          Spacer()
        }.frame(width: 210).disabled(host.busy)
        Divider()
        VStack(alignment: .leading, spacing: 9) {
          if host.guide.phase == .calibrating {
            CameraPreview(session: host.camera.session).frame(
              maxWidth: .infinity, minHeight: 110, maxHeight: 150
            )
            .background(.black).clipShape(RoundedRectangle(cornerRadius: 10))
          }
          GuidedTrialView(plan: host.guide, enabled: true, act: host.act)
          if host.guide.phase == .calibrating {
            Button("手腕遮挡：人工核对画面位置") { manual = true }
              .confirmationDialog(
                "确认画面中的手腕已到达" + TrialPanel.positions[host.guide.step] + "？", isPresented: $manual
              ) {
                Button("确认并记录人工来源") { host.confirmVisiblePosition() }
              }
          }
        }
      }
      Divider()
      HStack {
        Text(host.message).font(.callout).lineLimit(2)
        Spacer()
        if host.busy {
          Text("\(host.count) 帧 · \(Int(host.rate)) Hz").monospacedDigit()
          if !host.online {
            Button("保留部分记录") { host.savePartial() }
          } else if host.guide.phase != .saving && host.guide.phase != .recording {
            Button("取消本拍") { cancel = true }
          }
        } else if let u = host.latest {
          Button("复核本拍") { review = u }
        }
      }
    }.padding(18)
      .onAppear { cameraID = CameraRecorder.cameras.first?.uniqueID ?? "" }
      .onChange(of: cameraID) { _, _ in host.cameraReady = false }
      .sheet(isPresented: $history) { CaptureHistory(root: host.root, close: { history = false }) }
      .sheet(isPresented: $pairing) {
        VStack(alignment: .leading, spacing: 14) {
          Text(host.online ? "iPhone 已连接" : "连接采集手机").font(.title2.bold())
          if host.online {
            Label("可以关闭此面板，准备摄像头和采集动作。", systemImage: "checkmark.circle.fill")
          } else {
            Text("两端接入同一局域网，在 iPhone 首页打开「Mac 联合采集」。")
            if !host.listening {
              Text(host.message)
              Button("重试连接服务") { host.listen() }
            } else {

              Text(nearby.message.isEmpty ? "手机点「查找附近的 Mac」，选择本机。" : nearby.message)
              if let code = nearby.code {
                Text(code).font(.largeTitle.monospacedDigit())
                HStack {
                  Button("数字一致，允许连接") { nearby.approve() }.buttonStyle(.borderedProminent)
                  Button("拒绝") { nearby.reset() }
                }
              }
              DisclosureGroup("改用局域网密钥") {
                Text(host.secret).font(.title3.monospaced()).textSelection(.enabled)
                Text("手机展开密钥连接，搜索局域网，输入密钥并选择本机。").font(.caption)
              }
            }
          }
          HStack {
            Spacer()
            Button("完成") { pairing = false }
          }
        }.padding(24).frame(width: 470)
      }
      .confirmationDialog("取消本次采集并保留部分记录？", isPresented: $cancel) {
        Button("取消本拍", role: .destructive) { host.act(.cancel) }
      }
      .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
        if let review { SessionReview(dir: review, close: { self.review = nil }) }
      }
  }
}

struct SessionReview: View {
  let dir: URL, close: () -> Void
  @State private var archive: CaptureArchive?
  @State private var player = AVPlayer()
  @State private var duration = 0.0
  @State private var t = 0.0
  @State private var lo = 0.0
  @State private var hi = 0.0
  @State private var label = "上挑"
  @State private var status = ""
  @State private var list: [TrialLabel] = []
  @State private var trace: [CGPoint] = []
  @State private var frameTimes: [Double] = []
  @State private var events: [StudioEvent] = []
  @State private var exporting = false
  @State private var editing: UUID?
  let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(archive?.readOnly == true ? "训练包预览" : "同步复核").font(.title2.bold())
        Spacer()
        Button("导出训练包") {
          guard let archive, let parent = pickDirectory("选择训练包输出目录") else { return }
          exporting = true
          status = "正在复制并校验训练包"
          Task {
            defer { exporting = false }
            do {
              let u = try await Task.detached { try archive.export(to: parent) }.value
              status = "训练包已保存到 " + u.path
            } catch { status = error.localizedDescription }
          }
        }
        Button("在 Finder 中查看") { NSWorkspace.shared.open(dir) }
        Button("关闭", action: close)
      }
      Text(status).font(.caption).textSelection(.enabled)
      VideoPlayer(player: player).frame(minHeight: 220)
      Canvas { ctx, size in
        guard duration > 0 else { return }
        var path = Path()
        for (i, p) in trace.enumerated() {
          let q = CGPoint(x: p.x / duration * size.width, y: size.height * (1 - p.y))
          if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        ctx.stroke(path, with: .color(.mint), lineWidth: 1.5)
        var cursor = Path()
        let x = t / duration * size.width
        cursor.move(to: .init(x: x, y: 0))
        cursor.addLine(to: .init(x: x, y: size.height))
        ctx.stroke(cursor, with: .color(.orange), lineWidth: 2)
      }.frame(height: 48).background(.black.opacity(0.7))
      HStack {
        let calibration = events.filter { $0.text.hasPrefix("calibration:") }
        if !calibration.isEmpty {
          Menu("校准步骤") {
            ForEach(calibration.indices, id: \.self) { index in
              let item = calibration[index]
              let name = String(item.text.dropFirst("calibration:".count))
              Button(name + String(format: " · %.2f s", item.time)) { seek(item.time) }
            }
          }
        }
        if !events.isEmpty {
          Menu("现场与识别事件") {
            ForEach(events.indices, id: \.self) { i in
              Button(String(format: "%.2f s  ", events[i].time) + events[i].text) {
                seek(events[i].time)
              }
            }
          }
        }
        Text(events.last(where: { $0.time <= t })?.text ?? "").font(.caption)
      }
      Slider(
        value: Binding(get: { min(duration, max(0, t)) }, set: { seek($0) }),
        in: 0...max(0.01, duration))
      HStack {
        Button("上一帧") { seek(frameTimes.last(where: { $0 < t - 0.0001 }) ?? 0) }
        Button("下一帧") { seek(frameTimes.first(where: { $0 > t + 0.0001 }) ?? duration) }
        Button("0.25×") { player.playImmediately(atRate: 0.25) }
        Text(String(format: "%.3f s", t)).monospacedDigit()
        Button("设为起点") { lo = t }
        Button("设为终点") { hi = t }
        Text(String(format: "%.2f – %.2f s", lo, hi))
      }
      HStack {
        TextField("实际动作或背景", text: $label)
        Button(editing == nil ? "保存新标注" : "保存修订") {
          guard let archive else { return }
          do {
            try archive.annotate(label, start: lo, end: hi, id: editing ?? UUID())
            reload()
            editing = nil
            status = "已更新 trials_index.csv"
          } catch { status = error.localizedDescription }
        }.disabled(label.isEmpty || hi <= lo || archive?.readOnly != false)
        Button("新建区间") {
          editing = nil
          lo = t
          hi = t
        }
      }
      List(list, id: \.id) { item in
        Button("\(item.label)   " + String(format: "%.2f – %.2f s", item.start, item.end)) {
          editing = item.id
          label = item.label
          lo = item.start
          hi = item.end
          seek(lo)
        }
      }.frame(height: 85)
    }.padding().frame(minWidth: 780, minHeight: 580).disabled(exporting)
      .onReceive(timer) { _ in if player.rate != 0 { t = player.currentTime().seconds } }
      .task {
        do {
          let a = try CaptureArchive(open: dir)
          archive = a
          label = a.info.prompt
          status = a.info.participant + " · " + label + " · " + (a.info.speed?.title ?? "速度未记录")
          reload()
          if a.info.reason == "legacy_relative_time_only" {
            status = "旧版手机 CSV · " + String(a.samples) + " 帧 · 只有试次相对时间，可导出运动数据"
            return
          }
          let asset = AVURLAsset(url: dir.appendingPathComponent("camera.mov"))
          let length = try await asset.load(.duration).seconds
          guard length.isFinite && length > 0 else { throw CaptureFailure("视频时长无效") }
          duration = length
          player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
          if let data = try? Data(contentsOf: dir.appendingPathComponent("action_window.json")),
            let window = try? JSONDecoder().decode(ActionWindow.self, from: data),
            let begin = window.video_begin_s, let end = window.video_end_s
          {
            lo = max(0, min(length, begin))
            hi = max(lo, min(length, end))
            seek(lo)
          }
          let frames = try String(
            contentsOf: dir.appendingPathComponent("frames.csv"), encoding: .utf8
          ).split(separator: "\n").dropFirst().map { $0.split(separator: ",") }
          frameTimes = frames.compactMap { $0.count == 5 ? Double($0[3]) : nil }
          guard let first = frames.first, first.count == 5, let origin = Double(first[4]),
            let p = a.clocks.first?.phone
          else { throw CaptureFailure("视频可回放，缺少对时参考") }
          let map = ClockMap(points: a.clocks)
          guard let base = map.host(p), let delta = map.host(p + 1) else {
            throw CaptureFailure("时钟映射不可用")
          }
          let zero = origin - (frameTimes.first ?? 0)
          events = try a.allEvents().map { e in
            StudioEvent(
              text: e.text,
              time: (e.clock == "phone" ? base + (e.time - p) * (delta - base) : e.time) - zero,
              clock: "video")
          }.sorted { $0.time < $1.time }
          let csv = try String(
            contentsOf: dir.appendingPathComponent("samples.csv"), encoding: .utf8
          ).split(separator: "\n").dropFirst()
          var points: [CGPoint] = []
          var peak = 0.01
          // Peak envelope preserves brief strokes when displaying long recordings.
          var bucket = -1
          var best = CGPoint.zero
          for row in csv {
            let v = row.split(separator: ",", maxSplits: 5)
            guard v.count > 4, let ts = Double(v[1]), let x = Double(v[2]), let y = Double(v[3]),
              let z = Double(v[4])
            else { continue }
            let pos = base + (ts - p) * (delta - base) - zero
            let value = hypot(hypot(x, y), z)
            let col = Int(pos / duration * 1200)
            if col != bucket {
              if bucket >= 0 { points.append(best) }
              bucket = col
              best = CGPoint(x: pos, y: value)
            } else if value > best.y {
              best = CGPoint(x: pos, y: value)
            }
            peak = max(peak, value)
          }
          points.append(best)
          trace = points.map { CGPoint(x: $0.x, y: $0.y / peak) }
          status =
            "\(a.info.participant) · \(a.info.prompt) · \(a.info.speed?.title ?? "速度未记录") · \(a.info.state) · 角速度模长（峰值 "
            + String(format: "%.1f rad/s", peak) + "）"
        } catch { status = error.localizedDescription }
      }.onDisappear { player.pause() }
  }
  func seek(_ value: Double) {
    player.pause()
    t = max(0, min(duration, value))
    player.seek(
      to: CMTime(seconds: t, preferredTimescale: 60000), toleranceBefore: .zero,
      toleranceAfter: .zero)
  }
  func reload() {
    list = Dictionary(grouping: archive?.labels ?? [], by: { $0.id }).compactMap { $0.value.last }
      .sorted { $0.start < $1.start }
  }
}

import SwiftUI


struct ManualBatchView: View {
  @StateObject private var batch = ManualBatch()
  @State private var photos = false
  @State private var stroke = StandardStroke.forehandHighServe
  @State private var speed = CaptureSpeed.normal
  @State var left: Bool
  @AppStorage("manualCapturePlayer") private var player = "P01"
  @Environment(\.scenePhase) private var phase
  let close: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("连续挥拍采集").font(.title.bold())
          Spacer()
          if !batch.recording { Button("返回球社", action: close) }
        }
        if batch.recording {
          Text("\(stroke.displayName) · \(speed.title) · \(left ? "左手" : "右手")")
          if photos { Text("\(batch.marks) 拍已标记").font(.largeTitle.bold()).monospacedDigit() }
          Text(batch.samples == 0 ? "等待传感器，请稍候" : "正在记录运动数据 · 已写入 \(batch.samples) 帧").monospacedDigit()
          if photos { Text(batch.volumeHint) }
          Button("结束并保存整组") { batch.stop("手动结束") }.buttonStyle(.borderedProminent)
        } else {
          HStack {
            Picker("本组动作", selection: $stroke) {
              ForEach(StandardStroke.gameTraining) { Text($0.displayName).tag($0) }
            }.pickerStyle(.menu)
            Picker("速度", selection: $speed) {
              ForEach(CaptureSpeed.recordingOptions) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 210)
            Toggle("左手", isOn: $left).fixedSize()
          }
          HStack {
            Text("采集者")
            TextField("采集者编号", text: $player).textFieldStyle(.roundedBorder)
              .foregroundStyle(.primary).frame(maxWidth: 160)
          }
          Toggle("拍摄标注（iPhone 相机）", isOn: $photos)
          Text(photos ? "相机就绪后按音量＋标记击球，松开拍摄参考图。" : "本组仅记录连续运动数据。")
          Button("开始连续采集") {
            batch.start(photos: photos, stroke: stroke, speed: speed, left: left, player: player.trimmingCharacters(in: .whitespacesAndNewlines))
          }.buttonStyle(.borderedProminent).disabled(player.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if !batch.status.isEmpty { Text(batch.status) }
          if !batch.files.isEmpty {
            Text("已保存的组").font(.headline)
            ForEach(batch.files, id: \.self) { url in
              ShareLink(item: url) {
                Label(url.deletingPathExtension().lastPathComponent, systemImage: "square.and.arrow.up")
              }
            }
          }
        }
      }.padding()
    }
    .onAppear { batch.reload() }
    .onDisappear { batch.stop("离开页面") }
    .onChange(of: phase) { _, next in if next == .background { batch.stop("应用进入后台") } }
  }
}

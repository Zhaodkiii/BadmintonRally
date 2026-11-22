import SwiftUI

struct GuidedTrialView: View {
  let plan: TrialPanel
  let enabled: Bool
  var phoneControls = false
  let act: (TrialCommand) -> Void
  @State private var preview = false
  @State private var previewStep = 0
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        if plan.phase == .idle {
          Picker("本次动作", selection: Binding(get: { plan.stroke }, set: { act(.select($0)) })) {
            ForEach(StandardStroke.trainingGroups, id: \.title) { group in
              Section(group.title) {
                ForEach(group.strokes) { Text($0.displayName).tag($0.rawValue) }
              }
            }
          }.fixedSize().disabled(!enabled)
          Picker(
            "采集速度", selection: Binding(get: { plan.selectedSpeed }, set: { act(.setSpeed($0)) })
          ) {
            ForEach(CaptureSpeed.recordingOptions) { Text($0.title).tag($0) }
          }.fixedSize().disabled(!enabled)
        } else {
          Text(StandardStroke(rawValue: plan.stroke)?.displayName ?? plan.stroke).font(
            .subheadline.bold())
          Text(plan.selectedSpeed.title).font(.caption)
        }
        Spacer()
        Text(plan.title).font(.headline)
      }
      if plan.phase == .calibrating {
        PositionDemonstration(step: plan.step, left: plan.left, feedback: plan.feedback)
          .id(plan.step)
      } else if plan.phase == .idle && preview {
        PositionDemonstration(step: previewStep, left: plan.left).id(previewStep)
      } else if let stroke = StandardStroke(rawValue: plan.stroke) {
        StrokeDemonstration(
          stroke: stroke, left: plan.left, elapsed: nil, recording: plan.phase == .recording,
          speed: plan.selectedSpeed
        )
        .foregroundStyle(.white).id(
          stroke.rawValue + plan.selectedSpeed.rawValue + String(plan.phase == .recording))
      } else {
        Label("按自己的节奏完成连续回合", systemImage: "figure.badminton").font(.title3)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      HStack {
        if plan.phase != .calibrating {
          Text(plan.feedback.isEmpty && !plan.prepared ? "等待 Mac 选择目录、开启摄像头并连接手机" : plan.feedback)
            .font(.caption).lineLimit(2)
        }
        Spacer()
        switch plan.phase {
        case .idle:
          if preview {
            Button("下一姿势") { previewStep = (previewStep + 1) % 4 }
            Button("返回动作示范") { preview = false }
          } else {
            Button("先看握持与校准") {
              previewStep = 0
              preview = true
            }
          }
          Button("开始本次校准") {
            preview = false
            act(.prepare)
          }.disabled(!plan.prepared)
        case .ready:
          if phoneControls { Button("确认开始采集") { act(.begin) } }
        case .recording:
          if phoneControls { Button("确认结束并保存") { act(.finish) } }
        case .arming, .saving: ProgressView().controlSize(.small)
        case .calibrating: Text("到位后自动确认").font(.caption)
        }
      }.buttonStyle(.borderedProminent).disabled(!enabled)
    }
  }
}

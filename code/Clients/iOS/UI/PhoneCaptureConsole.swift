import SwiftUI

struct PhoneCaptureConsole: View {
  @ObservedObject var sender = StudioSender.shared
  let back: () -> Void
  @State private var cancel = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button(action: back) { Label("球社", systemImage: "chevron.left") }
          .disabled(sender.guide.phase != .idle && sender.linked)
        Spacer()
        Label(sender.linked ? "Mac 已连接" : "连接工作台", systemImage: sender.linked ? "link" : "macbook")
        if sender.linked && sender.guide.phase != .idle && sender.guide.phase != .saving {
          Button("取消本次") { cancel = true }
        }
      }.font(.subheadline.bold())
      if sender.linked {
        GuidedTrialView(plan: sender.guide, enabled: true, phoneControls: true, act: sender.act)
      } else if sender.guide.phase == .recording || sender.guide.phase == .saving {
        Text(sender.guide.phase == .recording ? "连接中断，运动数据在手机端继续保存。重连后可确认结束。" : "连接中断，正在等待重连补传。")
          .font(.headline).frame(maxWidth: .infinity, maxHeight: .infinity)
        Text(sender.status).font(.caption)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            Text("联合动作采集").font(.title.bold())
            StudioPairing()
          }.frame(maxWidth: 580).frame(maxWidth: .infinity)
        }
      }
    }.padding(.horizontal, 16).padding(.vertical, 5)
      .confirmationDialog("取消本拍？校准及已录数据将作为部分记录保存。", isPresented: $cancel) {
        Button("取消本拍并保留记录", role: .destructive) { sender.act(.cancel) }
      }
      .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
      .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }
}

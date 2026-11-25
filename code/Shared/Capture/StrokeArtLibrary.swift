import SwiftUI

/// Ordered like the gameplay collection scenes. The reference drawings use a right-handed player.
struct StrokeArtLibrary: View {
  private static let groups = [
    ("网前高点", ["扑球","推球","轻放网"]), ("贴网慢球", ["放直线","勾对角","推空当"]),
    ("网前低点", ["挑直线","挑对角","轻托回网"]), ("侧面平快球", ["正手平抽","反手平抽","减力挡网"]),
    ("接杀防守", ["接杀挡网","接杀挑高","接杀反抽"]), ("半场高点", ["点杀","下压突击","轻吊"]),
    ("后场高球", ["高远球","吊球","扣杀"]), ("平快压底线", ["平高球","被动高远球","过渡吊球"]),
    ("反手底角", ["反手高远","反手吊球","头顶正手处理"]),
    ("发球", ["正手高远发球","正手短发球","反手短发球","反手偷后场"])
  ]
  @Environment(\.dismiss) private var dismiss
  @State private var action: String

  init(stroke: StandardStroke) {
    let aliases: [StandardStroke:String] = [.clear:"高远球", .smash:"扣杀", .lift:"挑直线", .net:"轻放网",
      .netPush:"推球", .netKill:"扑球", .drive:"正手平抽", .shortServe:"反手短发球"]
    _action = State(initialValue: aliases[stroke] ?? stroke.rawValue)
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Picker("打法", selection: $action) {
          ForEach(Self.groups, id: \.0) { group in
            Section(group.0) {
              ForEach(group.1, id: \.self) { name in Text(name).tag(name) }
            }
          }
        }.pickerStyle(.menu)
        Spacer()
        Button("完成") { dismiss() }
      }
      Image("V2-" + action).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text(action + "右手四姿分镜"))
      Text("右手示意 · 从左到右看准备、引拍、击球和随挥").font(.caption)
    }.padding()
    #if os(macOS)
    .frame(minWidth: 680, minHeight: 410)
    #endif
  }
}

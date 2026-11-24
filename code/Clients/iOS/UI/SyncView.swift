import SwiftUI

/// Taps are compared with the nearest visual crossing on the same monotonic clock.
struct SyncView: View {
  let save: (Double) -> Void
  @State private var origin = ProcessInfo.processInfo.systemUptime
  @State private var taps: [Double] = []
  @State private var lastBeat = -1
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("看电视，光点到达中线时点一下。前两次用于熟悉节奏。").font(.headline)
      TimelineView(.animation) { _ in
        GeometryReader { g in
          let t =
            (ProcessInfo.processInfo.systemUptime - origin).truncatingRemainder(dividingBy: 1.6)
            / 1.6
          ZStack {
            Capsule().fill(.white.opacity(0.2)).frame(height: 3)
            Rectangle().fill(.white).frame(width: 2, height: 35)
            Circle().fill(.mint).frame(width: 17, height: 17).position(
              x: g.size.width * t, y: g.size.height / 2)
          }
        }
      }.frame(height: 50)
      if taps.count < 8 {
        Button("点按同步   \(taps.count) / 8") {
          let elapsed = ProcessInfo.processInfo.systemUptime - origin
          let beat = Int(floor(elapsed / 1.6))
          let lag = elapsed - (Double(beat) * 1.6 + 0.8)
          guard beat != lastBeat, abs(lag) < 0.55 else { return }
          lastBeat = beat
          taps.append(lag * 1000)
        }.buttonStyle(.borderedProminent).controlSize(.large)
      } else {
        let values = taps.dropFirst(2).sorted()
        let result = min(250, max(0, (values[2] + values[3]) / 2)).rounded()
        Button("采用 \(Int(result)) ms 补偿") { save(result) }.buttonStyle(.borderedProminent)
      }
    }
  }
}

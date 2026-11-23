import SwiftUI

struct StrokeDemonstration: View {
  let stroke: StandardStroke
  let left: Bool
  let elapsed: Double?
  let recording: Bool
  var speed: CaptureSpeed = .normal
  @Environment(\.accessibilityReduceMotion) private var reduced
  @State private var origin = Date()
  @State private var selected: Int?

  var body: some View {
    TimelineView(.animation(minimumInterval: 1/60, paused: elapsed != nil || (!recording && selected != nil) || reduced)) { clock in
      let preview = (max(0, clock.date.timeIntervalSince(origin)) * speed.playbackRate).truncatingRemainder(dividingBy: 4.4)
      let step = selected ?? 0
      let stop = step == 3 ? 3.43 : StandardStroke.bounds[step + 1] - 0.001
      let time = elapsed.map { $0 * speed.playbackRate } ?? (reduced || (!recording && selected != nil) ? stop : preview)
      let phase = StandardStroke.phase(time)
      HStack(spacing: 0) {
        StrokeCourt(stroke: stroke, left: left, time: time)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        VStack(alignment: .leading, spacing: 7) {
          Text("\(left ? "左手" : "右手")示范").font(.caption.weight(.semibold)).foregroundStyle(.mint)
          Text(stroke.displayName).font(.system(size: 27, weight: .heavy, design: .rounded))
          Text(stroke.lesson.0).font(.subheadline.bold())
          Spacer(minLength: 2)
          HStack(spacing: 4) {
            ForEach(0..<4) { index in
              Capsule().fill(index == phase ? Color.orange : .white.opacity(0.22)).frame(height: 3)
            }
          }
          Text("\(phase + 1)  \(StandardStroke.phases[phase])").font(.headline)
          Text(stroke.cues[phase]).font(.callout)
          if !recording {
            HStack {
              Button("分步查看") { selected = selected.map { ($0+1)%4 } ?? 0 }
              if selected != nil && !reduced { Button("连播") { selected = nil; origin = Date() } }
            }.font(.footnote.bold()).buttonStyle(.bordered)
          }
        }.padding(12).frame(width: 190, alignment: .leading)
      }.background(Color(red:0.08, green:0.19, blue:0.20)).clipShape(RoundedRectangle(cornerRadius:16))
    }
  }
}

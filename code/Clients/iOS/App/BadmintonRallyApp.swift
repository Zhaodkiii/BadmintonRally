import AVFoundation
import SwiftUI

@main struct BadmintonRallyApp: App {
  var body: some Scene {
    WindowGroup {
      #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-contactFrameReplay") {
        ContactFrameReplay()
      } else {
        ClubView().preferredColorScheme(.dark)
      }
      #else
      ClubView().preferredColorScheme(.dark)
      #endif
    }
  }
}

final class MatchFeedback {
  private var clips: [String: AVAudioPlayer] = [:]
  init() {
    for name in ["tap", "smash", "point"] {
      if let url = Bundle.main.url(forResource: name, withExtension: "wav"),
        let clip = try? AVAudioPlayer(contentsOf: url)
      {
        clip.prepareToPlay()
        clips[name] = clip
      }
    }
  }
  func play(_ name: String, sound: Bool, vibration: Bool) {
    if sound, let clip = clips[name] {
      clip.currentTime = 0
      clip.play()
    }
    if vibration {
      UIImpactFeedbackGenerator(style: name == "smash" ? .medium : .light).impactOccurred()
    }
  }
}

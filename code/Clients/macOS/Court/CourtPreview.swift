import AVFoundation
import SwiftUI

struct CourtPreview: NSViewRepresentable {
  let display: AVSampleBufferDisplayLayer

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    display.videoGravity = .resizeAspect
    display.backgroundColor = NSColor.black.cgColor
    view.wantsLayer = true
    view.layer = display
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

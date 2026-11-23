import AVFoundation
import Vision

/// Keep at most one camera frame in flight. Pose inference never blocks the movie writer.
final class WristTracker {
  private let gate = DispatchSemaphore(value: 1),
    queue = DispatchQueue(label: "rally.capture.wrist", qos: .utility)
  private var last = -Double.infinity
  var observe: ((WristObservation?, WristObservation?) -> Void)?
  func submit(_ buffer: CMSampleBuffer, time: Double) {
    guard time - last >= 0.18, gate.wait(timeout: .now()) == .success else { return }
    last = time
    queue.async {
      defer { self.gate.signal() }
      let req = VNDetectHumanBodyPoseRequest()
      try? VNImageRequestHandler(cmSampleBuffer: buffer, orientation: .up).perform([req])
      guard let body = req.results?.first, req.results?.count == 1,
        let a = try? body.recognizedPoint(.leftShoulder),
        let b = try? body.recognizedPoint(.rightShoulder),
        min(a.confidence, b.confidence) >= 0.35,
        let pix = CMSampleBufferGetImageBuffer(buffer)
      else {
        self.observe?(nil, nil)
        return
      }
      let ratio = Double(CVPixelBufferGetHeight(pix)) / Double(CVPixelBufferGetWidth(pix))
      let span = abs(b.x - a.x)
      let midX = (a.x + b.x) / 2
      let midY = (a.y + b.y) / 2
      guard span > 0.045 else {
        self.observe?(nil, nil)
        return
      }
      func position(_ left: Bool) -> WristObservation? {
        guard let w = try? body.recognizedPoint(left ? .leftWrist : .rightWrist),
          w.confidence >= 0.35
        else { return nil }
        let side = (left ? a.x : b.x) > midX ? 1.0 : -1.0
        return .init(
          time: time, x: side * (w.x - midX) / span, y: (w.y - midY) * ratio / span,
          confidence: Double(min(w.confidence, min(a.confidence, b.confidence))))
      }
      self.observe?(position(true), position(false))
    }
  }
}

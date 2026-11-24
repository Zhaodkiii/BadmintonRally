#if DEBUG
import CoreImage
import ReplayKit
import VideoToolbox

/// ReplayKit supplies the app's composited frames directly to the hardware encoder.
final class CourtStream {
  private let recorder = RPScreenRecorder.shared()
  private var requested: UUID?
  private var running: UUID?
  private var changing = false
  private var failed: UUID?
  var error: (String?) -> Void = { _ in }

  func update(_ match: UUID?) {
    guard requested != match else { return }
    requested = match
    if match == nil { failed = nil; error(nil) }
    reconcile()
  }

  private func reconcile() {
    guard !changing, requested != running || (running != nil && failed == running) else { return }
    if let running {
      StudioSender.shared.closeScreen(running)
      changing = true
      recorder.stopCapture { _ in
        DispatchQueue.main.async {
          self.running = nil
          self.changing = false
          self.reconcile()
        }
      }
    } else if let match = requested, failed != match {
      changing = true
      StudioSender.shared.openScreen(match)
      recorder.startCapture(handler: { sample, kind, failure in
        if let failure {
          DispatchQueue.main.async {
            guard self.requested == match else { return }
            self.failed = match
            self.error(failure.localizedDescription)
            self.reconcile()
          }
        } else if kind == .video {
          StudioSender.shared.screenFrame(match, sample: sample)
        }
      }, completionHandler: { failure in
        DispatchQueue.main.async {
          self.changing = false
          if let failure {
            self.failed = match
            StudioSender.shared.closeScreen(match)
            self.error(failure.localizedDescription)
          } else { self.running = match }
          self.reconcile()
        }
      })
    }
  }
}

final class CourtEncoder {
  private var session: VTCompressionSession?
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var pool: CVPixelBufferPool?
  private var currentBitrate = 0
  private var dimensions = CMVideoDimensions(width: 0, height: 0)

  func encode(_ pixel: CVPixelBuffer, time: Double, bitrate: Int, key: Bool,
              completion: @escaping (CMSampleBuffer?) -> Void) -> Bool {
    let sourceWidth = CVPixelBufferGetWidth(pixel)
    let sourceHeight = CVPixelBufferGetHeight(pixel)
    let scale = min(1, 1280.0 / Double(max(sourceWidth, sourceHeight)))
    let width = Int32(Double(sourceWidth) * scale) / 2 * 2
    let height = Int32(Double(sourceHeight) * scale) / 2 * 2
    guard width > 0, height > 0 else { return false }
    if width != dimensions.width || height != dimensions.height || session == nil {
      if let session { VTCompressionSessionInvalidate(session) }
      session = nil
      pool = nil
      if scale < 1 {
        CVPixelBufferPoolCreate(nil, nil, [
          kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
          kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pool)
        guard pool != nil else { return false }
      }
      currentBitrate = 0
      guard VTCompressionSessionCreate(allocator: nil, width: width, height: height,
        codecType: kCMVideoCodecType_H264, encoderSpecification: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary, imageBufferAttributes: nil,
        compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
        let session else { return false }
      dimensions = CMVideoDimensions(width: width, height: height)
      VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
      VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
      VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
      VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
      VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
      VTCompressionSessionPrepareToEncodeFrames(session)
    }
    guard let session else { return false }
    if bitrate != currentBitrate,
       VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber) == noErr {
      currentBitrate = bitrate
    }
    var input = pixel
    if let pool {
      var resized: CVPixelBuffer?
      guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &resized) == kCVReturnSuccess, let resized else { return false }
      let image = CIImage(cvPixelBuffer: pixel).transformed(by: CGAffineTransform(
        scaleX: CGFloat(width) / CGFloat(sourceWidth), y: CGFloat(height) / CGFloat(sourceHeight)))
      context.render(image, to: resized)
      input = resized
    }
    let options = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
    return VTCompressionSessionEncodeFrame(session, imageBuffer: input,
      presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 60000),
      duration: .invalid, frameProperties: options, infoFlagsOut: nil) { status, _, result in
        completion(status == noErr ? result : nil)
      } == noErr
  }

  deinit { if let session { VTCompressionSessionInvalidate(session) } }
}
#endif

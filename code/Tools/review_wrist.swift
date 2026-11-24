// swift Tools/review_wrist.swift <movie> <video seconds> <left|right>
// Samples the requested wrist around an IMU peak; missing detections stay missing.
import AVFoundation
import Vision

let args = CommandLine.arguments
guard args.count == 4, let peak = Double(args[2]) else { exit(2) }
let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: args[1])))
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: 960, height: 960)
generator.requestedTimeToleranceBefore = CMTime(seconds: 0.025, preferredTimescale: 6000)
generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
for k in -8...8 {
  autoreleasepool {
    var actual = CMTime.zero
    guard let image = try? generator.copyCGImage(at: CMTime(seconds: peak + Double(k)/30, preferredTimescale: 60000), actualTime: &actual) else { return }
    let pose = VNDetectHumanBodyPoseRequest()
    let handler = VNImageRequestHandler(cgImage: image)
    guard (try? handler.perform([pose])) != nil, let bodies = pose.results, bodies.count == 1,
          let wrist = try? bodies[0].recognizedPoint(args[3] == "左手" ? .leftWrist : .rightWrist),
          wrist.confidence >= 0.30 else { return }
    print(actual.seconds,wrist.location.x * CGFloat(image.width),wrist.location.y * CGFloat(image.height),wrist.confidence)
  }
}

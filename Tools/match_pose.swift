// Read chronological, near-player crops and export measured joints in crop pixels.
import AppKit
import Vision

guard (2...3).contains(CommandLine.arguments.count) else { exit(2) }
let hand = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "right"
guard hand == "left" || hand == "right" else { exit(2) }
let left = hand == "left"
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
print("frame,joint,x,y,confidence")
for file in files.filter({ $0.pathExtension == "jpg" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    autoreleasepool {
        let request = VNDetectHumanBodyPoseRequest()
        guard let source = CGImageSourceCreateWithURL(file as CFURL,nil),
              let image = CGImageSourceCreateImageAtIndex(source,0,nil),
              (try? VNImageRequestHandler(cgImage:image).perform([request])) != nil,
              let bodies = request.results else { return }
        // Crop includes a sliver of far court. Only accept a unique near-court pelvis.
        let near = bodies.filter {
            guard let hip = try? $0.recognizedPoint(.root) else { return false }
            return hip.confidence >= 0.35 && hip.location.y < 0.63 && hip.location.y > 0.08
        }
        guard near.count == 1 else { return }
        let joints: [(String,VNHumanBodyPoseObservation.JointName)] = [
            ("shoulder",left ? .leftShoulder : .rightShoulder),("elbow",left ? .leftElbow : .rightElbow),
            ("wrist",left ? .leftWrist : .rightWrist),("hip",left ? .leftHip : .rightHip),
            ("otherShoulder",left ? .rightShoulder : .leftShoulder)]
        for (name,key) in joints {
            guard let p = try? near[0].recognizedPoint(key), p.confidence >= 0.35 else { continue }
            print("\(file.deletingPathExtension().lastPathComponent),\(name),\(p.location.x*Double(image.width)),\((1-p.location.y)*Double(image.height)),\(p.confidence)")
        }
    }
}

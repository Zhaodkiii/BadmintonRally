// Run from the checkout: swift code/Tools/ExportMatchStrokePoses.swift
import Foundation
import Metal
import SceneKit

struct Source {
  let key, model: String
  let frames, impact: Int
  var release: Int? = nil
}

let sources: [Source] = [
  .init(key: "正手高远发球", model: "LinChengForehandHighServe", frames: 44, impact: 24, release: 20),
  .init(key: "正手短发球", model: "LinChengForehandShortServe", frames: 44, impact: 24, release: 20),
  .init(key: "反手短发球", model: "LinChengBackhandShortServe", frames: 38, impact: 18, release: 15),
  .init(key: "反手偷后场", model: "LinChengBackhandFlickServe", frames: 38, impact: 18, release: 15),
  .init(key: "扑球", model: "LinChengForehandNetKill", frames: 46, impact: 19),
  .init(key: "推球", model: "LinChengForehandNetPush", frames: 46, impact: 19),
  .init(key: "轻放网", model: "LinChengForehandSoftNet", frames: 46, impact: 19),
  .init(key: "正手平抽", model: "LinChengForehandDrive", frames: 40, impact: 16),
  .init(key: "反手平抽", model: "LinChengBackhandDrive", frames: 42, impact: 17),
  .init(key: "减力挡网", model: "LinChengForehandSoftBlock", frames: 37, impact: 16),
  .init(key: "高远球", model: "LinChengForehandClear", frames: 52, impact: 24),
  .init(key: "吊球", model: "LinChengForehandDrop", frames: 52, impact: 25),
  .init(key: "扣杀", model: "LinChengForehandSmash", frames: 52, impact: 24),
  .init(key: "反手高远", model: "LinChengBackhandRearClear", frames: 48, impact: 22),
  .init(key: "扑球扑空失衡", model: "LinChengNetOverreachFall", frames: 48, impact: 12),
]

struct StrokeTrack: Codable {
  let model: String
  let impact: Double
  let release: Double?
  let cached: Bool
  let racket, releaseCork: [Float]
  let samples: [[Float]]
}

struct PoseLibrary: Encodable {
  let bones: [String]
  let rate: Double
  let tracks: [String: StrokeTrack]
}

let resources = URL(fileURLWithPath: "code/Clients/iOS/Resources", isDirectory: true)
let rate = 120.0
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal renderer required.") }
var tracks: [String: StrokeTrack] = [:]
var names: [String] = []

for source in sources {
  let url = resources.appendingPathComponent(source.model).appendingPathExtension("usdz")
  let scene = try SCNScene(url: url)
  var bones: [SCNNode] = []
  scene.rootNode.enumerateChildNodes { node, _ in
    if let skin = node.skinner, bones.isEmpty { bones = skin.bones }
    for key in node.animationKeys {
      guard let player = node.animationPlayer(forKey: key) else { continue }
      player.animation.usesSceneTimeBase = true
      player.animation.isRemovedOnCompletion = false
      player.animation.repeatCount = 0
      player.animation.fillsForward = true
      player.play()
    }
  }

  let readNames = bones.compactMap(\.name)
  if names.isEmpty { names = readNames }
  precondition(readNames == names && names.count == 21, source.model)
  let grip = bones[names.firstIndex(of: "racket_grip_R")!]
  let hand = bones[names.firstIndex(of: "hand_L")!]
  let renderer = SCNRenderer(device: device, options: nil)
  renderer.scene = scene
  SCNTransaction.flush()
  var racket: [Float] = []
  var releaseCork: [Float] = []
  let impact = Double(source.impact - 1) / 30
  let samples = (0...((source.frames - 1) * 4)).map { step -> [Float] in
    let time = Double(step) / rate
    renderer.sceneTime = time
    renderer.update(atTime: time)
    if step == (source.impact - 1) * 4 {
      let p = grip.presentation.simdConvertPosition(SIMD3<Float>(0, 0.53, 0), to: nil)
      racket = [p.x, p.y, p.z]
    }
    if let release = source.release, step == (release - 1) * 4 {
      let back = source.model.contains("Backhand")
      let pin = hand.presentation.simdConvertPosition(SIMD3<Float>(-0.006, back ? 0.103 : 0.099, -0.044), to: nil)
      releaseCork = [pin.x, pin.y - (back ? 0.049 : 0.045), pin.z]
    }
    return bones.flatMap { bone in
      let p = bone.presentation.simdPosition, q = bone.presentation.simdOrientation.vector
      return [p.x, p.y, p.z, q.x, q.y, q.z, q.w]
    }
  }
  let cacheURL = url.deletingPathExtension().appendingPathExtension("brmesh")
  tracks[source.key] = .init(model: source.model, impact: impact, release: source.release.map { Double($0 - 1) / 30 },
                            cached: FileManager.default.fileExists(atPath: cacheURL.path), racket: racket, releaseCork: releaseCork, samples: samples)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let file = resources.appendingPathComponent("MatchStrokePoses.json")
try encoder.encode(PoseLibrary(bones: names, rate: rate, tracks: tracks)).write(to: file, options: .atomic)
print("Exported \(tracks.count) tracks at \(Int(rate)) Hz.")

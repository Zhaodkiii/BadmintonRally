import AVFoundation

/// Stores the original compressed frames and their phone/host timestamps.
final class CourtMovie {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let index: FileHandle
  private var awaitingKeyFrame = true

  init(folder: URL, format: CMVideoFormatDescription) throws {
    writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("game.mov"), fileType: .mov)
    writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
    input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
    input.expectsMediaDataInRealTime = true
    let file = folder.appendingPathComponent("screen_frames.csv")
    try Data("video_s,t_phone,t_mac_received\n".utf8).write(to: file)
    index = try FileHandle(forWritingTo: file)
    try index.seekToEnd()
    guard writer.canAdd(input) else { throw CaptureFailure("游戏视频格式不可用") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CaptureFailure("无法开始游戏录像") }
    writer.startSession(atSourceTime: .zero)
  }

  func append(_ sample: CMSampleBuffer, frame: CourtVideoFrame, received: Double) throws {
    guard writer.status == .writing else { throw writer.error ?? CaptureFailure("游戏录像已中断") }
    guard input.isReadyForMoreMediaData else { awaitingKeyFrame = true; return }
    guard !awaitingKeyFrame || !frame.parameters.isEmpty else { return }
    guard input.append(sample) else { throw writer.error ?? CaptureFailure("游戏视频帧写入失败") }
    awaitingKeyFrame = false
    try index.write(contentsOf: Data("\(sample.presentationTimeStamp.seconds),\(frame.time),\(received)\n".utf8))
  }

  func finish(_ completion: @escaping (String?) -> Void) {
    try? index.close()
    guard writer.status == .writing else { completion(writer.error?.localizedDescription); return }
    input.markAsFinished()
    writer.finishWriting { [writer] in completion(writer.error?.localizedDescription) }
  }
}

import AVFoundation
import SwiftUI

final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  let wristTracker = WristTracker()
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "rally.capture.video")
  private var writer: AVAssetWriter?, input: AVAssetWriterInput?, table: FileHandle?,
    directory: URL?
  private var videoFailure: String?
  private var count = 0, dropped = 0
  private var first: CMTime?
  var failure: (String) -> Void = { _ in }
  var firstFrame: () -> Void = {}
  static var cameras: [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
    ).devices
  }
  func configure(id: String, completion: @escaping (String?) -> Void) {
    AVCaptureDevice.requestAccess(for: .video) { allowed in
      self.queue.async {
        guard allowed else {
          completion("请在系统设置中允许摄像头访问")
          return
        }
        self.session.stopRunning()
        self.session.beginConfiguration()
        for i in self.session.inputs { self.session.removeInput(i) }
        for o in self.session.outputs { self.session.removeOutput(o) }
        do {
          guard let device = Self.cameras.first(where: { $0.uniqueID == id }) else {
            throw CaptureFailure("未找到摄像头")
          }
          let i = try AVCaptureDeviceInput(device: device)
          let o = AVCaptureVideoDataOutput()
          guard self.session.canAddInput(i) else { throw CaptureFailure("摄像头不可用") }
          self.session.addInput(i)
          if self.session.canSetSessionPreset(.hd1280x720) {
            self.session.sessionPreset = .hd1280x720
          }
          guard self.session.canAddOutput(o) else { throw CaptureFailure("无法取得摄像头画面") }
          o.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
          o.alwaysDiscardsLateVideoFrames = true
          o.setSampleBufferDelegate(self, queue: self.queue)
          self.session.addOutput(o)
        } catch {
          self.session.commitConfiguration()
          completion(error.localizedDescription)
          return
        }
        self.session.commitConfiguration()
        self.session.startRunning()
        completion(self.session.isRunning ? nil : "摄像头启动失败")
      }
    }
  }
  func arm(_ dir: URL) {
    queue.sync {
      self.directory = dir
      self.first = nil
      self.videoFailure = nil
      self.count = 0
      self.dropped = 0
    }
  }
  func captureOutput(
    _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if directory != nil { dropped += 1 }
  }
  func captureOutput(
    _ output: AVCaptureOutput, didOutput buf: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard directory != nil, videoFailure == nil else { return }
    guard let clock = session.synchronizationClock else {
      reportFailure(CaptureFailure("缺少摄像头时钟"))
      return
    }
    writeFrame(buf, clock: clock)
  }
  // Serial video queue owns both the movie and the PTS table.
  func writeFrame(_ buf: CMSampleBuffer, clock: CMClock) {
    guard let dir = directory, videoFailure == nil else { return }
    do {
      let pts = CMSampleBufferGetPresentationTimeStamp(buf)
      let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
      if writer == nil {
        guard let format = CMSampleBufferGetFormatDescription(buf) else { return }
        let d = CMVideoFormatDescriptionGetDimensions(format)
        let w = try AVAssetWriter(
          outputURL: dir.appendingPathComponent("camera.mov"), fileType: .mov)
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let i = AVAssetWriterInput(
          mediaType: .video,
          outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(d.width), AVVideoHeightKey: Int(d.height),
          ], sourceFormatHint: format)
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { throw CaptureFailure("不支持当前视频格式") }
        w.add(i)
        guard w.startWriting() else { throw w.error ?? CaptureFailure("录像写入失败") }
        w.startSession(atSourceTime: pts)
        writer = w
        input = i
        first = pts
        let url = dir.appendingPathComponent("frames.csv")
        try Data("frame,pts_value,pts_timescale,video_s,t_mac\n".utf8).write(to: url)
        table = try FileHandle(forWritingTo: url)
        try table?.seekToEnd()
      }
      if let writer, writer.status == .failed {
        throw writer.error ?? CaptureFailure("视频写入失败")
      }
      guard let input, let first, input.isReadyForMoreMediaData else {
        dropped += 1
        return
      }
      guard input.append(buf) else { throw writer?.error ?? CaptureFailure("录像中断") }
      let row = "\(count),\(pts.value),\(pts.timescale),\((pts-first).seconds),\(host)\n"
      try table?.write(contentsOf: Data(row.utf8))
      count += 1
      wristTracker.submit(buf, time: host)
      if count == 1 { firstFrame() }
    } catch {
      reportFailure(error)
    }
  }
  private func reportFailure(_ error: Error) {
    guard videoFailure == nil else { return }
    let problem = Self.describe(error)
    videoFailure = problem
    failure(problem)
  }

  private static func describe(_ error: Error) -> String {
    let ns = error as NSError
    let cause =
      (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map {
        " · \($0.domain) \($0.code) \($0.localizedDescription)"
      } ?? ""
    return "录像失败 · \(ns.localizedDescription)（\(ns.domain) \(ns.code)）" + cause
  }

  func stop(_ done: @escaping (String?) -> Void) {
    queue.async {
      if let dir = self.directory {
        try? JSONEncoder().encode(["written": self.count, "dropped": self.dropped]).write(
          to: dir.appendingPathComponent("video_quality.json"))
      }
      self.directory = nil
      try? self.table?.close()
      self.table = nil
      guard let w = self.writer else {
        done("没有录到视频帧")
        return
      }
      let priorFailure = self.videoFailure
      if w.status == .writing { self.input?.markAsFinished() }
      self.input = nil
      self.writer = nil
      guard w.status == .writing else {
        done(priorFailure ?? w.error.map(Self.describe) ?? "视频未完成")
        return
      }
      w.finishWriting {
        done(
          priorFailure ?? (w.status == .completed ? nil : (w.error.map(Self.describe) ?? "视频未完成")))
      }
    }
  }
}

struct CameraPreview: NSViewRepresentable {
  let session: AVCaptureSession
  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspect
    v.layer = layer
    return v
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

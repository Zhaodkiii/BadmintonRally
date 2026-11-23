import AVFAudio
import Combine
import CoreMotion
import UIKit

/// One append-only stream per group. Sensor and marker timestamps both use seconds since boot.
private final class BatchStream {
  let url: URL
  let queue = DispatchQueue(label: "rally.manual-batch.write")
  private let file: FileHandle
  private var closed = false
  private var samples = 0
  private var marks = 0
  private var errorMessage: String?
  private let report: (Int, Int, String?) -> Void

  init(photos: Bool, stroke: StandardStroke, speed: CaptureSpeed, left: Bool, player: String,
       report: @escaping (Int, Int, String?) -> Void) throws {
    self.report = report
    let folder = ManualBatch.folder
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    url = folder.appendingPathComponent("\(stroke.displayName)-\(UUID()).jsonl")
    try Data().write(to: url, options: .withoutOverwriting)
    file = try FileHandle(forWritingTo: url)
    try append(["type":"start", "schema":1, "captureMode":photos ? "cameraMarkers" : "imuOnly", "stroke":stroke.rawValue, "speed":speed.rawValue,
                "leftHand":left, "participant":player, "utc":ISO8601DateFormatter().string(from: Date()),
                "t":ProcessInfo.processInfo.systemUptime, "referenceFrame":"xArbitraryZVertical",
                "requestedHz":100, "clock":"seconds_since_boot", "gyroUnit":"rad/s", "accelerationUnit":"g"])
  }

  private func append(_ row: [String:Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: row)
    bytes.append(10)
    try file.write(contentsOf: bytes)
  }

  private func write(_ row: [String:Any]) -> Bool {
    guard !closed, errorMessage == nil else { return false }
    do { try append(row); return true }
    catch { errorMessage = error.localizedDescription; report(samples, marks, errorMessage); return false }
  }

  func sample(_ m: CMDeviceMotion) {
    queue.async {
      let r = m.rotationRate, a = m.userAcceleration, g = m.gravity, q = m.attitude.quaternion
      guard self.write(["type":"imu","t":m.timestamp,"gyro":[r.x,r.y,r.z],
                        "acc":[a.x,a.y,a.z],"gravity":[g.x,g.y,g.z],"quatXYZW":[q.x,q.y,q.z,q.w]]) else { return }
      self.samples += 1
      if self.samples == 1 || self.samples.isMultiple(of: 100) { self.report(self.samples,self.marks,nil) }
    }
  }

  func mark(time: Double, button: String, photo: String) {
    queue.async {
      guard self.write(["type":"manualContact","t":time,"index":self.marks + 1,
        "source":"cameraCaptureBegan","direction":button,"referencePhoto":photo]) else { return }
      self.marks += 1
      self.report(self.samples,self.marks,nil)
    }
  }

  func finish(_ reason: String) -> (Int,Int,String?) {
    queue.sync {
      _ = write(["type":"end","reason":reason,"t":ProcessInfo.processInfo.systemUptime,
                 "samples":samples,"markers":marks])
      closed = true
      do { try file.synchronize(); try file.close() } catch { errorMessage = error.localizedDescription }
      return (samples,marks,errorMessage)
    }
  }
}

final class ManualBatch: ObservableObject {
  static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("连续挥拍采集", isDirectory: true) }
  @Published private(set) var recording = false
  @Published private(set) var samples = 0
  @Published private(set) var marks = 0
  @Published private(set) var volumeHint = ""
  @Published private(set) var status = ""
  @Published private(set) var files: [URL] = []
  private var stream: BatchStream?
  private let volume = VolumeContactInput()
  private var previousIdle = false

  func reload() {
    files = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
      .filter { $0.pathExtension == "jsonl" }.sorted {
        ((try? $0.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast) >
        ((try? $1.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast)
      }
  }

  func start(photos: Bool, stroke: StandardStroke, speed: CaptureSpeed, left: Bool, player: String) {
    guard !recording else { return }
    guard DeviceMotionSource.shared.available else { status = "设备无法提供运动数据"; return }
    let id = UUID()
    session = id
    do {
      let sink = try BatchStream(photos: photos, stroke: stroke, speed: speed, left: left, player: player) { [weak self] n,k,error in
        DispatchQueue.main.async {
          guard let self, self.session == id, self.recording else { return }
          self.samples = n; self.marks = k
          if let error { self.stop("写入失败 · " + error) }
        }
      }
      if photos {
        volume.onHint = { [weak self] in self?.volumeHint = $0 }
        volume.start(folder: sink.url.deletingPathExtension()) { sink.mark(time: $0, button: $1, photo: $2) }
      }
      stream = sink
      marks = 0; samples = 0; recording = true
      status = "等待第一帧传感器数据"
      previousIdle = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      DeviceMotionSource.shared.subscribe("manualBatch") { [weak self] m,error in
        if let m { sink.sample(m) }
        if let error { DispatchQueue.main.async { if self?.session == id { self?.stop(error.localizedDescription) } } }
      }
    } catch { status = "无法开始 · " + error.localizedDescription }
  }

  private var session: UUID?
  func stop(_ reason: String) {
    guard let stream else { return }
    volume.stop()
    DeviceMotionSource.shared.remove("manualBatch")
    let result = stream.finish(reason)
    self.stream = nil; session = nil; recording = false
    samples = result.0; marks = result.1
    status = result.2.map { "保存异常 · " + $0 } ?? "\(reason) · \(samples) 帧，\(marks) 个标记"
    UIApplication.shared.isIdleTimerDisabled = previousIdle
    reload()
  }
}

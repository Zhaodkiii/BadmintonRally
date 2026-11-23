import AVFoundation
import AVKit
import UIKit

/// One delegate per exposure, retained through the final capture callback.
private final class ReferencePhoto: NSObject, AVCapturePhotoCaptureDelegate {
  let url: URL
  let finished: (Error?) -> Void
  private var failure: Error?

  init(_ url: URL, finished: @escaping (Error?) -> Void) {
    self.url = url
    self.finished = finished
  }
  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    do {
      if let error { throw error }
      guard let bytes = photo.fileDataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
      try bytes.write(to: url, options: .atomic)
    } catch { failure = error }
  }
  func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
    finished(error ?? failure)
  }
}

final class VolumeContactInput {
  private let queue = DispatchQueue(label: "rally.reference-camera")
  private var camera: AVCaptureSession?
  private var observers: [NSObjectProtocol] = []
  private var detach: (() -> Void)?
  private var generation = UUID()
  private var held: [String: URL] = [:]
  private var pending: [Int64: ReferencePhoto] = [:] // camera queue only
  var onReady: ((Bool) -> Void)?
  var onHint: ((String) -> Void)?

  func start(folder: URL, mark: @escaping (Double, String, String) -> Void) {
    stop()
    guard #available(iOS 17.2, *) else { onHint?("拍摄按键需要 iOS 17.2 或更高版本"); return }
    let token = generation
    onHint?("正在准备 iPhone 参考画面相机")
    AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self, self.generation == token else { return }
        guard allowed else { self.onHint?("相机未授权，请在设置中允许后重新开始"); return }
        self.configure(token, folder: folder, mark: mark)
      }
    }
  }

  @available(iOS 17.2, *)
  private func configure(_ token: UUID, folder: URL, mark: @escaping (Double, String, String) -> Void) {
    let session = AVCaptureSession()
    camera = session
    let output = AVCapturePhotoOutput()
    queue.async {
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
          else { throw CocoaError(.featureUnsupported) }
        let input = try AVCaptureDeviceInput(device: device)
        session.automaticallyConfiguresApplicationAudioSession = false
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .speed
        session.startRunning()
        DispatchQueue.main.async {
          guard self.generation == token else { return }
          guard session.isRunning, let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow, let host = window.rootViewController?.view else {
            self.stop(); self.onHint?("相机未就绪，请返回采集页重试"); return
          }
          func handle(_ event: AVCaptureEvent, _ button: String) {
            let t = ProcessInfo.processInfo.systemUptime
            guard self.generation == token else { return }
            switch event.phase {
            case .began:
              guard self.held[button] == nil else { return }
              let url = folder.appendingPathComponent(UUID().uuidString + ".jpg")
              self.held[button] = url
              mark(t, button, url.lastPathComponent)
            case .ended:
              guard let url = self.held.removeValue(forKey: button) else { return }
              self.capture(output, url: url, token: token)
            case .cancelled:
              self.held[button] = nil
              self.onHint?("按键取消，未拍摄本张参考图")
            @unknown default: break
            }
          }
          let interaction = AVCaptureEventInteraction(primary: { handle($0, "primary") }, secondary: { handle($0, "plus") })
          let preview = AVCaptureVideoPreviewLayer(session: session)
          preview.videoGravity = .resizeAspectFill
          let inset = UIView()
          inset.isHidden = true
          inset.isUserInteractionEnabled = false
          inset.translatesAutoresizingMaskIntoConstraints = false
          host.addSubview(inset)
          NSLayoutConstraint.activate([
            inset.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            inset.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            inset.widthAnchor.constraint(equalToConstant: 96), inset.heightAnchor.constraint(equalToConstant: 64)
          ])
          preview.frame = CGRect(x: 0, y: 0, width: 96, height: 64)
          inset.layer.addSublayer(preview)
          host.addInteraction(interaction)
          self.detach = { host.removeInteraction(interaction); inset.removeFromSuperview() }
          for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { _ in
              guard self.generation == token else { return }
              self.stop(); self.onHint?("相机中断，重新进入采集后再标记")
            })
          }
          self.onReady?(true)
          self.onHint?("相机就绪 · 按 ＋ 或 − 标记，松开拍摄")
        }
      } catch { DispatchQueue.main.async {
        if self.generation == token { self.stop(); self.onHint?("相机启动失败 · " + error.localizedDescription) }
      } }
    }
  }

  private func capture(_ output: AVCapturePhotoOutput, url: URL, token: UUID) {
    queue.async {
      let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
      settings.photoQualityPrioritization = .speed
      let id = settings.uniqueID
      let delegate = ReferencePhoto(url) { error in
        self.queue.async { self.pending[id] = nil }
        if let error { DispatchQueue.main.async {
          if self.generation == token { self.onHint?("参考图保存失败 · " + error.localizedDescription) }
        } }
      }
      self.pending[id] = delegate
      output.capturePhoto(with: settings, delegate: delegate)
    }
  }

  func stop() {
    onReady?(false)
    generation = UUID()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    detach?(); detach = nil
    held.removeAll()
    if let session = camera { queue.async { if session.isRunning { session.stopRunning() } } }
    camera = nil
  }
}

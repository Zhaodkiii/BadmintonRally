import CryptoKit
import CoreMotion
import CoreMedia
import Network
import SwiftUI

final class StudioSender: ObservableObject {
  static let shared = StudioSender()
  @Published private(set) var linked=false
  @Published private(set) var guide=TrialPanel()
  @Published var status = "未连接"
  @Published var instruction = ""
  @Published var availableHosts: [String] = []
  @Published private(set) var diagnosticStatus = ""
  private let diagnostics = DiagnosticSync()
  private var diagnosticHost: String?
  #if DEBUG
  private var videoWire: CaptureWire?
  private var videoToken: UUID?
  private var videoReady = false
  private var sentFrames: [Double: Double] = [:]
  private var bitrate = 2_000_000
  private var lastCongestion = 0.0
  private var lastQualityChange = 0.0

  private func connectVideo() {
    guard connected, screenID != nil, videoWire == nil, let token = videoToken,
          let endpoint = endpoints[desired] else { return }
    let link = CaptureWire(NWConnection(to: endpoint, using: CaptureWire.parameters(secret)), queue: work)
    videoWire = link
    link.state = { [weak self, weak link] ready in
      guard let self, let link, self.videoWire === link else { return }
      if ready { link.send(.videoJoin(token)) }
      else {
        self.videoWire = nil
        self.videoReady = false
        self.resetScreenEncoder()
        self.work.asyncAfter(deadline: .now() + 1) { self.connectVideo() }
      }
    }
    link.message = { [weak self, weak link] packet in
      guard let self, let link, self.videoWire === link else { return }
      switch packet {
      case .videoReady: self.videoReady = true
      case .courtFrameAck(let id, let time):
        guard self.screenID == id, let sent = self.sentFrames.removeValue(forKey: time) else { return }
        self.updateVideoQuality(delay: ProcessInfo.processInfo.systemUptime - sent)
      default: link.close()
      }
    }
    link.start()
    work.asyncAfter(deadline: .now() + 4) { [weak self, weak link] in
      if let link, self?.videoWire === link, self?.videoReady == false { link.close() }
    }
  }

  private func updateVideoQuality(delay: Double) {
    let now = ProcessInfo.processInfo.systemUptime
    if delay > 0.14 {
      lastCongestion = now
      if now - lastQualityChange > 2, bitrate > 850_000 {
        bitrate = max(850_000, Int(Double(bitrate) * 0.70))
        lastQualityChange = now
      }
    } else if now - max(lastCongestion, lastQualityChange) > 10, bitrate < 2_000_000 {
      bitrate = min(2_000_000, bitrate + 300_000)
      lastQualityChange = now
    }
  }

  private let screenSlots = DispatchSemaphore(value: 2)
  private var screenID: UUID?
  private var screenEpoch = UUID()
  private var encoder = CourtEncoder()
  private var needsKeyFrame = true
  private var screenClockOffset: Double?
  private var lastScreen = -Double.infinity

  func openScreen(_ id: UUID) {
    work.async {
      self.screenID = id
      self.resetScreenEncoder()
      self.connectVideo()
    }
  }

  private func resetScreenEncoder() {
    screenEpoch = UUID()
    encoder = CourtEncoder()
    sentFrames.removeAll()
    needsKeyFrame = true
    lastScreen = -.infinity
    screenClockOffset = nil
  }

  func screenFrame(_ id: UUID, sample: CMSampleBuffer) {
    guard screenSlots.wait(timeout: .now()) == .success else { return }
    work.async {
      guard self.connected, self.desired == self.diagnosticHost, self.screenID == id,
            self.videoReady, let pixel = sample.imageBuffer else {
        self.screenSlots.signal()
        return
      }
      let now = ProcessInfo.processInfo.systemUptime
      if let oldest = self.sentFrames.values.min(), now - oldest > 0.140 {
        self.updateVideoQuality(delay: now - oldest)
        if now - oldest > 0.85 { self.videoWire?.close() }
        self.screenSlots.signal()
        return
      }
      guard self.sentFrames.count < 4 else { self.screenSlots.signal(); return }
      let pts = sample.presentationTimeStamp.seconds
      guard pts.isFinite else { self.screenSlots.signal(); return }
      let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
      let uptime = ProcessInfo.processInfo.systemUptime
      if self.screenClockOffset == nil {
        self.screenClockOffset = abs(pts - host) < 5 ? uptime - host : uptime - pts
      }
      let time = pts + (self.screenClockOffset ?? 0)
      guard time.isFinite, time - self.lastScreen >= 0.030 else { self.screenSlots.signal(); return }
      self.lastScreen = time
      let epoch = self.screenEpoch
      let queued = self.encoder.encode(pixel, time: time, bitrate: self.bitrate, key: self.needsKeyFrame) { result in
        self.work.async {
          defer { self.screenSlots.signal() }
          guard self.screenEpoch == epoch else { return }
          guard let result, let packet = CourtVideoFrame(match: id, time: time, sample: result) else {
            self.needsKeyFrame = true
            return
          }
          guard !self.needsKeyFrame || !packet.parameters.isEmpty else { return }
          self.needsKeyFrame = false
          self.sentFrames[time] = ProcessInfo.processInfo.systemUptime
          self.videoWire?.sendVideo(packet)
        }
      }
      if !queued { self.needsKeyFrame = true; self.screenSlots.signal() }
    }
  }

  func closeScreen(_ id: UUID) {
    work.async {
      guard self.screenID == id else { return }
      self.screenID = nil
      self.resetScreenEncoder()
      self.videoWire?.send(.courtClosed(id))
      self.videoWire?.close()
    }
  }
  private var liveInFlight: LiveRallyTelemetry?

  private var liveQueue: [URL] = []
  private var liveFolder: URL?

  private func useLiveQueue(_ host: String) throws {
    let folder = base.appendingPathComponent("比赛待传")
      .appendingPathComponent(DiagnosticChunk.checksum(Data(host.utf8)))
    guard liveFolder != folder else { return }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    liveQueue = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    liveFolder = folder
    liveInFlight = nil
  }

  func sendLiveRally(_ batch: LiveRallyTelemetry) {
    work.async {
      guard let host = self.diagnosticHost else { return }
      do {
        try self.useLiveQueue(host)
        guard let folder = self.liveFolder else { return }
        let name = String(format: "%020lld", Int64(Date().timeIntervalSince1970 * 1000000))
          + "-\(batch.match)-" + String(format: "%012d", batch.sequence)
        let file = folder.appendingPathComponent(name).appendingPathExtension("json")
        try JSONEncoder().encode(batch).write(to: file, options: .atomic)
        self.liveQueue.append(file)
        self.pumpLive()
      } catch { self.report("比赛缓存失败 · " + error.localizedDescription) }
    }
  }

  private func pumpLive() {
    guard connected, desired == diagnosticHost, let wire, liveInFlight == nil,
          let file = liveQueue.first else { return }
    do {
      let batch = try JSONDecoder().decode(LiveRallyTelemetry.self, from: Data(contentsOf: file))
      liveInFlight = batch
      wire.send(.liveRally(batch))
      work.asyncAfter(deadline: .now() + 5) { [weak self, weak wire] in
        guard let self, self.wire === wire, self.liveInFlight?.match == batch.match,
              self.liveInFlight?.sequence == batch.sequence else { return }
        wire?.close()
      }
    } catch { report("比赛待传文件读取失败 · " + error.localizedDescription) }
  }
  #endif
  private let work = DispatchQueue(label: "rally.capture.phone")
  private let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("StudioOutbox")
  private var browser: NWBrowser?, wire: CaptureWire?
  private var endpoints: [String: NWEndpoint] = [:]
  private var secret = "", desired = "", connected = false
  private var session: UUID?, rows: [MotionRow] = []
  private var pendingEvents: [PhoneEvent] = []
  private var batch = 0, next = 0, inFlight = false, reason: String?
  private var folder: URL { base.appendingPathComponent(session!.uuidString) }
  private func report(_ text: String) { DispatchQueue.main.async { self.status = text } }
  private init() {
    work.async {
      // One pending session at a time. Recover the last complete batch after process death.
      if let id = try? String(
        contentsOf: self.base.appendingPathComponent("active"), encoding: .utf8),
        let uuid = UUID(uuidString: id)
      {
        self.session = uuid
        let names = (try? FileManager.default.contentsOfDirectory(atPath: self.folder.path)) ?? []
        self.batch = (names.compactMap { Int($0) }.max() ?? -1) + 1
        self.reason = "interrupted"
        self.report("有待补传的采集，请重新连接原 Mac")
      }
    }
  }
  func resumeDiagnosticSync(_ ticket: NearbyPairing.Ticket?) {
    browse()
    work.async {
      self.diagnosticHost = ticket?.host
      #if DEBUG
      if let host = ticket?.host {
        do { try self.useLiveQueue(host); self.pumpLive() }
        catch { self.report(error.localizedDescription) }
      }
      #endif
      for url in MotionTestTrace.archived().reversed() { self.diagnostics.enqueueArchived(url) }
      self.pumpDiagnostics()
    }
    if let ticket { connect(ticket.host, code: ticket.secret) }
  }

  func queueDiagnostic(_ url: URL) {
    work.async {
      self.diagnostics.enqueue(url)
      self.pumpDiagnostics()
    }
  }

  private func showDiagnostic(_ prefix: String) {
    let count = diagnostics.count
    DispatchQueue.main.async {
      self.diagnosticStatus = count == 0 ? prefix : "\(prefix) · 待同步 \(count) 组"
    }
  }

  private func pumpDiagnostics() {
    guard let wire, connected, desired == diagnosticHost else { showDiagnostic("手机本地保存"); return }
    do {
      guard let attempt = try diagnostics.pump(send: wire.send) else { return }
      showDiagnostic("同步到 Mac")
      work.asyncAfter(deadline: .now() + 20) { [weak self, weak wire] in
        guard let self, self.wire === wire, self.diagnostics.active?.attempt == attempt else { return }
        wire?.close()
      }
    } catch { showDiagnostic(error.localizedDescription) }
  }

  func browse() {
    work.async {
      guard self.browser == nil else { return }
      let b = NWBrowser(for: .bonjour(type: CaptureWire.service, domain: nil), using: .tcp)
      self.browser = b
      b.browseResultsChangedHandler = { results, _ in
        self.endpoints.removeAll()
        for result in results {
          if case .service(let name, _, _, _) = result.endpoint {
            self.endpoints[name] = result.endpoint
          }
        }
        let names = self.endpoints.keys.sorted()
        DispatchQueue.main.async { self.availableHosts = names }
        self.connectIfPossible()
        #if DEBUG
        self.connectVideo()
        #endif
      }
      b.stateUpdateHandler = { state in
        if case .failed(let err) = state { self.report(err.localizedDescription) }
      }
      b.start(queue: self.work)
    }
  }
  func connect(_ host: String, code: String) {
    work.async {
      let normalized = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
      guard self.desired != host || self.secret != normalized || self.wire == nil else { return }
      self.desired = host
      self.secret = normalized
      self.wire?.close()
      self.connectIfPossible()
    }
  }
  private func connectIfPossible() {
    guard wire == nil, let ep = endpoints[desired], !secret.isEmpty else { return }
    let w = CaptureWire(NWConnection(to: ep, using: CaptureWire.parameters(secret)), queue: work)
    wire = w
    w.message = { [weak self] in self?.handle($0) }
    w.state = { [weak self, weak w] ok in
      guard let self, self.wire === w else { return }
      DispatchQueue.main.async {self.linked=ok}
      self.connected = ok
      self.inFlight = false
      #if DEBUG
      self.liveInFlight = nil
      self.videoToken = nil
      self.videoWire?.close()
      self.resetScreenEncoder()
      #endif
      if ok {
        let ticket = NearbyPairing.Ticket(host: self.desired, secret: self.secret)
        if let encoded = try? JSONEncoder().encode(ticket) {
          CaptureTrust.save(encoded, as: "iphone-test-host")
        }
        self.diagnosticHost = self.desired
        self.report(self.session == nil ? "已连接，等待 Mac 开始" : "已重连，等待补传")
        var hw = utsname()
        uname(&hw)
        let hardware = withUnsafeBytes(of: &hw.machine) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        var build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        #if DEBUG
        build += CaptureWire.videoCapability
        #endif
        w?.send(
          .hello(
            device: hardware, system: UIDevice.current.systemVersion,
            build: build,
            pending: self.session))
        if self.desired == self.diagnosticHost { self.showDiagnostic("已连接测试 Mac") }
        self.pumpDiagnostics()
        #if DEBUG
        do { try self.useLiveQueue(self.desired); self.pumpLive() }
        catch { self.report(error.localizedDescription) }
        #endif
      } else {
        self.diagnostics.disconnected()
        self.showDiagnostic("手机本地保存")
        self.wire = nil
        self.report("连接已断开，请检查网络与配对密钥")
        self.work.asyncAfter(deadline: .now() + 3) { self.connectIfPossible() }
      }
    }
    w.start()
  }
  func disconnect() {
    work.async {
      self.finish("phone_disconnected")
      self.desired = ""
      self.wire?.close()
      self.browser?.cancel()
      self.browser = nil
      self.endpoints = [:]
      DispatchQueue.main.async { self.availableHosts = [] }
    }
  }
  func interrupt() { work.async { self.finish("interrupted") } }
  func event(_ label: String, at t: Double) {
    work.async {
      if self.session != nil, self.reason == nil {
        self.pendingEvents.append(PhoneEvent(t: t, name: label))
      }
    }
  }
  func act(_ cmd:TrialCommand){
    let token=guide.token
    work.async {guard self.connected else{return};self.wire?.send(.command(token,cmd))}
  }
  private func handle(_ m: CaptureMessage) {
    switch m {
    #if DEBUG
    case .videoOffer(let token):
      videoToken = token
      connectVideo()
    case .liveRallyAck(let id, let sequence):
      if liveInFlight?.match == id, liveInFlight?.sequence == sequence, let file = liveQueue.first {
        do {
          try FileManager.default.removeItem(at: file)
          liveQueue.removeFirst()
          liveInFlight = nil
          pumpLive()
        } catch { report(error.localizedDescription); wire?.close() }
      }
    #endif
    case .diagnosticReceipt(let id, let digest, let error):
      do {
        if try diagnostics.acknowledge(id, digest: digest, error: error) {
          showDiagnostic("已保存到 Mac")
          pumpDiagnostics()
        }
      } catch {
        showDiagnostic(error.localizedDescription)
        work.asyncAfter(deadline: .now() + 8) { self.pumpDiagnostics() }
      }
    case .panel(let panel):DispatchQueue.main.async {self.guide=panel}
    case .notice(let msg):report(msg)
    case .ping(let t):
      let p = ProcessInfo.processInfo.systemUptime
      wire?.send(.pong(t, p, ProcessInfo.processInfo.systemUptime))
    case .start(let id):
      if session == id {
        pump()
        return
      }
      guard session == nil, DeviceMotionSource.shared.available else {
        wire?.send(.error("手机有待补传数据或传感器不可用"))
        return
      }
      do {
        try FileManager.default.createDirectory(
          at: base.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        try id.uuidString.write(
          to: base.appendingPathComponent("active"), atomically: true, encoding: .utf8)
      } catch {
        wire?.send(.error(error.localizedDescription))
        return
      }
      session = id
      rows = []
      pendingEvents = []
      reason = nil
      batch = 0
      next = 0
      inFlight = false
      DispatchQueue.main.async {
        DeviceMotionSource.shared.subscribe("studio") { [weak self] data, error in
          guard let self else { return }
          self.work.async {
            guard self.session == id, self.reason == nil else { return }
            guard let d = data, error == nil else {
              self.finish("sensor_interrupted")
              return
            }
            let r = d.rotationRate
            let a = d.userAcceleration
            let g = d.gravity
            let q = d.attitude.quaternion
            self.rows.append(
              MotionRow(
                events: self.pendingEvents.isEmpty ? nil : self.pendingEvents, t: d.timestamp,
                v: [r.x, r.y, r.z, a.x, a.y, a.z, g.x, g.y, g.z, q.x, q.y, q.z, q.w]))
            self.pendingEvents.removeAll(keepingCapacity: true)
            if self.rows.count >= 10 {
              self.flush()
              self.pump()
            }
          }
        }
      }
      report("开发采集中，可返回比赛或动作演示")
    case .cue(let id, let text) where id == session && reason == nil:
      pendingEvents.append(PhoneEvent(t: ProcessInfo.processInfo.systemUptime, name: "cue:" + text))
      DispatchQueue.main.async { self.instruction = text }
    case .stop(let id) where id == session: finish("complete")
    case .resume(let id, let n) where id == session:
      guard (0...batch).contains(n) else {
        wire?.send(.error("补传序号超出手机日志"))
        return
      }
      next = n
      inFlight = false
      pump()
    case .ack(let id, let n) where id == session && n == next + 1:
      next = n
      inFlight = false
      pump()
    case .finished(let id) where id == session && reason != nil:
      do {
        try FileManager.default.removeItem(at: base.appendingPathComponent("active"))
        try? FileManager.default.removeItem(at: folder)
        session = nil
        reason = nil
        report("场次已归档")
      } catch { report(error.localizedDescription) }
    case .error(let msg): report(msg)
    default: break
    }
  }
  private func flush() {
    guard !rows.isEmpty else { return }
    do {
      try JSONEncoder().encode(rows).write(
        to: folder.appendingPathComponent(String(batch)), options: .atomic)
      batch += 1
      rows.removeAll(keepingCapacity: true)
    } catch {
      rows = []
      reason = "phone_disk_error"
      report(error.localizedDescription)
      DispatchQueue.main.async { DeviceMotionSource.shared.remove("studio") }
    }
  }
  private func finish(_ why: String) {
    guard session != nil, reason == nil else { return }
    DispatchQueue.main.async { DeviceMotionSource.shared.remove("studio") }
    DispatchQueue.main.async { self.instruction = "" }
    flush()
    if reason == nil { reason = why }
    pump()
    report("录制结束，等待 Mac 确认")
  }
  private func pump() {
    guard connected, !inFlight, let session else { return }
    if next < batch {
      do {
        let data = try Data(contentsOf: folder.appendingPathComponent(String(next)))
        let block = try JSONDecoder().decode([MotionRow].self, from: data)
        inFlight = true
        wire?.send(.batch(session, next, block))
      } catch {
        wire?.send(.error("补传日志读取失败"))
        report(error.localizedDescription)
      }
    } else if let reason {
      wire?.send(.end(session, batch, reason))
    }
  }
}

struct StudioPairing: View {
  @StateObject private var nearby = NearbyPhone()
  @ObservedObject var sender = StudioSender.shared
  @State private var code = ""
  var body: some View {
    VStack(alignment:.leading,spacing:8) {
      if sender.linked {
        HStack {Label("已连接采集工作台",systemImage:"checkmark.circle.fill");Spacer()
          Button("断开连接"){sender.disconnect()}.disabled(sender.guide.phase != .idle)}
      } else {
        Text("在 Mac 打开「连接 iPhone」，两端接入同一局域网。").font(.callout)
        HStack {
          Button("查找附近的 Mac"){nearby.browse()}
          ForEach(nearby.names.keys.sorted(by:{$0.uuidString<$1.uuidString}),id:\.self){id in
            Button(nearby.names[id] ?? "Mac"){nearby.pair(id)}
          }
        }
        if !nearby.status.isEmpty {Text(nearby.status).font(.headline)}
        DisclosureGroup("使用局域网密钥连接"){
          HStack {
            Button("搜索局域网"){sender.browse()}
            TextField("输入 Mac 显示的密钥",text:$code).textFieldStyle(.roundedBorder)
              .textInputAutocapitalization(.characters).autocorrectionDisabled()
          }
          ForEach(sender.availableHosts,id:\.self){name in Button("连接 "+name){sender.connect(name,code:code)}.disabled(code.isEmpty)}
        }
        Text(sender.status).font(.caption)
      }
    }
  }
}

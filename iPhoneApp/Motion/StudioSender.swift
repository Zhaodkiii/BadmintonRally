import CoreMotion
import Network
import SwiftUI

final class StudioSender: ObservableObject {
  static let shared = StudioSender()
  @Published private(set) var linked=false
  @Published private(set) var guide=TrialPanel()
  @Published var status = "未连接"
  @Published var instruction = ""
  @Published var availableHosts: [String] = []
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
      }
      b.stateUpdateHandler = { state in
        if case .failed(let err) = state { self.report(err.localizedDescription) }
      }
      b.start(queue: self.work)
    }
  }
  func connect(_ host: String, code: String) {
    work.async {
      self.desired = host
      self.secret = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
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
      if ok {
        self.report(self.session == nil ? "已连接，等待 Mac 开始" : "已重连，等待补传")
        var hw = utsname()
        uname(&hw)
        let hardware = withUnsafeBytes(of: &hw.machine) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        w?.send(
          .hello(
            device: hardware, system: UIDevice.current.systemVersion,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            pending: self.session))
      } else {
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

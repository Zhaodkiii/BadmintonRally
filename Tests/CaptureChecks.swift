import AVFoundation
import CryptoKit
import Network

@main struct CaptureChecks {
  static func network() throws {
    let q = DispatchQueue(label: "capture.test.network")
    let finished = DispatchSemaphore(value: 0)
    let key = UUID().uuidString
    let l = try NWListener(using: CaptureWire.parameters(key), on: .any)
    var client: CaptureWire?
    var server: CaptureWire?
    var succeeded = false
    l.newConnectionHandler = { c in
      let w = CaptureWire(c, queue: q)
      server = w
      w.message = { packet in if case .ping(let t) = packet { w.send(.pong(t, 2, 3)) } }
      w.start()
    }
    l.stateUpdateHandler = { state in
      if case .ready = state, let port = l.port {
        let w = CaptureWire(
          NWConnection(host: "127.0.0.1", port: port, using: CaptureWire.parameters(key)), queue: q)
        client = w
        w.state = { if $0 { w.send(.ping(1)) } }
        w.message = {
          if case .pong(1, 2, 3) = $0 {
            succeeded = true
            finished.signal()
          }
        }
        w.start()
      }
    }
    l.start(queue: q)
    guard finished.wait(timeout: .now() + 8) == .success, succeeded else {
      throw CaptureFailure("TLS loopback failed")
    }
    q.sync {
      client?.close()
      server?.close()
      l.cancel()
    }
  }
  static func video(_ recorder: CameraRecorder, _ dir: URL) throws {
    recorder.arm(dir)
    var failure: String?
    recorder.failure = { failure = $0 }
    for i in 0..<30 {
      var px: CVPixelBuffer?
      guard
        CVPixelBufferCreate(
          nil, 160, 120, kCVPixelFormatType_32BGRA,
          [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary] as CFDictionary, &px)
          == kCVReturnSuccess, let px
      else { throw CaptureFailure("pixel buffer") }
      var format: CMVideoFormatDescription?
      var buf: CMSampleBuffer?
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: px, formatDescriptionOut: &format)
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: 3000 + Int64(i), timescale: 30),
        decodeTimeStamp: .invalid)
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: px, formatDescription: format!, sampleTiming: &timing,
        sampleBufferOut: &buf)
      recorder.writeFrame(buf!, clock: CMClockGetHostTimeClock())
      Thread.sleep(forTimeInterval: 0.012)
    }
    let done = DispatchSemaphore(value: 0)
    recorder.stop {
      if let err = $0 { failure = err }
      done.signal()
    }
    guard done.wait(timeout: .now() + 5) == .success, failure == nil else {
      throw CaptureFailure(failure ?? "writer timeout")
    }
  }
  static func calibrations()throws {
    func block(_ g:[Double],_ q:[Double])->[MotionRow] {
      (0...95).map{ MotionRow(t:Double($0)/100,v:Array(repeating:0,count:6)+g+q) }
    }
    func wrist(_ x:Double,_ y:Double)->WristObservation {.init(time:1,x:x,y:y,confidence:0.95)}
    let neutral=block([0,0,-1],[0,0,0,1])
    let base=try PositionGate.evaluate(step:0,rows:neutral,base:nil,wrist:wrist(0.1,-0.4),manual:false)
    precondition((try? PositionGate.evaluate(step:1,rows:neutral,base:base,wrist:wrist(1.3,0),manual:false)) == nil)
    let side=block([0,0,-1],[0,0,0.7071,0.7071])
    _=try PositionGate.evaluate(step:1,rows:side,base:base,wrist:wrist(1.3,0),manual:false)
    precondition((try? PositionGate.evaluate(step:1,rows:side,base:base,wrist:wrist(-1.2,0),manual:false)) == nil)
    let raised=block([0,-0.7071,-0.7071],[0.3827,0,0,0.9239])
    _=try PositionGate.evaluate(step:2,rows:raised,base:base,wrist:wrist(0.5,0.6),manual:false)
    precondition((try? PositionGate.evaluate(step:2,rows:neutral,base:base,wrist:nil,manual:true)) == nil)
    precondition((try? PositionGate.evaluate(step:3,rows:neutral,base:base,wrist:nil,manual:false)) == nil)
    _=try PositionGate.evaluate(step:3,rows:neutral,base:base,wrist:wrist(0.2,-0.3),manual:false)
    precondition((try? PositionGate.evaluate(step:3,rows:neutral,base:base,wrist:wrist(1.4,0.6),manual:false)) == nil)
    let fallback=try PositionGate.evaluate(step:3,rows:neutral,base:base,wrist:nil,manual:true)
    precondition(fallback.evidence=="operator_confirmed_2d")
  }
  static func main() throws {
    try calibrations()
    let phone = Curve25519.KeyAgreement.PrivateKey()
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let phoneKey = try NearbyPairing.key(phone, mac.publicKey.rawRepresentation)
    let macKey = try NearbyPairing.key(mac, phone.publicKey.rawRepresentation)
    precondition(NearbyPairing.code(phoneKey) == NearbyPairing.code(macKey))
    try network()
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let id = UUID()
    let solo=try SoloPositionCalibration(folder:root,prompt:"上挑",hand:"R")
    var t=0.0
    for step in 0..<4 {
      let g = step==2 ? [0,-0.7071,-0.7071] : [0,0,-1.0]
      let q = step==1 ? [0,0,0.7071,0.7071] : step==2 ? [0.3827,0,0,0.9239] : [0,0,0,1.0]
      for _ in 0..<150 where solo.step==step {
        t+=0.01
        _=try solo.feed(MotionRow(t:t,v:Array(repeating:0,count:6)+g+q))
      }
      precondition(solo.step==step+1)
    }
    try solo.finish("complete")
    let result=try Data(contentsOf:root.appendingPathComponent(solo.id.uuidString+".calibration.json"))
    precondition(String(decoding:result,as:UTF8.self).contains("phone_orientation_only"))
    let info = SessionInfo(
      id: id, participant: "P,01", hand: "左手", grip: "自然", prompt: "连续", device: "fixture",
      system: "test", build: "test", created: Date(), speed: .fast)
    let a = try CaptureArchive(root: root, info: info)
    try video(CameraRecorder(), a.dir)
    try a.clock(ClockPoint(m0: 99.999, p1: 50, p2: 50, m3: 100.001))
    var rows = (0..<100).map {
      MotionRow(t: 50 + Double($0) / 100, v: Array(repeating: 0.1, count: 13))
    }
    rows[12].events = [PhoneEvent(t: 50.12, name: "prediction:上挑")]
    try a.accept(0, Array(rows.prefix(50)))
    try a.accept(0, Array(rows.prefix(50)))
    let b = try CaptureArchive(open: a.dir)
    precondition(b.info.speed == .fast)
    precondition(b.next == 1 && b.samples == 50)
    try b.accept(1, Array(rows.suffix(50)))
    try b.writeWindow(start:100.1,end:100.8)
    try b.close(reason: "complete")
    precondition(b.info.state == "complete")
    try b.annotate("上挑", start: 0.1, end: 0.4)
    let label = b.labels[0]
    try b.annotate("漏拍", start: 0.1, end: 0.45, id: label.id)
    try b.annotate("背景", start: 0.55, end: 0.8)
    let events = try b.allEvents()
    precondition(events.count == 1)
    let legacyURL = root.appendingPathComponent(UUID().uuidString + ".csv")
    let legacy =
      "participant,session,hand,prompt,t_s,rx,ry,rz,ax_g,ay_g,az_g,gx,gy,gz,qx,qy,qz,qw,hardware\nP01,S,R,上挑,0.01,0,0,0,0,0,0,0,1,0,0,0,0,1,\"iPhone18,3\"\n"
    try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
    let old = try CaptureArchive.importPhoneCSV(legacyURL, root: root)
    precondition(old.samples == 1 && old.info.device == "iPhone18,3" && old.info.state == "partial")
    precondition(StandardStroke.allCases.filter(\.isServe).count == 4)
    print(try b.export(to: root).path)
  }
}

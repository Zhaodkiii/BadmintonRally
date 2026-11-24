// Build with Tools/动作回放.command. Uses the same metre-scale court, game tick and player rig as iPhone.
import AppKit
import SceneKit

private struct Trial {
  let scene: CollectionScene
  let name: String
  let stroke: Stroke
  let label: String?
  let strength: Double
  var vertical = 0.0
  var aim = 0.08
  var sweep: Double? = nil
}
// Representative synthetic button inputs. The intended reply is never passed to Rally.
private typealias Profile = (stroke: Stroke, power: Double, vertical: Double, aim: Double, sweep: Double)
private let replyProfiles: [String: Profile] = [
  "扑球": (.smash,0.78,-0.77,0.12,0.3), "推球": (.drive,0.54,0.07,0.12,0.65), "轻放网": (.drive,0.16,0.13,0.12,0.15),
  "放直线": (.drive,0.17,0.14,0.08,0.16), "勾对角": (.drive,0.18,0.15,-0.88,0.17), "推空当": (.drive,0.53,0.04,-0.76,0.7),
  "挑直线": (.lift,0.76,0.8,0.08,0.76), "挑对角": (.lift,0.76,0.8,-0.87,0.76), "轻托回网": (.lift,0.17,0.39,0.1,0.2),
  "正手平抽": (.drive,0.71,0.02,0.18,0.72), "反手平抽": (.drive,0.68,0.03,0.18,0.7), "减力挡网": (.drive,0.2,0.12,0.1,0.12),
  "接杀挡网": (.drive,0.19,0.13,0.1,0.14), "接杀挑高": (.lift,0.79,0.82,0.1,0.74), "接杀反抽": (.drive,0.83,0.06,-0.4,0.84),
  "点杀": (.smash,0.64,-0.61,0.14,0.28), "下压突击": (.smash,0.86,-0.77,0.32,0.84), "轻吊": (.drive,0.22,-0.15,0.22,0.26),
  "高远球": (.lift,0.85,0.78,0.14,0.83), "吊球": (.drive,0.23,-0.22,0.16,0.26), "扣杀": (.smash,0.96,-0.88,0.2,0.89),
  "平高球": (.drive,0.83,0.12,0.15,0.85), "被动高远球": (.lift,0.77,0.88,0.15,0.68), "过渡吊球": (.drive,0.24,-0.1,0.18,0.25),
  "反手高远": (.lift,0.81,0.77,-0.12,0.70), "反手吊球": (.drive,0.23,-0.12,-0.1,0.24), "头顶正手处理": (.lift,0.84,0.68,0.2,0.85)
]
private let trials: [Trial] = CollectionScene.allCases.flatMap { scene in
  let names = scene == .serve ? ServeTraining.allCases.filter { $0 != .free }.map(\.rawValue) : scene == .flat ? ["正手平抽","反手平抽","减力挡网"] : scene.replies
  return names.map { name in
    let down = ["扑球","点杀","下压突击","扣杀"].contains(name)
    let up = ["挑直线","挑对角","接杀挑高","高远球","被动高远球","反手高远","正手高远发球","头顶正手处理","反手偷后场"].contains(name)
    let soft = name.contains("吊") || name.contains("放") || name.contains("托") || name.contains("挡") || name.contains("短发") || name.contains("勾")
    if let profile = replyProfiles[name] {
      return Trial(scene:scene,name:name,stroke:profile.stroke,label:nil,strength:profile.power,
                   vertical:profile.vertical,aim:profile.aim,sweep:profile.sweep)
    }
    return Trial(scene:scene,name:name,stroke:down ? .smash : up ? .lift : .drive,
                 label: scene == .serve ? name : nil,
                 strength:soft ? 0.24 : down ? 0.92 : 0.74,vertical:down ? -0.8 : up ? 0.7 : 0)
  }
}

private final class TrialRunner {
  var game = Rally()
  var court = CourtScene()
  var incoming: Flight?
  private let contactOffset: Double?
  private var interceptTime: Double?
  var attempted = false
  var hitTime: Double?
  var maxSpeed = 0.0
  let trial: Trial
  let dt: Double
  init(_ trial: Trial, standOff: Double? = nil, fps: Int = 60, left: Bool = false, contactOffset: Double? = nil) {
    self.contactOffset = contactOffset
    dt = 1/Double(fps)
    game.leftHanded = left
    self.trial = trial
    if let standOff { game.receivingStandOff = standOff }
    game.collectionScene = trial.scene
    game.readyToServe()
  }
  func step() {
    let old = SIMD2(game.playerX*3.05,game.playerY*13.4)
    game.tick(dt)
    maxSpeed = max(maxSpeed,simd_length(SIMD2(game.playerX*3.05,game.playerY*13.4)-old)/dt)
    if !attempted {
      let serve = trial.scene == .serve && game.now >= 0.72
      let intercept = game.predictedIntercept
      var timeToSwing = false
      if let flight = game.flight, flight.incoming, let intercept {
        if let offset = contactOffset {
          if interceptTime == nil {
            var low = flight.start, high = low + flight.duration
            for _ in 0..<24 {
              let mid = (low+high)/2
              if flight.at(mid).y < intercept.y { low = mid } else { high = mid }
            }
            interceptTime = (low+high)/2
          }
          timeToSwing = game.now + dt/2 >= (interceptTime ?? game.now) + offset
        } else {
          timeToSwing = flight.at(game.now).y >= intercept.y
        }
      }
      if serve || timeToSwing {
        attempted = true
        incoming = game.flight
        // The feed mirrors across the court for the other hand. Mirror the intended
        // court lane as well so a cross-court probe still crosses the centre line.
        let aim = trial.aim * (game.leftHanded ? -1 : 1)
        let swing = SwingImpact(power:trial.strength,sweep:trial.sweep ?? trial.strength,serveIntentConfirmed:serve,label:trial.label,
                                probableBackhand:trial.name.contains("反手"),verticalSweep:trial.vertical,lateralSweep:aim)
        if game.swing(trial.stroke,aim:aim,impact:swing,confirmedByButton:true) == .accepted { hitTime = game.now }
      }
    }
    court.update(game,reduced:false,left:game.leftHanded)
  }
}

@main enum CourtMotionLab {
  private static func auditNine(_ folder: URL) throws {
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    var rows = ["场景,回法,帧率,左手,触球,实际回法,球路,拍球误差米,触球握点跳变米,触球肘跳变米,距网落点米,横向落点米,最高米,过网"]
    let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
    for trial in trials where trial.scene != .serve {
      for fps in [30,60,120] {
        for left in [false,true] {
          try autoreleasepool {
            let run = TrialRunner(trial,fps:fps,left:left)
            var previous = run.court.nearArmPoints()
            for _ in 0..<(4*fps) {
              previous = run.court.nearArmPoints()
              run.step()
              if run.hitTime != nil { break }
            }
            var fields = [trial.scene.rawValue,trial.name,String(fps),String(left),String(run.hitTime != nil)]
            if run.hitTime != nil, let f = run.game.flight, let incoming = run.incoming {
              let points = run.court.nearArmPoints()
              let error = run.court.nearRacketError(to:f.from)
              let end = f.netCollision ?? f.to
              let top = (0...100).map { f.at(f.start + f.duration*Double($0)/100).z }.max()!
              fields += [run.game.returnDescription(incoming:incoming,outgoing:f),f.shot.rawValue,String(error),
                         String(simd_distance(previous[1],points[1])),String(simd_distance(previous[0],points[0])),
                         String((0.5-end.y)*13.4),String(end.x*3.05),String(top*1.524/Flight.netHeight),String(f.netCollision == nil)]
              if fps == 60 && !left {
                renderer.scene = run.court.scene
                renderer.pointOfView = run.court.camera
                let shot = renderer.snapshot(atTime:run.game.now,with:CGSize(width:640,height:360),antialiasingMode:.none)
                if let tiff = shot.tiffRepresentation, let jpg = NSBitmapImageRep(data:tiff)?.representation(using:.jpeg,properties:[:]) {
                  try jpg.write(to:folder.appendingPathComponent(trial.name+".jpg"))
                }
              }
            }
            rows.append(fields.joined(separator:","))
          }
        }
      }
    }
    try rows.joined(separator:"\n").write(to:folder.appendingPathComponent("回放.csv"),atomically:true,encoding:.utf8)
  }
  private static func film(_ trial: Trial, folder: URL, encoder: String, offsetMS: Int?) throws {
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let output = folder.appendingPathComponent(trial.name+".mp4")
    let partial = folder.appendingPathComponent(trial.name+".partial.mp4")
    let pipe = Pipe()
    let movie = Process()
    movie.executableURL = URL(fileURLWithPath:encoder)
    movie.arguments = ["-hide_banner","-loglevel","error","-y","-f","image2pipe","-framerate","60",
                       "-vcodec","mjpeg","-i","pipe:0","-an","-c:v","libx264","-preset","veryfast",
                       "-crf","19","-pix_fmt","yuv420p","-movflags","+faststart",partial.path]
    movie.standardInput = pipe
    try movie.run()
    let r = TrialRunner(trial,contactOffset:offsetMS.map { Double($0)/1000 })
    let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
    renderer.scene = r.court.scene
    renderer.pointOfView = r.court.camera
    var count = 0
    var contactFrame: Int?
    let start = r.game.now
    do {
      for _ in 0..<300 {
        r.step()
        try autoreleasepool {
          let image = renderer.snapshot(atTime:r.game.now,with:CGSize(width:800,height:450),antialiasingMode:.none)
          guard let tiff = image.tiffRepresentation,
                let data = NSBitmapImageRep(data:tiff)?.representation(using:.jpeg,properties:[.compressionFactor:0.89]) else {
            throw NSError(domain:"Missing rendered frame",code:1)
          }
          try pipe.fileHandleForWriting.write(contentsOf:data)
        }
        if contactFrame == nil && r.hitTime != nil { contactFrame = count }
        count += 1
        if let hit = r.hitTime, r.game.now-hit >= 1 { break }
      }
    } catch {
      try? pipe.fileHandleForWriting.close()
      movie.waitUntilExit()
      throw error
    }
    try pipe.fileHandleForWriting.close()
    movie.waitUntilExit()
    guard movie.terminationStatus == 0, let contactFrame else {
      throw NSError(domain:"Incomplete motion replay",code:2)
    }
    try FileManager.default.moveItem(at:partial,to:output)
    let summary: [String:Any] = ["action":trial.name,"scene":trial.scene.rawValue,"fps":60,
      "frames":count,"contactFrame":contactFrame,"gameStart":start]
    try JSONSerialization.data(withJSONObject:summary).write(to:folder.appendingPathComponent(trial.name+".json"),options:.atomic)
  }
  static func main() throws {
    let app = NSApplication.shared
    if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--film" {
      let args = CommandLine.arguments
      guard let trial = trials.first(where: { $0.name == args[2] && $0.scene != .serve }) else {
        throw NSError(domain:"Unknown return action",code:1)
      }
      try film(trial,folder:URL(fileURLWithPath:args[3]),encoder:args[4],offsetMS:args.count > 5 ? Int(args[5]) : nil)
      return
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--rear-frames" {
      let destination = URL(fileURLWithPath:CommandLine.arguments[2])
      try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
      let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
      for trial in trials where trial.scene == .deepDrive {
        for ms in [-65,0,65,150,200] {
          let run = TrialRunner(trial,contactOffset:Double(ms)/1000)
          renderer.scene = run.court.scene
          renderer.pointOfView = run.court.camera
          for _ in 0..<240 {
            run.step()
            guard let hit = run.hitTime else { continue }
            let frame = Int(((run.game.now-hit)*60).rounded())
            if [0,9].contains(frame) {
              let image = renderer.snapshot(atTime:run.game.now,with:CGSize(width:800,height:450),antialiasingMode:.multisampling2X)
              guard let tiff = image.tiffRepresentation,
                let jpg = NSBitmapImageRep(data:tiff)?.representation(using:.jpeg,properties:[.compressionFactor:0.9]) else {
                throw NSError(domain:"Missing timing image",code:1)
              }
              try jpg.write(to:destination.appendingPathComponent("\(trial.name)_\(ms)_\(frame).jpg"))
            }
            if frame >= 9 { break }
          }
        }
      }
      return
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--rear-timing" {
      var rows = ["回法,帧率,左手,偏移毫秒,按键状态,球高米,身体前距米,拍球误差米,握点单帧米,拍头单帧米,落深米,过网"]
      for trial in trials where trial.scene == .deepDrive {
        for fps in [30,60,120] {
          for left in [false,true] {
            for offset in [-0.065,0,0.065,0.150,0.200] {
              let r = TrialRunner(trial,fps:fps,left:left,contactOffset:offset)
              var fields = [trial.name,String(fps),String(left),String(Int((offset*1000).rounded()))]
              for _ in 0..<(4*fps) {
                let before = r.court.nearArmPoints()
                r.step()
                if r.hitTime != nil, let f = r.game.flight {
                  let after = r.court.nearArmPoints()
                  fields += ["已触球",String(f.from.z*1.524/Flight.netHeight),
                             String((r.game.playerY-f.from.y)*13.4),String(r.court.nearRacketError(to:f.from)),
                             String(simd_distance(before[1],after[1])),String(simd_distance(before[2],after[2])),
                             String((0.5-(f.netCollision ?? f.to).y)*13.4),String(f.netCollision == nil)]
                  break
                }
                if r.game.phase == .point { break }
              }
              if fields.count == 4 { fields.append("无触球") }
              rows.append(fields.joined(separator:","))
            }
          }
        }
      }
      try rows.joined(separator:"\n").write(toFile:CommandLine.arguments[2],atomically:true,encoding:.utf8)
      return
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--recovery" {
      var rows = ["回法,击后秒,拍头位移米,握点位移米"]
      for trial in trials where trial.scene != .serve {
        let r = TrialRunner(trial)
        for _ in 0..<300 {
          let previous = r.court.nearArmPoints()
          r.step()
          if let t = r.hitTime {
            let points = r.court.nearArmPoints()
            rows.append([trial.name,String(r.game.now-t),String(simd_distance(points[2],previous[2])),
                         String(simd_distance(points[1],previous[1]))].joined(separator:","))
            if r.game.now-t >= 0.82 { break }
          }
        }
      }
      try rows.joined(separator:"\n").write(toFile:CommandLine.arguments[2],atomically:true,encoding:.utf8)
      return
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--legs" {
      var rows = ["回法,大腿最短米,大腿最长米,小腿最短米,小腿最长米"]
      for trial in trials where trial.scene != .serve {
        let r = TrialRunner(trial)
        var lo = [Float](repeating: 10,count:2), hi = [Float](repeating: 0,count:2)
        for _ in 0..<240 {
          r.step()
          for (i,value) in r.court.nearLegLengths().enumerated() {
            lo[i%2] = min(lo[i%2],value)
            hi[i%2] = max(hi[i%2],value)
          }
          if let t = r.hitTime, r.game.now-t >= 0.30 { break }
        }
        rows.append(([trial.name]+[lo[0],hi[0],lo[1],hi[1]].map { String($0) }).joined(separator:","))
      }
      try rows.joined(separator:"\n").write(toFile:CommandLine.arguments[2],atomically:true,encoding:.utf8)
      return
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--nine" {
      try auditNine(URL(fileURLWithPath:CommandLine.arguments[2]))
      return
    }
    if CommandLine.arguments.dropFirst().first == "--fit" {
      for offset in [0.020,0.030,0.040,0.045,0.055] {
        var errors: [Double] = []
        for trial in trials where trial.scene != .serve {
          autoreleasepool {
            let r = TrialRunner(trial,standOff:offset)
            for _ in 0..<240 {
              r.step()
              if r.hitTime != nil, let f = r.game.flight {
                errors.append(Double(r.court.nearRacketError(to:f.from)))
                break
              }
            }
          }
        }
        print(String(format:"站位距击球点 %.2f m，%d 拍，平均拍面距离 %.3f m，最大 %.3f m",
          offset*13.4,errors.count,errors.reduce(0,+)/Double(errors.count),errors.max() ?? 0))
      }
      return
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--audit-arms" {
      var rows = ["动作,帧率,左手,按键触球,触球帧拍面距离米"]
      for trial in trials where ["反手高远","反手吊球","头顶正手处理","扑球","接杀挡网"].contains(trial.name) {
        for fps in [30,60,120] {
          for left in [false,true] {
            let run = TrialRunner(trial,fps:fps,left:left)
            for _ in 0..<(4*fps) where run.hitTime == nil { run.step() }
            let hit = run.hitTime != nil
            let error = hit ? run.game.flight.map { String(run.court.nearRacketError(to:$0.from)) } : nil
            rows.append("\(trial.name),\(fps),\(left),\(hit),\(error ?? "")")
          }
        }
      }
      try rows.joined(separator:"\n").write(toFile:CommandLine.arguments[2],atomically:true,encoding:.utf8)
      return
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--phases" {
      let folder = URL(fileURLWithPath:CommandLine.arguments[2])
      let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
      for trial in trials where trial.scene != .serve {
        let probe = TrialRunner(trial)
        for _ in 0..<240 where probe.hitTime == nil { probe.step() }
        guard let contact = probe.hitTime else { throw NSError(domain:"Missing reference contact",code:1) }
        let replay = TrialRunner(trial)
        renderer.scene = replay.court.scene
        renderer.pointOfView = replay.court.camera
        let dir = folder.appendingPathComponent(trial.name)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        var armRows = ["frame,elbowX,elbowY,elbowZ,palmX,palmY,palmZ,racketX,racketY,racketZ"]
        for _ in 0..<240 {
          replay.step()
          let offset = Int(((replay.game.now-contact)*60).rounded())
          if offset > 18 { break }
          guard offset >= -12 else { continue }
          let coordinates = replay.court.nearArmPoints().flatMap { [$0.x,$0.y,$0.z] }
          armRows.append(([String(offset)] + coordinates.map { String($0) }).joined(separator:","))
          let snap = renderer.snapshot(atTime:replay.game.now,with:CGSize(width:800,height:450),antialiasingMode:.multisampling2X)
          guard let tiff = snap.tiffRepresentation, let data = NSBitmapImageRep(data:tiff)?.representation(using:.jpeg,properties:[.compressionFactor:0.90]) else {
            throw NSError(domain:"Missing phase image",code:2)
          }
          try data.write(to:dir.appendingPathComponent(String(format:"%03d.jpg",offset+12)))
        }
        try armRows.joined(separator:"\n").write(to:dir.appendingPathComponent("手肘握拍.csv"),atomically:true,encoding:.utf8)
      }
      return
    }
    if CommandLine.arguments.count == 2 {
      let folder = URL(fileURLWithPath:CommandLine.arguments[1])
      try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(), options:nil)
      var paths = ["场景,模拟动作,出拍后秒,横向米,距球网纵向米,高度米"]
      var records = ["场景,模拟动作,按键秒,峰速米每秒,起跳请求米,游戏球路,触球帧拍面距离米"]
      for (index,trial) in trials.enumerated() {
        let r = TrialRunner(trial)
        renderer.scene = r.court.scene; renderer.pointOfView = r.court.camera
        var error: Float = 0
        for _ in 0..<240 {
          r.step()
          if let hit = r.hitTime {
            let frame = Int(((r.game.now-hit)*60).rounded())
            if frame == 0, let f = r.game.flight {
              error = r.court.nearRacketError(to:f.from)
              // Free flight until landing or first net collision, before another player's interception.
              for tick in 0...Int(ceil(f.duration*60)) {
                let time = min(Double(tick)/60,f.duration)
                var pos = f.at(f.start+time)
                let collided = f.netCollision.map { (pos.y-0.5)*(f.from.y-0.5) <= 0 && $0.y == 0.5 } ?? false
                if collided { pos = f.netCollision! }
                paths.append("\(trial.scene.rawValue),\(trial.name),\(time),\(pos.x*3.05),\((pos.y-0.5)*13.4),\(pos.z*1.524/Flight.netHeight)")
                if collided { break }
              }
            }
            if [0,6,15].contains(frame) {
              let snap = renderer.snapshot(atTime:r.game.now,with:CGSize(width:640,height:360),antialiasingMode:.none)
              if let tiff = snap.tiffRepresentation, let data = NSBitmapImageRep(data:tiff)?.representation(using:.jpeg,properties:[.compressionFactor:0.85]) {
                try data.write(to:folder.appendingPathComponent(String(format:"%02d-%02d.jpg",index,frame)))
              }
            }
            if frame == 15 {
              records.append("\(trial.scene.rawValue),\(trial.name),\(hit),\(r.maxSpeed),\(r.game.flight?.jumpHeightMeters ?? 0),\(r.game.lastShot.rawValue),\(error)")
              break
            }
          }
        }
      }
      try paths.joined(separator:"\n").write(to:folder.appendingPathComponent("预测自由飞行轨迹.csv"),atomically:true,encoding:.utf8)
      try records.joined(separator:"\n").write(to:folder.appendingPathComponent("回放指标.csv"),atomically:true,encoding:.utf8)
      return
    }
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:850,height:490),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
    let view = SCNView(); window.contentView = view
    var index = 0, run = TrialRunner(trials[0])
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/羽球动作回放")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    var audit = ["场景\t动作\t自动检查"]
    var contactError: Float?
    func attach() {
      view.scene = run.court.scene; view.pointOfView = run.court.camera
      window.title = "羽球动作回放 · \(index+1)/\(trials.count) · \(run.trial.scene.rawValue) · \(run.trial.name)"
    }
    attach(); window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
    let timer = Timer(timeInterval:1.0/60,repeats:true) { _ in MainActor.assumeIsolated {
      guard window.isVisible || window.isMiniaturized else { app.terminate(nil); return }
      if window.isMiniaturized { return }
      if run.game.now > (run.hitTime ?? 3.0)+0.9 {
        let issue = contactError.map { $0 > 0.08 ? "拍面偏差超过8厘米" : "通过" } ?? "模拟按键未触球"
        audit.append([run.trial.scene.rawValue,run.trial.name,run.maxSpeed > 5.11 ? "跑速越界" : issue].joined(separator:"\t"))
        if index == trials.count-1 {
          do { try audit.joined(separator:"\n").write(to:folder.appendingPathComponent("最近完整一轮.tsv"),atomically:true,encoding:.utf8) }
          catch { NSLog("回放指标写入失败 %@",error.localizedDescription) }
          audit.removeSubrange(1...)
        }
        contactError = nil
        index = (index+1)%trials.count; run = TrialRunner(trials[index]); attach()
      }
      run.step()
      if run.game.now == run.hitTime, let flight = run.game.flight { contactError = run.court.nearRacketError(to:flight.from) }
      view.needsDisplay = true
    }}
    RunLoop.main.add(timer,forMode:.common); app.run()
  }
}

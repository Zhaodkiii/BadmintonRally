import Foundation

enum StandardStroke: String, CaseIterable, Identifiable {
  case lift = "上挑"
  case down = "下挥"
  case drive = "平抽"
  case clear = "头顶高远"
  case smash = "正手扣杀"
  case drop = "吊球"
  case net = "网前放网"
  case shortServe = "反手短发"
  case backLift = "反手挑球"
  case background = "背景"
  case forehandHighServe = "正手高远发球"
  case forehandShortServe = "正手短发球"
  case backhandFlickServe = "反手偷后场"
  case netBlock = "接杀挡网"
  case netPush = "网前推球"
  case netKill = "网前扑球"
  case counterDrive = "接杀反抽"

  static let trainingGroups: [(title: String, strokes: [Self])] = [
    ("后场", [.clear, .smash, .drop]),
    ("网前", [.lift, .net, .netPush, .netKill]),
    ("中场与接杀", [.drive, .netBlock, .counterDrive]),
    ("发球", [.forehandHighServe, .forehandShortServe, .shortServe, .backhandFlickServe]),
  ]
  static let gameTraining = trainingGroups.flatMap(\.strokes)

  var displayName: String {
    switch self {
    case .lift: "正手挑球"
    case .drive: "平抽球"
    case .clear: "正手高远球"
    case .shortServe: "反手短发球"
    default: rawValue
    }
  }
  var isForehandServe: Bool { self == .forehandHighServe || self == .forehandShortServe }
  var isServe: Bool {
    switch self {
    case .forehandHighServe, .forehandShortServe, .shortServe, .backhandFlickServe: true
    default: false
    }
  }
  var id: Self { self }
  static let phases = ["准备", "引拍", "挥出", "回位"]
  static let bounds = [0.0, 1.0, 2.2, 2.9, 4.4]
  static func phase(_ time: Double) -> Int {
    time < bounds[1] ? 0 : time < bounds[2] ? 1 : time < bounds[3] ? 2 : 3
  }
  var cues: [String] {
    switch self {
    case .lift: ["拍放身前", "持拍脚向前跨，拍头降至来球下方", "从下往前上方送出", "收回到身前"]
    case .backLift: ["拍放身前", "反手面朝前，拍头落到身体另一侧", "拇指侧引导，从低处向前上方送", "放松回到准备位"]
    case .down: ["自然握持", "提至肩旁", "向前下方短挥", "收回身前"]
    case .drive: ["胸前举拍", "肘略弯，向持拍侧短引", "在身前水平挥出", "迅速回到胸前"]
    case .clear: ["侧身举拍，另一只手指向来球", "后脚蹬地，转髋带肩，肘先向前", "向前上方伸展，在高点挥出", "顺势收拍，再回正"]
    case .smash: ["侧身举拍", "肘部抬起，拍头后引", "在身体前上方击球，拍头向下通过", "顺势向身前收拍后回位"]
    case .drop: ["侧身举拍", "用与高远球相似的引拍", "高点短送，控制拍头速度", "小幅随挥后回位"]
    case .net: ["拍头在身前", "向前伸臂，拍面微仰", "在网前轻托，保持拍面稳定", "前脚蹬地回位，拍仍在身前"]
    case .forehandHighServe: ["侧身站稳，非持拍手在身前持球", "球拍向持拍侧后方引", "放球后由下向前上方挥拍", "自然随挥，球飞向对角后场"]
    case .forehandShortServe: ["侧身准备，非持拍手在身前持球", "缩短引拍，拍头保持较低", "放球后在身前轻送", "短随挥，球贴网落向前场"]
    case .shortServe: ["反手拇指握拍，身前持球", "拍头略朝下，短距离引拍", "在身前轻轻向前推送", "短随挥，球贴网落向前场"]
    case .backhandFlickServe: ["沿用反手短发的站姿和持球位置", "保持与反手短发相同的短引拍", "触球前用拇指和手指短促加速", "小幅上随挥，球越过接发者"]
    case .netBlock: ["拍举在身前，准备接杀", "迎球时保持短引拍", "拍面稍仰，在身前轻挡", "缩短随挥，回到准备位"]
    case .netPush: ["举拍贴近网前", "拍头短收，准备抢球", "朝中后场空当短促前推", "立即收拍，准备接下一拍"]
    case .netKill: ["拍举在身前，抢网前高球", "拍头保持在触球点上方", "球高于网带时，短促向前下方点击", "收住拍头并回位"]
    case .counterDrive: ["屈膝举拍，准备接杀", "在身侧短引拍", "在身前快速平挥，把杀球反抽回去", "短随挥，迅速回拍"]
    case .background: ["回到自然握姿", "轻微调整握持", "保持站姿，自然移手", "静止，结束对照录制"]
    }
  }
  var overhead: Bool { self == .clear || self == .drop || self == .smash }
  var lunge: Bool {
    self == .net || self == .lift || self == .backLift || self == .netPush || self == .netKill
  }
  var lesson: (String, String?) {
    switch self {
    case .clear: ("高点击球 · 深远弧线", "8QCeXig1eDE")
    case .smash: ("前上方击球 · 快速下压", "2J4V37Qf9FY")
    case .drop: ("高点轻送 · 落向前场", "z2YGlINxso4")
    case .lift: ("正手低点击球 · 挑向后场", "ZDfaUrR0RY0")
    case .backLift: ("反手低点击球 · 挑向后场", "UXhneWqy0Zw")
    case .forehandHighServe: ("侧身下手挥拍 · 高弧线到后场", nil)
    case .forehandShortServe: ("正手轻送 · 贴网落前场", nil)
    case .backhandFlickServe: ("反手短促加速 · 越过接发者", nil)
    case .shortServe: ("拍头朝下 · 贴网短发", "RqEsdMSq7pg")
    case .net: ("前跨伸拍 · 轻托过网", "TVNW9S7o0Bk")
    case .drive: ("身前短挥 · 平快出球", "hFIc77HRSiA")
    case .down: ("游戏手势 · 肩旁短挥", nil)
    case .netBlock: ("借来球速度 · 轻挡回网前", nil)
    case .netPush: ("抢网前 · 平推中后场", nil)
    case .netKill: ("网前高点 · 点压得分", nil)
    case .counterDrive: ("接杀 · 快速平抽反击", nil)
    case .background: ("对照采集 · 自然移手", nil)
    }
  }
  // Wrist x, wrist y and racket angle in a right-handed schematic (screen y grows down).
  typealias Pose = (Double, Double, Double)
  var poses: [Pose] {
    let ready: Pose
    switch self {
    case .shortServe, .backhandFlickServe: ready = (100, 73, 98)
    case .forehandHighServe, .forehandShortServe: ready = (83, 79, 115)
    default: ready = overhead ? (81, 43, -75) : (106, 69, -55)
    }
    let draw: Pose
    let contact: Pose
    let finish: Pose
    switch self {
    case .lift: (draw, contact, finish) = ((99, 85, 62), (121, 80, 9), (119, 58, -53))
    case .backLift: (draw, contact, finish) = ((72, 84, 112), (112, 80, 21), (118, 66, -24))
    case .down: (draw, contact, finish) = ((77, 42, -115), (118, 53, 0), (109, 84, 63))
    case .drive: (draw, contact, finish) = ((66, 69, -130), (123, 65, -5), (114, 65, 12))
    case .clear: (draw, contact, finish) = ((68, 46, -232), (96, 23, -76), (97, 76, 47))
    case .smash: (draw, contact, finish) = ((68, 46, -232), (106, 26, -61), (91, 84, 65))
    case .drop: (draw, contact, finish) = ((68, 46, -232), (100, 24, -71), (114, 53, -18))
    case .net: (draw, contact, finish) = ((109, 67, -17), (122, 64, -15), (124, 63, -17))
    case .forehandHighServe:
      (draw, contact, finish) = ((52, 79, 153), (106, 80, 37), (113, 43, -67))
    case .forehandShortServe:
      (draw, contact, finish) = ((70, 78, 129), (104, 80, 49), (110, 76, 34))
    case .shortServe: (draw, contact, finish) = ((94, 71, 109), (103, 71, 85), (106, 70, 75))
    case .backhandFlickServe:
      (draw, contact, finish) = ((94, 71, 109), (105, 70, 63), (110, 64, 31))
    case .netBlock: (draw, contact, finish) = ((103, 69, -20), (112, 65, -13), (114, 64, -14))
    case .netPush: (draw, contact, finish) = ((102, 65, -35), (124, 62, -8), (129, 62, -3))
    case .netKill: (draw, contact, finish) = ((107, 55, -52), (124, 53, -12), (123, 68, 30))
    case .counterDrive: (draw, contact, finish) = ((81, 68, -115), (119, 65, -4), (116, 64, 17))
    case .background: (draw, contact, finish) = ((102, 72, -51), (106, 70, -54), ready)
    }
    let neutral: Pose = (104, 66, -56)
    return [neutral, ready, draw, contact, finish, neutral]
  }
}

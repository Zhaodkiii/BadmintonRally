// Local racket travel in metres from contact, plus the time to brake.
// Along follows the measured horizontal shot bearing; across follows the racket arm.
struct ReturnMotion {
  let along, up, across: Float
  let brakeTime, forearmRoll: Float

  init(_ along: Float, _ up: Float, _ across: Float, seconds: Float, roll: Float) {
    self.along = along
    self.up = up
    self.across = across
    self.brakeTime = seconds
    self.forearmRoll = roll
  }
}

extension ReturnStyle {
  var motion: ReturnMotion {
    switch self {
    case .netKill:        return .init(0.13,-0.31, 0.00, seconds:0.13, roll:0.35)
    case .push:           return .init(0.35, 0.02,-0.02, seconds:0.18, roll:0.18)
    case .feather:        return .init(0.07, 0.03, 0.00, seconds:0.16, roll:0.09)
    case .straightNet:    return .init(0.11, 0.05, 0.00, seconds:0.17, roll:0.10)
    case .crossNet:       return .init(0.16, 0.04, 0.00, seconds:0.15, roll:0.26)
    case .pushGap:        return .init(0.38, 0.01, 0.00, seconds:0.19, roll:0.21)
    case .straightLift:   return .init(0.32, 0.52, 0.00, seconds:0.20, roll:0.36)
    case .crossLift:      return .init(0.41, 0.49, 0.00, seconds:0.20, roll:0.38)
    case .lowNet:         return .init(0.09, 0.14, 0.00, seconds:0.16, roll:0.12)
    case .foreDrive:      return .init(0.36, 0.00,-0.13, seconds:0.15, roll:0.39)
    case .backDrive:      return .init(0.32, 0.03, 0.14, seconds:0.15, roll:0.32)
    case .cushion:        return .init(0.08, 0.02, 0.00, seconds:0.15, roll:0.09)
    case .block:          return .init(0.07, 0.04, 0.00, seconds:0.16, roll:0.07)
    case .liftSmash:      return .init(0.28, 0.49, 0.01, seconds:0.20, roll:0.34)
    case .counter:        return .init(0.42, 0.01,-0.06, seconds:0.15, roll:0.38)
    case .tapAttack:      return .init(0.17,-0.25,-0.05, seconds:0.13, roll:0.32)
    case .steepAttack:    return .init(0.32,-0.47,-0.12, seconds:0.18, roll:0.47)
    case .halfDrop:       return .init(0.14,-0.12,-0.03, seconds:0.19, roll:0.18)
    case .clear:          return .init(0.47,-0.20,-0.30, seconds:0.20, roll:0.50)
    case .drop:           return .init(0.13,-0.12,-0.05, seconds:0.18, roll:0.22)
    case .smash:          return .init(0.38,-0.65,-0.29, seconds:0.19, roll:0.62)
    case .flatClear:      return .init(0.43, 0.12,-0.08, seconds:0.18, roll:0.42)
    case .defensiveClear: return .init(0.29, 0.48,-0.03, seconds:0.21, roll:0.38)
    case .escapeDrop:     return .init(0.13, 0.02,-0.03, seconds:0.19, roll:0.16)
    case .backClear:      return .init(0.25, 0.16, 0.16, seconds:0.18, roll:0.43)
    case .backDrop:       return .init(0.12,-0.09, 0.05, seconds:0.16, roll:0.19)
    case .roundHead:      return .init(0.35,-0.21,-0.31, seconds:0.22, roll:0.53)
    }
  }
}

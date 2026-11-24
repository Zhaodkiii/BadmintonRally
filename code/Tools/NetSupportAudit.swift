// Built with audit_net_support.command beside the real match-replay inputs.
// Measurements inspect scene geometry only. They never modify the game or rig.
import SceneKit
import simd
import Foundation

private struct Sole {
    let node: SCNNode
    let vertices: [SIMD3<Float>]

    init(_ node: SCNNode) {
        self.node = node
        let source = node.geometry!.sources(for: .vertex).first!
        precondition(source.usesFloatComponents && source.bytesPerComponent == 4 && source.componentsPerVector == 3)
        vertices = source.data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            (0..<source.vectorCount).map { i in
                let offset = source.dataOffset + i * source.dataStride
                return SIMD3(p.loadUnaligned(fromByteOffset: offset, as: Float.self),
                             p.loadUnaligned(fromByteOffset: offset+4, as: Float.self),
                             p.loadUnaligned(fromByteOffset: offset+8, as: Float.self))
            }
        }
        precondition(!vertices.isEmpty)
    }

    func bottom() -> Float {
        let m = node.simdWorldTransform
        return vertices.map { m.columns.0.y * $0.x + m.columns.1.y * $0.y + m.columns.2.y * $0.z + m.columns.3.y }.min()!
    }
}

private struct SupportRig {
    let left: Sole
    let right: Sole
    let floorY: Float
    let body: SCNNode
    let thighs: [SCNNode]
    init(_ scene: SCNScene) {
        let roots = scene.rootNode.childNodes
        let floor = roots.first { node in
            guard let box = node.geometry as? SCNBox else { return false }
            return abs(box.width-6.1) < 0.001 && abs(box.length-13.4) < 0.001
        }!
        floorY = floor.simdConvertPosition(SIMD3(0,Float((floor.geometry as! SCNBox).height/2),0),to:nil).y
        // Select the visible actor on the near side after the first game tick.
        body = roots.first { node in
            !node.isHidden && node.simdWorldPosition.z > 0 &&
            node.childNodes.contains { ($0.geometry as? SCNBox)?.chamferRadius == 0.035 }
        }!
        let shoes = body.childNodes.filter { ($0.geometry as? SCNBox)?.chamferRadius == 0.035 }.sorted {
            $0.simdWorldPosition.x < $1.simdWorldPosition.x
        }
        precondition(shoes.count == 2)
        left = Sole(shoes[0]); right = Sole(shoes[1])
        thighs = body.childNodes.filter { ($0.geometry as? SCNCylinder)?.radius == 0.09 }
        precondition(thighs.count == 2)
    }

    var hip: SIMD3<Float> {
        // The local low-Y endpoint of each thigh cylinder is its hip socket.
        (thighs[0].simdConvertPosition(SIMD3(0,-0.5,0),to:nil) +
         thighs[1].simdConvertPosition(SIMD3(0,-0.5,0),to:nil)) / 2
    }
}

private struct FootSample {
    let time: Double
    let lhs, rhs, hip: SIMD3<Float>
    let leftClearance, rightClearance: Float
    let rootX: Float
}

@main private enum SupportAudit {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var rows = ["action,fps,hand,buttonOffsetMs,tMs,groundY,leftX,leftMidY,leftZ,leftClearance,rightX,rightMidY,rightZ,rightClearance,hipX,hipY,hipZ,contactX,expectedSide,leadTowardNet,state"]
        for trial in trials where [.netHigh,.netSlow,.netLow].contains(trial.scene) {
            for fps in [30,60,120] {
                for left in [false,true] {
                    for offset in [-65,0,65] {
                        let r = TrialRunner(trial,fps:fps,left:left,contactOffset:offset == 0 ? nil : Double(offset)/1000)
                        r.step()
                        let rig = SupportRig(r.court.scene)
                        var stream: [FootSample] = []
                        var contactX: Float?
                        for _ in 0..<(4*fps) {
                            r.step()
                            stream.append(FootSample(time:r.game.now,lhs:rig.left.node.simdWorldPosition,
                                rhs:rig.right.node.simdWorldPosition,hip:rig.hip,
                                leftClearance:rig.left.bottom()-rig.floorY,rightClearance:rig.right.bottom()-rig.floorY,
                                rootX:rig.body.simdWorldPosition.x))
                            if let hit = r.hitTime {
                                if contactX == nil { contactX = Float(r.game.flight!.from.x*3.05) }
                                if r.game.now-hit > 0.40 {break}
                            }
                        }
                        guard let hit = r.hitTime, let x = contactX,
                              let atHit = stream.min(by:{ abs($0.time-hit)<abs($1.time-hit) }) else {
                            throw NSError(domain:"Unaccepted net replay "+trial.name,code:offset)
                        }
                        let expected = abs(x-atHit.rootX)<0.08 ? "center" : x>atHit.rootX ? "right" : "left"
                        for s in stream where s.time-hit >= -0.301 && s.time-hit <= 0.401 {
                            let low = min(s.leftClearance,s.rightClearance)
                            let state = low < -0.005 ? "penetrates" : low>0.015 ? "bothAirborne" :
                                max(s.leftClearance,s.rightClearance)>0.015 ? "singleSupport" : "doubleSupport"
                            let lead = abs(s.lhs.z-s.rhs.z)<0.02 ? "level" : s.lhs.z<s.rhs.z ? "left" : "right"
                            let values: [Float] = [rig.floorY,s.lhs.x,s.lhs.y,s.lhs.z,s.leftClearance,s.rhs.x,
                                s.rhs.y,s.rhs.z,s.rightClearance,s.hip.x,s.hip.y,s.hip.z,x]
                            rows.append(([trial.name,String(fps),left ? "left":"right",String(offset),
                                          String(Int(((s.time-hit)*1000).rounded()))]+values.map { String($0) }+
                                         [expected,lead,state]).joined(separator:","))
                        }
                    }
                }
            }
        }
        try rows.joined(separator:"\n").write(to:output,atomically:true,encoding:.utf8)
        print("\(rows.count-1) net contact frames evaluated")
    }
}

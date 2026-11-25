import SceneKit
import SwiftUI

private enum PreviewStroke: String, CaseIterable {
  case overhead, block, lunge, net
  var title: String {
    switch self {
    case .overhead: "头顶主动击球"
    case .block: "近身短挡"
    case .lunge: "远身救球"
    case .net: "网前预判"
    }
  }
}

struct PlayerPreview: View {
  let close: () -> Void
  @State private var stroke = PreviewStroke.overhead

  var body: some View {
    ZStack(alignment: .topLeading) {
      PlayerScene(stroke: stroke).id(stroke).ignoresSafeArea()
      HStack {
        Button(action: close) { Label("球社", systemImage: "chevron.left") }
        Picker("动作", selection: $stroke) {
          ForEach(PreviewStroke.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented)
      }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal).padding(.top, 4)
    }
  }
}

private struct PlayerScene: UIViewRepresentable {
  let stroke: PreviewStroke

  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    guard let scene = SCNScene(named: "RallyPlayer.scnassets/\(stroke.rawValue).scn") else {
      let label = UILabel()
      label.text = "动作资源加载失败"
      label.textColor = .white
      label.sizeToFit()
      label.center = CGPoint(x: 170, y: 130)
      view.addSubview(label)
      return view
    }
    scene.background.contents = UIColor(red: 0.23, green: 0.29, blue: 0.33, alpha: 1)
    let ground = SCNFloor()
    ground.reflectivity = 0
    ground.firstMaterial?.diffuse.contents = UIColor(red: 0.23, green: 0.39, blue: 0.40, alpha: 1)
    let floor = SCNNode(geometry: ground)
    floor.position.y = -0.012
    scene.rootNode.addChildNode(floor)
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera?.fieldOfView = stroke == .overhead ? 42 : 35
    camera.position = stroke == .overhead ? SCNVector3(2.1, 1.92, 4.22) : SCNVector3(3.35, 1.92, 3.35)
    camera.look(at: SCNVector3(0, stroke == .overhead ? 1.24 : 0.84, -0.16))
    scene.rootNode.addChildNode(camera)
    for kind in [SCNLight.LightType.ambient, .directional] {
      let node = SCNNode()
      node.light = SCNLight()
      node.light?.type = kind
      node.light?.intensity = kind == .ambient ? 480 : 760
      node.position = SCNVector3(-2, 4, -3)
      node.look(at: SCNVector3Zero)
      scene.rootNode.addChildNode(node)
    }
    view.scene = scene
    view.pointOfView = camera
    view.isPlaying = true
    view.loops = true
    view.preferredFramesPerSecond = 60
    return view
  }

  func updateUIView(_ view: SCNView, context: Context) {}
  static func dismantleUIView(_ view: SCNView, coordinator: ()) {
    view.isPlaying = false
    view.scene = nil
  }
}

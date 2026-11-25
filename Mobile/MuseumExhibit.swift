import SceneKit
import SwiftUI

struct MuseumExhibit: View {
    let code: String
    let entering: Bool
    let reducedMotion: Bool

    var body: some View {
        if let url = Bundle.main.url(forResource: code, withExtension: "usdz", subdirectory: "Museum") {
            MuseumScene(url: url, entering: entering, reducedMotion: reducedMotion)
        } else if let image = UIImage(named: "Museum/\(code).webp") {
            Image(uiImage: image).resizable().scaledToFit().padding(24)
        }
    }
}

private struct MuseumScene: UIViewRepresentable {
    let url: URL
    let entering: Bool
    let reducedMotion: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        guard let imported = try? SCNScene(url: url) else { return view }
        let scene = SCNScene()
        let exhibit = SCNNode()
        let model = SCNNode()
        for child in imported.rootNode.childNodes { model.addChildNode(child) }
        exhibit.addChildNode(model)
        scene.rootNode.addChildNode(exhibit)
        let (low, high) = model.boundingBox
        let size = max(0.001, max(high.x-low.x, max(high.y-low.y, high.z-low.z)))
        model.position = SCNVector3(-(low.x+high.x)/2, -(low.y+high.y)/2, -(low.z+high.z)/2)
        exhibit.scale = SCNVector3(2/size, 2/size, 2/size)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.position = SCNVector3(2, 1.55, 5)
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)
        let corners = [low.x, high.x].flatMap { horizontal in
            [low.y, high.y].flatMap { vertical in
                [low.z, high.z].map { depth in
                    camera.convertPosition(SCNVector3(horizontal, vertical, depth), from: model)
                }
            }
        }
        let left = corners.map(\.x).min() ?? -1
        let right = corners.map(\.x).max() ?? 1
        let bottom = corners.map(\.y).min() ?? -1
        let top = corners.map(\.y).max() ?? 1
        let scale = max(0.01, max((right-left)/1.82, (top-bottom)/1.25))
        camera.camera?.orthographicScale = Double(scale)
        let shift = camera.convertVector(SCNVector3(-(left+right)/2, -0.72*scale-bottom, 0), to: nil)
        exhibit.position = shift
        view.scene = scene
        view.pointOfView = camera
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let camera = uiView.pointOfView else { return }
        let target = entering ? SCNVector3(0.45, 0.8, 4) : SCNVector3(2, 1.55, 5)
        guard camera.position.x != target.x else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = reducedMotion ? 0 : 1.4
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.055, 0.675, 0.19)
        camera.position = target
        camera.look(at: SCNVector3Zero)
        SCNTransaction.commit()
    }
}

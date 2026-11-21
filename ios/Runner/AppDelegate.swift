import ARKit
import AVFoundation
import Flutter
import SceneKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ArPhotoPlugin") {
      ArPhotoPlugin.register(with: registrar)
    }
  }
}

// MARK: - AR plugin (kept in this file so the Xcode project needs no changes)

/// Channel "walk_on_photos/ar" + platform view "walk_on_photos/ar_view".
final class ArPhotoPlugin: NSObject {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "walk_on_photos/ar", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        result(ARWorldTrackingConfiguration.isSupported)
      case "requestCameraPermission":
        AVCaptureDevice.requestAccess(for: .video) { granted in
          DispatchQueue.main.async { result(granted) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    registrar.register(
      ArPhotoViewFactory(messenger: registrar.messenger()),
      withId: "walk_on_photos/ar_view")
  }
}

final class ArPhotoViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    return ArPhotoView(frame: frame, viewId: viewId, messenger: messenger)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// ARSCNView showing the live camera with the reconstructed photo anchored
/// in the room. The photo's original camera is placed exactly at the phone's
/// pose (yaw only, gravity-aligned), so the first view looks like the photo
/// and walking forward physically walks into it.
final class ArPhotoView: NSObject, FlutterPlatformView, ARSessionDelegate {
  private let sceneView: ARSCNView
  private let channel: FlutterMethodChannel
  private var sceneRoot: SCNNode?
  private var placePending = false
  private var lastTracking = ""

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
    sceneView = ARSCNView(frame: frame)
    channel = FlutterMethodChannel(
      name: "walk_on_photos/ar_view_\(viewId)", binaryMessenger: messenger)
    super.init()

    sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    sceneView.autoenablesDefaultLighting = false
    sceneView.automaticallyUpdatesLighting = false
    sceneView.antialiasingMode = .multisampling4X
    sceneView.session.delegate = self

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    runSession()
  }

  deinit {
    sceneView.session.pause()
  }

  func view() -> UIView { sceneView }

  private func runSession() {
    let config = ARWorldTrackingConfiguration()
    config.worldAlignment = .gravity
    config.planeDetection = []
    sceneView.session.run(config)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "loadScene":
      guard let args = call.arguments as? [String: Any],
        let layers = args["layers"] as? [[String: Any]]
      else {
        result(FlutterError(code: "bad_args", message: "layers missing", details: nil))
        return
      }
      let root = SCNNode()
      for layer in layers {
        for node in makeForegroundTiles(layer) { root.addChildNode(node) }
      }
      if let particles = args["particles"] as? [String: Any],
         let pNode = makeParticleNode(particles) {
        pNode.name = "particles"
        root.addChildNode(pNode)
      }
      sceneRoot?.removeFromParentNode()
      sceneRoot = root
      placePending = true
      result(nil)
    case "placeHere":
      placePending = sceneRoot != nil
      result(nil)
    case "pause":
      sceneView.session.pause()
      result(nil)
    case "resume":
      runSession()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func makeForegroundTiles(_ layer: [String: Any]) -> [SCNNode] {
    guard let pos = (layer["positions"] as? FlutterStandardTypedData)?.data,
      let uv = (layer["uvs"] as? FlutterStandardTypedData)?.data,
      let idx = (layer["indices"] as? FlutterStandardTypedData)?.data,
      let png = (layer["texture"] as? FlutterStandardTypedData)?.data,
      let image = UIImage(data: png)
    else { return [] }

    let vertexCount = pos.count / 12
    let triCount = idx.count / 12
    guard vertexCount > 0, triCount > 0 else { return [] }

    let vertices = SCNGeometrySource(
      data: pos, semantic: .vertex, vectorCount: vertexCount,
      usesFloatComponents: true, componentsPerVector: 3,
      bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    // SceneKit texture coordinates have their origin at the top-left,
    // matching the uv layout produced on the Dart side.
    let texcoords = SCNGeometrySource(
      data: uv, semantic: .texcoord, vectorCount: vertexCount,
      usesFloatComponents: true, componentsPerVector: 2,
      bytesPerComponent: 4, dataOffset: 0, dataStride: 8)

    let material = SCNMaterial()
    material.diffuse.contents = image
    material.diffuse.wrapS = .clamp
    material.diffuse.wrapT = .clamp
    material.diffuse.minificationFilter = .linear
    material.diffuse.magnificationFilter = .linear
    material.diffuse.mipFilter = .linear
    material.lightingModel = .constant
    material.isDoubleSided = true

    var uvFloats = [Float](repeating: 0, count: vertexCount * 2)
    uvFloats.withUnsafeMutableBytes { dst in
      uv.copyBytes(to: dst)
    }
    var idxInts = [Int32](repeating: 0, count: triCount * 3)
    idxInts.withUnsafeMutableBytes { dst in
      idx.copyBytes(to: dst)
    }

    let cols = 6
    let rows = 8
    var buckets = [[Int32]](repeating: [], count: cols * rows)
    for t in 0..<triCount {
      let a = Int(idxInts[t * 3])
      let b = Int(idxInts[t * 3 + 1])
      let c = Int(idxInts[t * 3 + 2])
      let avgU = (uvFloats[a * 2] + uvFloats[b * 2] + uvFloats[c * 2]) / 3.0
      let avgV = (uvFloats[a * 2 + 1] + uvFloats[b * 2 + 1] + uvFloats[c * 2 + 1]) / 3.0
      let col = min(cols - 1, max(0, Int(avgU * Float(cols))))
      let row = min(rows - 1, max(0, Int(avgV * Float(rows))))
      buckets[row * cols + col].append(contentsOf: [Int32(a), Int32(b), Int32(c)])
    }

    var nodes: [SCNNode] = []
    for row in 0..<rows {
      for col in 0..<cols {
        let tileIndices = buckets[row * cols + col]
        if tileIndices.isEmpty { continue }
        let elemData = tileIndices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
          data: elemData, primitiveType: .triangles,
          primitiveCount: tileIndices.count / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [vertices, texcoords], elements: [element])
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = "tile_\(col)_\(row)"
        nodes.append(node)
      }
    }
    return nodes
  }

  private static let particleSprite: UIImage = {
    let size = CGSize(width: 32, height: 32)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
      let colorSpace = CGColorSpaceCreateDeviceRGB()
      let colors = [
        UIColor(white: 1.0, alpha: 1.0).cgColor,
        UIColor(white: 1.0, alpha: 0.72).cgColor,
        UIColor(white: 1.0, alpha: 0.0).cgColor,
      ] as CFArray
      let locations: [CGFloat] = [0.0, 0.45, 1.0]
      if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
        let center = CGPoint(x: 16, y: 16)
        ctx.cgContext.drawRadialGradient(
          gradient,
          startCenter: center,
          startRadius: 0,
          endCenter: center,
          endRadius: 16,
          options: []
        )
      }
    }
  }()

  private func makeParticleNode(_ particles: [String: Any]) -> SCNNode? {
    guard let posData = (particles["positions"] as? FlutterStandardTypedData)?.data,
      let colData = (particles["colors"] as? FlutterStandardTypedData)?.data,
      let sizeData = (particles["sizes"] as? FlutterStandardTypedData)?.data
    else { return nil }

    let count = sizeData.count / MemoryLayout<Float>.size
    guard count > 0,
      posData.count == count * 3 * MemoryLayout<Float>.size,
      colData.count == count * 4
    else { return nil }

    var positions = [Float](repeating: 0, count: count * 3)
    positions.withUnsafeMutableBytes { dst in
      posData.copyBytes(to: dst)
    }
    var sizes = [Float](repeating: 0, count: count)
    sizes.withUnsafeMutableBytes { dst in
      sizeData.copyBytes(to: dst)
    }
    let colorBytes = [UInt8](colData)

    let vCount = count * 8
    var verts = [Float]()
    verts.reserveCapacity(vCount * 3)
    var uvs = [Float]()
    uvs.reserveCapacity(vCount * 2)
    var cols = [Float]()
    cols.reserveCapacity(vCount * 4)
    var indices = [Int32]()
    indices.reserveCapacity(count * 12)

    let c1: Float = 0.8660254
    let s1: Float = 0.5
    let c2: Float = 0.5
    let s2: Float = -0.8660254

    for i in 0..<count {
      let px = positions[i * 3]
      let py = positions[i * 3 + 1]
      let pz = positions[i * 3 + 2]
      let r = sizes[i] * 1.15

      let cr = powf(Float(colorBytes[i * 4]) / 255.0, 2.2)
      let cg = powf(Float(colorBytes[i * 4 + 1]) / 255.0, 2.2)
      let cb = powf(Float(colorBytes[i * 4 + 2]) / 255.0, 2.2)
      let ca = Float(colorBytes[i * 4 + 3]) / 255.0

      let baseV = Int32(i * 8)

      // Quad 1 (+30 deg around Y)
      let rx1 = r * c1
      let rz1 = r * s1
      verts.append(contentsOf: [
        px - rx1, py - r, pz - rz1,
        px + rx1, py - r, pz + rz1,
        px + rx1, py + r, pz + rz1,
        px - rx1, py + r, pz - rz1,
      ])
      // Quad 2 (-60 deg around Y)
      let rx2 = r * c2
      let rz2 = r * s2
      verts.append(contentsOf: [
        px - rx2, py - r, pz - rz2,
        px + rx2, py - r, pz + rz2,
        px + rx2, py + r, pz + rz2,
        px - rx2, py + r, pz - rz2,
      ])

      for _ in 0..<2 {
        uvs.append(contentsOf: [0, 1, 1, 1, 1, 0, 0, 0])
      }
      for _ in 0..<8 {
        cols.append(contentsOf: [cr, cg, cb, ca])
      }
      indices.append(contentsOf: [
        baseV, baseV + 1, baseV + 2,
        baseV, baseV + 2, baseV + 3,
        baseV + 4, baseV + 5, baseV + 6,
        baseV + 4, baseV + 6, baseV + 7,
      ])
    }

    let vData = verts.withUnsafeBytes { Data($0) }
    let uvData = uvs.withUnsafeBytes { Data($0) }
    let cData = cols.withUnsafeBytes { Data($0) }
    let iData = indices.withUnsafeBytes { Data($0) }

    let vSource = SCNGeometrySource(
      data: vData, semantic: .vertex, vectorCount: vCount,
      usesFloatComponents: true, componentsPerVector: 3,
      bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    let uvSource = SCNGeometrySource(
      data: uvData, semantic: .texcoord, vectorCount: vCount,
      usesFloatComponents: true, componentsPerVector: 2,
      bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
    let cSource = SCNGeometrySource(
      data: cData, semantic: .color, vectorCount: vCount,
      usesFloatComponents: true, componentsPerVector: 4,
      bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
    let element = SCNGeometryElement(
      data: iData, primitiveType: .triangles,
      primitiveCount: count * 4, bytesPerIndex: 4)

    let geometry = SCNGeometry(sources: [vSource, uvSource, cSource], elements: [element])
    let material = SCNMaterial()
    material.diffuse.contents = Self.particleSprite
    material.diffuse.wrapS = .clamp
    material.diffuse.wrapT = .clamp
    material.lightingModel = .constant
    material.isDoubleSided = true
    material.blendMode = .alpha
    material.transparencyMode = .aOne
    material.writesToDepthBuffer = false
    material.readsFromDepthBuffer = true
    geometry.materials = [material]

    let node = SCNNode(geometry: geometry)
    node.renderingOrder = 1
    return node
  }

  private func place(_ root: SCNNode, camera: ARCamera) {
    let t = camera.transform
    let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
    // Rotation about +Y by `yaw` maps the photo's -Z axis onto `forward`.
    let yaw = atan2(-forward.x, -forward.z)
    root.simdPosition = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    root.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    if root.parent == nil { sceneView.scene.rootNode.addChildNode(root) }
    animateFlyIn(root)
    channel.invokeMethod("onPlaced", arguments: nil)
  }

  private func animateFlyIn(_ root: SCNNode) {
    for child in root.childNodes {
      child.removeAllActions()
      if let name = child.name, name.hasPrefix("tile_") {
        let parts = name.split(separator: "_")
        if parts.count == 3, let col = Int(parts[1]), let row = Int(parts[2]) {
          let dx = (Float(col) - 2.5) * 0.16
          let dy = (3.5 - Float(row)) * 0.16
          let jitter = Float((col * 17 + row * 31) % 7) * 0.06
          child.opacity = 0.0
          child.simdPosition = SIMD3<Float>(dx, dy, -0.7 - jitter)

          let dist = sqrtf(powf(Float(col) - 2.5, 2) + powf(Float(row) - 3.5, 2)) / 4.3
          let delay = Double(dist) * 0.35 + Double((col * 7 + row * 13) % 5) * 0.03
          let fly = SCNAction.group([
            SCNAction.fadeIn(duration: 0.38),
            SCNAction.move(to: SCNVector3Zero, duration: 0.48),
          ])
          fly.timingMode = .easeOut
          child.runAction(SCNAction.sequence([SCNAction.wait(duration: delay), fly]))
          continue
        }
      }
      if child.name == "particles" {
        child.opacity = 0.0
        let fade = SCNAction.fadeIn(duration: 0.55)
        fade.timingMode = .easeOut
        child.runAction(SCNAction.sequence([SCNAction.wait(duration: 0.30), fade]))
      }
    }
  }

  // MARK: ARSessionDelegate (delivered on the main queue)

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard placePending, let root = sceneRoot else { return }
    if case .normal = frame.camera.trackingState {
      placePending = false
      place(root, camera: frame.camera)
    }
  }

  func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    let state: String
    switch camera.trackingState {
    case .normal: state = "normal"
    case .notAvailable: state = "notAvailable"
    case .limited(let reason):
      switch reason {
      case .initializing: state = "limited:initializing"
      case .excessiveMotion: state = "limited:excessiveMotion"
      case .insufficientFeatures: state = "limited:insufficientFeatures"
      case .relocalizing: state = "limited:relocalizing"
      @unknown default: state = "limited"
      }
    }
    if state != lastTracking {
      lastTracking = state
      channel.invokeMethod("onTracking", arguments: state)
    }
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    channel.invokeMethod("onTracking", arguments: "error:\(error.localizedDescription)")
  }
}

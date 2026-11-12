import CoreImage
import ImageIO
import Network
import SwiftUI

private struct RGBDHeader: Encodable {
    let jpegBytes: Int
    let width: Int
    let height: Int
    let depthWidth: Int
    let depthHeight: Int
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let quarterTurns: Int
}

private final class LANCamera: ObservableObject {
    let camera = CameraManager()
    @Published var status = "正在寻找附近的 Mac…"
    @Published var nearby: [NWEndpoint] = []
    @Published var connecting = false
    private let context = CIContext()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var hotspotListener: NWListener?
    private var ready = false
    private var sending = false
    private var quarterTurns = 0
    private var lastFrame: Double = -.infinity

    init() {
        camera.onFrame = { [weak self] frame in self?.send(frame) }
    }

    func updateOrientation(_ orientation: UIDeviceOrientation) {
        let turns: Int
        switch orientation {
        case .portrait: turns = 0
        case .landscapeLeft: turns = 1
        case .portraitUpsideDown: turns = 2
        case .landscapeRight: turns = 3
        default: return
        }
        camera.videoQueue.async { self.quarterTurns = turns }
    }

    func browse() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_yolodepth._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, self.browser === browser else { return }
            self.nearby = results.map { result in
                guard case let .service(name, type, domain, _) = result.endpoint,
                      let wireless = result.interfaces.first(where: { $0.name == "awdl0" }) else {
                    return result.endpoint
                }
                return NWEndpoint.service(name: name, type: type, domain: domain, interface: wireless)
            }.sorted { $0.debugDescription < $1.debugDescription }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, self.browser === browser, !self.connecting else { return }
            if case let .waiting(error) = state { self.status = error.localizedDescription }
            if case let .failed(error) = state { self.status = error.localizedDescription }
        }
        browser.start(queue: .main)
    }

    func start(_ endpoint: NWEndpoint) {
        connecting = true
        status = "正在连接 Mac…"
        let parameters = NWParameters.tcp
        if case .service = endpoint {
            parameters.includePeerToPeer = true
            parameters.prohibitedInterfaceTypes = [.wiredEthernet]
        }
        if case let .service(_, _, _, interface) = endpoint, interface?.name == "awdl0" {
            parameters.requiredInterface = interface
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        attach(connection)
    }

    func listenOnHotspot() {
        connecting = true
        status = "等待 Mac 连接热点…"
        do {
            let listener = try NWListener(using: .tcp, on: 8767)
            hotspotListener = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, self.hotspotListener === listener else {
                    connection.cancel()
                    return
                }
                self.hotspotListener?.cancel()
                self.hotspotListener = nil
                self.attach(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.hotspotListener === listener else { return }
                if case let .failed(error) = state {
                    self.stop()
                    self.status = "热点接收失败 · \(error)"
                }
            }
            listener.start(queue: .main)
        } catch {
            connecting = false
            status = error.localizedDescription
        }
    }

    private func attach(_ connection: NWConnection) {
        camera.videoQueue.async {
            self.connection = connection
            self.lastFrame = -.infinity
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.camera.start { [weak self] error in
                        self?.status = error ?? "已连接 · 等待相机画面"
                    }
                case .waiting(let error):
                    DispatchQueue.main.async { self.status = "等待无线连接 · \(error)" }
                case .failed(let error):
                    self.disconnect(connection, message: "连接失败 · \(error)")
                default:
                    break
                }
            }
            connection.start(queue: self.camera.videoQueue)
            self.camera.videoQueue.asyncAfter(deadline: .now() + 12) { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection, !self.ready else { return }
                self.disconnect(connection, message: "无线连接超时，请重新选择 Mac")
            }
        }
    }

    func stop() {
        if let listener = hotspotListener {
            hotspotListener = nil
            listener.cancel()
            connecting = false
            status = "已停止"
        }
        camera.videoQueue.async {
            if let connection = self.connection { self.disconnect(connection, message: "已停止") }
        }
    }

    func leave() {
        browser?.cancel()
        browser = nil
        nearby = []
        stop()
    }

    private func disconnect(_ connection: NWConnection, message: String) {
        guard self.connection === connection else { return }
        self.connection = nil
        ready = false
        sending = false
        connection.cancel()
        camera.stop()
        DispatchQueue.main.async {
            self.connecting = false
            self.status = message
        }
    }

    private func send(_ frame: CameraFrame) {
        guard let connection, ready, !sending, frame.timestamp - lastFrame >= 1.0 / 30 else { return }
        lastFrame = frame.timestamp
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        let scale = min(1, 720 / image.extent.width)
        let preview = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let jpeg = context.jpegRepresentation(of: preview, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                     options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.65]) else { return }
        let depth = frame.depth.flatMap(Self.copyDepth)
        let k = frame.intrinsics
        let header = RGBDHeader(jpegBytes: jpeg.count, width: width, height: height,
                               depthWidth: depth?.width ?? 0, depthHeight: depth?.height ?? 0,
                               fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy, quarterTurns: quarterTurns)
        guard var body = try? JSONEncoder().encode(header) else { return }
        body.append(10)
        body.append(jpeg)
        if let depth { body.append(depth.bytes) }
        var length = UInt32(body.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(body)
        sending = true
        connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            if let error {
                self.disconnect(connection, message: error.localizedDescription)
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak connection] reply, _, _, _ in
                guard let self, let connection, self.connection === connection else { return }
                guard reply == Data([1]) else {
                    self.disconnect(connection, message: "Mac 接收器已断开")
                    return
                }
                self.sending = false
                let status = depth == nil ? "已连接 · 暂无深度" : "已连接 · 正在发送 RGB + LiDAR"
                DispatchQueue.main.async { self.status = status }
            }
        })
    }

    private static func copyDepth(_ map: CVPixelBuffer) -> (width: Int, height: Int, bytes: Data)? {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat16,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let stride = CVPixelBufferGetBytesPerRow(map)
        var bytes = Data(capacity: width * height * 2)
        for row in 0..<height {
            bytes.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * 2)
        }
        return (width, height, bytes)
    }
}

struct LANCameraView: View {
    @StateObject private var stream = LANCamera()
    @AppStorage("manualMacAddress") private var manualAddress = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            CameraPreview(session: stream.camera.session)
            VStack(spacing: 12) {
                Text(stream.status).font(.footnote)
                if stream.connecting {
                    Button("停止发送") { stream.stop() }
                        .buttonStyle(.borderedProminent)
                } else {
                    HStack {
                        TextField("Mac 的 Wi-Fi IP", text: $manualAddress)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                        Button("直接连接") {
                            let address = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                            stream.start(.hostPort(host: NWEndpoint.Host(address), port: 8766))
                        }
                        .disabled(manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button("等待 Mac 通过热点连接") { stream.listenOnHotspot() }
                        .buttonStyle(.bordered)
                    ForEach(stream.nearby, id: \.self) { endpoint in
                        Button(displayName(endpoint)) { stream.start(endpoint) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding()
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            stream.updateOrientation(UIDevice.current.orientation)
            stream.browse()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            stream.updateOrientation(UIDevice.current.orientation)
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            stream.leave()
        }
    }

    private func displayName(_ endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return endpoint.debugDescription
    }
}

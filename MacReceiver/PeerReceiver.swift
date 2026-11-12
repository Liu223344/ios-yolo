import Foundation
import Network

final class PeerReceiver {
    private let queue = DispatchQueue(label: "yolo.peer.receiver")
    private let listener: NWListener
    private var active: NWConnection?
    private let dialsHotspot: Bool
    private let upstream = URL(string: "http://127.0.0.1:8765/frame")!

    init(hotspotHost: String) throws {
        dialsHotspot = true
        listener = try NWListener(using: .tcp)
        let connection = NWConnection(host: NWEndpoint.Host(hotspotHost), port: 8767, using: .tcp)
        queue.async { self.accept(connection) }
    }

    init(peerToPeer: Bool) throws {
        dialsHotspot = false
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = peerToPeer
        listener = try NWListener(using: parameters, on: peerToPeer ? .any : 8766)
        let host = Host.current().localizedName ?? "YOLO LiDAR Mac"
        let suffix = peerToPeer ? "" : " · Wi-Fi"
        let name = host + suffix
        listener.service = NWListener.Service(name: name, type: "_yolodepth._tcp")
        listener.stateUpdateHandler = { state in
            if case .ready = state { NSLog("Listening for iPhone: %@", name) }
            if case let .failed(error) = state {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        active?.cancel()
        active = connection
        let dialsHotspot = self.dialsHotspot
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                let interfaces = connection?.currentPath?.availableInterfaces.map(\.name).joined(separator: ", ") ?? "unknown"
                NSLog("iPhone connected from %@; interfaces: %@", String(describing: connection?.endpoint), interfaces)
            case .failed(let error):
                NSLog("iPhone connection failed: %@", String(describing: error))
                if dialsHotspot { exit(1) }
            case .cancelled:
                if dialsHotspot { exit(0) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        if dialsHotspot {
            queue.asyncAfter(deadline: .now() + 5) { [weak connection] in
                guard let connection, connection.state != .ready else { return }
                connection.cancel()
            }
        }
        readLength(connection)
    }

    private func readLength(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, _ in
            guard let self, self.active === connection else { return }
            let length = data?.reduce(0) { ($0 << 8) | Int($1) } ?? 0
            guard data?.count == 4, (1...4_000_000).contains(length) else {
                connection.cancel()
                self.active = nil
                return
            }
            self.readFrame(connection, length: length)
        }
    }

    private func readFrame(_ connection: NWConnection, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, _ in
            guard let self, self.active === connection else { return }
            guard let data, data.count == length else {
                connection.cancel()
                self.active = nil
                return
            }
            var request = URLRequest(url: self.upstream, timeoutInterval: 3)
            request.httpMethod = "POST"
            request.httpBody = data
            URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
                guard let self else { return }
                let ok = (response as? HTTPURLResponse)?.statusCode == 204
                if !ok { NSLog("Local vision process did not acknowledge frame") }
                self.queue.async {
                    guard self.active === connection else { return }
                    connection.send(content: Data([ok ? 1 : 0]), completion: .contentProcessed { error in
                        guard self.active === connection else { return }
                        if ok, error == nil {
                            self.readLength(connection)
                        } else {
                            connection.cancel()
                            self.active = nil
                        }
                    })
                }
            }.resume()
        }
    }
}

let receivers: [PeerReceiver]
if CommandLine.arguments.count == 2 {
    receivers = [try PeerReceiver(hotspotHost: CommandLine.arguments[1])]
} else {
    receivers = [try PeerReceiver(peerToPeer: true), try PeerReceiver(peerToPeer: false)]
}
dispatchMain()

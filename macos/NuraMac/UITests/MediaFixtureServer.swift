import Foundation
import Network

final class MediaFixtureServer: @unchecked Sendable {
    private(set) var baseURL: URL
    private let fixtureURL: URL
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let stateLock = NSLock()

    init(fixtureURL: URL) {
        baseURL = URL(string: "http://127.0.0.1:0")!
        self.fixtureURL = fixtureURL
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let listenerPort = listener.port {
                        continuation.resume(returning: listenerPort.rawValue)
                    } else {
                        continuation.resume(throwing: MediaFixtureServerError.missingPort)
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
        self.listener = listener
        setBaseURL(URL(string: "http://127.0.0.1:\(port)")!)
    }

    func stop() {
        stateLock.lock()
        let connectionsToCancel = connections
        connections.removeAll()
        let listenerToCancel = listener
        stateLock.unlock()
        listenerToCancel?.cancel()
        for connection in connectionsToCancel {
            connection.cancel()
        }
    }

    private func setBaseURL(_ url: URL) {
        stateLock.lock()
        baseURL = url
        stateLock.unlock()
    }

    private func handle(_ connection: NWConnection) {
        stateLock.lock()
        connections.append(connection)
        stateLock.unlock()
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            let request = String(decoding: data, as: UTF8.self)
            guard request.hasPrefix("GET ") else {
                connection.cancel()
                return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            guard path == "/oceans.mp4", let body = try? Data(contentsOf: self.fixtureURL) else {
                self.respond(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
                return
            }
            self.respond(connection, status: "200 OK", contentType: "video/mp4", body: body)
        }
    }

    private func respond(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var payload = Data(headers.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private enum MediaFixtureServerError: Error {
    case missingPort
}

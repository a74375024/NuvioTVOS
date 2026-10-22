import Foundation
import Network
import Darwin

/// Serves one immutable allowlisted JSON snapshot, only after an explicit export action.
final class PlaybackDiagnosticExportServer: @unchecked Sendable {
    enum State: Sendable { case stopped, starting, ready(URL), failed }
    private let queue = DispatchQueue(label: "nuvio.diagnostic-export", qos: .utility)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var generation = UUID()
    private var expiry: DispatchWorkItem?
    private var callback: (@Sendable (State) -> Void)?

    func start(
        report: Data,
        contentType: String = "application/json",
        filename: String = "nuvio-diagnostics.json",
        maximumBytes: Int = PlaybackDiagnosticTimeline.maximumBytes,
        lifetime: TimeInterval = 300,
        changed: @escaping @Sendable (State) -> Void
    ) {
        queue.async {
            self.stopOnQueue()
            self.callback = changed
            changed(.starting)
            guard report.count <= maximumBytes,
                  let host = Self.localIPv4Address() else {
                changed(.failed)
                return
            }
            let current = UUID()
            self.generation = current
            let path = "/\(UUID().uuidString)/\(filename)"
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
                let listener = try NWListener(using: parameters, on: .any)
                listener.newConnectionLimit = 16
                self.listener = listener
                listener.stateUpdateHandler = { [weak server = self, weak listener] state in
                    guard let server, server.generation == current else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port,
                              let url = URL(string: "http://\(host):\(port.rawValue)\(path)") else {
                            server.stopOnQueue()
                            changed(.failed)
                            return
                        }
                        changed(.ready(url))
                    case .failed:
                        server.stopOnQueue()
                        changed(.failed)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak server = self] connection in
                    guard let server, server.generation == current, server.connections.count < 4 else {
                        connection.cancel()
                        return
                    }
                    let id = UUID()
                    server.connections[id] = connection
                    connection.start(queue: server.queue)
                    server.receive(connection, id: id, path: path, report: report, buffered: Data(),
                                   contentType: contentType, filename: filename)
                    server.queue.asyncAfter(deadline: .now() + 30) { [weak server] in server?.finish(id) }
                }
                let expiry = DispatchWorkItem { [weak server = self] in
                    guard let server, server.generation == current else { return }
                    server.stopOnQueue()
                    changed(.stopped)
                }
                self.expiry = expiry
                self.queue.asyncAfter(deadline: .now() + lifetime, execute: expiry)
                listener.start(queue: self.queue)
            } catch {
                self.stopOnQueue()
                changed(.failed)
            }
        }
    }

    func stop() {
        queue.async {
            let callback = self.callback
            self.stopOnQueue()
            callback?(.stopped)
        }
    }

    private func stopOnQueue() {
        generation = UUID()
        expiry?.cancel()
        expiry = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        callback = nil
    }

    private func finish(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, path: String, report: Data, buffered: Data,
                         contentType: String, filename: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var request = buffered
            if let data { request.append(data) }
            guard request.count <= 8192, error == nil else { self.finish(id); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { self.finish(id) }
                else { self.receive(connection, id: id, path: path, report: report, buffered: request,
                                    contentType: contentType, filename: filename) }
                return
            }
            let allowed = Self.accepts(request, path: path)
            let body = allowed ? report : Data()
            let status = allowed ? "200 OK" : "404 Not Found"
            let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nContent-Disposition: attachment; filename=\"\(filename)\"\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
            var response = Data(headers.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
        }
    }

    /// Exact tokenized GET only. No file-system routes, request bodies or directory listing.
    static func accepts(_ request: Data, path: String) -> Bool {
        guard request.count <= 8192,
              let text = String(data: request, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n"),
              headerEnd.upperBound == text.endIndex else { return false }
        let lines = text[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let line = lines.first else { return false }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[1] == Substring(path),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return false }
        return !lines.dropFirst().contains { line in
            let name = line.split(separator: ":", maxSplits: 1).first?.lowercased()
            return name == "content-length" || name == "transfer-encoding"
        }
    }

    private static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var next = interfaces
        while let item = next {
            defer { next = item.pointee.ifa_next }
            let info = item.pointee
            guard let address = info.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  info.ifa_flags & UInt32(IFF_UP) != 0,
                  info.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  String(cString: info.ifa_name).hasPrefix("en") else { continue }
            let result: String? = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var ip = pointer.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let result { return result }
        }
        return nil
    }
}

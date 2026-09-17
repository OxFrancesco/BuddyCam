import CryptoKit
import Foundation
import Network
import Observation
import Security

// Incremental RFC 6455 frame parser. Buffers partial frames across chunks,
// handles 7/16/64-bit lengths, masked and unmasked payloads, and fragmented
// messages with interleaved control frames.
struct WebSocketFrameParser {
    enum Message: Equatable {
        case binary(Data)
        case text(String)
        case ping(Data)
        case pong(Data)
        case close(code: UInt16?)
    }

    enum ParseError: Error {
        case protocolViolation(String)
        case tooLarge
    }

    var maxMessageSize = 16 * 1024 * 1024
    private var buffer = Data()
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0

    mutating func append(_ data: Data) throws -> [Message] {
        buffer.append(data)
        var messages: [Message] = []
        while let frame = try nextFrame() {
            switch frame.opcode {
            case 0x0:
                guard fragmentOpcode != 0 else { throw ParseError.protocolViolation("Continuation frame without a message.") }
                fragments.append(frame.payload)
                if fragments.count > maxMessageSize { throw ParseError.tooLarge }
                if frame.fin {
                    let opcode = fragmentOpcode
                    fragmentOpcode = 0
                    try emit(opcode: opcode, payload: fragments, into: &messages)
                    fragments = Data()
                }
            case 0x1, 0x2:
                guard fragmentOpcode == 0 else { throw ParseError.protocolViolation("New message while a fragmented message is open.") }
                if frame.fin {
                    try emit(opcode: frame.opcode, payload: frame.payload, into: &messages)
                } else {
                    fragmentOpcode = frame.opcode
                    fragments = frame.payload
                }
            case 0x8:
                var code: UInt16?
                if frame.payload.count >= 2 {
                    code = UInt16(frame.payload[frame.payload.startIndex]) << 8
                        | UInt16(frame.payload[frame.payload.index(after: frame.payload.startIndex)])
                }
                messages.append(.close(code: code))
            case 0x9:
                messages.append(.ping(frame.payload))
            case 0xA:
                messages.append(.pong(frame.payload))
            default:
                throw ParseError.protocolViolation("Unknown opcode \(frame.opcode).")
            }
        }
        return messages
    }

    private func emit(opcode: UInt8, payload: Data, into messages: inout [Message]) throws {
        if opcode == 0x2 {
            messages.append(.binary(payload))
        } else {
            messages.append(.text(String(decoding: payload, as: UTF8.self)))
        }
    }

    private struct Frame {
        let fin: Bool
        let opcode: UInt8
        let payload: Data
    }

    private mutating func nextFrame() throws -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.index(after: buffer.startIndex)]
        let fin = b0 & 0x80 != 0
        let rsv = b0 & 0x70
        let opcode = b0 & 0x0F
        let masked = b1 & 0x80 != 0
        var length = UInt64(b1 & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            length = UInt64(buffer[buffer.index(buffer.startIndex, offsetBy: offset)]) << 8
                | UInt64(buffer[buffer.index(buffer.startIndex, offsetBy: offset + 1)])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            length = 0
            for i in 0..<8 {
                length = length << 8 | UInt64(buffer[buffer.index(buffer.startIndex, offsetBy: offset + i)])
            }
            offset += 8
        }
        guard rsv == 0 else { throw ParseError.protocolViolation("Reserved bits set.") }
        if opcode >= 0x8 {
            guard fin else { throw ParseError.protocolViolation("Fragmented control frame.") }
            guard length <= 125 else { throw ParseError.protocolViolation("Oversized control frame.") }
        }
        guard length <= UInt64(maxMessageSize) else { throw ParseError.tooLarge }
        let maskStart = offset
        if masked { offset += 4 }
        guard UInt64(offset) + length <= UInt64(buffer.count) else { return nil }
        let payloadStart = buffer.startIndex + offset
        let payloadEnd = payloadStart + Int(length)
        var payload = Data(buffer[payloadStart..<payloadEnd])
        if masked {
            var key = [UInt8](repeating: 0, count: 4)
            for i in 0..<4 { key[i] = buffer[buffer.index(buffer.startIndex, offsetBy: maskStart + i)] }
            payload.withUnsafeMutableBytes { bytes in
                for i in 0..<bytes.count { bytes[i] ^= key[i % 4] }
            }
        }
        if opcode == 0x8, payload.count == 1 { throw ParseError.protocolViolation("Close frame with a 1-byte payload.") }
        buffer = Data(buffer[payloadEnd..<buffer.endIndex])
        return Frame(fin: fin, opcode: opcode, payload: payload)
    }

    // Server-to-client frames are never masked.
    static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out.append(126)
            out.append(UInt8(payload.count >> 8))
            out.append(UInt8(payload.count & 0xFF))
        } else {
            out.append(127)
            var length = UInt64(payload.count)
            var bytes = [UInt8](repeating: 0, count: 8)
            for i in (0..<8).reversed() { bytes[i] = UInt8(length & 0xFF); length >>= 8 }
            out.append(contentsOf: bytes)
        }
        out.append(payload)
        return out
    }

    static func acceptKey(for key: String) -> String {
        var sha = Insecure.SHA1()
        sha.update(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(sha.finalize()).base64EncodedString()
    }
}

// Non-loopback IPv4 addresses from getifaddrs, used for the self-signed SAN
// list and for picking the host the QR code points at.
enum LocalAddresses {
    static func ipv4() -> [(interface: String, address: String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var current = list
        while let ifa = current {
            defer { current = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard ok == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("127.") else { continue }
            result.append((String(cString: ifa.pointee.ifa_name), address))
        }
        return result
    }

    static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
    }
}

// Resolves the TLS identity for the link server. Runs Process calls, so call
// from a background task. Prefers a Tailscale-issued certificate for the
// Mac's MagicDNS name (trusted by the phone's browser with no warning); falls
// back to a long-lived self-signed certificate.
enum LinkIdentity {
    struct Resolved {
        let identity: SecIdentity
        let host: String?
        let trusted: Bool
    }

    static func resolve(directory: URL) throws -> Resolved {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let resolved = try? tailscale(directory: directory) { return resolved }
        do {
            let crt = directory.appendingPathComponent("self.crt")
            let key = directory.appendingPathComponent("self.key")
            let valid = FileManager.default.fileExists(atPath: crt.path)
                && FileManager.default.fileExists(atPath: key.path)
                && (try? run("/usr/bin/openssl", ["x509", "-checkend", "2592000", "-noout", "-in", crt.path], timeout: 10)) != nil
            if valid {
                return Resolved(identity: try importIdentity(crt: crt, key: key,
                                                             p12: directory.appendingPathComponent("self.p12")),
                                host: nil, trusted: false)
            }
            var host = ProcessInfo.processInfo.hostName
            if host.hasSuffix(".local") { host = String(host.dropLast(6)) }
            if host.isEmpty { host = "buddycam" }
            let identity = try makeSelfSigned(directory: directory,
                                              hosts: ["\(host).local"],
                                              ips: LocalAddresses.ipv4().map(\.address))
            return Resolved(identity: identity, host: nil, trusted: false)
        } catch {
            throw CaptureError.message("The phone link could not create a certificate.")
        }
    }

    static func makeSelfSigned(directory: URL, hosts: [String], ips: [String]) throws -> SecIdentity {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let crt = directory.appendingPathComponent("self.crt")
        let key = directory.appendingPathComponent("self.key")
        let san = (hosts.map { "DNS:\($0)" } + ips.map { "IP:\($0)" }).joined(separator: ",")
        _ = try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                                     "-keyout", key.path, "-out", crt.path, "-days", "3650",
                                     "-subj", "/CN=BuddyCam", "-addext", "subjectAltName=\(san)"],
                timeout: 30)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        return try importIdentity(crt: crt, key: key, p12: directory.appendingPathComponent("self.p12"))
    }

    private static func tailscale(directory: URL) throws -> Resolved {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                          "/usr/local/bin/tailscale",
                          "/opt/homebrew/bin/tailscale"]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CaptureError.message("Tailscale is not installed.")
        }
        let status = try run(cli, ["status", "--json"], timeout: 5)
        guard let object = try JSONSerialization.jsonObject(with: status) as? [String: Any],
              let selfInfo = object["Self"] as? [String: Any],
              var name = selfInfo["DNSName"] as? String, !name.isEmpty else {
            throw CaptureError.message("Tailscale did not report a DNS name.")
        }
        guard object["BackendState"] as? String == "Running" else {
            throw CaptureError.message("Tailscale is not running.")
        }
        if name.hasSuffix(".") { name = String(name.dropLast()) }
        let domains = object["CertDomains"] as? [String] ?? []
        guard domains.contains(name) else {
            throw CaptureError.message("HTTPS certificates are not enabled for the tailnet.")
        }
        let crt = directory.appendingPathComponent("tailscale.crt")
        let key = directory.appendingPathComponent("tailscale.key")
        _ = try run(cli, ["cert", "--cert-file", crt.path, "--key-file", key.path, name], timeout: 30)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let identity = try importIdentity(crt: crt, key: key,
                                          p12: directory.appendingPathComponent("tailscale.p12"))
        return Resolved(identity: identity, host: name, trusted: true)
    }

    private static func importIdentity(crt: URL, key: URL, p12: URL) throws -> SecIdentity {
        let password = UUID().uuidString
        _ = try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path, "-in", crt.path,
                                     "-passout", "env:BUDDYCAM_P12", "-out", p12.path],
                env: ["BUDDYCAM_P12": password], timeout: 30)
        defer { try? FileManager.default.removeItem(at: p12) }
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let options: [CFString: Any] = [kSecImportExportPassphrase: password, kSecImportToMemoryOnly: true]
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[CFString: Any]])?.first,
              let identity = first[kSecImportItemIdentity] as! SecIdentity? else {
            throw CaptureError.message("The link certificate could not be loaded.")
        }
        return identity
    }

    private static func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if !env.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            environment.merge(env) { _, new in new }
            process.environment = environment
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let group = DispatchGroup()
        var out = Data()
        var err = Data()
        group.enter()
        DispatchQueue.global().async {
            out = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            err = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let timedOut = process.isRunning
        if timedOut { process.terminate() }
        process.waitUntilExit()
        group.wait()
        let name = URL(fileURLWithPath: path).lastPathComponent
        if timedOut { throw CaptureError.message("\(name) timed out.") }
        guard process.terminationStatus == 0 else {
            let detail = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CaptureError.message(detail.isEmpty ? "\(name) exited with \(process.terminationStatus)." : "\(name): \(detail)")
        }
        return out
    }
}

// Network.framework TLS listener serving the phone page over HTTP/1.1 and
// receiving JPEG frames over a WebSocket. Everything runs on one serial
// queue; callbacks fire from that queue.
final class PhoneLinkServer: @unchecked Sendable {
    var onFrame: (@Sendable (Data) -> Void)?
    var onClients: (@Sendable (Int) -> Void)?

    private let identity: SecIdentity
    private let page: Data
    private let queue = DispatchQueue(label: "org.buddytools.BuddyCam.link", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: Set<LinkConnection> = []
    private var clients: Set<LinkConnection> = []
    private var ports: [UInt16] = []
    private var completion: (@Sendable (Result<UInt16, Error>) -> Void)?
    private var stopped = false

    init(identity: SecIdentity, page: String) {
        self.identity = identity
        self.page = Data(page.utf8)
    }

    func start(ports: [UInt16], completion: @escaping @Sendable (Result<UInt16, Error>) -> Void) {
        queue.async {
            self.ports = ports
            self.completion = completion
            self.stopped = false
            self.tryPort(0)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            for conn in Array(self.connections) { self.drop(conn) }
            self.finish(.failure(CancellationError()))
        }
    }

    private func tryPort(_ index: Int) {
        guard !stopped else { return }
        guard index < ports.count else {
            finish(.failure(CaptureError.message("Ports 7443-7449 are all in use.")))
            return
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: ports[index])!)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.finish(.success(self.ports[index]))
                case .failed(let error):
                    listener?.cancel()
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        self.tryPort(index + 1)
                    } else {
                        self.finish(.failure(error))
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<UInt16, Error>) {
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    private func accept(_ nw: NWConnection) {
        guard !stopped else { nw.cancel(); return }
        let conn = LinkConnection(nw: nw, server: self)
        connections.insert(conn)
        conn.start()
    }

    fileprivate func receive(_ data: Data, on conn: LinkConnection) {
        conn.receive(data)
    }

    fileprivate func addClient(_ conn: LinkConnection) {
        let old = clients.subtracting([conn])
        clients = [conn]
        onClients?(clients.count)
        for client in old {
            client.sendClose(1000)
        }
    }

    fileprivate func drop(_ conn: LinkConnection) {
        if conn.dead { return }
        conn.dead = true
        connections.remove(conn)
        let wasClient = clients.remove(conn) != nil
        conn.nw.stateUpdateHandler = nil
        conn.nw.cancel()
        if wasClient { onClients?(clients.count) }
    }

    fileprivate func gotFrame(_ data: Data) {
        onFrame?(data)
    }

    fileprivate var pageData: Data { page }
    fileprivate var workQueue: DispatchQueue { queue }
}

private final class LinkConnection: Hashable {
    enum Phase { case http, websocket }

    let nw: NWConnection
    weak var server: PhoneLinkServer?
    var phase = Phase.http
    var buffer = Data()
    var parser = WebSocketFrameParser()
    var dead = false

    init(nw: NWConnection, server: PhoneLinkServer) {
        self.nw = nw
        self.server = server
    }

    static func == (lhs: LinkConnection, rhs: LinkConnection) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    func start() {
        guard let server else { return }
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.server?.drop(self)
            default:
                break
            }
        }
        nw.start(queue: server.workQueue)
        receiveMore()
    }

    private func receiveMore() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self, !self.dead else { return }
            if let data, !data.isEmpty { self.receive(data) }
            if complete || error != nil {
                self.server?.drop(self)
                return
            }
            if !self.dead { self.receiveMore() }
        }
    }

    func receive(_ data: Data) {
        switch phase {
        case .http:
            buffer.append(data)
            let marker = Data("\r\n\r\n".utf8)
            guard let range = buffer.range(of: marker) else {
                if buffer.count > 16 * 1024 { server?.drop(self) }
                return
            }
            let head = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            let rest = buffer.subdata(in: range.upperBound..<buffer.endIndex)
            buffer = Data()
            handleHTTP(head: head, rest: rest)
        case .websocket:
            feedParser(data)
        }
    }

    private func handleHTTP(head: Data, rest: Data) {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(status: "404 Not Found", body: Data())
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<index]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "/")
        switch path {
        case "/", "/index.html":
            respond(status: "200 OK", body: server?.pageData ?? Data(),
                    type: "text/html; charset=utf-8", close: true)
        case "/ws":
            guard headers["upgrade"]?.lowercased() == "websocket",
                  let key = headers["sec-websocket-key"], !key.isEmpty else {
                respond(status: "404 Not Found", body: Data())
                return
            }
            handshake(key: key, rest: rest)
        default:
            respond(status: "404 Not Found", body: Data())
        }
    }

    private func respond(status: String, body: Data, type: String? = nil, close: Bool = true) {
        var response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n"
        if let type { response += "Content-Type: \(type)\r\nCache-Control: no-store\r\n" }
        response += "Connection: close\r\n\r\n"
        send(Data(response.utf8) + body) { [weak self] in
            guard let self else { return }
            self.server?.drop(self)
        }
    }

    private func handshake(key: String, rest: Data) {
        let accept = WebSocketFrameParser.acceptKey(for: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        phase = .websocket
        server?.addClient(self)
        send(Data(response.utf8))
        if !rest.isEmpty { feedParser(rest) }
    }

    private func feedParser(_ data: Data) {
        do {
            for message in try parser.append(data) {
                switch message {
                case .binary(let payload):
                    server?.gotFrame(payload)
                case .text:
                    break
                case .ping(let payload):
                    send(WebSocketFrameParser.frame(opcode: 0xA, payload: payload))
                case .pong:
                    break
                case .close(let code):
                    var payload = Data()
                    if let code { payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)]) }
                    send(WebSocketFrameParser.frame(opcode: 0x8, payload: payload)) { [weak self] in
                        guard let self else { return }
                        self.server?.drop(self)
                    }
                }
            }
        } catch {
            sendClose(1002)
        }
    }

    func sendClose(_ code: UInt16) {
        send(WebSocketFrameParser.frame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))) { [weak self] in
            guard let self else { return }
            self.server?.drop(self)
        }
    }

    private func send(_ data: Data, then: (@Sendable () -> Void)? = nil) {
        nw.send(content: data, completion: .contentProcessed { _ in then?() })
    }
}

// The Mac-side half of the LINK source: resolves a TLS identity, serves the
// phone page, and pushes decoded frames into a FrameFeed shared with the
// recording pipeline.
@MainActor @Observable
final class PhoneLink {
    enum State: Equatable {
        case off, preparing, waiting, live
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var url = ""
    private(set) var trusted = false
    nonisolated let feed = FrameFeed()

    nonisolated let decoder = JPEGDecoder()
    private var server: PhoneLinkServer?
    private var startTask: Task<Void, Never>?
    // Incremented on every start/stop so a stale detached task from an
    // earlier start cannot bind a listener or overwrite the state.
    private var generation = 0

    var detailText: String {
        state == .live ? feed.detailText : ""
    }

    init() {
        decoder.onImage = { [weak self] image in
            self?.feed.push(image)
            Task { @MainActor in
                guard let self, self.state == .waiting else { return }
                self.state = .live
            }
        }
    }

    func start() {
        switch state {
        case .preparing, .waiting, .live: return
        case .off, .failed: break
        }
        state = .preparing
        generation += 1
        let generation = self.generation
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BuddyCam/link", isDirectory: true)
        startTask = Task.detached { [weak self] in
            do {
                let resolved = try LinkIdentity.resolve(directory: directory)
                await self?.serve(resolved, generation: generation)
            } catch {
                await self?.fail(error.localizedDescription, generation: generation)
            }
        }
    }

    func stop() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        server?.stop()
        server = nil
        state = .off
        url = ""
        trusted = false
        feed.clear()
    }

    private func serve(_ resolved: LinkIdentity.Resolved, generation: Int) async {
        guard state == .preparing, generation == self.generation else { return }
        let server = PhoneLinkServer(identity: resolved.identity, page: PhonePage.html)
        server.onFrame = { [weak self] data in
            self?.decoder.submit(data)
        }
        server.onClients = { [weak self] count in
            Task { @MainActor in
                guard let self, count == 0, self.state == .live else { return }
                self.state = .waiting
            }
        }
        self.server = server
        let result: Result<UInt16, Error> = await withCheckedContinuation { continuation in
            server.start(ports: [7443, 7444, 7445, 7446, 7447, 7448, 7449]) { result in
                continuation.resume(returning: result)
            }
        }
        guard state == .preparing, generation == self.generation else {
            if self.server === server { self.server = nil }
            server.stop()
            return
        }
        switch result {
        case .success(let port):
            let host = Self.host(using: resolved)
            trusted = resolved.trusted
            url = "https://\(host):\(port)/"
            state = .waiting
        case .failure(let error):
            if self.server === server { self.server = nil }
            server.stop()
            fail(error.localizedDescription, generation: generation)
        }
    }

    private static func host(using resolved: LinkIdentity.Resolved) -> String {
        if resolved.trusted, let host = resolved.host { return host }
        let addresses = LocalAddresses.ipv4()
        if let tailscale = addresses.first(where: { LocalAddresses.isTailscale($0.address) }) {
            return tailscale.address
        }
        if let en0 = addresses.first(where: { $0.interface == "en0" }) { return en0.address }
        if let first = addresses.first { return first.address }
        var host = ProcessInfo.processInfo.hostName
        if !host.hasSuffix(".local") { host += ".local" }
        return host
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        state = .failed(message)
    }

    func startRecording(to file: URL) throws -> Date {
        guard state == .live else {
            throw CaptureError.message("Scan the QR code with your phone first.")
        }
        return try feed.startRecording(to: file)
    }

    func stopRecording() async throws {
        try await feed.stopRecording()
    }
}

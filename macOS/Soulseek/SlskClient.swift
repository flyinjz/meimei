import Foundation
import Network

// The Soulseek engine: the server session, peer connections, searches,
// downloads, and serving uploads and share lists to other users.
//
// Transport is Apple's Network.framework, the quickest route on macOS. It is
// Apple-only: the Windows and Linux ports replace `SlskSocket` and the
// listener (SwiftNIO or plain sockets). Everything above them is portable.
// See the port notes.
//
// All state lives on one serial queue; events reach the app on the main queue.

// MARK: - Route

/// How Raven reaches the network. Every outbound connection, to the server
/// and to peers, goes through the same route, so nothing bypasses it.
struct SlskRoute: Sendable, Equatable {
    /// `tunnel` is Raven Tunnel: SOCKS5 to the WireGuard tunnel's loopback endpoint.
    enum Mode: String, Codable, Sendable, CaseIterable { case direct, socks5, tunnel }

    var mode: Mode = .direct
    var proxyHost = ""
    var proxyPort: UInt16 = 1080
    var proxyUser = ""
    var proxyPassword = ""
    /// IPv4 resolvers the user typed (preferred first). Empty: the system resolver.
    var dnsServers: [String] = []
    /// Listen for peers dialing in. Never through a SOCKS proxy.
    var acceptIncoming = true

    var viaProxy: Bool { mode == .socks5 || mode == .tunnel }
    var listens: Bool { acceptIncoming && !viaProxy }

    /// Connection parameters for a route. With resolvers set, name lookups
    /// are DNS over TLS (port 853) to them; with a proxy, names are resolved
    /// by the proxy and never looked up here.
    func parameters() -> NWParameters {
        let p = NWParameters.tcp
        if !viaProxy, let first = dnsServers.first {
            let context = NWParameters.PrivacyContext(description: "i2s.raven")
            let endpoints = dnsServers.map { NWEndpoint.hostPort(host: NWEndpoint.Host($0), port: 853) }
            context.requireEncryptedNameResolution(true, fallbackResolver: .tls(.hostPort(host: NWEndpoint.Host(first), port: 853),
                                                                              serverAddresses: endpoints))
            p.setPrivacyContext(context)
        }
        return p
    }

    /// "1.1.1.1" style addresses only: four decimal octets, 0–255.
    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isASCII) && p.allSatisfy(\.isNumber) && (Int(p) ?? 256) <= 255
        }
    }
}

// MARK: - Socket

/// One TCP connection with Soulseek framing. Starts in `server`, `peerInit`,
/// or `peer` framing; file connections switch to `raw` after their init.
final class SlskSocket {
    enum Framing { case server, peerInit, peer, raw }

    let connection: NWConnection
    var framing: Framing
    var onReady: (() -> Void)?
    var onInit: ((UInt8, inout SlskReader) -> Void)?
    var onMessage: ((UInt32, inout SlskReader) -> Void)?
    var onRaw: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    /// A large message still arriving: its code, bytes so far, and full length.
    var onPartial: ((UInt32, Int, Int) -> Void)?
    /// Free-form tag for the engine (which user, which job).
    var user = ""
    private var buffer = Data()
    private(set) var isClosed = false
    private let queue: DispatchQueue

    init(_ connection: NWConnection, framing: Framing, queue: DispatchQueue) {
        self.connection = connection
        self.framing = framing
        self.queue = queue
    }

    /// An outbound connection, along `route`. Through a SOCKS5 proxy, the
    /// socket dials the proxy, asks it for `host:port`, and only then counts as ready.
    convenience init(host: String, port: UInt16, framing: Framing, queue: DispatchQueue, route: SlskRoute = SlskRoute()) {
        let params = route.parameters()
        if route.viaProxy {
            let conn = NWConnection(host: NWEndpoint.Host(route.proxyHost), port: NWEndpoint.Port(rawValue: route.proxyPort) ?? 1080, using: params)
            self.init(conn, framing: framing, queue: queue)
            socks = (host, port, route.proxyUser, route.proxyPassword)
        } else {
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 2242, using: params)
            self.init(conn, framing: framing, queue: queue)
        }
    }

    private var socks: (host: String, port: UInt16, user: String, password: String)?

    /// The socket keeps itself alive (through its handlers) until it closes,
    /// so a connection accepted or dialed before anyone owns it isn't dropped.
    func start() {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if self.socks != nil { self.socksHandshake() } else { self.onReady?() }
            case .failed(let e): self.close("\(e)")
            case .waiting(let e): self.close("\(e)")
            case .cancelled: self.close(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        if socks == nil { receive() }
    }

    // MARK: SOCKS5 (RFC 1928, RFC 1929)

    private func socksHandshake() {
        guard let target = socks else { return }
        let auth = !target.user.isEmpty
        connection.send(content: Data(auth ? [5, 2, 0, 2] : [5, 1, 0]), completion: .contentProcessed { _ in })
        read(2) { reply in
            guard reply.count == 2, reply[0] == 5 else { return self.close("Proxy did not answer as SOCKS5.") }
            switch reply[1] {
            case 0: self.socksConnect(target.host, target.port)
            case 2:
                var msg = Data([1, UInt8(min(target.user.utf8.count, 255))]) + Data(target.user.utf8.prefix(255))
                msg += Data([UInt8(min(target.password.utf8.count, 255))]) + Data(target.password.utf8.prefix(255))
                self.connection.send(content: msg, completion: .contentProcessed { _ in })
                self.read(2) { status in
                    guard status.count == 2, status[1] == 0 else { return self.close("Proxy rejected the username or password.") }
                    self.socksConnect(target.host, target.port)
                }
            default:
                self.close("Proxy requires an authentication method Raven does not support.")
            }
        }
    }

    private func socksConnect(_ host: String, _ port: UInt16) {
        var msg = Data([5, 1, 0])
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 && host.split(separator: ".").count == 4 {
            msg.append(1); msg.append(contentsOf: octets)
        } else {
            // A name: the proxy resolves it, so no DNS lookup leaves this Mac.
            let name = Data(host.utf8.prefix(255))
            msg.append(3); msg.append(UInt8(name.count)); msg.append(name)
        }
        msg.append(UInt8(port >> 8)); msg.append(UInt8(port & 0xFF))
        connection.send(content: msg, completion: .contentProcessed { _ in })
        read(4) { head in
            guard head.count == 4, head[0] == 5 else { return self.close("Proxy sent an invalid reply.") }
            guard head[1] == 0 else { return self.close(Self.socksError(head[1])) }
            let finish = { (n: Int) in
                self.read(n) { _ in
                    self.onReady?()
                    self.receive()
                }
            }
            switch head[3] {
            case 1: finish(4 + 2)
            case 4: finish(16 + 2)
            case 3: self.read(1) { len in finish(Int(len.first ?? 0) + 2) }
            default: self.close("Proxy sent an invalid address type.")
            }
        }
    }

    private func read(_ n: Int, _ then: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, error in
            guard !self.isClosed else { return }
            if let error { self.close("\(error)"); return }
            then(data ?? Data())
        }
    }

    private static func socksError(_ code: UInt8) -> String {
        switch code {
        case 2: return "Proxy rules do not allow this connection."
        case 3: return "Proxy reports the network is unreachable."
        case 4: return "Proxy reports the host is unreachable."
        case 5: return "Connection refused through the proxy."
        case 6: return "Proxy connection timed out."
        default: return "Proxy error \(code)."
        }
    }

    func send(_ data: Data, then: (() -> Void)? = nil) {
        guard !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.close("\(error)") } else { then?() }
        })
    }

    func close(_ reason: String? = nil) {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let handler = onClose
        onClose = nil
        handler?(reason)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { data, _, done, error in
            guard !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if done || error != nil { self.close(error.map { "\($0)" }) } else { self.receive() }
        }
    }

    private func drain() {
        while !isClosed {
            if framing == .raw {
                guard !buffer.isEmpty else { return }
                let chunk = buffer
                buffer = Data()
                onRaw?(chunk)
                return
            }
            guard buffer.count >= 4 else { return }
            let length = Int(buffer[buffer.startIndex]) | Int(buffer[buffer.startIndex + 1]) << 8
                | Int(buffer[buffer.startIndex + 2]) << 16 | Int(buffer[buffer.startIndex + 3]) << 24
            guard length >= 1, length < 64 << 20 else { close("bad frame length \(length)"); return }
            guard buffer.count >= 4 + length else {
                if framing == .peer, length > 64 << 10, buffer.count >= 8, let onPartial {
                    let s = buffer.startIndex
                    let code = UInt32(buffer[s + 4]) | UInt32(buffer[s + 5]) << 8 | UInt32(buffer[s + 6]) << 16 | UInt32(buffer[s + 7]) << 24
                    onPartial(code, buffer.count - 4, length)
                }
                return
            }
            let body = Data(buffer[(buffer.startIndex + 4)..<(buffer.startIndex + 4 + length)])
            buffer = Data(buffer[(buffer.startIndex + 4 + length)...])
            var r = SlskReader(body)
            do {
                if framing == .peerInit {
                    let code = try r.u8()
                    onInit?(code, &r)
                } else {
                    let code = try r.u32()
                    onMessage?(code, &r)
                }
            } catch {
                // A message we couldn't parse: skip it, keep the connection.
                continue
            }
        }
    }
}

// MARK: - Engine

final class SlskClient {
    struct Credentials: Sendable {
        var host = "server.slsknet.org"
        var port: UInt16 = 2242
        var username: String
        var password: String
        var listenPort: UInt16 = 2234
        /// Bind the listener to loopback only (tests).
        var loopbackOnly = false
        var route = SlskRoute()
    }

    enum Event {
        case loggedIn(greeting: String, seenAs: String?)
        case loginFailed(reason: String)
        case disconnected(reason: String?)
        case listening(port: UInt16?)
        case searchReply(SlskSearchReply)
        case download(SlskTransferUpdate)
        case upload(SlskTransferUpdate)
        case browse(user: String, folders: [SlskFolder]?)
        /// A user's file list arriving: bytes so far of the whole (compressed).
        case browseProgress(user: String, received: Int, total: Int)
        /// Another user asked for our share list or our user info.
        case sharesRequested(user: String)
        case infoRequested(user: String)
        case message(user: String, text: String, sent: Date)
        /// Open peer connections, reported when the number changes.
        case connections(Int)
        /// A line for the log: what the engine is doing with peers ("peer", "alice  connected directly").
        case trace(String, String)
    }

    var onEvent: (Event) -> Void = { _ in }
    let queue = DispatchQueue(label: "i2s.soulseek")

    private var credentials: Credentials?
    private var server: SlskSocket?
    private var listener: NWListener?
    private var loggedIn = false
    private var pingTimer: DispatchSourceTimer?
    private var nextTokenValue = UInt32.random(in: 1_000_000...900_000_000)

    private var peers: [String: PeerLink] = [:]

    /// Users whose file list we asked for and haven't received.

    private var browsePending: Set<String> = []
    /// Tokens we gave the server in ConnectToPeer, waiting for the peer to dial in.
    private var indirect: [UInt32: Indirect] = [:]
    private var addressWaiters: [String: [(String, UInt16) -> Void]] = [:]

    private var downloads: [UUID: DownloadJob] = [:]
    private var uploads: [UUID: UploadJob] = [:]
    private var shares = SlskShareIndex.empty
    var uploadSlots = 2

    private final class PeerLink {
        var socket: SlskSocket?
        var pending: [Data] = []
        var connecting = false
    }

    private enum Indirect {
        case peer(String)
        case uploadFile(UUID)
    }

    // MARK: Session

    func connect(_ credentials: Credentials) {
        queue.async { [self] in
            disconnectNow(reason: nil, notify: false)
            self.credentials = credentials
            if credentials.route.listens {
                startListener(port: credentials.listenPort, loopbackOnly: credentials.loopbackOnly, route: credentials.route)
            } else {
                emit(.listening(port: nil))
            }
            let socket = dial(credentials.host, credentials.port, framing: .server)
            socket.onReady = { [weak socket] in socket?.send(SlskOut.login(credentials.username, credentials.password)) }
            socket.onMessage = { [weak self] code, r in self?.serverMessage(code, &r) }
            socket.onClose = { [weak self] reason in
                guard let self else { return }
                let wasLoggedIn = self.loggedIn
                self.loggedIn = false
                self.server = nil
                self.emit(wasLoggedIn ? .disconnected(reason: reason) : .loginFailed(reason: reason.map { "Server unreachable (\($0))." } ?? "Server closed the connection."))
            }
            server = socket
            socket.start()
        }
    }

    func disconnect() { queue.async { [self] in disconnectNow(reason: nil, notify: true) } }

    private func disconnectNow(reason: String?, notify: Bool) {
        pingTimer?.cancel(); pingTimer = nil
        statsTimer?.cancel(); statsTimer = nil; reportedConnections = -1
        server?.onClose = nil
        server?.close()
        server = nil
        listener?.cancel(); listener = nil
        for link in peers.values { link.socket?.onClose = nil; link.socket?.close() }
        peers = [:]
        indirect = [:]
        addressWaiters = [:]
        let wasLoggedIn = loggedIn
        loggedIn = false
        if notify && wasLoggedIn { emit(.disconnected(reason: reason)) }
    }

    /// Every outbound connection goes through here, so it follows the route.
    private func dial(_ host: String, _ port: UInt16, framing: SlskSocket.Framing) -> SlskSocket {
        SlskSocket(host: host, port: port, framing: framing, queue: queue, route: credentials?.route ?? SlskRoute())
    }

    private func startListener(port: UInt16, loopbackOnly: Bool, route: SlskRoute) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        do {
            let l = loopbackOnly ? try NWListener(using: params) : try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.emit(.listening(port: l.port?.rawValue))
                    // Signed in before the listener was up: tell the server our port now.
                    if let self, self.loggedIn, let port = l.port?.rawValue { self.sendServer(SlskOut.setWaitPort(port)) }
                case .failed: self?.emit(.listening(port: nil))
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            emit(.listening(port: nil))
        }
    }

    private var me: String { credentials?.username ?? "" }

    private func token() -> UInt32 {
        nextTokenValue &+= 1
        return nextTokenValue
    }

    private func trace(_ topic: String, _ text: String) { emit(.trace(topic, text)) }

    private func emit(_ event: Event) {
        let handler = onEvent
        DispatchQueue.main.async { handler(event) }
    }

    private func sendServer(_ data: Data) { server?.send(data) }

    // MARK: Server messages

    private func serverMessage(_ code: UInt32, _ r: inout SlskReader) {
        guard let kind = SlskServerCode(rawValue: code) else { return }
        switch kind {
        case .login:
            guard let ok = try? r.bool() else { return }
            if ok {
                let greeting = (try? r.str()) ?? ""
                let seenAs = try? r.ip()
                loggedIn = true
                if listener != nil, let port = listener?.port?.rawValue ?? credentials?.listenPort { sendServer(SlskOut.setWaitPort(port)) }
                sendServer(SlskOut.setStatus(2))
                sendServer(SlskOut.sharedFoldersFiles(folders: shares.folders.count, files: shares.fileCount))
                sendServer(SlskOut.haveNoParent(true))
                sendServer(SlskOut.acceptChildren(false))
                startPing()
                startStats()
                emit(.loggedIn(greeting: greeting, seenAs: seenAs))
            } else {
                let reason = (try? r.str()) ?? "UNKNOWN"
                server?.onClose = nil
                server?.close()
                server = nil
                emit(.loginFailed(reason: reason))
            }
        case .getPeerAddress:
            guard let user = try? r.str(), let ip = try? r.ip(), let port = try? r.u32() else { return }
            let waiters = addressWaiters.removeValue(forKey: user) ?? []
            for w in waiters { w(ip, UInt16(truncatingIfNeeded: port)) }
        case .connectToPeer:
            guard let user = try? r.str(), let type = try? r.str(), let ip = try? r.ip(),
                  let port = try? r.u32(), let tok = try? r.u32() else { return }
            dialBack(user: user, type: type, ip: ip, port: UInt16(truncatingIfNeeded: port), token: tok)
        case .messageUser:
            guard let id = try? r.u32(), let time = try? r.u32(), let user = try? r.str(), let text = try? r.str() else { return }
            sendServer(SlskOut.messageAcked(id))
            emit(.message(user: user, text: text, sent: Date(timeIntervalSince1970: TimeInterval(time))))
        case .relogged:
            disconnectNow(reason: "Signed in from another client.", notify: true)
        case .cantConnectToPeer:
            guard let tok = try? r.u32() else { return }
            if case .peer(let user)? = indirect.removeValue(forKey: tok) { peerUnreachable(user) }
        default:
            break
        }
    }

    private var statsTimer: DispatchSourceTimer?
    private var reportedConnections = -1

    /// Reports the number of open peer connections every couple of seconds, when it changes.
    private func startStats() {
        statsTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let n = self.loggedIn ? self.peers.values.filter { $0.socket != nil }.count : 0
            if n != self.reportedConnections {
                self.reportedConnections = n
                self.emit(.connections(n))
            }
        }
        t.resume()
        statsTimer = t
    }

    private func startPing() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 300, repeating: 300)
        t.setEventHandler { [weak self] in self?.sendServer(SlskOut.serverPing()) }
        t.resume()
        pingTimer = t
    }

    // MARK: Peer connections

    /// Sends a peer message, opening the connection first if needed: a direct
    /// dial to the address the server gives, and at the same time a request
    /// through the server for the peer to dial us (for peers behind a router).
    private func sendPeer(_ user: String, _ data: Data) {
        let link = peers[user] ?? { let l = PeerLink(); peers[user] = l; return l }()
        if let s = link.socket, !s.isClosed {
            s.send(data)
            return
        }
        link.pending.append(data)
        guard !link.connecting else { return }
        link.connecting = true
        trace("peer", "\(user)  connecting  directly and through the server")

        let tok = token()
        indirect[tok] = .peer(user)
        sendServer(SlskOut.connectToPeer(token: tok, user: user, type: "P"))

        address(of: user) { [weak self] ip, port in
            guard let self else { return }
            if port == 0 { self.trace("peer", "\(user)  no address  the server knows no listening port") }
            else if self.peers[user]?.socket == nil { self.trace("peer", "\(user)  address  \(ip):\(port)") }
            guard port > 0, self.peers[user]?.socket == nil else { return }
            let s = self.dial(ip, port, framing: .peer)
            s.onReady = { [weak self, weak s] in
                guard let self, let s else { return }
                s.send(SlskOut.peerInit(user: self.me, type: "P"))
                self.trace("peer", "\(user)  connected directly  \(ip):\(port)")
                self.attachPeer(user, s)
            }
            s.start()
        }
        queue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, let link = self.peers[user], link.socket == nil, link.connecting else { return }
            self.indirect.removeValue(forKey: tok)
            self.peerUnreachable(user)
        }
    }

    private func address(of user: String, _ then: @escaping (String, UInt16) -> Void) {
        let first = addressWaiters[user] == nil
        addressWaiters[user, default: []].append(then)
        if first { sendServer(SlskOut.getPeerAddress(user)) }
    }

    private func attachPeer(_ user: String, _ s: SlskSocket) {
        let link = peers[user] ?? { let l = PeerLink(); peers[user] = l; return l }()
        if let existing = link.socket, existing !== s, !existing.isClosed {
            // Already connected another way; keep the first, but still read this one.
        } else {
            link.socket = s
        }
        link.connecting = false
        s.user = user
        s.framing = .peer
        s.onMessage = { [weak self] code, r in self?.peerMessage(user, code, &r) }
        var lastPartial: TimeInterval = 0
        s.onPartial = { [weak self] code, got, total in
            guard code == SlskPeerCode.sharedFileListResponse.rawValue else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPartial > 0.12 else { return }
            lastPartial = now
            self?.emit(.browseProgress(user: user, received: got, total: total))
        }
        s.onClose = { [weak self, weak link] reason in
            guard let self, let link, link.socket === s else { return }
            self.trace("peer", "\(user)  closed" + (reason.map { "  " + $0 } ?? ""))
            link.socket = nil
            if !link.pending.isEmpty { link.connecting = false }
        }
        if link.socket === s {
            let pending = link.pending
            link.pending = []
            pending.forEach { s.send($0) }
        }
    }

    private func peerUnreachable(_ user: String) {
        guard let link = peers[user], link.socket == nil else { return }
        trace("peer", "\(user)  unreachable")
        link.pending = []
        link.connecting = false
        if browsePending.remove(user) != nil { emit(.browse(user: user, folders: nil)) }
        for (id, job) in downloads where job.user == user && job.state.isWaitingOnPeer {
            job.state = .failed("Could not connect to \(user). The user is offline or unreachable.")
            report(id, job)
        }
    }

    /// The listener: peers dialing in, directly or answering our ConnectToPeer.
    private func accept(_ connection: NWConnection) {
        let s = SlskSocket(connection, framing: .peerInit, queue: queue)
        s.onInit = { [weak self, weak s] code, r in
            guard let self, let s else { return }
            switch SlskInitCode(rawValue: code) {
            case .peerInit:
                guard let user = try? r.str(), let type = try? r.str() else { s.close(); return }
                switch type {
                case "P": self.trace("peer", "\(user)  connected to us"); self.attachPeer(user, s)
                case "F": self.trace("transfer", "\(user)  file connection in"); self.startDownloadSocket(user: user, s)
                default: s.close()
                }
            case .pierceFirewall:
                guard let tok = try? r.u32(), let pending = self.indirect.removeValue(forKey: tok) else { s.close(); return }
                switch pending {
                case .peer(let user): self.trace("peer", "\(user)  connected through server request"); self.attachPeer(user, s)
                case .uploadFile(let id): self.startUploadSocket(id, s)
                }
            case nil:
                s.close()
            }
        }
        s.start()
    }

    /// The server passing on a peer's request that we dial them.
    private func dialBack(user: String, type: String, ip: String, port: UInt16, token tok: UInt32) {
        let s = dial(ip, port, framing: type == "F" ? .raw : .peer)
        s.onReady = { [weak self, weak s] in
            guard let self, let s else { return }
            s.send(SlskOut.pierceFirewall(token: tok))
            switch type {
            case "P": self.trace("peer", "\(user)  reached at their request  \(ip):\(port)"); self.attachPeer(user, s)
            case "F": self.startDownloadSocket(user: user, s)
            default: s.close()
            }
        }
        s.onClose = { [weak self] _ in
            self?.sendServer(SlskOut.cantConnectToPeer(token: tok, user: user))
        }
        s.start()
    }

    // MARK: Peer messages

    private func peerMessage(_ user: String, _ code: UInt32, _ r: inout SlskReader) {
        guard let kind = SlskPeerCode(rawValue: code) else { return }
        switch kind {
        case .fileSearchResponse:
            if let reply = try? SlskSearchReply.decode(r.rest()) { emit(.searchReply(reply)) }
        case .sharedFileListRequest:
            sendPeer(user, SlskOut.sharedFileListResponse(shares.compressedList))
            emit(.sharesRequested(user: user))
        case .sharedFileListResponse:
            let body = r.rest()
            browsePending.remove(user)
            trace("peer", "\(user)  file list received  \(ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .file))")
            emit(.browse(user: user, folders: try? SlskShareList.decode(body)))
        case .userInfoRequest:
            emit(.infoRequested(user: user))
            let queued = uploads.values.filter { $0.state == .queued }.count
            sendPeer(user, SlskOut.userInfoResponse(description: "", uploadSlots: uploadSlots, queue: queued,
                                                    freeSlot: activeUploads < uploadSlots))
        case .transferRequest:
            guard let dir = try? r.u32(), let tok = try? r.u32(), let path = try? r.str() else { return }
            let size = dir == SlskDirection.upload.rawValue ? (try? r.u64()) : nil
            peerOffersUpload(user, token: tok, path: path, size: size)
        case .transferResponse:
            guard let tok = try? r.u32(), let allowed = try? r.bool() else { return }
            let reason = allowed ? nil : (try? r.str())
            uploadAnswered(token: tok, allowed: allowed, reason: reason)
        case .queueUpload:
            guard let path = try? r.str() else { return }
            trace("upload", "\(user)  asked for  \(path)")
            queueUpload(for: user, path: path)
        case .placeInQueueRequest:
            guard let path = try? r.str() else { return }
            let place = uploadQueuePlace(user: user, path: path)
            sendPeer(user, SlskOut.placeInQueueResponse(path, place: place))
        case .placeInQueueResponse:
            guard let path = try? r.str(), let place = try? r.u32() else { return }
            if let (id, job) = download(user: user, path: path) {
                job.state = .remoteQueued(place: Int(place))
                report(id, job)
            }
        case .uploadDenied:
            guard let path = try? r.str() else { return }
            let reason = (try? r.str()) ?? ""
            trace("transfer", "\(user)  denied  \(reason.isEmpty ? "no reason" : reason)")
            if let (id, job) = download(user: user, path: path) {
                job.state = .failed(SlskReasons.plain(reason))
                job.denial = reason
                report(id, job)
            }
        case .uploadFailed:
            guard let path = try? r.str() else { return }
            if let (id, job) = download(user: user, path: path) {
                job.state = .failed("Upload failed on the remote side.")
                report(id, job)
            }
        default:
            break
        }
    }

    // MARK: Search and browse

    func search(_ query: String, token tok: UInt32) {
        queue.async { [self] in sendServer(SlskOut.fileSearch(token: tok, query: query)) }
    }

    /// Searches one user's shares; the server forwards the query to them.
    func search(_ query: String, user: String, token tok: UInt32) {
        queue.async { [self] in sendServer(SlskOut.userSearch(user: user, token: tok, query: query)) }
    }

    func browse(_ user: String) {
        queue.async { [self] in
            trace("peer", "\(user)  file list requested")
            browsePending.insert(user)
            sendPeer(user, SlskOut.sharedFileListRequest())
        }
    }

    // MARK: Private messages

    func message(_ user: String, _ text: String) {
        queue.async { [self] in sendServer(SlskOut.messageUser(user, text)) }
    }

    // MARK: Downloads

    private final class DownloadJob {
        let user: String
        let path: String
        var size: UInt64
        let destination: URL
        var token: UInt32?
        var received: UInt64 = 0
        var state: SlskTransferState = .queued
        var denial: String?
        var handle: FileHandle?
        var socket: SlskSocket?
        var lastReport = Date.distantPast

        init(user: String, path: String, size: UInt64, destination: URL) {
            self.user = user; self.path = path; self.size = size; self.destination = destination
        }
    }

    func download(id: UUID, user: String, path: String, size: UInt64, to destination: URL) {
        queue.async { [self] in
            let job = DownloadJob(user: user, path: path, size: size, destination: destination)
            let partial = Self.partialURL(destination)
            job.received = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? UInt64) ?? 0
            job.state = .requesting
            downloads[id] = job
            report(id, job)
            sendPeer(user, SlskOut.queueUpload(path))
            // Ask where we stand once they've had a moment to queue us.
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, let job = self.downloads[id], job.state.isWaitingOnPeer else { return }
                self.sendPeer(user, SlskOut.placeInQueueRequest(path))
            }
        }
    }

    func cancelDownload(_ id: UUID) {
        queue.async { [self] in
            guard let job = downloads.removeValue(forKey: id) else { return }
            job.socket?.close()
            try? job.handle?.close()
        }
    }

    private func download(user: String, path: String) -> (UUID, DownloadJob)? {
        downloads.first { $0.value.user == user && $0.value.path == path && !$0.value.state.isFinished }.map { ($0.key, $0.value) }
    }

    /// The uploader is ready for us: say yes, then wait for its file connection.
    private func peerOffersUpload(_ user: String, token tok: UInt32, path: String, size: UInt64?) {
        guard let (id, job) = download(user: user, path: path) else {
            sendPeer(user, SlskOut.transferResponse(token: tok, allowed: false, reason: "Cancelled"))
            return
        }
        job.token = tok
        if let size { job.size = size }
        job.state = .connecting
        report(id, job)
        sendPeer(user, SlskOut.transferResponse(token: tok, allowed: true))
    }

    /// A file connection from an uploader: their token, our offset, then the bytes.
    private func startDownloadSocket(user: String, _ s: SlskSocket) {
        s.framing = .raw
        var header = Data()
        var jobID: UUID?
        s.onRaw = { [weak self, weak s] chunk in
            guard let self, let s else { return }
            var data = chunk
            if jobID == nil {
                header.append(data)
                guard header.count >= 4 else { return }
                var r = SlskReader(header.prefix(4))
                let tok = (try? r.u32()) ?? 0
                data = Data(header.dropFirst(4))
                guard let (id, job) = self.downloads.first(where: { $0.value.token == tok }).map({ ($0.key, $0.value) }) else {
                    s.close(); return
                }
                jobID = id
                job.socket = s
                self.openPartial(job)
                var w = SlskWriter()
                w.u64(job.received)
                s.send(w.data)
                job.state = .downloading
                self.report(id, job, force: true)
            }
            guard let id = jobID, let job = self.downloads[id] else { s.close(); return }
            if !data.isEmpty {
                job.handle?.write(data)
                job.received += UInt64(data.count)
                self.report(id, job)
            }
            if job.received >= job.size { self.finish(id, job) }
        }
        s.onClose = { [weak self] reason in
            guard let self, let id = jobID, let job = self.downloads[id], !job.state.isFinished else { return }
            try? job.handle?.close()
            job.handle = nil
            job.state = .failed("Connection lost at \(Self.percent(job))%. Retry to resume.")
            self.report(id, job, force: true)
        }
    }

    private func openPartial(_ job: DownloadJob) {
        let partial = Self.partialURL(job.destination)
        try? FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            job.received = 0
        }
        job.handle = try? FileHandle(forWritingTo: partial)
        if let h = job.handle {
            if job.received > 0 { _ = try? h.seek(toOffset: job.received) } else { try? h.truncate(atOffset: 0) }
        }
    }

    private func finish(_ id: UUID, _ job: DownloadJob) {
        try? job.handle?.close()
        job.handle = nil
        job.socket?.onClose = nil
        job.socket?.close()
        var target = job.destination
        if FileManager.default.fileExists(atPath: target.path) { target = Self.uniqueURL(target) }
        do {
            try FileManager.default.moveItem(at: Self.partialURL(job.destination), to: target)
            job.state = .done(target)
        } catch {
            job.state = .failed("Could not save the file: \(error.localizedDescription)")
        }
        report(id, job, force: true)
    }

    private func report(_ id: UUID, _ job: DownloadJob, force: Bool = false) {
        let now = Date()
        // Progress at most ~8 times a second; state changes always.
        if !force, case .downloading = job.state, now.timeIntervalSince(job.lastReport) < 0.12 { return }
        job.lastReport = now
        emit(.download(SlskTransferUpdate(id: id, state: job.state, bytes: job.received, size: job.size, denial: job.denial)))
    }

    static func partialURL(_ destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent("." + destination.lastPathComponent + ".part")
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for n in 2...999 {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    private static func percent(_ job: DownloadJob) -> Int {
        job.size == 0 ? 0 : Int(Double(job.received) / Double(job.size) * 100)
    }

    // MARK: Uploads

    private final class UploadJob {
        let user: String
        let path: String
        let url: URL
        let size: UInt64
        var token: UInt32?
        var sent: UInt64 = 0
        var state: SlskUploadPhase = .queued
        var socket: SlskSocket?
        var lastReport = Date.distantPast

        init(user: String, path: String, url: URL, size: UInt64) {
            self.user = user; self.path = path; self.url = url; self.size = size
        }
    }

    enum SlskUploadPhase { case queued, offered, sending, done, failed }

    func setShares(_ index: SlskShareIndex) {
        queue.async { [self] in
            shares = index
            if loggedIn { sendServer(SlskOut.sharedFoldersFiles(folders: index.folders.count, files: index.fileCount)) }
        }
    }

    func setUploadSlots(_ n: Int) { queue.async { [self] in uploadSlots = max(1, n); pumpUploads() } }

    private var activeUploads: Int { uploads.values.filter { $0.state == .offered || $0.state == .sending }.count }

    private func queueUpload(for user: String, path: String) {
        guard let file = shares.lookup(path) else {
            sendPeer(user, SlskOut.uploadDenied(path, reason: "File not shared."))
            return
        }
        if uploads.values.contains(where: { $0.user == user && $0.path == path && ($0.state == .queued || $0.state == .offered || $0.state == .sending) }) { return }
        let id = UUID()
        uploads[id] = UploadJob(user: user, path: path, url: file.url, size: file.size)
        reportUpload(id, uploads[id]!, force: true)
        pumpUploads()
    }

    private func uploadQueuePlace(user: String, path: String) -> Int {
        let queued = uploads.values.filter { $0.state == .queued }
        return (queued.firstIndex { $0.user == user && $0.path == path } ?? 0) + 1
    }

    private func pumpUploads() {
        while activeUploads < uploadSlots, let (id, job) = uploads.first(where: { $0.value.state == .queued }).map({ ($0.key, $0.value) }) {
            let tok = token()
            job.token = tok
            job.state = .offered
            reportUpload(id, job, force: true)
            sendPeer(job.user, SlskOut.transferRequest(upload: tok, path: job.path, size: job.size))
            queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, let job = self.uploads[id], job.state == .offered else { return }
                job.state = .failed
                self.reportUpload(id, job, force: true)
                self.pumpUploads()
            }
        }
    }

    private func uploadAnswered(token tok: UInt32, allowed: Bool, reason: String?) {
        guard let (id, job) = uploads.first(where: { $0.value.token == tok }).map({ ($0.key, $0.value) }) else { return }
        guard allowed else {
            uploads.removeValue(forKey: id)
            emit(.upload(SlskTransferUpdate(id: id, state: .failed(reason ?? "Declined"), bytes: 0, size: job.size, denial: nil)))
            pumpUploads()
            return
        }
        // Dial them for the file connection; if that fails, ask them to dial us.
        address(of: job.user) { [weak self] ip, port in
            guard let self else { return }
            let s = self.dial(ip, port, framing: .raw)
            s.onReady = { [weak self, weak s] in
                guard let self, let s else { return }
                s.send(SlskOut.peerInit(user: self.me, type: "F"))
                self.startUploadSocket(id, s)
            }
            s.onClose = { [weak self] _ in
                guard let self, let job = self.uploads[id], job.socket == nil else { return }
                let t2 = self.token()
                self.indirect[t2] = .uploadFile(id)
                self.sendServer(SlskOut.connectToPeer(token: t2, user: job.user, type: "F"))
            }
            if port > 0 { s.start() } else { s.close() }
        }
    }

    /// Our side of a file connection: send the token, read their offset, stream.
    private func startUploadSocket(_ id: UUID, _ s: SlskSocket) {
        guard let job = uploads[id], let tok = job.token else { s.close(); return }
        job.socket = s
        s.framing = .raw
        var w = SlskWriter()
        w.u32(tok)
        s.send(w.data)
        var header = Data()
        s.onRaw = { [weak self, weak s] chunk in
            guard let self, let s, job.state == .offered else { return }
            header.append(chunk)
            guard header.count >= 8 else { return }
            var r = SlskReader(header.prefix(8))
            let offset = (try? r.u64()) ?? 0
            job.sent = min(offset, job.size)
            job.state = .sending
            self.reportUpload(id, job, force: true)
            self.stream(id, job, s)
        }
        s.onClose = { [weak self] _ in
            guard let self, job.state != .done else { return }
            job.state = .failed
            self.reportUpload(id, job, force: true)
            self.pumpUploads()
        }
    }

    private func stream(_ id: UUID, _ job: UploadJob, _ s: SlskSocket) {
        guard let handle = try? FileHandle(forReadingFrom: job.url) else {
            sendPeer(job.user, SlskOut.uploadFailed(job.path)); s.close(); return
        }
        _ = try? handle.seek(toOffset: job.sent)
        func next() {
            guard !s.isClosed else { try? handle.close(); return }
            let chunk = handle.readData(ofLength: 128 << 10)
            if chunk.isEmpty {
                try? handle.close()
                job.state = .done
                reportUpload(id, job, force: true)
                // Let the peer close once it has everything.
                queue.asyncAfter(deadline: .now() + 2) { s.onClose = nil; s.close() }
                pumpUploads()
                return
            }
            s.send(chunk) {
                job.sent += UInt64(chunk.count)
                self.reportUpload(id, job)
                next()
            }
        }
        next()
    }

    private func reportUpload(_ id: UUID, _ job: UploadJob, force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(job.lastReport) < 0.25 { return }
        job.lastReport = now
        let state: SlskTransferState
        switch job.state {
        case .queued: state = .queued
        case .offered: state = .connecting
        case .sending: state = .downloading
        case .done: state = .done(job.url)
        case .failed: state = .failed("Stopped")
        }
        emit(.upload(SlskTransferUpdate(id: id, state: state, bytes: job.sent, size: job.size, denial: nil,
                                        user: job.user, path: job.path)))
    }
}

// MARK: - Shared types

enum SlskTransferState: Equatable, Sendable {
    case queued
    case requesting
    case remoteQueued(place: Int)
    case connecting
    case downloading
    case done(URL)
    case failed(String)

    var isFinished: Bool {
        switch self { case .done, .failed: return true; default: return false }
    }
    var isWaitingOnPeer: Bool {
        switch self { case .requesting, .remoteQueued, .queued: return true; default: return false }
    }
}

struct SlskTransferUpdate: Sendable {
    var id: UUID
    var state: SlskTransferState
    var bytes: UInt64
    var size: UInt64
    var denial: String?
    var user: String? = nil
    var path: String? = nil
}

/// What we share: the folders, each file's real location, and the compressed
/// list peers ask for. Built off the main thread; immutable once made.
final class SlskShareIndex: @unchecked Sendable {
    static let empty = SlskShareIndex(folders: [], locations: [:])

    let folders: [SlskFolder]
    let fileCount: Int
    private let locations: [String: (url: URL, size: UInt64)]
    private(set) lazy var compressedList: Data = SlskShareList.encode(folders)

    init(folders: [SlskFolder], locations: [String: (url: URL, size: UInt64)]) {
        self.folders = folders
        self.locations = locations
        fileCount = folders.reduce(0) { $0 + $1.files.count }
    }

    func lookup(_ path: String) -> (url: URL, size: UInt64)? { locations[path] }

    /// Walks `roots` for audio and other files; virtual paths start at each root's name.
    static func build(_ roots: [URL]) -> SlskShareIndex {
        var folders: [String: [SlskFile]] = [:]
        var locations: [String: (URL, UInt64)] = [:]
        let fm = FileManager.default
        for root in roots.map({ $0.resolvingSymlinksInPath() }) {
            let rootName = root.lastPathComponent
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let found as URL in walker {
                let url = found.resolvingSymlinksInPath()
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                let relative = url.path.dropFirst(root.path.count).split(separator: "/").map(String.init)
                let virtual = ([rootName] + relative).joined(separator: "\\")
                let folder = ([rootName] + relative.dropLast()).joined(separator: "\\")
                let size = UInt64(values.fileSize ?? 0)
                folders[folder, default: []].append(SlskFile(path: virtual, size: size, ext: url.pathExtension.lowercased()))
                locations[virtual] = (url, size)
            }
        }
        let list = folders.keys.sorted().map { SlskFolder(path: $0, files: folders[$0]!.sorted { $0.path < $1.path }) }
        return SlskShareIndex(folders: list, locations: locations)
    }
}

/// Peers' refusal reasons, in plain words.
enum SlskReasons {
    static let requiresSharing = "Declined: this user only uploads to peers who share files."

    static func plain(_ reason: String) -> String {
        let r = reason.lowercased()
        if r.contains("banned") { return "Declined: you are banned by this user." }
        if r.contains("not shared") { return "Declined: the file is no longer shared." }
        if r.contains("too many files") || r.contains("too many megabytes") { return "Declined: per-user queue limit reached." }
        if r.contains("share") || r.contains("leech") { return SlskReasons.requiresSharing }
        if r.contains("pending shutdown") { return "Declined: the user is going offline." }
        if r.contains("file read error") { return "Remote file read error." }
        if r.contains("queued") { return "Queued by the remote user." }
        return reason.isEmpty ? "Declined by the remote user." : "Declined: \(reason)"
    }
}

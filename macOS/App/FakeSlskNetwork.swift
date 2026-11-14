#if DEBUG
import Foundation
import Network

/// A tiny Soulseek server and one peer ("alice"), on loopback only, for the
/// self-test: sign-in (and a taken name), search, a download from alice, and
/// alice browsing our shares. Speaks the same wire format as the real network.
final class FakeSlskNetwork {
    let queue = DispatchQueue(label: "i2s.fake-soulseek")
    private var serverListener: NWListener?
    private var peerListener: NWListener?
    private(set) var serverPort: UInt16 = 0
    private(set) var peerPort: UInt16 = 0
    private var clients: [String: SlskSocket] = [:]
    private var waitPorts: [String: UInt16] = [:]
    private var keep: [SlskSocket] = []

    let aliceFile: SlskFile
    let aliceBytes: Data
    /// Filled when alice browses the client's shares.
    private(set) var browsedFolders: [SlskFolder]?

    init() {
        var bytes = Data(count: 300_000)
        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        aliceBytes = bytes
        aliceFile = SlskFile(path: "Music\\Test Album\\01 Test Song.flac", size: UInt64(bytes.count), ext: "flac",
                             duration: 200, sampleRate: 44_100, bitDepth: 16)
    }

    func start() async -> Bool {
        await withCheckedContinuation { c in
            queue.async { [self] in
                var pending = 2
                func done() { pending -= 1; if pending == 0 { c.resume(returning: serverPort > 0 && peerPort > 0) } }
                serverListener = listen { [weak self] s in self?.acceptServer(s) } ready: { [weak self] p in self?.serverPort = p; done() }
                peerListener = listen { [weak self] s in self?.acceptPeer(s) } ready: { [weak self] p in self?.peerPort = p; done() }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            serverListener?.cancel(); peerListener?.cancel()
            (Array(clients.values) + keep).forEach { $0.close() }
        }
    }

    private func listen(_ accept: @escaping (NWConnection) -> Void, ready: @escaping (UInt16) -> Void) -> NWListener? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { ready(0); return nil }
        l.newConnectionHandler = accept
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready(l.port?.rawValue ?? 0)
            case .failed: ready(0)
            default: break
            }
        }
        l.start(queue: queue)
        return l
    }

    // MARK: Server

    private func acceptServer(_ conn: NWConnection) {
        let s = SlskSocket(conn, framing: .server, queue: queue)
        s.onMessage = { [weak self, weak s] code, r in
            guard let self, let s else { return }
            self.serverMessage(s, code, &r)
        }
        keep.append(s)
        s.start()
    }

    /// Private message ids the client acknowledged.
    private(set) var acked: [UInt32] = []
    /// Private messages the client sent: (to, text).
    private(set) var delivered: [(String, String)] = []

    private func serverMessage(_ s: SlskSocket, _ code: UInt32, _ r: inout SlskReader) {
        switch SlskServerCode(rawValue: code) {
        case .login?:
            guard let user = try? r.str(), let password = try? r.str() else { return }
            if user == "taken" && password != "right" {
                s.send(SlskWriter.frame(code: 1) { w in w.bool(false); w.str("INVALIDPASS") })
                return
            }
            s.user = user
            clients[user] = s
            s.send(SlskWriter.frame(code: 1) { w in
                w.bool(true); w.str("Welcome to the test server"); w.u32(0x7F00_0001); w.str(""); w.bool(false)
            })
        case .setWaitPort?:
            if let p = try? r.u32() { waitPorts[s.user] = UInt16(truncatingIfNeeded: p) }
        case .getPeerAddress?:
            guard let user = try? r.str() else { return }
            let port = user == "alice" ? peerPort : (waitPorts[user] ?? 0)
            s.send(SlskWriter.frame(code: 3) { w in w.str(user); w.u32(0x7F00_0001); w.u32(UInt32(port)) })
        case .fileSearch?:
            guard let tok = try? r.u32(), let query = try? r.str() else { return }
            aliceAnswers(search: query, token: tok, from: s.user)
        case .userSearch?:
            // Forwarded only to the named user; alice is the only one here.
            guard let target = try? r.str(), let tok = try? r.u32(), let query = try? r.str(), target == "alice" else { return }
            aliceAnswers(search: query, token: tok, from: s.user)
            // A private message from alice, as the server relays it.
            s.send(SlskWriter.frame(code: SlskServerCode.messageUser.rawValue) { w in
                w.u32(41); w.u32(UInt32(Date().timeIntervalSince1970)); w.str("alice"); w.str("hello from alice"); w.bool(true)
            })
        case .messageAcked?:
            if let id = try? r.u32() { acked.append(id) }
        case .messageUser?:
            // From a client: str user, str text. Alice answers.
            guard let target = try? r.str(), let text = try? r.str() else { return }
            delivered.append((target, text))
            guard target == "alice" else { return }
            s.send(SlskWriter.frame(code: SlskServerCode.messageUser.rawValue) { w in
                w.u32(42); w.u32(UInt32(Date().timeIntervalSince1970)); w.str("alice"); w.str("got: " + text); w.bool(true)
            })
        default:
            break
        }
    }

    // MARK: Alice

    /// Alice dials the searcher and sends one result, as a real peer would.
    private func aliceAnswers(search query: String, token tok: UInt32, from user: String) {
        guard query.lowercased().contains("test"), let port = waitPorts[user] else { return }
        let s = SlskSocket(host: "127.0.0.1", port: port, framing: .peer, queue: queue)
        let file = aliceFile
        s.onReady = { [weak s] in
            s?.send(SlskOut.peerInit(user: "alice", type: "P"))
            let reply = SlskSearchReply(username: "alice", token: tok, files: [file], freeSlot: true, speed: 900_000, queue: 0)
            s?.send(SlskOut.searchReply(reply.encode()))
            s?.send(SlskOut.sharedFileListRequest())
        }
        s.user = user
        // Like a real peer, alice takes any message on any connection with this user.
        s.onMessage = { [weak self, weak s] code, r in
            guard let self, let s else { return }
            if code == SlskPeerCode.sharedFileListResponse.rawValue {
                self.browsedFolders = try? SlskShareList.decode(r.rest())
            } else {
                self.aliceMessage(s, code, &r)
            }
        }
        keep.append(s)
        s.start()
    }

    private func acceptPeer(_ conn: NWConnection) {
        let s = SlskSocket(conn, framing: .peerInit, queue: queue)
        s.onInit = { [weak self, weak s] code, r in
            guard let self, let s, code == SlskInitCode.peerInit.rawValue, let user = try? r.str() else { return }
            s.user = user
            s.framing = .peer
            s.onMessage = { [weak self, weak s] code, r in
                guard let self, let s else { return }
                self.aliceMessage(s, code, &r)
            }
        }
        keep.append(s)
        s.start()
    }

    private var offered: [UInt32: String] = [:]

    private func aliceMessage(_ s: SlskSocket, _ code: UInt32, _ r: inout SlskReader) {
        switch SlskPeerCode(rawValue: code) {
        case .queueUpload?:
            guard let path = try? r.str() else { return }
            guard path == aliceFile.path else { s.send(SlskOut.uploadDenied(path, reason: "File not shared.")); return }
            let tok = UInt32.random(in: 1...1_000_000)
            offered[tok] = s.user
            s.send(SlskOut.transferRequest(upload: tok, path: path, size: aliceFile.size))
        case .transferResponse?:
            guard let tok = try? r.u32(), let ok = try? r.bool(), ok, let user = offered[tok], let port = waitPorts[user] else { return }
            sendFile(token: tok, toPort: port)
        default:
            break
        }
    }

    private func sendFile(token tok: UInt32, toPort port: UInt16) {
        let s = SlskSocket(host: "127.0.0.1", port: port, framing: .raw, queue: queue)
        let bytes = aliceBytes
        var header = Data()
        s.onReady = { [weak s] in
            s?.send(SlskOut.peerInit(user: "alice", type: "F"))
            var w = SlskWriter(); w.u32(tok)
            s?.send(w.data)
        }
        s.onRaw = { [weak s] chunk in
            guard let s else { return }
            header.append(chunk)
            guard header.count >= 8 else { return }
            var r = SlskReader(header.prefix(8))
            let offset = Int((try? r.u64()) ?? 0)
            header = Data(count: 0)
            s.onRaw = nil
            s.send(bytes.subdata(in: offset..<bytes.count))
        }
        keep.append(s)
        s.start()
    }
}
/// A minimal SOCKS5 proxy on loopback (no auth, or username/password), relaying
/// bytes both ways. Records which targets it was asked for.
final class FakeSocks5 {
    let queue = DispatchQueue(label: "i2s.fake-socks")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private(set) var targets: [String] = []
    var requireAuth: (user: String, password: String)?
    private var keep: [NWConnection] = []

    func start() async -> Bool {
        await withCheckedContinuation { c in
            queue.async { [self] in
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                guard let l = try? NWListener(using: params) else { c.resume(returning: false); return }
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.stateUpdateHandler = { state in
                    if case .ready = state { self.port = l.port?.rawValue ?? 0; c.resume(returning: true) }
                    if case .failed = state { c.resume(returning: false) }
                }
                l.start(queue: queue)
                listener = l
            }
        }
    }

    func stop() { queue.async { [self] in listener?.cancel(); keep.forEach { $0.cancel() } } }

    private func read(_ c: NWConnection, _ n: Int, _ then: @escaping (Data) -> Void) {
        c.receive(minimumIncompleteLength: n, maximumLength: n) { d, _, _, _ in then(d ?? Data()) }
    }

    private func accept(_ client: NWConnection) {
        keep.append(client)
        client.start(queue: queue)
        read(client, 2) { head in
            let n = Int(head.count == 2 ? head[1] : 0)
            self.read(client, n) { methods in
                if let auth = self.requireAuth {
                    guard methods.contains(2) else { client.send(content: Data([5, 0xFF]), completion: .idempotent); return }
                    client.send(content: Data([5, 2]), completion: .idempotent)
                    self.read(client, 2) { h in
                        self.read(client, Int(h.count == 2 ? h[1] : 0)) { user in
                            self.read(client, 1) { pl in
                                self.read(client, Int(pl.first ?? 0)) { pass in
                                    let ok = String(decoding: user, as: UTF8.self) == auth.user && String(decoding: pass, as: UTF8.self) == auth.password
                                    client.send(content: Data([1, ok ? 0 : 1]), completion: .idempotent)
                                    if ok { self.request(client) }
                                }
                            }
                        }
                    }
                } else {
                    client.send(content: Data([5, 0]), completion: .idempotent)
                    self.request(client)
                }
            }
        }
    }

    private func request(_ client: NWConnection) {
        read(client, 4) { head in
            guard head.count == 4 else { return }
            let resolve = { (host: String) in
                self.read(client, 2) { p in
                    let port = UInt16(p[p.startIndex]) << 8 | UInt16(p[p.startIndex + 1])
                    self.targets.append("\(host):\(port)")
                    self.relay(client, host: host, port: port)
                }
            }
            switch head[3] {
            case 1: self.read(client, 4) { a in resolve(a.map(String.init).joined(separator: ".")) }
            case 3: self.read(client, 1) { l in self.read(client, Int(l.first ?? 0)) { n in resolve(String(decoding: n, as: UTF8.self)) } }
            default: client.cancel()
            }
        }
    }

    private func relay(_ client: NWConnection, host: String, port: UInt16) {
        let upstream = NWConnection(host: NWEndpoint.Host(host == "localhost" ? "127.0.0.1" : host),
                                    port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        keep.append(upstream)
        upstream.stateUpdateHandler = { state in
            if case .ready = state {
                client.send(content: Data([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]), completion: .idempotent)
                self.pipe(client, upstream)
                self.pipe(upstream, client)
            }
            if case .failed = state { client.send(content: Data([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .idempotent) }
        }
        upstream.start(queue: queue)
    }

    private func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { d, _, done, err in
            if let d, !d.isEmpty { to.send(content: d, completion: .idempotent) }
            if done || err != nil { to.cancel(); return }
            self.pipe(from, to)
        }
    }
}
#endif

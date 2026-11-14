import Foundation
import AppKit
import Network
import Security

// Soulseek in the app: settings, the account, searches, transfers, and what
// is shared. Off until the user turns it on and finishes setup; nothing here
// touches the network before that.

struct SoulseekSettings: LenientDecodable, Equatable {
    var enabled = false
    var setupComplete = false
    var username = ""
    var downloadFolder = SoulseekSettings.defaultDownloadFolder
    var shareDownloads = true
    var shareLibrary = false
    var extraShares: [String] = []
    var listenPort = 2234
    var uploadSlots = 2
    var maxActiveDownloads = 4
    /// Downloads keep the uploader's folder name ("Artist - Album").
    var keepFolders = true
    var connectOnLaunch = true

    // Network (configured before the account, so nothing connects unprotected)
    var routeMode: SlskRoute.Mode = .direct
    var proxyHost = ""
    var proxyPort = 1080
    var proxyUser = ""
    /// Resolvers typed by the user, as dotted IPv4. Empty: the system resolver.
    var dnsPreferred = ""
    var dnsAlternate = ""
    var acceptIncoming = true
    /// Raven Tunnel: what the imported WireGuard config points at (the config itself is in the Keychain).
    var tunnelEndpoint = ""
    var tunnelAddress = ""
    var serverHost = "server.slsknet.org"
    var serverPort = 2242

    // Search
    var keepSearchHistory = true
    /// Recent queries, newest first.
    var searchHistory: [String] = []
    /// Users whose results are never shown.
    var hiddenUsers: [String] = []
    /// Users pinned to the top of results and listed in the rail.
    var starredUsers: [String] = []

    // Messages
    /// The notice on the Messages page was read and accepted.
    var messagesAcknowledged = false
    /// Users whose private messages are dropped on this Mac.
    var ignoredUsers: [String] = []

    var dnsServers: [String] { [dnsPreferred, dnsAlternate].filter(SlskRoute.isIPv4) }

    static var defaultDownloadFolder: String {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("i2s Downloads", isDirectory: true).path
    }

    var sharesNothing: Bool { !shareDownloads && !shareLibrary && extraShares.isEmpty }
}

@MainActor
final class SoulseekStore: ObservableObject {
    enum Status: Equatable {
        case off
        case connecting
        case online
        case offline(String)

        var label: String {
            switch self {
            case .off: return "off"
            case .connecting: return "connecting"
            case .online: return "online"
            case .offline: return "offline"
            }
        }
    }

    struct SearchGroup: Identifiable {
        let id: String
        let user: String
        let folder: String
        /// Setting the files works out the summary again.
        var files: [SlskFile] { didSet { summary = Summary(files) } }
        var freeSlot: Bool
        var speed: Int
        var queue: Int
        let folderName: String
        let parentPath: String
        /// The folder path, lowercased, for filters.
        let lowerFolder: String
        /// The last year (1900–2099) written in the folder's path.
        let year: Int?
        /// Everything the result list and its filters ask about the files,
        /// worked out once instead of on every draw and every sort comparison.
        private(set) var summary: Summary

        init(user: String, folder: String, files: [SlskFile], freeSlot: Bool, speed: Int, queue: Int) {
            self.id = user + "|" + folder
            self.user = user
            self.folder = folder
            self.files = files
            self.freeSlot = freeSlot
            self.speed = speed
            self.queue = queue
            let parts = folder.split(separator: "\\")
            folderName = parts.last.map(String.init) ?? folder
            parentPath = parts.dropLast().last.map(String.init) ?? ""
            lowerFolder = folder.lowercased()
            year = Self.year(in: folder)
            summary = Summary(files)
        }

        struct Summary {
            /// Music formats, most common first.
            var kinds: [String] = []
            var audioCount = 0
            var hasAudio: Bool { audioCount > 0 }
            var hasCover = false
            var hasLyrics = false
            var qualityScore = 0
            var qualityLabel = ""
            var duration = 0
            var size: UInt64 = 0

            init(_ files: [SlskFile]) {
                var counts: [String: Int] = [:], order: [String] = []
                for f in files {
                    size += f.size
                    duration += f.duration ?? 0
                    if f.isAudio {
                        audioCount += 1
                        let k = f.kind
                        if counts[k] == nil { order.append(k) }
                        counts[k, default: 0] += 1
                        let q = f.qualityScore
                        if q > qualityScore || qualityLabel.isEmpty && q == qualityScore { qualityScore = q; qualityLabel = f.qualityLabel }
                    } else if f.isImage {
                        hasCover = true
                    } else if f.isLyrics {
                        hasLyrics = true
                    }
                }
                kinds = order.sorted { counts[$0]! > counts[$1]! }
            }
        }

        var size: UInt64 { summary.size }

        static func year(in folder: String) -> Int? {
            let chars = Array(folder.utf8)
            var found: Int?
            var i = 0
            func digit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
            while i + 4 <= chars.count {
                let before = i > 0 ? chars[i - 1] : 32, after = i + 4 < chars.count ? chars[i + 4] : 32
                if chars[i..<i + 4].allSatisfy(digit), !digit(before), !digit(after) {
                    let v = chars[i..<i + 4].reduce(0) { $0 * 10 + Int($1 - 48) }
                    if (1900...2099).contains(v) { found = v; i += 4; continue }
                }
                i += 1
            }
            return found
        }
    }

    /// Who a search goes to: the whole network, starred users, or one user.
    enum SearchScope: Equatable {
        case everyone, starred, users([String])
    }

    struct Search: Identifiable {
        let id = UUID()
        let token: UInt32
        /// As typed.
        let query: String
        var scope: SearchScope = .everyone
        /// What Soulseek was sent.
        var wire = ""
        /// Applied here to what comes back.
        var filters = SearchFilters()
        let started = Date()
        var groups: [SearchGroup] = []
        var fileCount = 0
        var userCount: Int { Set(groups.map(\.user)).count }
    }

    struct Transfer: Identifiable {
        let id: UUID
        let user: String
        let path: String
        var size: UInt64
        var bytes: UInt64 = 0
        var state: SlskTransferState = .queued
        var denial: String?
        let added = Date()
        /// Bytes per second, smoothed.
        var speed: Double = 0
        var lastSample: (Date, UInt64)?

        /// Every update this transfer's bar showed, oldest first.
        var history: [Step] = []
        /// The last tenth of the file logged, so progress lands in the history every 10%.
        var loggedTenth = 0

        struct Step: Identifiable {
            let id = UUID()
            var time = Date()
            let event: String
            var detail = ""
            var bad = false
        }

        mutating func record(_ event: String, _ detail: String = "", bad: Bool = false) {
            history.append(Step(event: event, detail: detail, bad: bad))
            if history.count > 200 { history.removeFirst(history.count - 200) }
        }

        /// The history line for a new state.
        mutating func record(_ state: SlskTransferState, upload: Bool) {
            switch state {
            case .queued: record("waiting", "for a free slot here")
            case .requesting: record("requested", upload ? "\(user) asked for the file" : "asked \(user) for the file")
            case .remoteQueued(let place): record("their queue", place > 0 ? "place \(place)" : "no place given")
            case .connecting: record("connecting", "opening a file connection")
            case .downloading: record(upload ? "sending" : "receiving", bytes > 0 ? "from \(Format.bytes(bytes)) of \(Format.bytes(size))" : Format.bytes(size))
            case .done(let url): record("finished", upload ? "sent \(Format.bytes(size))" : (url.path as NSString).abbreviatingWithTildeInPath)
            case .failed(let why): record("failed", why, bad: true)
            }
        }

        var name: String { path.split(separator: "\\").last.map(String.init) ?? path }
        var folder: String { path.split(separator: "\\").dropLast().last.map(String.init) ?? "" }
        var progress: Double { size == 0 ? 0 : min(1, Double(bytes) / Double(size)) }
        var localURL: URL? { if case .done(let url) = state { return url } else { return nil } }
    }

    enum BrowseState {
        case loading
        case loaded(BrowseList)
        case failed
    }

    /// A user's file list, ready to show: one result group per folder, and
    /// each folder's text (path and file names, lowercased) for the filter.
    /// Built off the main thread when the list arrives.
    struct BrowseList: Sendable {
        let groups: [SearchGroup]
        let haystacks: [String]
        let fileCount: Int

        init(user: String, folders: [SlskFolder]) {
            var groups: [SearchGroup] = [], haystacks: [String] = []
            groups.reserveCapacity(folders.count)
            haystacks.reserveCapacity(folders.count)
            var files = 0
            for folder in folders {
                let g = SearchGroup(user: user, folder: folder.path, files: folder.files, freeSlot: true, speed: 0, queue: 0)
                groups.append(g)
                var text = g.lowerFolder
                for f in folder.files { text += "\n" + f.lowerName }
                haystacks.append(text)
                files += folder.files.count
            }
            self.groups = groups
            self.haystacks = haystacks
            fileCount = files
        }

        /// The folders whose path or file names contain `needle` (case-insensitive).
        func matching(_ needle: String) -> [SearchGroup] {
            let n = needle.trimmingCharacters(in: .whitespaces).lowercased()
            guard !n.isEmpty else { return groups }
            return groups.indices.filter { haystacks[$0].has(n) }.map { groups[$0] }
        }
    }

    @Published var settings: SoulseekSettings {
        didSet {
            guard settings != oldValue else { return }
            if persists { DefaultsStore.save(settings, key: Self.settingsKey) }
            if settings.shareDownloads != oldValue.shareDownloads || settings.shareLibrary != oldValue.shareLibrary
                || settings.extraShares != oldValue.extraShares || settings.downloadFolder != oldValue.downloadFolder {
                rebuildShares()
            }
            if settings.uploadSlots != oldValue.uploadSlots { client.setUploadSlots(settings.uploadSlots) }
        }
    }
    @Published private(set) var status: Status = .off
    @Published private(set) var greeting = ""
    @Published private(set) var listeningPort: UInt16?
    /// Our address as the Soulseek server reports it at sign-in: what the network sees.
    @Published private(set) var seenAs: String?
    /// Raven Tunnel: nil while stopped, else its loopback SOCKS5 port.
    @Published private(set) var tunnelPort: UInt16?
    @Published private(set) var tunnelError: String?
    /// Credentials for the tunnel's loopback endpoint, fresh each session.
    private let tunnelUser = UUID().uuidString
    private let tunnelPassword = UUID().uuidString + UUID().uuidString
    @Published private(set) var searches: [Search] = []
    @Published var selectedSearch: UUID?
    @Published private(set) var downloads: [Transfer] = []
    @Published private(set) var uploads: [Transfer] = []
    @Published private(set) var sharedFolders = 0
    @Published private(set) var sharedFiles = 0
    @Published private(set) var indexingShares = false
    @Published private(set) var browsing: [String: BrowseState] = [:]
    /// When each open file-list request was sent, and how much of the list has arrived.
    @Published private(set) var browseStarted: [String: Date] = [:]
    @Published private(set) var browseProgress: [String: ListProgress] = [:]

    struct ListProgress: Equatable {
        var received: Int
        var total: Int
        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }
    /// What the connection did, newest last: shown in setup and on the account page.
    @Published private(set) var sessionLog: [LogLine] = []
    /// What other users and transfers did, newest first: the title bar shows the latest.
    @Published private(set) var activity: [Activity] = []
    /// Open peer connections, as the engine last reported.
    @Published private(set) var connections = 0

    struct Activity: Identifiable, Equatable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    func note(_ text: String) {
        activity.insert(Activity(text: text), at: 0)
        if activity.count > 60 { activity.removeLast(activity.count - 60) }
    }

    var downloadSpeed: Double { downloads.reduce(0) { $0 + ($1.state == .downloading ? $1.speed : 0) } }
    var uploadSpeed: Double { uploads.reduce(0) { $0 + ($1.state == .downloading ? $1.speed : 0) } }

    func isStarred(_ user: String) -> Bool { settings.starredUsers.contains(user) }

    func toggleStar(_ user: String) {
        if let i = settings.starredUsers.firstIndex(of: user) { settings.starredUsers.remove(at: i) }
        else { settings.starredUsers.append(user); settings.hiddenUsers.removeAll { $0 == user } }
    }

    struct LogLine: Identifiable {
        enum Kind { case info, ok, error }
        /// What a line is about, for the log panel's filter.
        enum Topic: String, CaseIterable {
            case server, peer, search, transfer, share, message
            var title: String {
                switch self {
                case .server: return "Server"
                case .peer: return "Peers"
                case .search: return "Search"
                case .transfer: return "Transfers"
                case .share: return "Sharing"
                case .message: return "Messages"
                }
            }
        }
        let id = UUID()
        var time = Date()
        let kind: Kind
        var topic: Topic = .server
        /// "event  detail": the first part is the event, double spaces separate the rest.
        let text: String
    }

    static let logLimit = 2000

    func log(_ kind: LogLine.Kind, _ text: String, _ topic: LogLine.Topic = .server) {
        sessionLog.append(LogLine(kind: kind, topic: topic, text: text))
        if sessionLog.count > Self.logLimit { sessionLog.removeFirst(sessionLog.count - Self.logLimit) }
    }

    func clearLog() { sessionLog = [] }

    // MARK: Messages

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var time = Date()
        let incoming: Bool
        let text: String
    }

    struct Conversation: Identifiable, Equatable {
        var id: String { user }
        let user: String
        var messages: [Message] = []
        var unread = 0
        var last: Date { messages.last?.time ?? .distantPast }
    }

    /// Newest activity first. Kept in memory only: gone when i2s quits.
    @Published private(set) var conversations: [Conversation] = []
    @Published var openConversation: String?
    /// The Messages page is on screen: messages to the open conversation arrive read.
    var messagesVisible = false

    var unreadMessages: Int { conversations.reduce(0) { $0 + $1.unread } }

    func isIgnored(_ user: String) -> Bool { settings.ignoredUsers.contains(user) }

    func toggleIgnore(_ user: String) {
        if let i = settings.ignoredUsers.firstIndex(of: user) {
            settings.ignoredUsers.remove(at: i)
            log(.info, "unignored  \(user)", .message)
        } else {
            settings.ignoredUsers.append(user)
            log(.info, "ignored  \(user)  messages from them are dropped", .message)
        }
    }

    /// Opens (or creates) a conversation with a user.
    func startConversation(with user: String) {
        let name = user.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !conversations.contains(where: { $0.user == name }) { conversations.insert(Conversation(user: name), at: 0) }
        openConversation = name
        markRead(name)
    }

    func markRead(_ user: String) {
        guard let i = conversations.firstIndex(where: { $0.user == user }), conversations[i].unread > 0 else { return }
        conversations[i].unread = 0
    }

    func closeConversation(_ user: String) {
        conversations.removeAll { $0.user == user }
        if openConversation == user { openConversation = conversations.first?.user }
    }

    /// Sends a private message. Returns nil, or why it wasn't sent.
    @discardableResult
    func sendMessage(_ text: String, to user: String) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        guard status == .online else { return "Not connected. The message was not sent." }
        guard !isIgnored(user) else { return "You are ignoring \(user). Unignore them to send." }
        client.message(user, body)
        append(Message(incoming: false, text: body), with: user)
        log(.info, "sent  to \(user)  \(body.count) characters", .message)
        return nil
    }

    private func append(_ m: Message, with user: String) {
        var c = conversations.first { $0.user == user } ?? Conversation(user: user)
        c.messages.append(m)
        if c.messages.count > 500 { c.messages.removeFirst(c.messages.count - 500) }
        if m.incoming && (openConversation != user || !messagesVisible) { c.unread += 1 }
        conversations.removeAll { $0.user == user }
        conversations.insert(c, at: 0)
    }

    var serverAddress: String {
        if let c = credentialsOverride { return "\(c.host):\(c.port)" }
        return "\(settings.serverHost):\(settings.serverPort)"
    }

    var route: SlskRoute {
        if settings.routeMode == .tunnel {
            return SlskRoute(mode: .tunnel, proxyHost: "127.0.0.1", proxyPort: tunnelPort ?? 9, proxyUser: tunnelUser,
                             proxyPassword: tunnelPassword, acceptIncoming: false)
        }
        return SlskRoute(mode: settings.routeMode, proxyHost: settings.proxyHost, proxyPort: UInt16(clamping: settings.proxyPort),
                  proxyUser: settings.proxyUser, proxyPassword: Keychain.password(for: Self.proxyAccount) ?? "",
                  dnsServers: settings.dnsServers, acceptIncoming: settings.acceptIncoming)
    }

    static let proxyAccount = "proxy"
    static let tunnelAccount = "wireguard"

    var tunnelConfig: String? { Keychain.password(for: Self.tunnelAccount) }

    /// Stores a WireGuard config (it holds a private key, so it goes in the Keychain).
    func importTunnel(_ text: String) -> String? {
        switch RavenTunnel.describe(text) {
        case .failure(let e): return e.message
        case .success(let summary):
            stopTunnel()
            Keychain.save(text, for: Self.tunnelAccount)
            settings.tunnelEndpoint = summary.endpoint
            settings.tunnelAddress = summary.address
            log(.info, "tunnel  imported  \(summary.endpoint)")
            return nil
        }
    }

    func removeTunnel() {
        stopTunnel()
        Keychain.delete(for: Self.tunnelAccount)
        settings.tunnelEndpoint = ""
        settings.tunnelAddress = ""
    }

    /// Brings Raven Tunnel up if the route needs it. Returns a reason on failure.
    @discardableResult
    func ensureTunnel() -> String? {
        guard settings.routeMode == .tunnel else { return nil }
        if tunnelPort != nil { return nil }
        guard let config = tunnelConfig else { return "No WireGuard configuration imported." }
        switch RavenTunnel.start(config, user: tunnelUser, password: tunnelPassword) {
        case .success(let port):
            tunnelPort = port
            tunnelError = nil
            log(.info, "tunnel  up  \(settings.tunnelEndpoint)")
            return nil
        case .failure(let e):
            tunnelError = e.message
            log(.error, "tunnel  " + e.message)
            return "Raven Tunnel did not start: \(e.message)"
        }
    }

    func stopTunnel() {
        guard tunnelPort != nil else { return }
        RavenTunnel.stop()
        tunnelPort = nil
        log(.info, "tunnel  down")
    }

    func setProxyPassword(_ password: String) {
        if password.isEmpty { Keychain.delete(for: Self.proxyAccount) } else { Keychain.save(password, for: Self.proxyAccount) }
    }

    /// Opens one connection to the server along the current route and closes
    /// it. Returns nil if it got through, or the reason it didn't.
    func testRoute() async -> String? {
        if let problem = routeProblem() { return problem }
        let host = settings.serverHost, port = UInt16(clamping: settings.serverPort), route = self.route
        return await withCheckedContinuation { c in
            let queue = DispatchQueue(label: "i2s.raven.test")
            queue.async {
                var resumed = false
                func finish(_ r: String?) { if !resumed { resumed = true; c.resume(returning: r) } }
                let s = SlskSocket(host: host, port: port, framing: .server, queue: queue, route: route)
                s.onReady = { [weak s] in s?.onClose = nil; s?.close(); finish(nil) }
                s.onClose = { reason in finish(reason ?? "Connection closed.") }
                s.start()
                queue.asyncAfter(deadline: .now() + 12) { s.onClose = nil; s.close(); finish("Timed out.") }
            }
        }
    }

    /// Why Raven won't connect along the chosen route right now, or nil.
    func routeProblem() -> String? {
        switch settings.routeMode {
        case .direct: return nil
        case .socks5:
            if settings.proxyHost.trimmingCharacters(in: .whitespaces).isEmpty { return "No proxy address set." }
            return nil
        case .tunnel:
            return ensureTunnel()
        }
    }

    let client = SlskClient()
    /// Off for snapshot sample data, so it never lands in saved settings.
    var persists = true
    private static let settingsKey = "com.meimei.player.soulseek.v1"
    private var pendingReplies: [SlskSearchReply] = []
    private var flushScheduled = false
    private var signInContinuation: CheckedContinuation<String?, Never>?
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var shareRebuild: DispatchWorkItem?
    private var credentialsOverride: SlskClient.Credentials?

    init() {
        settings = DefaultsStore.loadLenient(SoulseekSettings.self, key: Self.settingsKey)
        SoulseekDev.applyOnLaunch(self)
        client.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } }
        client.setUploadSlots(settings.uploadSlots)
    }

    /// Called once the app is up: reconnect a finished setup, if wanted.
    func start() {
        guard settings.enabled, settings.setupComplete, settings.connectOnLaunch, !isHeadless else { return }
        rebuildShares()
        connect()
    }

    private var isHeadless: Bool {
        #if DEBUG
        return DebugHooks.isHeadless
        #else
        return false
        #endif
    }

    // MARK: Account

    var hasSavedPassword: Bool { Keychain.password(for: settings.username) != nil }

    /// Signs in, creating the account if the name is free. Returns nil on
    /// success or a plain-words reason.
    func signIn(username: String, password: String, creating: Bool) async -> String? {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "Username is required." }
        guard !password.isEmpty else { return "Password is required." }
        if let problem = routeProblem() {
            log(.error, "blocked  " + problem)
            return problem
        }
        status = .connecting
        log(.info, "connect  \(serverAddress)  via \(routeLabel)")
        log(.info, (creating ? "register  " : "login  ") + name)
        let reason: String? = await withCheckedContinuation { c in
            signInContinuation = c
            client.connect(credentials(username: name, password: password))
        }
        if let reason {
            status = .offline(reason)
            return Self.loginReason(reason, creating: creating)
        }
        settings.username = name
        Keychain.save(password, for: name)
        return nil
    }

    func connect() {
        guard let password = Keychain.password(for: settings.username) else {
            status = .offline("Not signed in.")
            return
        }
        reconnectWork?.cancel()
        if let problem = routeProblem() {
            status = .offline(problem)
            log(.error, "blocked  " + problem)
            return
        }
        status = .connecting
        log(.info, "connect  \(serverAddress)  via \(routeLabel)")
        rebuildShares()
        client.connect(credentials(username: settings.username, password: password))
    }

    func disconnect() {
        reconnectWork?.cancel()
        client.disconnect()
        stopTunnel()
        status = .off
    }

    func signOut() {
        disconnect()
        Keychain.delete(for: settings.username)
        settings.username = ""
    }

    /// Turns the whole feature off; the account and files are kept.
    func turnOff() {
        disconnect()
        settings.enabled = false
    }

    private func credentials(username: String, password: String) -> SlskClient.Credentials {
        if var c = credentialsOverride {
            c.username = username
            c.password = password
            return c
        }
        return SlskClient.Credentials(host: settings.serverHost, port: UInt16(clamping: settings.serverPort),
                                      username: username, password: password,
                                      listenPort: UInt16(clamping: settings.listenPort), route: route)
    }

    #if DEBUG
    /// Points the store at a local test server (self-test only).
    func useTestServer(host: String, port: UInt16, listenPort: UInt16) {
        credentialsOverride = SlskClient.Credentials(host: host, port: port, username: "", password: "",
                                                     listenPort: listenPort, loopbackOnly: true)
    }
    #endif

    static func loginReason(_ code: String, creating: Bool) -> String {
        switch code {
        case "INVALIDPASS":
            return creating ? "Username is already registered. Choose another, or sign in if the account is yours." : "Incorrect password."
        case "INVALIDUSERNAME": return "Username is not valid."
        case "EMPTYPASSWORD": return "Password is required."
        case "INVALIDVERSION": return "The server rejected this client version."
        case "SVRFULL": return "The server is full. Try again later."
        case "SVRPRIVATE": return "The server is not accepting new registrations."
        default: return code.hasPrefix("Server unreachable") || code.hasPrefix("Server closed") ? code : "Sign-in failed (\(code))."
        }
    }

    // MARK: Events

    private func handle(_ event: SlskClient.Event) {
        switch event {
        case .loggedIn(let greeting, let seenAs):
            self.greeting = greeting
            self.seenAs = seenAs
            status = .online
            log(.ok, "online  " + settings.username.ifEmpty("signed in") + (seenAs.map { "  seen as \($0)" } ?? ""))
            reconnectAttempt = 0
            signInContinuation?.resume(returning: nil)
            signInContinuation = nil
        case .loginFailed(let reason):
            log(.error, "refused  " + reason)
            if let c = signInContinuation {
                signInContinuation = nil
                c.resume(returning: reason)
            } else {
                status = .offline(Self.loginReason(reason, creating: false))
                scheduleReconnect()
            }
        case .disconnected(let reason):
            connections = 0
            status = .offline(reason ?? "Disconnected.")
            log(.error, "disconnected" + (reason.map { "  " + $0 } ?? ""))
            if reason?.contains("another client") != true { scheduleReconnect() }
        case .listening(let port):
            listeningPort = port
            if let port { log(.info, "listen  tcp \(port)") }
            else { log(.info, route.listens ? "listen  failed" : "listen  off") }
        case .searchReply(let reply):
            pendingReplies.append(reply)
            if !flushScheduled {
                flushScheduled = true
                // Replies arrive in bursts of hundreds; fold them in a few times a second.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    MainActor.assumeIsolated { self?.flushReplies() }
                }
            }
        case .download(let update):
            let before = downloads.first { $0.id == update.id }
            apply(update, to: &downloads, upload: false)
            if let t = before, t.state != update.state {
                switch update.state {
                case .done: note("Downloaded \(t.name) from \(t.user)")
                case .failed: note("Download failed: \(t.name) from \(t.user)")
                default: break
                }
                logTransfer("download", t, update.state)
            }
            if case .done = update.state { rebuildShares(after: 5) }
        case .upload(let update):
            if !uploads.contains(where: { $0.id == update.id }), let user = update.user, let path = update.path {
                var t = Transfer(id: update.id, user: user, path: path, size: update.size)
                t.record("added", "\(user) wants it  \(Format.bytes(update.size))")
                uploads.insert(t, at: 0)
                note("\(user) queued \(uploads[0].name)")
            }
            let before = uploads.first { $0.id == update.id }
            apply(update, to: &uploads, upload: true)
            if let t = before, t.state != update.state {
                switch update.state {
                case .downloading: note("Uploading \(t.name) to \(t.user)")
                case .done: note("Uploaded \(t.name) to \(t.user)")
                case .failed: note("Upload of \(t.name) to \(t.user) stopped")
                default: break
                }
                logTransfer("upload", t, update.state)
            }
        case .browse(let user, let folders):
            guard let folders else {
                browsing[user] = .failed
                browseProgress[user] = nil
                log(.error, "file list  \(user)  not received", .peer)
                return
            }
            log(.info, "\(user)  reading  \(folders.count) folders", .peer)
            Task.detached(priority: .userInitiated) {
                let list = BrowseList(user: user, folders: folders)
                await MainActor.run { [weak self] in
                    guard let self, case .loading? = self.browsing[user] else { return }
                    self.browsing[user] = .loaded(list)
                    self.browseProgress[user] = nil
                    self.log(.ok, "file list  \(user)  \(list.groups.count) folders, \(list.fileCount) files", .peer)
                }
            }
        case .browseProgress(let user, let received, let total):
            guard case .loading? = browsing[user] else { return }
            browseProgress[user] = ListProgress(received: received, total: total)
        case .sharesRequested(let user):
            note("\(user) is browsing your shared files")
            log(.info, "browsed  \(user) asked for your file list", .share)
        case .infoRequested(let user):
            note("\(user) viewed your user info")
            log(.info, "info  \(user) asked for your user info", .peer)
        case .message(let user, let text, let sent):
            if isIgnored(user) {
                log(.info, "dropped  message from ignored user \(user)", .message)
                return
            }
            append(Message(time: min(sent, Date()), incoming: true, text: text), with: user)
            note("Message from \(user): \(text)")
            log(.info, "received  from \(user)  \(text.count) characters", .message)
        case .connections(let n):
            connections = n
        case .trace(let topic, let text):
            let t: LogLine.Topic = topic == "peer" ? .peer : topic == "upload" || topic == "transfer" ? .transfer : .server
            log(.info, text, t)
        }
    }

    private func logTransfer(_ kind: String, _ t: Transfer, _ state: SlskTransferState) {
        let who = (kind == "download" ? "from " : "to ") + t.user
        switch state {
        case .queued: break
        case .requesting: log(.info, "\(kind)  requested  \(t.name)  \(who)", .transfer)
        case .remoteQueued(let place): log(.info, "\(kind)  queued remotely" + (place > 0 ? " #\(place)" : "") + "  \(t.name)  \(who)", .transfer)
        case .connecting: log(.info, "\(kind)  connecting  \(t.name)  \(who)", .transfer)
        case .downloading: log(.info, "\(kind)  started  \(t.name)  \(who)", .transfer)
        case .done: log(.ok, "\(kind)  finished  \(t.name)  \(who)", .transfer)
        case .failed(let why): log(.error, "\(kind)  failed  \(t.name)  \(who)  \(why)", .transfer)
        }
    }

    private func scheduleReconnect() {
        guard settings.enabled, settings.setupComplete, !isHeadless else { return }
        reconnectWork?.cancel()
        let delays: [Double] = [5, 15, 30, 60, 120]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.connect() } }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func apply(_ update: SlskTransferUpdate, to list: inout [Transfer], upload: Bool) {
        guard let i = list.firstIndex(where: { $0.id == update.id }) else { return }
        var t = list[i]
        let now = Date()
        if let (at, bytes) = t.lastSample, update.bytes >= bytes {
            let dt = now.timeIntervalSince(at)
            if dt > 0.05 {
                let instant = Double(update.bytes - bytes) / dt
                t.speed = t.speed == 0 ? instant : t.speed * 0.7 + instant * 0.3
                t.lastSample = (now, update.bytes)
            }
        } else {
            t.lastSample = (now, update.bytes)
        }
        t.bytes = update.bytes
        t.size = update.size
        let changed = t.state != update.state
        t.state = update.state
        t.denial = update.denial
        if changed { t.record(update.state, upload: upload) }
        if update.state == .downloading, t.size > 0 {
            let tenth = Int(t.progress * 10)
            if tenth > t.loggedTenth && tenth < 10 {
                t.loggedTenth = tenth
                t.record("\(tenth * 10)%", "\(Format.bytes(t.bytes)) of \(Format.bytes(t.size))" + (t.speed > 0 ? "  ·  " + Format.speed(t.speed) : ""))
            }
        }
        if update.state.isFinished { t.speed = 0 }
        list[i] = t
        if update.state.isFinished { startQueuedDownloads() }
    }

    // MARK: Search

    /// Runs a typed search (see `SearchCommand`). Returns nil, or why it can't run.
    @discardableResult
    func search(_ text: String) -> String? {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = SearchCommand(q)
        if let problem = cmd.problem { return problem }
        guard status == .online else { return "Not connected." }
        let users: [String]
        switch cmd.scope {
        case .everyone: users = []
        case .starred:
            users = settings.starredUsers
            guard !users.isEmpty else { return "No starred users yet. Star a user from a result's menu." }
        case .users(let names): users = names
        }
        var search = Search(token: UInt32.random(in: 1...UInt32.max - 1), query: q, scope: cmd.scope)
        search.wire = cmd.wire
        search.filters = cmd.filters
        searches.insert(search, at: 0)
        remember(q)
        if searches.count > 12 { searches.removeLast() }
        selectedSearch = search.id
        if users.isEmpty { client.search(cmd.wire, token: search.token) }
        for user in users { client.search(cmd.wire, user: user, token: search.token) }
        log(.info, "search  \(cmd.wire)  " + (users.isEmpty ? "everyone" : users.joined(separator: ", "))
            + "  token \(search.token)", .search)
        return nil
    }

    func setSort(_ id: UUID, _ sort: SearchFilters.Sort) {
        guard let i = searches.firstIndex(where: { $0.id == id }) else { return }
        searches[i].filters.sort = sort
        searches[i].filters.reversed = false
    }

    private func remember(_ query: String) {
        guard settings.keepSearchHistory else { return }
        var h = settings.searchHistory.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        h.insert(query, at: 0)
        settings.searchHistory = Array(h.prefix(20))
    }

    func clearSearchHistory() { settings.searchHistory = [] }

    func hideUser(_ user: String) {
        guard !settings.hiddenUsers.contains(user) else { return }
        settings.hiddenUsers.append(user)
    }

    /// A search's results as shown: filtered, ordered, counted.
    struct SearchResults {
        var groups: [SearchGroup] = []
        var users = 0
        var files = 0
    }

    private struct ResultsKey: Equatable {
        let filters: SearchFilters
        let hidden: [String]
        let starred: [String]
    }

    /// Per search: what its filters kept so far, how many of its groups that
    /// covers, and the ordered results.
    private var resultsCache: [UUID: (key: ResultsKey, kept: [SearchGroup], through: Int, results: SearchResults)] = [:]

    /// The results for a search, recomputed only when its replies, filters,
    /// hidden or starred users change. New replies are filtered on their own
    /// and merged; only the ordering covers everything again.
    func results(for search: Search) -> SearchResults {
        let key = ResultsKey(filters: search.filters, hidden: settings.hiddenUsers, starred: settings.starredUsers)
        let entry = resultsCache[search.id]
        if let entry, entry.key == key, entry.through == search.groups.count { return entry.results }
        let kept: [SearchGroup]
        if let entry, entry.key == key, entry.through < search.groups.count {
            kept = entry.kept + search.filters.filtered(search.groups[entry.through...], hidden: Set(key.hidden))
        } else {
            kept = search.filters.filtered(search.groups, hidden: Set(key.hidden))
        }
        let ordered = search.filters.ordered(kept, starred: Set(key.starred))
        let results = SearchResults(groups: ordered, users: Set(ordered.map(\.user)).count,
                                    files: ordered.reduce(0) { $0 + $1.audioCount })
        resultsCache[search.id] = (key, kept, search.groups.count, results)
        return results
    }

    /// The last browse filter worked out, so redraws don't search the list again.
    private var browseFilterCache: (user: String, needle: String, count: Int, groups: [SearchGroup])?

    func browseMatches(_ user: String, _ list: BrowseList, _ needle: String) -> [SearchGroup] {
        if needle.isEmpty { return list.groups }
        if let c = browseFilterCache, c.user == user, c.needle == needle, c.count == list.groups.count { return c.groups }
        let groups = list.matching(needle)
        browseFilterCache = (user, needle, list.groups.count, groups)
        return groups
    }

    func closeSearch(_ id: UUID) {
        resultsCache[id] = nil
        searches.removeAll { $0.id == id }
        if selectedSearch == id { selectedSearch = searches.first?.id }
    }

    private func flushReplies() {
        flushScheduled = false
        let replies = pendingReplies
        pendingReplies = []
        // One change to `searches` per flush, not one per reply: each change redraws the page.
        var all = searches
        for reply in replies {
            guard let i = all.firstIndex(where: { $0.token == reply.token }) else { continue }
            let byFolder = Dictionary(grouping: reply.files, by: \.folder)
            for (folder, files) in byFolder {
                all[i].groups.append(SearchGroup(user: reply.username, folder: folder, files: files.sorted { $0.path < $1.path },
                                                 freeSlot: reply.freeSlot, speed: reply.speed, queue: reply.queue))
            }
            all[i].fileCount += reply.files.count
        }
        searches = all
    }

    // MARK: Transfers

    func download(_ files: [SlskFile], from user: String) {
        for file in files where !downloads.contains(where: { $0.user == user && $0.path == file.path && !$0.state.isFinished }) {
            var t = Transfer(id: UUID(), user: user, path: file.path, size: file.size)
            t.record("added", "from \(user)  \(Format.bytes(file.size))")
            downloads.insert(t, at: 0)
        }
        startQueuedDownloads()
    }

    private func startQueuedDownloads() {
        let active = downloads.filter { !$0.state.isFinished && $0.state != .queued }.count
        var slots = max(0, settings.maxActiveDownloads * 4 - active)
        // Many users queue requests on their side; asking for several at once is normal.
        for t in downloads.reversed() where t.state == .queued && slots > 0 {
            slots -= 1
            begin(t)
        }
    }

    private func begin(_ t: Transfer) {
        guard let i = downloads.firstIndex(where: { $0.id == t.id }) else { return }
        downloads[i].state = .requesting
        downloads[i].record(.requesting, upload: false)
        client.download(id: t.id, user: t.user, path: t.path, size: t.size, to: destination(for: t))
    }

    private func destination(for t: Transfer) -> URL {
        var url = URL(fileURLWithPath: settings.downloadFolder, isDirectory: true)
        if settings.keepFolders, !t.folder.isEmpty { url.appendPathComponent(Self.safe(t.folder), isDirectory: true) }
        return url.appendingPathComponent(Self.safe(t.name))
    }

    private static func safe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
    }

    func retry(_ id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }), case .failed = downloads[i].state else { return }
        client.cancelDownload(id)
        downloads[i].state = .queued
        downloads[i].denial = nil
        downloads[i].loggedTenth = 0
        downloads[i].record("retry", "back in line")
        startQueuedDownloads()
    }

    func cancel(_ id: UUID) {
        client.cancelDownload(id)
        downloads.removeAll { $0.id == id }
        startQueuedDownloads()
    }

    /// Cancels (or, once finished, removes) several downloads at once.
    func cancel(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { client.cancelDownload(id) }
        downloads.removeAll { ids.contains($0.id) }
        startQueuedDownloads()
    }

    func retry(_ ids: Set<UUID>) {
        for t in downloads where ids.contains(t.id) { if case .failed = t.state { retry(t.id) } }
    }

    /// Shows the finished files of a list in the file manager.
    func reveal(_ list: [Transfer]) {
        let urls = list.compactMap(\.localURL)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func clearFinished() {
        downloads.removeAll { if case .done = $0.state { return true } else { return false } }
        uploads.removeAll { $0.state.isFinished }
    }

    func retryAllFailed() {
        for t in downloads { if case .failed = t.state { retry(t.id) } }
    }

    func reveal(_ t: Transfer) {
        if let url = t.localURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func browse(_ user: String) {
        browsing[user] = .loading
        browseStarted[user] = Date()
        browseProgress[user] = nil
        client.browse(user)
        log(.info, "browse  \(user)", .peer)
    }

    // MARK: Shares

    var shareRoots: [URL] {
        var roots: [URL] = []
        if settings.shareDownloads { roots.append(URL(fileURLWithPath: settings.downloadFolder, isDirectory: true)) }
        if settings.shareLibrary {
            roots += AppSession.shared.scanner.folders.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        }
        roots += settings.extraShares.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    func rebuildShares(after delay: Double = 0.3) {
        shareRebuild?.cancel()
        let roots = shareRoots
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.indexingShares = true }
            DispatchQueue.global(qos: .utility).async {
                let index = SlskShareIndex.build(roots)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.sharedFolders = index.folders.count
                        self.sharedFiles = index.fileCount
                        self.indexingShares = false
                        self.log(.info, "shares  \(index.fileCount) files in \(index.folders.count) folders", .share)
                        self.client.setShares(index)
                    }
                }
            }
        }
        shareRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

#if DEBUG
extension SoulseekStore {
    /// Feeds an engine event straight in (self-test only).
    func debugHandle(_ event: SlskClient.Event) { handle(event) }

    /// Sample searches and transfers for offscreen snapshots. Never connects.
    func debugFill() {
        persists = false
        settings.enabled = true
        settings.setupComplete = true
        settings.username = "quiet_listener"
        status = .online
        listeningPort = 2234
        sharedFiles = 1240
        sharedFolders = 96
        func f(_ p: String, _ size: UInt64, _ ext: String, br: Int? = nil, sr: Int? = nil, bd: Int? = nil, d: Int) -> SlskFile {
            SlskFile(path: p, size: size, ext: ext, bitrate: br, duration: d, sampleRate: sr, bitDepth: bd)
        }
        var s = Search(token: 1, query: "boards of canada geogaddi")
        s.groups = [
            SearchGroup(user: "tapehiss", folder: "Music\\Boards of Canada\\2002 - Geogaddi [FLAC 24-96]",
                        files: (1...23).map { f("Music\\Boards of Canada\\2002 - Geogaddi [FLAC 24-96]\\\(String(format: "%02d", $0)) Track.flac", 48_000_000, "flac", sr: 96_000, bd: 24, d: 180) }
                            + [f("Music\\Boards of Canada\\2002 - Geogaddi [FLAC 24-96]\\cover.jpg", 900_000, "jpg", d: 0),
                               f("Music\\Boards of Canada\\2002 - Geogaddi [FLAC 24-96]\\01 Track.lrc", 2_000, "lrc", d: 0)],
                        freeSlot: true, speed: 4_800_000, queue: 0),
            SearchGroup(user: "northern_lights", folder: "share\\BoC\\Geogaddi (2002)",
                        files: (1...23).map { f("share\\BoC\\Geogaddi (2002)\\\($0) - Track.mp3", 9_200_000, "mp3", br: 320, d: 180) },
                        freeSlot: false, speed: 1_200_000, queue: 6),
            SearchGroup(user: "warp_archive", folder: "Electronic\\Boards Of Canada - Geogaddi",
                        files: (1...23).map { f("Electronic\\Boards Of Canada - Geogaddi\\\($0).flac", 31_000_000, "flac", sr: 44_100, bd: 16, d: 180) },
                        freeSlot: true, speed: 900_000, queue: 0),
            SearchGroup(user: "lowfreq", folder: "Rips\\Boards of Canada\\Geogaddi (Warp, WARPCD101)",
                        files: (1...23).map { f("Rips\\Boards of Canada\\Geogaddi (Warp, WARPCD101)\\\($0).m4a", 7_000_000, "m4a", br: 256, d: 180) },
                        freeSlot: false, speed: 300_000, queue: 41),
            SearchGroup(user: "cassette_ghost", folder: "incoming\\singles",
                        files: [f("incoming\\singles\\Boards of Canada - Dawn Chorus.mp3", 8_100_000, "mp3", br: 320, d: 236)],
                        freeSlot: true, speed: 2_100_000, queue: 0),
            SearchGroup(user: "hexagon_sun", folder: "lossless\\BoC\\2002 Geogaddi",
                        files: (1...23).map { f("lossless\\BoC\\2002 Geogaddi\\\($0).flac", 30_000_000, "flac", sr: 44_100, bd: 16, d: 180) }
                            + [f("lossless\\BoC\\2002 Geogaddi\\folder.png", 400_000, "png", d: 0)],
                        freeSlot: false, speed: 2_600_000, queue: 2),
        ]
        s.fileCount = 116
        s.wire = "boards of canada geogaddi"
        var t = Search(token: 2, query: "aphex twin drukqs")
        t.wire = t.query
        t.groups = [s.groups[4]]
        searches = [s, t]
        selectedSearch = s.id
        settings.searchHistory = ["boards of canada geogaddi", "aphex twin drukqs", "autechre tri repetae", "plaid not for threes"]
        settings.starredUsers = ["tapehiss", "hexagon_sun"]
        connections = 14
        note("Downloaded 02 Music Is Math.flac from tapehiss")
        note("northern_lights is browsing your shared files, 1,240 files in 96 folders, and queued two albums from your download folder")
        var a = Transfer(id: UUID(), user: "tapehiss", path: "Music\\Boards of Canada\\Geogaddi\\03 Music Is Math.flac", size: 61_000_000)
        a.bytes = 38_000_000; a.state = .downloading; a.speed = 4_100_000
        let t0 = Date().addingTimeInterval(-95)
        for (s, e, d) in [(0.0, "added", "from tapehiss  61 MB"), (0.1, "requested", "asked tapehiss for the file"),
                          (1.4, "their queue", "place 3"), (41, "their queue", "place 1"), (63, "connecting", "opening a file connection"),
                          (64, "receiving", "61 MB"), (70, "10%", "6.1 MB of 61 MB  ·  3.8 MB/s"), (77, "20%", "12.2 MB of 61 MB  ·  4.0 MB/s"),
                          (84, "30%", "18.3 MB of 61 MB  ·  4.1 MB/s"), (90, "40%", "24.4 MB of 61 MB  ·  4.1 MB/s"),
                          (94, "50%", "30.5 MB of 61 MB  ·  4.2 MB/s"), (95, "60%", "36.6 MB of 61 MB  ·  4.1 MB/s")] {
            a.record(e, d); a.history[a.history.count - 1].time = t0.addingTimeInterval(s)
        }
        var b = Transfer(id: UUID(), user: "northern_lights", path: "share\\BoC\\Geogaddi (2002)\\04 Beware the Friendly Stranger.mp3", size: 1_900_000)
        b.state = .remoteQueued(place: 6)
        var c = Transfer(id: UUID(), user: "warp_archive", path: "Electronic\\Geogaddi\\01 Ready Lets Go.flac", size: 4_000_000)
        c.state = .failed(SlskReasons.requiresSharing)
        var d = Transfer(id: UUID(), user: "tapehiss", path: "Music\\Boards of Canada\\Geogaddi\\02 Music Is Math.flac", size: 52_000_000)
        d.bytes = 52_000_000; d.state = .done(URL(fileURLWithPath: "/tmp/x.flac"))
        var more: [Transfer] = []
        for (i, name) in ["01 Ready Lets Go.flac", "04 Beware the Friendly Stranger.flac", "05 Gyroscope.flac", "cover.jpg"].enumerated() {
            var x = Transfer(id: UUID(), user: "tapehiss", path: "Music\\Boards of Canada\\Geogaddi\\" + name, size: UInt64(20_000_000 + i * 7_000_000))
            x.state = i == 0 ? .done(URL(fileURLWithPath: "/tmp/y.flac")) : i == 1 ? .connecting : .queued
            more.append(x)
        }
        var e = Transfer(id: UUID(), user: "hexagon_sun", path: "rips\\Label Sampler\\02 Side B.mp3", size: 9_000_000)
        e.state = .done(URL(fileURLWithPath: "/tmp/z.mp3"))
        var f = Transfer(id: UUID(), user: "hexagon_sun", path: "rips\\Label Sampler\\01 Side A.mp3", size: 8_400_000)
        f.state = .done(URL(fileURLWithPath: "/tmp/w.mp3"))
        downloads = [a] + more + [b, c, d, e, f]
        log(.info, "connect  server.slsknet.org:2242  via default")
        log(.info, "listen  tcp 2234")
        log(.info, "login  quiet_listener")
        log(.ok, "online  quiet_listener  seen as 203.0.113.24")
        log(.info, "shares  1240 files in 96 folders", .share)
        log(.info, "search  boards of canada geogaddi  everyone  token 1", .search)
        log(.info, "tapehiss  connected to us", .peer)
        log(.info, "download  requested  03 Music Is Math.flac  from tapehiss", .transfer)
        log(.info, "download  started  03 Music Is Math.flac  from tapehiss", .transfer)
        log(.info, "northern_lights  reached at their request  198.51.100.7:2234", .peer)
        log(.info, "browsed  northern_lights asked for your file list", .share)
        log(.error, "download  failed  01 Ready Lets Go.flac  from warp_archive  \(SlskReasons.requiresSharing)", .transfer)
        log(.info, "received  from tapehiss  64 characters", .message)
        var talk = Conversation(user: "tapehiss")
        let base = Date().addingTimeInterval(-1800)
        talk.messages = [
            Message(time: base, incoming: true, text: "hey, saw you grabbing geogaddi. the 24/96 rip is from the 2013 vinyl press"),
            Message(time: base.addingTimeInterval(60), incoming: false, text: "thanks, good to know. is the cd rip in the same folder?"),
            Message(time: base.addingTimeInterval(140), incoming: true, text: "separate folder, Music\\Boards of Canada\\2002 - Geogaddi [CD]"),
        ]
        talk.unread = 1
        conversations = [talk, Conversation(user: "hexagon_sun", messages: [Message(time: base.addingTimeInterval(-7200), incoming: false, text: "do you have the peel session?")])]
        openConversation = "tapehiss"
        settings.messagesAcknowledged = true
    }

    /// Snapshots: a file-list request in flight, arriving, or failed, with its trace.
    func debugBrowseRequest(_ user: String, received: Int?, failed: Bool = false) {
        let start = Date().addingTimeInterval(-9)
        browseStarted[user] = start
        browsing[user] = failed ? .failed : .loading
        browseProgress[user] = received.map { ListProgress(received: $0, total: 4_800_000) }
        sessionLog.removeAll { $0.text.hasPrefix(user + "  ") }
        func at(_ s: Double, _ text: String) { log(.info, text, .peer); sessionLog[sessionLog.count - 1].time = start.addingTimeInterval(s) }
        at(0, "\(user)  file list requested")
        at(0, "\(user)  connecting  directly and through the server")
        if failed {
            at(0.4, "\(user)  no address  the server knows no listening port")
            at(25, "\(user)  unreachable")
        } else {
            at(0.3, "\(user)  address  198.51.100.7:2234")
            at(1.1, "\(user)  connected directly  198.51.100.7:2234")
        }
    }
}
#endif

extension SoulseekStore {
    var routeLabel: String {
        switch settings.routeMode {
        case .direct: return "default"
        case .socks5: return "socks5 \(settings.proxyHost):\(settings.proxyPort)"
        case .tunnel: return "raven tunnel \(settings.tunnelEndpoint)"
        }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

// MARK: - Keychain

/// The Soulseek password, kept in the macOS Keychain (never in settings).
/// Platform piece: the ports use their own secret stores.
enum Keychain {
    private static let service = "i2s.soulseek"

    static func save(_ password: String, for account: String) {
        delete(for: account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(password.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func password(for account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for account: String) {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - DEV: first-run every launch (remove before release)

/// A development switch (Settings → Sources → developer) that wipes the
/// Soulseek setup at every launch so the first-time flow can be tried again.
/// To remove for release: delete this enum, its call in `SoulseekStore.init`,
/// and the developer section in the Sources settings page.
enum SoulseekDev {
    static let key = "com.meimei.player.dev.soulseekFirstRunEveryLaunch"

    static var firstRunEveryLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    @MainActor
    static func applyOnLaunch(_ store: SoulseekStore) {
        guard firstRunEveryLaunch else { return }
        Keychain.delete(for: store.settings.username)
        store.settings = SoulseekSettings()
    }
}

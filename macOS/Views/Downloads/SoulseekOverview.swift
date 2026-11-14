import SwiftUI
import AppKit

// The Soulseek overview (first setup step) and the legal and compliance
// window it links to. Raven is the name of i2s's own Soulseek engine.

struct SoulseekOverview: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RavenPanel(skin: skin)

            HStack(alignment: .top, spacing: 12) {
                LibrarySection(title: "soulseek is", skin: skin, fillsHeight: true) {
                    Point(text: "A network of individual users sharing folders from their own computers", skin: skin)
                    Point(text: "Run by an independent operator, unaffiliated with i2s", skin: skin)
                    Point(text: "A source for adding files to the music on this Mac", skin: skin)
                }
                LibrarySection(title: "soulseek is not", skin: skin, fillsHeight: true) {
                    Point(text: "A streaming, subscription or store service", skin: skin)
                    Point(text: "Operated, reviewed or endorsed by i2s", skin: skin)
                    Point(text: "Anonymous or encrypted", skin: skin)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            LibrarySection(title: "relationship to i2s", skin: skin) {
                Text("Soulseek is an optional source, separate from the player. Completed downloads are ordinary files in the download folder on this Mac; add that folder to the library to play them. Nothing in your library is sent to Soulseek unless its folder is shared.")
                    .font(TypeScale.body).foregroundStyle(skin.textSecondary)
                    .lineSpacing(TypeScale.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LibrarySection(title: "security and privacy", skin: skin) {
                Risk(title: "Your address is visible",
                     text: "The Soulseek server and every user you search, browse or transfer with can see the address you connect from. Through Raven Tunnel, a SOCKS5 proxy or a system VPN, that is the provider's or proxy's address, not your own.",
                     skin: skin)
                Risk(title: "Traffic is not encrypted",
                     text: "Soulseek has no encryption. Searches, file lists, transfers and your password are sent in clear text. Raven Tunnel or a system VPN encrypts traffic between this Mac and the provider; a SOCKS5 proxy alone does not. The Soulseek server always sees your searches. Use a password you use nowhere else.",
                     skin: skin)
                Risk(title: "An open listening port",
                     text: "With incoming connections on, Raven listens on a TCP port (\(store.settings.listenPort) by default) and macOS asks whether to allow it the first time. Forwarding the port on a router exposes it to the internet. Raven only answers Soulseek messages on it, but any open port adds to your network's exposure. Incoming connections can be turned off in the Network step.",
                     skin: skin)
                Risk(title: "Shared folders are public",
                     text: "Any Soulseek user can list and download everything in your shared folders, including file names and folder structure. Share only material you are entitled to distribute, and nothing personal.",
                     skin: skin)
                Risk(title: "Files come from unknown users",
                     text: "Downloads may be mislabelled, incomplete or malicious. i2s only reads downloaded files as audio, but other apps may open them differently. Inspect or scan anything that is not an audio file before opening it.",
                     skin: skin)
                Risk(title: "Your username is public",
                     text: "Usernames are visible to other users alongside your shared files and transfers.",
                     skin: skin)
            }

            LegalLink(skin: skin).padding(.top, 2)
        }
    }
}

/// The type scale for the Soulseek pages: one body size, one caption size,
/// weight for emphasis. Line positions don't depend on the font being
/// monospaced, so every typeface sets the same way.
enum TypeScale {
    static var body: Font { AppFont.ui(12) }
    static var strong: Font { AppFont.ui(12, weight: .medium) }
    static var caption: Font { AppFont.ui(10.5) }
    static let leading: CGFloat = 3
}

private struct Point: View {
    var text: String
    var skin: Skin

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("–").font(TypeScale.body).foregroundStyle(skin.textTertiary)
            Text(text).font(TypeScale.body).foregroundStyle(skin.textSecondary)
                .lineSpacing(TypeScale.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Risk: View {
    var title: String
    var text: String
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(TypeScale.strong).foregroundStyle(skin.textPrimary)
            Text(text).font(TypeScale.body).foregroundStyle(skin.textSecondary)
                .lineSpacing(TypeScale.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
    }
}

/// Raven: what Soulseek is, and how i2s connects to it. Facts only.
private struct RavenPanel: View {
    var skin: Skin

    private let features: [(String, String)] = [
        ("Routing", "Default, Raven Tunnel (WireGuard) or SOCKS5. If the chosen route is unavailable, Raven does not connect."),
        ("DNS", "Encrypted lookups to resolvers you set, inside the tunnel, or by the proxy."),
        ("Exposure", "Incoming connections are optional and the port is configurable. The address the server sees is shown after sign-in."),
        ("Uploads", "Exact files from shared folders only. Every other request is refused."),
        ("Transfers", "Resume from partial files on retry. Partial files are never shared."),
        ("Footprint", "Inactive until enabled. No i2s servers, no analytics. Credentials in the Keychain."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Raven")
                .font(AppFont.ui(44, weight: .bold))
                .foregroundStyle(skin.textPrimary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Soulseek is a peer-to-peer network where people share music directly from their own computers. Raven is the Soulseek client built into i2s, written in Swift: it searches the network, downloads to a folder on this Mac, and shares only the folders you choose.")
                Text("Every connection Raven makes, to the server and to each peer, follows the route set in the next step. Raven Tunnel runs the official WireGuard implementation in user space, for Raven's traffic only.")
            }
            .font(TypeScale.body).foregroundStyle(skin.textSecondary)
            .lineSpacing(TypeScale.leading)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 1) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<3, id: \.self) { col in
                            let f = features[row * 3 + col]
                            VStack(alignment: .leading, spacing: 4) {
                                Text(f.0).font(TypeScale.strong).foregroundStyle(skin.textPrimary)
                                Text(f.1).font(TypeScale.body).foregroundStyle(skin.textSecondary)
                                    .lineSpacing(TypeScale.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Rectangle().fill(skin.textPrimary.opacity(0.035)))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(22)
        .background(Rectangle().fill(skin.textPrimary.opacity(0.03)))
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
        .fuiCorners(skin)
    }
}

/// Typography for long-form text (the legal window): headings by size and
/// weight over the shared body size.
struct DocStyle {
    var skin: Skin

    func title(_ text: String) -> some View {
        Text(text).font(AppFont.ui(26, weight: .bold)).foregroundStyle(skin.textPrimary)
            .padding(.bottom, 8)
    }

    func heading(_ text: String) -> some View {
        Text(text).font(AppFont.ui(15, weight: .bold)).foregroundStyle(skin.textPrimary)
            .padding(.top, 28).padding(.bottom, 8)
    }

    func body(_ text: String) -> some View {
        Text(text).font(TypeScale.body).foregroundStyle(skin.textSecondary)
            .lineSpacing(TypeScale.leading + 1.5).fixedSize(horizontal: false, vertical: true)
    }

    func fine(_ text: String) -> some View {
        Text(text).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small text button that opens the legal and compliance window.
struct LegalLink: View {
    var skin: Skin
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    var body: some View {
        Button { openWindow(id: "soulseek-legal") } label: {
            HStack(spacing: 6) {
                Text("Legal and compliance")
                Glyph("arrow.up.forward", size: 9)
            }
            .font(TypeScale.caption)
            .foregroundStyle(hovering ? skin.textPrimary : skin.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Legal and compliance window

struct SoulseekLegalWindowView: View {
    @ObservedObject private var theme = AppSession.shared.theme
    @ObservedObject private var settings = AppSession.shared.settings

    var body: some View {
        let skin = settings.styled(theme.skin)
        SoulseekLegalView(skin: skin)
            .frame(minWidth: 620, minHeight: 520)
            .glassWindow(skin, minSize: NSSize(width: 620, height: 520), tint: min(0.6, GlassWindow.tint + 0.2))
            .navigationTitle("Legal and Compliance")
            .preferredColorScheme(.dark)
    }
}

struct SoulseekLegalView: View {
    var skin: Skin
    var scrolls = true

    var body: some View {
        content
            .clipShape(Rectangle()).frostedPane(skin, tint: 0.14)
            .padding(.horizontal, Corners.inset)
            .padding(.bottom, Corners.inset)
            .padding(.top, TitleBand.height)
            .overlay(alignment: .top) { WindowDragArea().frame(height: TitleBand.height) }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 12) {
                    if !AppSession.shared.settings.data.systemWindowFrame { WindowControls(skin: skin, closeOnly: true) }
                    Text("legal and compliance").font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                }
                .frame(height: TitleBand.height)
                .padding(.leading, TitleBand.controlsLeading)
            }
    }

    @ViewBuilder
    private var content: some View {
        let doc = DocStyle(skin: skin)
        let body = VStack(alignment: .leading, spacing: 0) {
            doc.title("Legal and compliance")
            doc.fine("Applies to the optional Soulseek source in i2s. Last updated 3 November 2026.")
            ForEach(SoulseekLegal.sections, id: \.title) { section in
                doc.heading(section.title.prefix(1).uppercased() + section.title.dropFirst())
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(section.paragraphs, id: \.self) { doc.body($0) }
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        if scrolls { ScrollView { body } } else { body.frame(maxHeight: .infinity, alignment: .top) }
    }
}

enum SoulseekLegal {
    struct Section { let title: String; let paragraphs: [String] }

    static let sections: [Section] = [
        Section(title: "not legal advice", paragraphs: [
            "This text is general information about using the Soulseek source in i2s. It is not legal advice. Laws differ between countries and change over time; if you are unsure whether an activity is lawful where you live, consult a qualified lawyer.",
        ]),
        Section(title: "no affiliation", paragraphs: [
            "i2s is not affiliated with, endorsed by or sponsored by Soulseek or its operators. Soulseek is a third-party network with its own rules and terms, which apply to your account and your use of the network.",
            "i2s does not operate, host, index, monitor or moderate the Soulseek network or any content on it, and cannot remove, alter or verify that content.",
        ]),
        Section(title: "your responsibility", paragraphs: [
            "You are solely responsible for what you search for, download, keep and share through Soulseek, and for complying with the laws of every jurisdiction that applies to you, including copyright, related rights, licensing and data protection law.",
            "Many recordings, compositions, artwork and other works are protected by copyright. Downloading, copying or making them available to others without the rights holder's permission may be unlawful, even when the files are freely accessible on the network, and may expose you to civil claims, fines or criminal penalties.",
            "Lawful uses include material that is in the public domain, released under a licence that permits sharing, distributed with the rights holder's permission, or otherwise permitted by the law that applies to you.",
        ]),
        Section(title: "shared folders", paragraphs: [
            "Folders you share are made available to every Soulseek user. Sharing a file is a form of distribution. Share only material you have the right to distribute, and never personal or confidential files.",
        ]),
        Section(title: "network and security risks", paragraphs: [
            "Using Soulseek reveals your IP address to the Soulseek server and to other users, sends traffic without encryption, and accepts incoming connections on a listening port. Files received from other users may be mislabelled, damaged or malicious. You accept these risks by enabling the Soulseek source; see the security and privacy section of the Soulseek overview for details.",
        ]),
        Section(title: "no warranty", paragraphs: [
            "The Soulseek source and the Raven engine are provided as is and as available, without warranties of any kind, express or implied, including fitness for a particular purpose, availability, accuracy of search results, and the integrity or legality of any file.",
        ]),
        Section(title: "limitation of liability", paragraphs: [
            "To the maximum extent permitted by law, the developers of i2s are not liable for any loss, damage, claim or penalty arising from your use of the Soulseek source, from content obtained from or shared on the Soulseek network, or from the conduct of other users or of the network's operators.",
        ]),
        Section(title: "rights holders", paragraphs: [
            "i2s does not host or index files and cannot take content down. Notices about material on the Soulseek network should be directed to the user sharing it or to the network's operators.",
        ]),
    ]
}

// MARK: - Network form

/// Route, proxy, incoming connections, DNS and server: everything that decides
/// how Raven reaches the network. Used in setup (before the account step) and
/// on the Downloads account page.
struct NetworkForm: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var proxyUser = ""
    @State private var proxyPassword = ""
    @State private var listenPort = ""
    @State private var serverHost = ""
    @State private var serverPort = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var tunnelMessage: String?

    private var viaProxy: Bool { store.settings.routeMode == .socks5 || store.settings.routeMode == .tunnel }

    private var tunnelStatus: String {
        guard store.tunnelPort != nil else { return store.tunnelError ?? "Starts when Raven connects" }
        guard let shake = RavenTunnel.lastHandshake else { return "Running, no handshake yet" }
        let ago = Int(Date().timeIntervalSince(shake))
        return "Handshake \(ago < 5 ? "just now" : "\(ago) s ago")"
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "conf") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        importText(text)
    }

    private func importText(_ text: String) {
        tunnelMessage = store.importTunnel(text)
        testResult = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LibrarySection(title: "route", skin: skin) {
                VStack(spacing: 6) {
                    RouteOption(selected: store.settings.routeMode == .direct, title: "Default",
                                detail: "Connect from this Mac's own address, through whatever network or system VPN is active.",
                                tag: nil, skin: skin) { set(.direct) }
                    RouteOption(selected: store.settings.routeMode == .tunnel, title: "Raven Tunnel",
                                detail: "A WireGuard tunnel for Raven only. Import a configuration from a VPN provider; the rest of this Mac is unaffected. Traffic is encrypted to the provider and names resolve inside the tunnel.",
                                tag: "wireguard", tagAccent: true, skin: skin) { set(.tunnel) }
                    RouteOption(selected: store.settings.routeMode == .socks5, title: "SOCKS5 proxy",
                                detail: "Send the server connection and every peer connection through a SOCKS5 proxy. Host names are resolved by the proxy.",
                                tag: nil, skin: skin) { set(.socks5) }
                }
            }
            if store.settings.routeMode == .tunnel {
                LibrarySection(title: "tunnel", skin: skin) {
                    if store.settings.tunnelEndpoint.isEmpty {
                        SpecRow(label: "configuration", value: "None imported. Use the .conf file your VPN provider issues for WireGuard.", skin: skin)
                    } else {
                        SpecRow(label: "endpoint", value: store.settings.tunnelEndpoint, skin: skin)
                        SpecRow(label: "address", value: store.settings.tunnelAddress, skin: skin)
                        SpecRow(label: "status", value: tunnelStatus, tag: store.tunnelPort == nil ? "down" : "up",
                                tagAccent: store.tunnelPort != nil, skin: skin)
                        SpecRow(label: "storage", value: "Configuration and private key in the macOS Keychain", skin: skin)
                    }
                    if let tunnelMessage {
                        Text(tunnelMessage).font(TypeScale.caption).foregroundStyle(skin.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Import Configuration…") { importFile() }
                            .buttonStyle(PillButtonStyle(skin: skin, prominent: store.settings.tunnelEndpoint.isEmpty, compact: true))
                        Button("Paste") { importText(NSPasteboard.general.string(forType: .string) ?? "") }
                            .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                        if !store.settings.tunnelEndpoint.isEmpty {
                            Button("Remove") { store.removeTunnel(); tunnelMessage = nil }
                                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                        }
                    }
                    .padding(.top, 6)
                }
            }
            if store.settings.routeMode == .socks5 {
                LibrarySection(title: "proxy", skin: skin) {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            FormField(title: "Host", text: $proxyHost, placeholder: "127.0.0.1", skin: skin)
                            FormField(title: "Port", text: $proxyPort, placeholder: "1080", skin: skin).frame(width: 140)
                        }
                        HStack(spacing: 12) {
                            FormField(title: "Username (optional)", text: $proxyUser, skin: skin)
                            SecureFormField(title: "Password (optional)", text: $proxyPassword, skin: skin)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            LibrarySection(title: "incoming connections", skin: skin) {
                SettingsToggleRow(title: "Accept incoming peer connections",
                                  subtitle: viaProxy ? "Unavailable through a proxy or Raven Tunnel. Peers that also cannot accept connections are unreachable."
                                    : store.settings.acceptIncoming ? "Peers can connect to this Mac on the port below."
                                    : "Outbound connections only, no open port. Peers that also cannot accept connections are unreachable.",
                                  isOn: Binding(get: { store.settings.acceptIncoming && !viaProxy },
                                                set: { store.settings.acceptIncoming = $0 }), skin: skin)
                    .disabled(viaProxy)
                if store.settings.acceptIncoming && !viaProxy {
                    HStack(alignment: .bottom, spacing: 12) {
                        FormField(title: "Listening port (TCP)", text: $listenPort, placeholder: "2234", skin: skin)
                            .frame(width: 180)
                        Button("Random Port") { listenPort = "\(Int.random(in: 49152...65535))"; commit() }
                            .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                        Spacer()
                    }
                    .padding(.top, 6)
                }
            }
            LibrarySection(title: "dns", skin: skin) {
                if store.settings.routeMode == .tunnel {
                    SpecRow(label: "resolution", value: "Inside the tunnel, by the provider's resolver. No lookups are made from this Mac.", skin: skin)
                } else if store.settings.routeMode == .socks5 {
                    SpecRow(label: "resolution", value: "By the proxy. No lookups are made from this Mac.", skin: skin)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        IPv4Field(title: "Preferred DNS server", address: $store.settings.dnsPreferred, skin: skin)
                        IPv4Field(title: "Alternate DNS server", address: $store.settings.dnsAlternate, skin: skin)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    SpecRow(label: "resolution", value: store.settings.dnsServers.isEmpty
                            ? "System resolver. Lookups are visible to your network."
                            : "DNS over TLS on port 853. Lookups are encrypted; both servers must be from the same provider.", skin: skin)
                }
            }
            LibrarySection(title: "server", skin: skin) {
                HStack(spacing: 12) {
                    FormField(title: "Host", text: $serverHost, placeholder: "server.slsknet.org", skin: skin)
                    FormField(title: "Port", text: $serverPort, placeholder: "2242", skin: skin).frame(width: 140)
                }
                .padding(.vertical, 4)
            }
            LibrarySection(title: "exposure", skin: skin) {
                Terminal(rows: exposure, skin: skin)
                HStack(spacing: 10) {
                    Button(testing ? "Testing" : "Test Connection") { test() }
                        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                        .disabled(testing)
                    if let testResult {
                        Text(testResult.text).font(TypeScale.caption).foregroundStyle(testResult.ok ? skin.accent : skin.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            }
        }
        .onAppear(perform: load)
        .onChange(of: proxyHost) { _ in commit() }
        .onChange(of: proxyPort) { _ in commit() }
        .onChange(of: proxyUser) { _ in commit() }
        .onChange(of: proxyPassword) { _ in commit() }
        .onChange(of: listenPort) { _ in commit() }
        .onChange(of: serverHost) { _ in commit() }
        .onChange(of: serverPort) { _ in commit() }
    }

    private func set(_ mode: SlskRoute.Mode) {
        withAnimation(.easeOut(duration: 0.15)) { store.settings.routeMode = mode }
        testResult = nil
    }

    private func load() {
        let s = store.settings
        proxyHost = s.proxyHost
        proxyPort = "\(s.proxyPort)"
        proxyUser = s.proxyUser
        proxyPassword = Keychain.password(for: SoulseekStore.proxyAccount) ?? ""
        listenPort = "\(s.listenPort)"
        serverHost = s.serverHost
        serverPort = "\(s.serverPort)"
    }

    private func commit() {
        var s = store.settings
        s.proxyHost = proxyHost.trimmingCharacters(in: .whitespaces)
        if let p = Int(proxyPort), (1...65535).contains(p) { s.proxyPort = p }
        s.proxyUser = proxyUser
        if let p = Int(listenPort), (1024...65535).contains(p) { s.listenPort = p }
        let host = serverHost.trimmingCharacters(in: .whitespaces)
        s.serverHost = host.isEmpty ? "server.slsknet.org" : host
        if let p = Int(serverPort), (1...65535).contains(p) { s.serverPort = p }
        if s != store.settings { store.settings = s }
        if proxyPassword != (Keychain.password(for: SoulseekStore.proxyAccount) ?? "") { store.setProxyPassword(proxyPassword) }
        testResult = nil
    }

    private func test() {
        commit()
        testing = true
        testResult = nil
        Task { @MainActor in
            let problem = await store.testRoute()
            testing = false
            testResult = problem.map { (false, $0) } ?? (true, "Reached \(store.serverAddress) via \(store.routeLabel).")
        }
    }

    private var exposure: [(String, String)] {
        let s = store.settings
        let source: String
        switch s.routeMode {
        case .direct: source = "This Mac's public address"
        case .socks5: source = "The proxy's address (\(s.proxyHost.isEmpty ? "not set" : s.proxyHost))"
        case .tunnel: source = "The tunnel provider's exit address"
        }
        let dns: String
        switch s.routeMode {
        case .tunnel: dns = "Inside the tunnel"
        case .socks5: dns = "Resolved by the proxy"
        case .direct:
            let servers = Array(NSOrderedSet(array: s.dnsServers)) as? [String] ?? s.dnsServers
            dns = servers.isEmpty ? "System resolver, unencrypted" : "DNS over TLS to " + servers.joined(separator: ", ")
        }
        var rows: [(String, String)] = [
            ("Server sees", source),
            ("Peers see", source),
            ("DNS", dns),
            ("Listening", (s.acceptIncoming && !viaProxy) ? "TCP \(s.listenPort)" : "Off"),
            ("Traffic", s.routeMode == .tunnel ? "WireGuard to the provider, then plain Soulseek" : "Plain Soulseek, unencrypted"),
        ]
        if let seen = store.seenAs { rows.append(("Last seen as", seen + " (reported by the server)")) }
        return rows
    }
}

private struct RouteOption: View {
    var selected: Bool
    var title: String
    var detail: String
    var tag: String?
    var tagAccent = false
    var skin: Skin
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Glyph(selected ? "checkmark.circle.fill" : "circle", size: 11)
                    .foregroundStyle(selected ? skin.accent : skin.textTertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title).font(TypeScale.strong).foregroundStyle(skin.textPrimary)
                        if let tag { LibraryTag(text: tag, skin: skin, accent: tagAccent) }
                    }
                    Text(detail).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(Rectangle().fill(selected ? skin.accent.opacity(0.1) : skin.textPrimary.opacity(0.03)))
            .overlay(Rectangle().strokeBorder(selected ? skin.accent.opacity(0.7) : skin.textPrimary.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Label and value pairs in two aligned columns. Columns come from the
/// layout, not from spaces, so they line up in proportional typefaces too.
struct Terminal: View {
    var rows: [(String, String)]
    var skin: Skin

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(row.0).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                        .gridColumnAlignment(.leading)
                    Text(row.1).font(TypeScale.body).foregroundStyle(skin.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

/// An IPv4 address typed as four octets, like a network control panel.
/// Typing a dot or a third digit moves to the next octet; the arrow keys
/// cross between octets at either end, and Delete in an empty octet goes back.
/// Pasting a whole address fills all four. Empty means "not set".
struct IPv4Field: View {
    var title: String
    @Binding var address: String
    var skin: Skin
    @State private var octets = ["", "", "", ""]
    @FocusState private var focus: Int?
    @State private var keyMonitor: Any?

    private var invalid: Bool {
        octets.contains { !$0.isEmpty } && !SlskRoute.isIPv4(octets.joined(separator: "."))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in
                    if i > 0 {
                        Text(".").font(AppFont.ui(13, weight: .bold)).foregroundStyle(skin.textTertiary)
                            .frame(width: 8)
                    }
                    TextField("", text: octet(i))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(AppFont.ui(12.5))
                        .foregroundStyle(skin.textPrimary)
                        .focused($focus, equals: i)
                        .onSubmit { if i < 3 { focus = i + 1 } else { focus = nil } }
                        .frame(width: 32, height: 22)
                        .background(Rectangle().fill(skin.textPrimary.opacity(focus == i ? 0.06 : 0)))
                }
                Button { set(["", "", "", ""]) } label: { Glyph("xmark.circle.fill", size: 9) }
                    .buttonStyle(.plain)
                    .foregroundStyle(skin.textTertiary)
                    .frame(width: 20)
                    .opacity(octets.contains { !$0.isEmpty } ? 1 : 0)
                    .help("Clear")
            }
            .padding(.leading, 6)
            .frame(height: 30)
            .background(Rectangle().fill(skin.textPrimary.opacity(focus != nil ? 0.07 : 0.045)))
            .overlay(Rectangle().strokeBorder(focus != nil ? skin.accent.opacity(0.8)
                                              : invalid ? skin.textPrimary.opacity(0.45) : skin.textPrimary.opacity(0.12), lineWidth: 1))
            Text(invalid ? "Incomplete address" : " ").font(TypeScale.caption).foregroundStyle(skin.textTertiary)
        }
        .onAppear(perform: load)
        .onChange(of: address) { _ in if octets.joined(separator: ".") != address { load() } }
        .onChange(of: focus) { f in if f == nil { removeMonitor() } else { installMonitor() } }
        .onDisappear(perform: removeMonitor)
    }

    /// Arrow keys at the edge of an octet, and Delete in an empty one.
    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let i = focus, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty else { return event }
            let selection = editor.selectedRange()
            let length = (editor.string as NSString).length
            switch event.keyCode {
            case 123 where selection.length == 0 && selection.location == 0 && i > 0:
                focus = i - 1
                return nil
            case 124 where selection.length == 0 && selection.location == length && i < 3:
                focus = i + 1
                return nil
            case 51 where length == 0 && i > 0:
                focus = i - 1
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func load() {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        octets = (0..<4).map { $0 < parts.count ? parts[$0] : "" }
    }

    private func set(_ next: [String]) {
        octets = next
        address = next.allSatisfy(\.isEmpty) ? "" : next.joined(separator: ".")
    }

    private func octet(_ i: Int) -> Binding<String> {
        Binding(get: { octets[i] }, set: { typed in
            // A whole address pasted into any octet.
            let pieces = typed.split(separator: ".", omittingEmptySubsequences: false)
            if pieces.count == 4, SlskRoute.isIPv4(typed.trimmingCharacters(in: .whitespaces)) {
                set(typed.trimmingCharacters(in: .whitespaces).split(separator: ".").map(String.init))
                focus = nil
                return
            }
            var next = octets
            let digits = String(typed.filter(\.isASCII).filter(\.isNumber).prefix(3))
            next[i] = (Int(digits) ?? 0) > 255 ? "255" : digits
            set(next)
            if i < 3, typed.contains(".") || digits.count == 3 { focus = i + 1 }
        })
    }
}

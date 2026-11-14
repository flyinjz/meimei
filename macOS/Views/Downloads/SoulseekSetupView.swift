import SwiftUI
import AppKit

/// First-run Soulseek configuration, in the Downloads window's own layout: a
/// rail of steps, and the step on the right.
/// Registration happens here; the server creates an account the first time an
/// unused username signs in. Nothing connects before the account step.
struct SoulseekSetupView: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    var onFinish: () -> Void
    /// Off only for offscreen snapshots, whose renderer can't draw scroll views.
    var scrolls = true

    enum Step: Int, CaseIterable {
        case overview, network, account, location, sharing, review
        var label: String {
            switch self {
            case .overview: return "overview"
            case .network: return "network"
            case .account: return "account"
            case .location: return "location"
            case .sharing: return "sharing"
            case .review: return "review"
            }
        }
        var title: String { label.capitalized }
    }

    enum SharingChoice { case downloads, downloadsAndLibrary, nothing }

    @State var step: Step = .overview
    @State private var reached: Step = .overview
    @State private var registering = true
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false
    @State private var sharing: SharingChoice = .downloads

    var body: some View {
        HStack(spacing: Corners.inset) {
            rail
                .frame(width: 196)
                .frostedPane(skin, tint: 0.08)
            VStack(spacing: 0) {
                scrolling {
                    VStack(alignment: .leading, spacing: 14) {
                        content
                    }
                    .padding(24)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(Rectangle()).frostedPane(skin, tint: 0.14)
        }
        .onAppear {
            username = store.settings.username
            registering = store.settings.username.isEmpty
            if step.rawValue > reached.rawValue { reached = step }
        }
    }

    @ViewBuilder
    private func scrolling<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if scrolls { ScrollView { content() } } else { content().frame(maxHeight: .infinity, alignment: .top) }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("setup")
                .font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                .padding(.leading, 8).padding(.top, 4).padding(.bottom, 8)
            ForEach(Step.allCases, id: \.self) { s in
                StepRow(number: s.rawValue + 1, title: s.title, current: s == step,
                        done: s.rawValue < reached.rawValue || (s == .account && isSignedIn),
                        enabled: s.rawValue <= reached.rawValue && !working, skin: skin) { step = s }
            }
            Spacer()
        }
        .padding(10)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d / %02d", step.rawValue + 1, Step.allCases.count))
                .font(TypeScale.caption).foregroundStyle(skin.textTertiary)
            if working { CapsuleProgress(fraction: nil, skin: skin).frame(width: 90, height: 2) }
            Spacer()
            if step != .overview {
                Button("Back") { step = Step(rawValue: step.rawValue - 1)!; error = nil }
                    .buttonStyle(PillButtonStyle(skin: skin))
                    .disabled(working)
            }
            Button(primaryTitle, action: primary)
                .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
                .disabled(!canContinue || working)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var isSignedIn: Bool { store.status == .online && !store.settings.username.isEmpty && store.settings.username == username }

    private var primaryTitle: String {
        switch step {
        case .account: return isSignedIn ? "Continue" : (registering ? "Register" : "Sign In")
        case .review: return "Finish"
        default: return "Continue"
        }
    }

    private var canContinue: Bool {
        guard step == .account, !isSignedIn else { return true }
        let name = username.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !password.isEmpty && (!registering || password == confirm)
    }

    private func advance() {
        error = nil
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        if next.rawValue > reached.rawValue { reached = next }
    }

    private func primary() {
        switch step {
        case .overview:
            store.settings.enabled = true
            advance()
        case .network:
            advance()
        case .account:
            if isSignedIn { advance(); return }
            working = true
            error = nil
            Task { @MainActor in
                let reason = await store.signIn(username: username, password: password, creating: registering)
                working = false
                if let reason { error = reason } else { password = ""; confirm = ""; advance() }
            }
        case .location:
            try? FileManager.default.createDirectory(atPath: store.settings.downloadFolder, withIntermediateDirectories: true)
            advance()
        case .sharing:
            store.settings.shareDownloads = sharing != .nothing
            store.settings.shareLibrary = sharing == .downloadsAndLibrary
            store.rebuildShares()
            advance()
        case .review:
            store.settings.setupComplete = true
            onFinish()
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .overview: overview
        case .network: network
        case .account: account
        case .location: location
        case .sharing: sharingStep
        case .review: review
        }
    }

    private var overview: some View { SoulseekOverview(store: store, skin: skin) }

    private var network: some View {
        Group {
            LibraryHeader(title: "Network",
                          subtitle: "How Raven reaches Soulseek. Set this before signing in; no connection is made until the account step.",
                          skin: skin)
            NetworkForm(store: store, skin: skin)
        }
    }

    private var account: some View {
        Group {
            LibraryHeader(title: "Account", subtitle: "Register a new account or sign in with an existing one.", skin: skin)
            if !isSignedIn {
                ChoiceChips(options: [("Register", nil), ("Sign In", nil)], selected: registering ? 0 : 1, skin: skin) {
                    registering = $0 == 0
                    error = nil
                }
                .disabled(working)
            }
            LibrarySection(title: "credentials", skin: skin) {
                if isSignedIn {
                    HStack(spacing: 10) {
                        Glyph("person.crop.circle", size: 14).foregroundStyle(skin.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.settings.username).font(TypeScale.strong)
                            Text("Signed in to \(store.serverAddress)").font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                        }
                        Spacer()
                        Button("Sign Out") { signOut() }
                            .help("Disconnects and forgets the saved password. Sign in with another account or register a new one.")
                            .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    }
                    .padding(.vertical, 4)
                } else {
                    // Equal columns: two to sign in, three to register.
                    Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            FormField(title: "Username", text: $username, placeholder: "", skin: skin)
                            SecureFormField(title: "Password", text: $password, skin: skin)
                            if registering { SecureFormField(title: "Confirm password", text: $confirm, skin: skin) }
                        }
                    }
                    .padding(.vertical, 4)
                    if registering && !confirm.isEmpty && confirm != password {
                        Text("Passwords do not match.").font(TypeScale.caption).foregroundStyle(skin.accent)
                    }
                }
                if let error {
                    Text(error).font(TypeScale.strong).foregroundStyle(skin.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            LibrarySection(title: "session", skin: skin) {
                SessionLog(lines: store.sessionLog, skin: skin)
            }
            LibrarySection(title: "details", skin: skin) {
                SpecRow(label: "route", value: store.routeLabel, skin: skin)
                SpecRow(label: "registration", value: "Created by the server on first sign-in with an unused username", skin: skin)
                SpecRow(label: "recovery", value: "Passwords cannot be reset", skin: skin)
                SpecRow(label: "storage", value: "macOS Keychain", skin: skin)
            }
        }
    }

    /// Ends the session and forgets the saved password, back to the form.
    private func signOut() {
        store.signOut()
        username = ""
        password = ""
        confirm = ""
        error = nil
        registering = false
    }

    private var location: some View {
        Group {
            LibraryHeader(title: "Location", subtitle: "Completed downloads are saved to this folder.", skin: skin)
            LibrarySection(title: "download folder", skin: skin) {
                HStack(spacing: 12) {
                    Glyph("downloads", size: 13).foregroundStyle(skin.textSecondary)
                    Text((store.settings.downloadFolder as NSString).abbreviatingWithTildeInPath)
                        .font(TypeScale.body).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { if let url = SharingPage.chooseFolder() { store.settings.downloadFolder = url.path } }
                        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                }
                .padding(.vertical, 2)
            }
            LibrarySection(title: "organization", skin: skin) {
                SettingsToggleRow(title: "Preserve remote folder structure",
                                  subtitle: "Each download is saved inside the folder name used by the uploader.",
                                  isOn: $store.settings.keepFolders, skin: skin)
                SpecRow(label: "partial files", value: "Hidden .part files until complete; resumed on retry", skin: skin)
            }
        }
    }

    private var sharingStep: some View {
        Group {
            LibraryHeader(title: "Sharing",
                          subtitle: "Many users upload only to peers who share files. Sharing the download folder is the common configuration.",
                          skin: skin)
            VStack(spacing: 6) {
                option(.downloads, "Download folder", "Completed downloads are shared.", tag: "recommended")
                option(.downloadsAndLibrary, "Download folder and library", "Includes every folder in the i2s library.", tag: nil)
                option(.nothing, "None", "Some users will decline your download requests.", tag: nil)
            }
            LibrarySection(title: "details", skin: skin) {
                SpecRow(label: "visibility", value: "Shared files can be browsed and downloaded by any Soulseek user", skin: skin)
                SpecRow(label: "partial files", value: "Never shared", skin: skin)
                SpecRow(label: "upload slots", value: "\(store.settings.uploadSlots) simultaneous", skin: skin)
            }
        }
    }

    private func option(_ choice: SharingChoice, _ head: String, _ detail: String, tag: String?) -> some View {
        let selected = sharing == choice
        return Button { withAnimation(.easeOut(duration: 0.15)) { sharing = choice } } label: {
            HStack(spacing: 12) {
                Glyph(selected ? "checkmark.circle.fill" : "circle", size: 11)
                    .foregroundStyle(selected ? skin.accent : skin.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(head).font(TypeScale.strong).foregroundStyle(skin.textPrimary)
                        if let tag { LibraryTag(text: tag, skin: skin) }
                    }
                    Text(detail).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
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

    private var review: some View {
        Group {
            LibraryHeader(title: "Review", subtitle: "These settings can be changed later under Account and Sharing.", skin: skin)
            LibrarySection(title: "configuration", skin: skin) {
                SpecRow(label: "account", value: store.settings.username, tag: store.status.label,
                        tagAccent: store.status == .online, skin: skin)
                SpecRow(label: "location", value: (store.settings.downloadFolder as NSString).abbreviatingWithTildeInPath, skin: skin)
                SpecRow(label: "sharing", value: store.settings.sharesNothing ? "None"
                        : (store.indexingShares ? "Indexing" : "\(store.sharedFiles) files in \(store.sharedFolders) folders"), skin: skin)
                SpecRow(label: "listening port", value: "TCP \(store.listeningPort.map(String.init) ?? "\(store.settings.listenPort)")",
                        tag: store.listeningPort == nil ? "not listening" : "listening", tagAccent: store.listeningPort != nil, skin: skin)
            }
        }
    }
}

// MARK: - Parts

private struct StepRow: View {
    var number: Int
    var title: String
    var current: Bool
    var done: Bool
    var enabled: Bool
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(String(format: "%02d", number))
                    .font(AppFont.ui(10.5, weight: .medium))
                    .foregroundStyle(current ? skin.accent : skin.textTertiary)
                Text(title)
                    .font(AppFont.ui(12, weight: current ? .semibold : .regular))
                    .foregroundStyle(current ? skin.textPrimary : enabled ? skin.textSecondary : skin.textTertiary)
                Spacer()
                if done && !current {
                    Glyph("checkmark.circle.fill", size: 9).foregroundStyle(skin.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Rectangle().fill(current ? skin.selection.opacity(0.55) : hovering && enabled ? skin.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// A label / value line, like a specification sheet.
struct SpecRow: View {
    var label: String
    var value: String
    var tag: String? = nil
    var tagAccent = false
    var skin: Skin

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(TypeScale.caption).foregroundStyle(skin.textTertiary).frame(width: 110, alignment: .leading)
            Text(value).font(TypeScale.body).foregroundStyle(skin.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let tag { LibraryTag(text: tag, skin: skin, accent: tagAccent) }
        }
        .padding(.vertical, 4)
    }
}

/// The connection's recent events as plain terminal lines, newest last.
struct SessionLog: View {
    var lines: [SoulseekStore.LogLine]
    var skin: Skin

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            if lines.isEmpty {
                Text("Idle").font(TypeScale.caption).foregroundStyle(skin.textTertiary)
            }
            ForEach(lines.filter { $0.topic == .server }.suffix(10)) { line in
                let parts = Self.split(line.text)
                GridRow(alignment: .firstTextBaseline) {
                    Text(Self.time.string(from: line.time)).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                    Text(parts.event).font(TypeScale.strong).foregroundStyle(color(line.kind))
                    Text(parts.detail).font(TypeScale.body).foregroundStyle(skin.textSecondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .padding(.vertical, 2)
    }

    /// "connect  host:port  via default" → ("connect", "host:port, via default").
    static func split(_ text: String, joiner: String = ", ") -> (event: String, detail: String) {
        let pieces = text.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = pieces.first else { return ("", "") }
        return (first, pieces.dropFirst().joined(separator: joiner))
    }

    private func color(_ kind: SoulseekStore.LogLine.Kind) -> Color {
        switch kind {
        case .info: return skin.textSecondary
        case .ok: return skin.textPrimary
        case .error: return skin.accent
        }
    }
}

/// `FormField` for passwords.
struct SecureFormField: View {
    var title: String
    @Binding var text: String
    var skin: Skin
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
            SecureField("", text: $text)
                .textFieldStyle(.plain)
                .font(AppFont.ui(12.5))
                .foregroundStyle(skin.textPrimary)
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Rectangle().fill(skin.textPrimary.opacity(focused ? 0.07 : 0.045)))
                .overlay(Rectangle().strokeBorder(focused ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.12), lineWidth: 1))
        }
    }
}

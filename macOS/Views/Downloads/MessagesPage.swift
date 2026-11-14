import SwiftUI
import AppKit

// Private messages in the Downloads window: a notice to read first, then
// conversations on the left and the open one on the right.

struct MessagesPage: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    var scrolls: Bool
    var onBrowse: (String) -> Void
    @State private var newUser = ""
    @State private var readingNotice = false

    var body: some View {
        Group {
            if !store.settings.messagesAcknowledged || readingNotice {
                scroll {
                    MessagesNotice(skin: skin, accepted: store.settings.messagesAcknowledged) {
                        store.settings.messagesAcknowledged = true
                        withAnimation(.easeOut(duration: 0.16)) { readingNotice = false }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 232)
                        .background(skin.textPrimary.opacity(0.025))
                    thread.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            store.messagesVisible = true
            if store.openConversation == nil { store.openConversation = store.conversations.first?.user }
            if let u = store.openConversation { store.markRead(u) }
        }
        .onDisappear { store.messagesVisible = false }
        .onChange(of: store.openConversation) { u in if let u { store.markRead(u) } }
        .onChange(of: store.unreadMessages) { _ in if let u = store.openConversation { store.markRead(u) } }
    }

    @ViewBuilder
    private func scroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        let body = content().padding(24).frame(maxWidth: .infinity, alignment: .leading)
        if scrolls { ScrollView { body } } else { body.frame(maxHeight: .infinity, alignment: .top) }
    }

    // MARK: Conversations

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Messages").font(AppFont.ui(15, weight: .bold)).foregroundStyle(skin.textPrimary)
                Text(subtitle).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            NewConversationField(text: $newUser, skin: skin) {
                store.startConversation(with: newUser)
                newUser = ""
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 8)
            let rows = VStack(spacing: 1) {
                ForEach(store.conversations) { c in
                    ConversationRow(conversation: c, selected: c.user == store.openConversation,
                                    starred: store.isStarred(c.user), ignored: store.isIgnored(c.user), skin: skin) {
                        store.openConversation = c.user
                    }
                    .appContextMenu { menu(for: c.user) }
                }
            }
            if scrolls { ScrollView { rows } } else { rows }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Glyph("shield.alert", size: 10)
                Text("Not encrypted").lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                TextAction(title: "Notice", skin: skin) { withAnimation(.easeOut(duration: 0.16)) { readingNotice = true } }
            }
            .font(TypeScale.caption)
            .foregroundStyle(skin.textTertiary)
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
    }

    private var subtitle: String {
        let n = store.conversations.count
        let unread = store.unreadMessages
        if n == 0 { return "No conversations" }
        return "\(n) conversation\(n == 1 ? "" : "s")" + (unread > 0 ? " · \(unread) unread" : "")
    }

    private func menu(for user: String) -> MenuContent {
        MenuContent(title: user, entries: [
            .action("Browse Their Files", glyph: "folder.badge.plus") { onBrowse(user) },
            .action(store.isStarred(user) ? "Unstar User" : "Star User", glyph: store.isStarred(user) ? "star" : "star.fill") { store.toggleStar(user) },
            .action(store.isIgnored(user) ? "Stop Ignoring" : "Ignore User", glyph: "person.blocked") { store.toggleIgnore(user) },
            .action("Close Conversation", glyph: "window.close") { store.closeConversation(user) },
        ])
    }

    // MARK: Thread

    @ViewBuilder
    private var thread: some View {
        if let user = store.openConversation, let c = store.conversations.first(where: { $0.user == user }) {
            ThreadView(store: store, conversation: c, skin: skin, scrolls: scrolls, onBrowse: { onBrowse(user) })
                .id(user)
        } else {
            VStack(spacing: 8) {
                Glyph("messages", size: 22).foregroundStyle(skin.textTertiary)
                Text("No conversation open").font(TypeScale.strong).foregroundStyle(skin.textSecondary)
                Text("Messages other users send you appear on the left. To write to someone, type their username there.")
                    .font(TypeScale.body).foregroundStyle(skin.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(TypeScale.leading)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Notice

/// What to know before using private messages. Short enough to read in
/// one go; shown until accepted, and again from the page's footer.
struct MessagesNotice: View {
    var skin: Skin
    var accepted: Bool
    var onAccept: () -> Void

    private let points: [(glyph: String, title: String, text: String)] = [
        ("notice.unlocked", "Not private",
         "Messages reach the other person through the Soulseek server in plain text. Its operators can read them."),
        ("notice.identity", "Names prove nothing",
         "Anyone can take any username. Someone may pose as a friend, an artist or staff."),
        ("notice.links", "Guard your details",
         "Never share passwords, payment or personal information. i2s never opens links."),
        ("notice.sent", "No unsend",
         "A sent message can't be recalled. If they're offline, they get it when they return."),
        ("notice.ephemeral", "Gone when you quit",
         "Conversations live in memory only. Ignore anyone to drop their messages quietly."),
        ("notice.responsibility", "Yours to answer for",
         "What you send, and what you agree to share, is on you, including the law where you live."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Before you message anyone")
                    .font(AppFont.ui(20, weight: .bold))
                    .foregroundStyle(skin.textPrimary)
                Text("Messages put you in touch with real people. That is the point, and it is also the risk. Please take a minute with these first.")
                    .font(TypeScale.body).foregroundStyle(skin.textSecondary)
                    .lineSpacing(TypeScale.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 18) {
                ForEach(0..<(points.count + 1) / 2, id: \.self) { row in
                    GridRow(alignment: .top) {
                        point(points[row * 2])
                        if row * 2 + 1 < points.count { point(points[row * 2 + 1]) }
                    }
                }
            }
            HStack(spacing: 16) {
                Button(accepted ? "Back to Messages" : "Continue", action: onAccept)
                    .buttonStyle(PillButtonStyle(skin: skin, prominent: true, compact: true))
                LegalLink(skin: skin)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func point(_ p: (glyph: String, title: String, text: String)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Glyph(p.glyph, size: 16).foregroundStyle(skin.textSecondary)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(TypeScale.strong).foregroundStyle(skin.textPrimary)
                Text(p.text).font(TypeScale.caption).foregroundStyle(skin.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pieces

private struct NewConversationField: View {
    @Binding var text: String
    var skin: Skin
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Glyph("message.plus", size: 11).foregroundStyle(focused ? skin.textPrimary : skin.textTertiary)
            TextField("Message a user", text: $text)
                .textFieldStyle(.plain)
                .font(TypeScale.body)
                .foregroundStyle(skin.textPrimary)
                .focused($focused)
                .onSubmit { if !text.trimmingCharacters(in: .whitespaces).isEmpty { onSubmit() } }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Rectangle().fill(skin.textPrimary.opacity(focused ? 0.07 : 0.04)))
        .overlay(Rectangle().strokeBorder(focused ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.1), lineWidth: 1))
        .help("Type a username and press Return")
    }
}

private struct ConversationRow: View {
    var conversation: SoulseekStore.Conversation
    var selected: Bool
    var starred: Bool
    var ignored: Bool
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if starred { Glyph("star.fill", size: 8).foregroundStyle(skin.textSecondary) }
                        Text(conversation.user)
                            .font(conversation.unread > 0 || selected ? TypeScale.strong : TypeScale.body)
                            .foregroundStyle(ignored ? skin.textTertiary : skin.textPrimary)
                            .strikethrough(ignored, color: skin.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(MessageTime.short(conversation.last)).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                    }
                    Text(preview).font(TypeScale.caption)
                        .foregroundStyle(conversation.unread > 0 ? skin.textSecondary : skin.textTertiary)
                        .lineLimit(1)
                }
                if conversation.unread > 0 {
                    Text("\(conversation.unread)").font(AppFont.ui(10.5, weight: .bold)).foregroundStyle(skin.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(skin.textPrimary.opacity(selected ? 0.09 : hovering ? 0.04 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var preview: String {
        guard let m = conversation.messages.last else { return "No messages yet" }
        return (m.incoming ? "" : "You: ") + m.text.replacingOccurrences(of: "\n", with: " ")
    }
}

/// One conversation: who, the messages, and a field to reply.
private struct ThreadView: View {
    @ObservedObject var store: SoulseekStore
    var conversation: SoulseekStore.Conversation
    var skin: Skin
    var scrolls: Bool
    var onBrowse: () -> Void
    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var user: String { conversation.user }
    private var ignored: Bool { store.isIgnored(user) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            transcript
            composer
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(user).font(AppFont.ui(15, weight: .bold)).foregroundStyle(skin.textPrimary).lineLimit(1)
                Text(ignored ? "Ignored. Their messages are dropped." : "\(conversation.messages.count) message\(conversation.messages.count == 1 ? "" : "s")")
                    .font(TypeScale.caption).foregroundStyle(skin.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            TextAction(title: "Browse Files", skin: skin, action: onBrowse)
            TextAction(title: store.isStarred(user) ? "Unstar" : "Star", skin: skin) { store.toggleStar(user) }
            TextAction(title: ignored ? "Stop Ignoring" : "Ignore", skin: skin) { store.toggleIgnore(user) }
            TextAction(title: "Close", skin: skin) { store.closeConversation(user) }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var blocks: [[SoulseekStore.Message]] {
        // Consecutive messages from one side, a few minutes apart, read as one block.
        var out: [[SoulseekStore.Message]] = []
        for m in conversation.messages {
            if let last = out.last?.last, last.incoming == m.incoming, m.time.timeIntervalSince(last.time) < 300 {
                out[out.count - 1].append(m)
            } else {
                out.append([m])
            }
        }
        return out
    }

    @ViewBuilder
    private var transcript: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            if conversation.messages.isEmpty {
                Text("No messages yet. Anything you send goes to \(user) through the Soulseek server, in plain text.")
                    .font(TypeScale.body).foregroundStyle(skin.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(blocks, id: \.first!.id) { block in
                MessageBlock(messages: block, user: user, skin: skin)
            }
            Color.clear.frame(height: 1).id("end")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView { content }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: conversation.messages.count) { _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
            }
        } else {
            content.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ignored {
                HStack {
                    Text("You are ignoring \(user).").font(TypeScale.body).foregroundStyle(skin.textSecondary)
                    TextAction(title: "Stop Ignoring", skin: skin) { store.toggleIgnore(user) }
                }
                .frame(height: 34)
            } else {
                HStack(spacing: 10) {
                    TextField("Message \(user)", text: $draft)
                        .textFieldStyle(.plain)
                        .font(TypeScale.body)
                        .foregroundStyle(skin.textPrimary)
                        .focused($focused)
                        .onSubmit(send)
                    Button(action: send) {
                        Glyph("send", size: 12).frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? skin.textTertiary : skin.textPrimary)
                    .help("Send")
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .frame(height: 36)
                .background(Rectangle().fill(skin.textPrimary.opacity(focused ? 0.07 : 0.045)))
                .overlay(Rectangle().strokeBorder(focused ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.12), lineWidth: 1))
            }
            Text(problem ?? (store.status == .online ? "Plain text, through the Soulseek server. Return to send." : "Not connected. Messages can't be sent."))
                .font(TypeScale.caption)
                .foregroundStyle(problem == nil ? skin.textTertiary : skin.textPrimary)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .padding(.top, 6)
    }

    private func send() {
        if let p = store.sendMessage(draft, to: user) {
            problem = p.isEmpty ? nil : p
            return
        }
        draft = ""
        problem = nil
    }
}

private struct MessageBlock: View {
    var messages: [SoulseekStore.Message]
    var user: String
    var skin: Skin

    var body: some View {
        let incoming = messages.first?.incoming ?? true
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(incoming ? user : "You").font(TypeScale.strong)
                    .foregroundStyle(incoming ? skin.textPrimary : skin.textSecondary)
                Text(MessageTime.long(messages.first?.time ?? Date())).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
            }
            ForEach(messages) { m in
                Text(verbatim: m.text)
                    .font(TypeScale.body)
                    .foregroundStyle(incoming ? skin.textPrimary : skin.textSecondary)
                    .lineSpacing(TypeScale.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .padding(.leading, incoming ? 0 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MessageTime {
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()

    /// "14:02" today, else "3 Nov".
    static func short(_ d: Date) -> String {
        guard d > .distantPast else { return "" }
        return Calendar.current.isDateInToday(d) ? clock.string(from: d) : day.string(from: d)
    }

    /// "14:02" today, else "3 Nov 14:02".
    static func long(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? clock.string(from: d) : day.string(from: d) + " " + clock.string(from: d)
    }
}

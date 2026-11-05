import AppKit
import HermesGatewayKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var avatars = AvatarStore.shared
    @Namespace private var selectionSpace
    @FocusState private var focused: Bool
    @Environment(\.motionEnabled) private var motion

    private var order: [SidebarItem] { model.rooms.map { .room($0.roomId) } + model.bots.map { .bot($0.name) } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s0) {
                    sectionHeader("Group Chats") {
                        IconButton(symbol: "plus", label: "New group chat") { model.showCreateRoom = true }
                            .disabled(model.backend == nil || model.bots.count < 2 || !model.groupsAvailable)
                    }
                    if !model.groupsAvailable {
                        Text("Group Chat needs Hermes Agent v2026.9.14 or later.")
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    } else if model.rooms.isEmpty {
                        Text(model.phase.isConnected ? "No group chats yet" : "Not loaded yet")
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    }
                    ForEach(model.rooms) { room in
                        row(.room(room.roomId)) { roomRow(room) }
                    }
                    sectionHeader("Bots") { EmptyView() }
                    if model.bots.isEmpty {
                        Text(model.phase.isConnected ? "No profiles found" : "Not loaded yet")
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    }
                    ForEach(model.bots) { bot in
                        row(.bot(bot.name)) { botRow(bot) }
                    }
                }
                .padding(.horizontal, DS.Space.s2).padding(.bottom, DS.Space.s3)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onMoveCommand(perform: move)
            Hairline()
            footer
        }
    }

    private func sectionHeader<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title).font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted)
            Spacer()
            trailing()
        }
        .frame(minHeight: DS.Size.sectionHeader)
        .padding(.horizontal, DS.Space.s2).padding(.top, DS.Space.s3).padding(.bottom, DS.Space.s0)
        .accessibilityAddTraits(.isHeader)
    }

    private func row<Content: View>(_ item: SidebarItem, @ViewBuilder content: () -> Content) -> some View {
        Button { select(item) } label: {
            content()
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .frame(maxWidth: .infinity, minHeight: DS.Size.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(selected: model.selection == item, keyboardFocus: focused, space: selectionSpace))
        .accessibilityAddTraits(model.selection == item ? .isSelected : [])
    }

    private func roomRow(_ room: RoomSummary) -> some View {
        HStack(spacing: DS.Space.gutter) {
            RoomAvatarStack(identities: room.members.map { avatars.identity(profile: $0.profile, title: $0.title) })
            VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                Text(room.name).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink).lineLimit(1)
                Text("\(room.members.count) bots · " + room.members.map { "@\($0.handle)" }.joined(separator: " "))
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let m = model.roomModels[room.roomId] { RoomLiveDot(model: m) }
        }
    }

    private func botRow(_ bot: Bot) -> some View {
        HStack(spacing: DS.Space.gutter) {
            AvatarView(identity: avatars.identity(profile: bot.name, title: bot.title))
            VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                HStack(spacing: DS.Space.s2) {
                    Text(bot.title).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    if bot.isDefault && bot.title.lowercased() != "default" { DefaultTag() }
                }
                if let sub = bot.model ?? bot.description {
                    Text(sub).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                }
            }
        }
    }

    /// Connection footer: dot + the backend in two or three words (fits the 220 pt minimum sidebar
    /// without truncating); the full mode text is the tooltip.
    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            switch model.phase {
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            case .failed:
                StatusDot(color: DS.Palette.danger)
                Text("Not connected")
            case .connected:
                StatusDot(color: DS.Palette.statusOK)
                Text(connectionLabel)
            }
            Spacer(minLength: 0)
        }
        .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
        .lineLimit(1)
        .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.gutter)
        .help(model.modeText)
        .accessibilityElement(children: .combine)
    }

    private var connectionLabel: String {
        switch model.backend?.mode {
        case .attached(let a)?: return a.role == .desktopServe ? "Hermes Desktop" : "hermes serve"
        case .spawned?: return "Private hermes serve"
        case nil: return "Connected"
        }
    }

    private func select(_ item: SidebarItem) {
        withDSAnimation(motion) { model.selection = item }
    }

    /// Up/down arrows move the selection through rooms then bots (the sidebar is focusable).
    private func move(_ direction: MoveCommandDirection) {
        let items = order
        guard !items.isEmpty else { return }
        let i = model.selection.flatMap { items.firstIndex(of: $0) }
        switch direction {
        case .up: select(items[max(0, (i ?? items.count) - 1)])
        case .down: select(items[min(items.count - 1, (i ?? -1) + 1)])
        default: break
        }
    }
}

/// `sidebar-row`: hover tint; the selection background is one shape that slides between rows.
/// While the sidebar has keyboard focus (arrow keys move the selection) the selected row carries the
/// focus ring instead of the whole column.
struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    var keyboardFocus = false
    let space: Namespace.ID
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(DS.Palette.selected)
                            .overlay {
                                // System focus colour: keyboard focus follows the user's macOS setting.
                                if keyboardFocus {
                                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: DS.Stroke.keyboardFocus)
                                }
                            }
                            .matchedGeometryEffect(id: "sidebar.selection", in: space)
                    } else if hovering || configuration.isPressed {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.hover)
                    }
                }
        }
    }
}

/// Breathing dot on a room whose round is running.
struct RoomLiveDot: View {
    @ObservedObject var model: RoomModel
    var body: some View {
        if model.active {
            StatusDot(color: DS.Palette.primary, live: true)
                .help("A round is running")
                .accessibilityLabel("Round running")
        }
    }
}

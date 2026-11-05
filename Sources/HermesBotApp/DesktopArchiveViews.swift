import AppKit
import HermesGatewayKit
import SwiftUI

// E4 / D17 views: the File menu command, the import sheet, the sidebar's "Desktop archive" section and the
// read-only archive pane. Logic and copy helpers: DesktopArchiveModel.swift.

/// File → Import from Hermes Desktop…
struct DesktopImportCommand: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button("Import from Hermes Desktop…") { model.openDesktopImport() }
            .disabled(model.showDesktopImport)
    }
}

// MARK: - import sheet

struct DesktopImportView: View {
    @ObservedObject var archive: DesktopArchiveModel
    let onImport: ([DesktopArchiveRoom]) -> String?
    let onRetry: () -> Void
    let onClose: () -> Void
    @State private var picked: Set<String> = []
    @State private var seeded = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Import from Hermes Desktop").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            Text("Group chats Hermes Desktop saved to your default profile. They are copied into this app as a read-only archive; nothing in Hermes or Hermes Desktop changes.")
                .font(DS.Typeface.body).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            listing
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
            }
            HStack(spacing: DS.Space.s2) {
                Text("Hermes Desktop keeps the last \(DesktopGroupArchive.maxMessages) messages of each room here.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    error = onImport(chosen)
                    if error == nil { onClose() }
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .onChange(of: archive.listing) { _, listing in seed(listing) }
        .onAppear { seed(archive.listing) }
    }

    private var available: [DesktopArchiveRoom] {
        if case .loaded(let rooms) = archive.listing { return rooms }
        return []
    }

    private var chosen: [DesktopArchiveRoom] { available.filter { picked.contains($0.id) } }

    /// Rooms not imported yet start ticked.
    private func seed(_ listing: DesktopArchiveModel.Listing) {
        guard !seeded, case .loaded(let rooms) = listing else { return }
        seeded = true
        picked = Set(rooms.filter { !archive.isImported($0.id) }.map(\.id))
    }

    @ViewBuilder private var listing: some View {
        switch archive.listing {
        case .idle, .loading:
            HStack(spacing: DS.Space.s2) {
                ProgressView().controlSize(.small)
                Text("Reading Hermes Desktop's group chats…").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
            .frame(maxWidth: .infinity, minHeight: Self.listMinHeight)
        case .failed(let message):
            VStack(spacing: DS.Space.s2) {
                Text(message).font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                Button("Try Again", action: onRetry).buttonStyle(DSButtonStyle(kind: .secondary))
            }
            .frame(maxWidth: .infinity, minHeight: Self.listMinHeight)
        case .loaded(let rooms) where rooms.isEmpty:
            Text("No saved group chats found. Hermes Desktop saves its group chats to the default profile of the Hermes it is connected to.")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: Self.listMinHeight)
        case .loaded(let rooms):
            ScrollView {
                VStack(spacing: DS.Space.s2) {
                    ForEach(rooms) { room in roomToggle(room) }
                }
            }
            .frame(maxHeight: Self.listMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let listMinHeight: CGFloat = 96
    static let listMaxHeight: CGFloat = 320

    private func roomToggle(_ room: DesktopArchiveRoom) -> some View {
        let on = picked.contains(room.id)
        return Toggle(isOn: Binding(get: { on }, set: { if $0 { picked.insert(room.id) } else { picked.remove(room.id) } })) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.s2) {
                    Text(room.name).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    if archive.isImported(room.id) { DefaultTag(text: "Imported") }
                }
                Text(DesktopArchivePresentation.summary(room) + (room.lastAt.map { " · " + RoomDigest.age(of: $0.timeIntervalSince1970, now: Date()) } ?? ""))
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, DS.Space.s2).frame(maxWidth: .infinity, minHeight: DS.Size.memberToggleHeight, alignment: .leading)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(on ? DS.Palette.ring : DS.Palette.hairline, lineWidth: on ? DS.Stroke.selectedToggle : DS.Stroke.hairline))
    }
}

// MARK: - sidebar section

/// "Desktop archive": collapsible, below Boards, absent while the archive is empty.
struct DesktopArchiveSection: View {
    @ObservedObject var archive: DesktopArchiveModel
    let query: String
    let selection: SidebarItem?
    let keyboardFocus: Bool
    let space: Namespace.ID
    let onSelect: (SidebarItem) -> Void
    let onContinue: (DesktopArchiveRoom) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        if !archive.rooms.isEmpty {
            let rows = archive.sidebarRooms(query: query)
            let filtering = SidebarFilter.isActive(query)
            if !filtering || !rows.isEmpty {
                header(open: archive.expanded || filtering, filtering: filtering)
                ForEach(rows) { room in rowButton(room) }
            }
        }
    }

    private func header(open: Bool, filtering: Bool) -> some View {
        Button { archive.expanded.toggle() } label: {
            HStack(spacing: DS.Space.s1) {
                Text("Desktop archive").font(DS.Typeface.captionStrong)
                Image(systemName: open ? "chevron.down" : "chevron.right").font(DS.Typeface.iconSmall)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DS.Palette.muted)
            .frame(minHeight: DS.Size.sectionHeader)
            .padding(.horizontal, DS.Space.s2).padding(.top, DS.Space.s3).padding(.bottom, DS.Space.s0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(filtering)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Desktop archive, \(archive.rooms.count)")
        .accessibilityValue(open ? "expanded" : "collapsed")
        .help("Group chats imported read-only from Hermes Desktop")
    }

    private func rowButton(_ room: DesktopArchiveRoom) -> some View {
        let item = SidebarItem.archive(room.id)
        return Button { onSelect(item) } label: {
            HStack(spacing: DS.Space.gutter) {
                Image(systemName: "archivebox")
                    .font(DS.Typeface.icon).foregroundStyle(DS.Palette.muted)
                    .frame(width: DS.Size.avatarRow, height: DS.Size.avatarRow)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.avatar, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.avatar, style: .continuous)
                        .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
                VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                    Text(room.name).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    Text(DesktopArchivePresentation.summary(room)).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
            .frame(maxWidth: .infinity, minHeight: DS.Size.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(selected: selection == item, keyboardFocus: keyboardFocus, space: space))
        .accessibilityAddTraits(selection == item ? .isSelected : [])
        .contextMenu {
            Button("Open") { onSelect(item) }
            Button("Continue in a New Room…") { onContinue(room) }
            Divider()
            Button("Remove from Archive", role: .destructive) { onRemove(room.id) }
        }
    }
}

// MARK: - archive pane

/// One archived room, read-only: its members, the saved messages, and the two things to do with it.
struct DesktopArchiveRoomView: View {
    let room: DesktopArchiveRoom
    let bots: [Bot]
    let canContinue: Bool
    let onContinue: () -> Void
    let onRemove: () -> Void
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.s4) {
                    header
                    ForEach(room.messages) { message in messageRow(message) }
                }
                .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
                .padding(DS.Space.s5)
                .frame(maxWidth: .infinity)
            }
            Hairline()
            footer
        }
        .navigationTitle(room.name)
        .navigationSubtitle("Desktop archive")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "archivebox").font(DS.Typeface.iconSmall).accessibilityHidden(true)
                Text("Read-only copy from Hermes Desktop").font(DS.Typeface.caption)
            }
            .foregroundStyle(DS.Palette.muted)
            if !room.members.isEmpty {
                HStack(spacing: DS.Space.s2) {
                    ForEach(room.members, id: \.name) { member in
                        HStack(spacing: DS.Space.s1) {
                            AvatarView(identity: avatars.identity(profile: member.name, title: memberTitle(member)),
                                       size: DS.Size.avatarChip)
                            Text(memberTitle(member)).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink).lineLimit(1)
                        }
                    }
                }
            }
            if room.omitted > 0 {
                Text(room.omitted == 1 ? "1 earlier message was not saved by Hermes Desktop."
                                       : "\(room.omitted) earlier messages were not saved by Hermes Desktop.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
            Hairline().padding(.top, DS.Space.s1)
        }
    }

    private func memberTitle(_ member: DesktopArchiveMember) -> String {
        bots.first { $0.name == member.name }?.title ?? member.handle ?? member.name
    }

    private func messageRow(_ m: DesktopArchiveMessage) -> some View {
        HStack(alignment: .top, spacing: DS.Space.gutter) {
            if m.fromUser {
                Image(systemName: "person.crop.circle").font(.system(size: DS.Size.avatarMessage * 0.8))
                    .foregroundStyle(DS.Palette.muted).frame(width: DS.Size.avatarMessage, height: DS.Size.avatarMessage)
                    .accessibilityHidden(true)
            } else {
                AvatarView(identity: avatars.identity(profile: profile(for: m), title: m.author), size: DS.Size.avatarMessage)
            }
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                HStack(spacing: DS.Space.s2) {
                    Text(m.author).font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    if let at = m.at {
                        Text(at.formatted(date: .abbreviated, time: .shortened))
                            .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    }
                    if let thread = m.thread, thread != RoomThreads.main, thread != "legacy" {
                        DefaultTag(text: "in a thread")
                    }
                }
                MessageBody(text: m.text).textSelection(.enabled)
                if m.truncated {
                    Text("Shortened by Hermes Desktop when it saved the room.")
                        .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The member whose name or handle matches the author, so the avatar matches the bot's own.
    private func profile(for m: DesktopArchiveMessage) -> String {
        room.members.first { $0.name == m.author || $0.handle == m.author }?.name ?? m.author
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            Text(canContinue ? "Archived messages can't be answered here. Continue in a new room to pick up the conversation."
                             : "Archived messages can't be answered here. A new room needs two of its bots on this Hermes.")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s2)
            Button("Remove from Archive", action: onRemove).buttonStyle(DSButtonStyle(kind: .secondary))
            Button("Continue in a New Room…", action: onContinue)
                .buttonStyle(DSButtonStyle(kind: .primary))
                .disabled(!canContinue)
        }
        .padding(.horizontal, DS.Space.s5).padding(.vertical, DS.Space.s3)
    }
}

import HermesGatewayKit
import SwiftUI

/// The sidebar's "Boards" section body: one row per non-archived board, or one muted line for the
/// loading / off / empty states. Rows are drawn by `row` (SidebarView's row style and selection).
struct KanbanSidebarRows<Row: View>: View {
    @ObservedObject var hub: KanbanHub
    let connected: Bool
    @ViewBuilder let row: (KanbanSidebarRow) -> Row

    var body: some View {
        let rows = hub.rows
        if let text = KanbanHub.sidebarPlaceholder(connected: connected, availability: hub.availability, rows: rows.count) {
            Text(text)
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .help(hub.availability == .off ? "Enable the kanban plugin in Hermes to see boards here." : "")
        }
        ForEach(rows) { r in row(r) }
    }
}

/// A board row: board tile, name, task count, and badges for running (breathing dot + count) and blocked
/// (attention count: the worker is waiting on a person).
struct KanbanBoardRowContent: View {
    let row: KanbanSidebarRow

    static func subtitle(_ row: KanbanSidebarRow) -> String { row.total == 1 ? "1 task" : "\(row.total) tasks" }

    static func accessibilityLabel(_ row: KanbanSidebarRow) -> String {
        var parts = [row.name, subtitle(row)]
        if row.running > 0 { parts.append("\(row.running) running") }
        if row.blocked > 0 { parts.append("\(row.blocked) blocked") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: DS.Space.gutter) {
            Image(systemName: "rectangle.split.3x1")
                .font(DS.Typeface.icon).foregroundStyle(DS.Palette.muted)
                .frame(width: DS.Size.avatarRow, height: DS.Size.avatarRow)
                .background(DS.Palette.selected, in: RoundedRectangle(cornerRadius: DS.Radius.avatar, style: .continuous))
            VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                Text(row.name).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink).lineLimit(1)
                Text(Self.subtitle(row)).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if row.running > 0 {
                HStack(spacing: DS.Space.s1) {
                    StatusDot(color: DS.Palette.primary, live: true)
                    Text("\(row.running)").font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted).monospacedDigit()
                }
                .help(row.running == 1 ? "1 card running" : "\(row.running) cards running")
            }
            if row.blocked > 0 {
                Text("\(row.blocked)")
                    .font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.ink).monospacedDigit()
                    .padding(.horizontal, DS.Space.s1 + DS.Space.s0).padding(.vertical, DS.Space.s0 / 2)
                    .background(DS.Palette.attentionSoft, in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.Palette.attentionRing, lineWidth: DS.Stroke.hairline))
                    .help(row.blocked == 1 ? "1 card blocked" : "\(row.blocked) cards blocked")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(row))
    }
}

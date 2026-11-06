import AppKit
import SwiftUI

/// A short flipped document needs a negative visible origin to put its last row at the viewport's
/// bottom. Native scrolling continues to constrain long documents normally.
@MainActor
private final class TranscriptBottomClipView: NSClipView {
    var contentHeight: CGFloat?
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        if let documentView, documentView.isFlipped,
           let height = contentHeight, height < constrained.height {
            constrained.origin.y = documentView.frame.minY + height - constrained.height
        }
        return constrained
    }
}

/// The native table is the only owner of transcript geometry. SwiftUI supplies individual rows, never
/// a document containing thousands of eagerly hosted messages.
@MainActor
final class TranscriptTableScrollView: NSScrollView {
    let tracker: TranscriptScrollTracker
    let tableView = NSTableView()
    var viewportChanged: (() -> Void)?
    private var previousViewport = CGSize.zero

    private(set) var createdCellCount = 0
    private(set) var configuredCellCount = 0
    private(set) var measuredCellCount = 0

    init(tracker: TranscriptScrollTracker) {
        self.tracker = tracker
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        contentView = TranscriptBottomClipView()
        contentView.drawsBackground = false
        setAccessibilityIdentifier("herald.transcript.table")
        contentView.postsBoundsChangedNotifications = true
        documentView = tableView
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = contentView.bounds.size
        if previousViewport != size {
            previousViewport = size
            viewportChanged?()
        }
    }

    func countedCreation() { createdCellCount += 1 }
    func countedConfiguration() { configuredCellCount += 1 }
    func countedMeasurement() { measuredCellCount += 1 }
}

struct TranscriptTable<Data: RandomAccessCollection, Row: View>: NSViewRepresentable
where Data.Index == Int, Data.Element: Identifiable {
    let items: Data
    let revision: AnyHashable
    var structureRevision: AnyHashable?
    let tracker: TranscriptScrollTracker
    let onFollowChange: (Bool) -> Void
    let sameContent: (Data.Element, Data.Element) -> Bool
    let row: (Data.Element) -> Row

    init(items: Data, revision: AnyHashable, structureRevision: AnyHashable? = nil,
         tracker: TranscriptScrollTracker, onFollowChange: @escaping (Bool) -> Void,
         sameContent: @escaping (Data.Element, Data.Element) -> Bool,
         @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.items = items
        self.revision = revision
        self.structureRevision = structureRevision
        self.tracker = tracker
        self.onFollowChange = onFollowChange
        self.sameContent = sameContent
        self.row = row
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> TranscriptTableScrollView {
        let view = TranscriptTableScrollView(tracker: tracker)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: TranscriptTableScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ view: TranscriptTableScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        typealias Item = Data.Element
        typealias ID = Item.ID

        private struct Anchor {
            let id: ID
            let offset: CGFloat
        }

        private struct Height {
            let width: CGFloat
            let value: CGFloat
            let stamp: Int
        }

        private var parent: TranscriptTable
        private weak var scroll: TranscriptTableScrollView?
        private var ids: [ID] = []
        private var indexes: [ID: Int] = [:]
        private var heights: [ID: Height] = [:]
        private var heightOrder: [(ID, Int)] = []
        private var oldestHeight = 0
        private var heightStamp = 0
        private var readingAnchor: Anchor?
        private var tokens: [NSObjectProtocol] = []
        private var appliedRevision: AnyHashable?
        private var appliedStructure: AnyHashable?
        private var applying = false
        private var adjustmentScheduled = false
        private var pendingHeights = IndexSet()
        private var resizeWork: DispatchWorkItem?
        private var columnWidth: CGFloat = 0
        private let reuseID = NSUserInterfaceItemIdentifier("herald.transcript.row")

        init(parent: TranscriptTable) { self.parent = parent }

        func attach(_ scroll: TranscriptTableScrollView) {
            self.scroll = scroll
            let table = scroll.tableView
            table.headerView = nil
            table.style = .plain
            table.backgroundColor = .clear
            table.focusRingType = .none
            table.selectionHighlightStyle = .none
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.intercellSpacing = .zero
            table.rowHeight = 160
            table.usesAutomaticRowHeights = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.autoresizingMask = [.width]
            table.setAccessibilityIdentifier("herald.transcript.rows")
            let column = NSTableColumn(identifier: reuseID)
            column.minWidth = 1
            column.width = max(1, scroll.contentView.bounds.width)
            column.resizingMask = []
            table.addTableColumn(column)
            table.delegate = self
            table.dataSource = self
            scroll.viewportChanged = { [weak self] in self?.viewportChanged() }
            parent.tracker.nativeAttached = true
            parent.tracker.scrollToLatest = { [weak self] in self?.scrollToLatest() }
            parent.tracker.scrollToID = { [weak self] id, anchor in self?.scroll(to: id, anchor: anchor) }
            observe(scroll)
            update(parent)
        }

        func detach() {
            resizeWork?.cancel()
            resizeWork = nil
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens.removeAll()
            scroll?.viewportChanged = nil
            scroll?.tableView.delegate = nil
            scroll?.tableView.dataSource = nil
            parent.tracker.nativeAttached = false
            parent.tracker.userScrolling = false
            parent.tracker.scrollToLatest = nil
            parent.tracker.scrollToID = nil
            scroll = nil
        }

        private func item(at row: Int, in data: Data) -> Item {
            data[data.index(data.startIndex, offsetBy: row)]
        }

        func update(_ next: TranscriptTable) {
            guard let scroll else { parent = next; return }
            let old = parent
            parent = next
            guard appliedRevision != next.revision else { return }
            var anchor = readingAnchor ?? captureAnchor()
            let checkStructure = ids.count != next.items.count || next.structureRevision == nil
                || appliedStructure != next.structureRevision
            let nextIDs = checkStructure ? next.items.map(\.id) : ids
            let structural = checkStructure && nextIDs != ids
            applying = true
            if structural {
                let previousIDs = ids
                ids = nextIDs
                indexes = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
                heights = heights.filter { indexes[$0.key] != nil }
                anchor = resolve(anchor, previousIDs: previousIDs)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    if !previousIDs.isEmpty, ids.count > previousIDs.count,
                       ids.prefix(previousIDs.count).elementsEqual(previousIDs) {
                        scroll.tableView.insertRows(at: IndexSet(integersIn: previousIDs.count..<ids.count), withAnimation: [])
                    } else if !ids.isEmpty, ids.count < previousIDs.count,
                              previousIDs.prefix(ids.count).elementsEqual(ids) {
                        scroll.tableView.removeRows(at: IndexSet(integersIn: ids.count..<previousIDs.count), withAnimation: [])
                    } else {
                        // Reset/reorder snapshots invalidate native geometry; ordinary appends do not.
                        scroll.tableView.reloadData()
                    }
                }
            }
            let visible = scroll.tableView.rows(in: scroll.contentView.bounds)
            if visible.location != NSNotFound {
                for index in visible.location..<min(ids.count, NSMaxRange(visible)) {
                    guard let cell = scroll.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TranscriptHostingCell else { continue }
                    let current = item(at: index, in: next.items)
                    let changed = index >= old.items.count || !next.sameContent(item(at: index, in: old.items), current)
                    configure(cell, at: index, remeasure: changed)
                }
            }
            appliedRevision = next.revision
            appliedStructure = next.structureRevision
            applying = false
            if !next.tracker.follow.following { readingAnchor = anchor }
            if structural || !pendingHeights.isEmpty { scheduleAdjustment() }
            viewportChanged()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { ids.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < ids.count else { return 160 }
            guard let height = heights[ids[row]] else { return 160 }
            // Unknown widths use the last measured height as an estimate, never eager offscreen layout.
            return max(1, height.value)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < ids.count, let scroll else { return nil }
            let cell: TranscriptHostingCell
            if let reused = tableView.makeView(withIdentifier: reuseID, owner: self) as? TranscriptHostingCell {
                cell = reused
            } else {
                cell = TranscriptHostingCell()
                cell.identifier = reuseID
                scroll.countedCreation()
            }
            configure(cell, at: row)
            return cell
        }

        private func configure(_ cell: TranscriptHostingCell, at index: Int, remeasure: Bool = true) {
            guard let scroll, index < ids.count else { return }
            let value = item(at: index, in: parent.items)
            let id = value.id
            let width = max(1, columnWidth > 0 ? columnWidth : scroll.contentView.bounds.width)
            // SwiftUI initially installs the native view at zero size. Do not lay out a huge reply at
            // one glyph per line before its real viewport arrives.
            guard width >= 40 else { return }
            let geometryChanged = cell.requiresMeasurement(id: AnyHashable(id), width: width)
            scroll.countedConfiguration()
            cell.configure(id: AnyHashable(id), width: width, content: AnyView(parent.row(value)))
            cell.onIntrinsicChange = { [weak self, weak cell] in
                guard let self, let cell, cell.rowID == AnyHashable(id), let row = self.indexes[id] else { return }
                self.scroll?.countedMeasurement()
                self.record(cell.measure(), id: id, width: width, row: row)
            }
            if remeasure || geometryChanged || heights[id] == nil {
                scroll.countedMeasurement()
                record(cell.measure(), id: id, width: width, row: index)
            }
        }

        private func record(_ value: CGFloat, id: ID, width: CGFloat, row: Int) {
            guard value.isFinite, value > 0 else { return }
            if let previous = heights[id], abs(previous.width - width) < 0.5, abs(previous.value - value) < 0.5 { return }
            heightStamp &+= 1
            heights[id] = Height(width: width, value: value, stamp: heightStamp)
            heightOrder.append((id, heightStamp))
            while heights.count > 4_096, oldestHeight < heightOrder.count {
                let (oldID, stamp) = heightOrder[oldestHeight]
                oldestHeight += 1
                if heights[oldID]?.stamp == stamp { heights[oldID] = nil }
            }
            if heightOrder.count > 8_192 {
                heightOrder = heights.map { ($0.key, $0.value.stamp) }.sorted { $0.1 < $1.1 }
                oldestHeight = 0
            }
            pendingHeights.insert(row)
            scheduleAdjustment()
        }

        private func viewportChanged() {
            guard let scroll else { return }
            parent.tracker.viewport = scroll.contentView.bounds.size
            let width = floor(scroll.contentView.bounds.width)
            guard width > 1, abs(width - columnWidth) > 0.5 else { return }
            resizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.resize(to: width) }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }

        private func resize(to width: CGFloat) {
            guard let scroll else { return }
            let anchor = readingAnchor ?? captureAnchor()
            columnWidth = width
            applying = true
            scroll.tableView.setFrameSize(NSSize(width: width, height: scroll.tableView.frame.height))
            scroll.tableView.tableColumns.first?.width = width
            let visible = scroll.tableView.rows(in: scroll.contentView.bounds)
            if visible.location != NSNotFound {
                for index in visible.location..<min(ids.count, NSMaxRange(visible)) {
                    if let cell = scroll.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TranscriptHostingCell {
                        configure(cell, at: index)
                    }
                }
            }
            applying = false
            if !parent.tracker.follow.following { readingAnchor = anchor }
            scheduleAdjustment()
        }

        private func scheduleAdjustment() {
            guard !adjustmentScheduled else { return }
            adjustmentScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.adjustmentScheduled = false
                self.adjustLayout()
            }
        }

        private func adjustLayout() {
            guard let scroll else { return }
            let anchor = readingAnchor ?? captureAnchor()
            let changes = pendingHeights.intersection(IndexSet(integersIn: 0..<ids.count))
            pendingHeights.removeAll()
            applying = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                if !changes.isEmpty { scroll.tableView.noteHeightOfRows(withIndexesChanged: changes) }
                scroll.tableView.layoutSubtreeIfNeeded()
            }
            refreshContentExtent()
            if !parent.tracker.userScrolling {
                if parent.tracker.follow.following { positionAtLatest() }
                else if let anchor { restore(anchor) }
            }
            applying = false
        }

        private func captureAnchor() -> Anchor? {
            guard let scroll, !ids.isEmpty else { return nil }
            let y = scroll.contentView.bounds.minY
            var index = scroll.tableView.row(at: NSPoint(x: 1, y: y + 1))
            if index < 0 { index = min(ids.count - 1, max(0, scroll.tableView.rows(in: scroll.contentView.bounds).location)) }
            guard index >= 0, index < ids.count else { return nil }
            return Anchor(id: ids[index], offset: y - scroll.tableView.rect(ofRow: index).minY)
        }

        private func restore(_ anchor: Anchor) {
            guard let scroll, let index = indexes[anchor.id] else { return }
            let rect = scroll.tableView.rect(ofRow: index)
            position(y: rect.minY + min(max(0, anchor.offset), max(0, rect.height - 1)))
        }

        private func resolve(_ anchor: Anchor?, previousIDs: [ID]) -> Anchor? {
            guard let anchor, !ids.isEmpty else { return nil }
            if indexes[anchor.id] != nil { return anchor }
            let previousIndex = previousIDs.firstIndex(of: anchor.id) ?? 0
            // Keep the nearest surviving part of the previous transcript in view. Prefer the next
            // row at equal distance so deleting the current row naturally reveals its successor.
            for distance in 1...max(previousIndex + 1, previousIDs.count - previousIndex) {
                let after = previousIndex + distance
                if after < previousIDs.count, indexes[previousIDs[after]] != nil {
                    return Anchor(id: previousIDs[after], offset: anchor.offset)
                }
                let before = previousIndex - distance
                if before >= 0, indexes[previousIDs[before]] != nil {
                    return Anchor(id: previousIDs[before], offset: anchor.offset)
                }
            }
            return Anchor(id: ids[min(previousIndex, ids.count - 1)], offset: 0)
        }

        private func position(y: CGFloat) {
            guard let scroll else { return }
            let clip = scroll.contentView
            let maximum = max(0, refreshContentExtent() - clip.bounds.height)
            let proposal = NSRect(origin: NSPoint(x: 0, y: min(maximum, max(0, y))), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(proposal).origin)
            scroll.reflectScrolledClipView(clip)
        }

        @discardableResult private func refreshContentExtent() -> CGFloat {
            guard let scroll else { return 0 }
            // NSTableView expands its document frame to at least the clip height. The row extent,
            // rather than that expanded frame, determines short-transcript bottom alignment.
            let height = ids.isEmpty
                ? 0 : scroll.tableView.rect(ofRow: ids.count - 1).maxY
            (scroll.contentView as? TranscriptBottomClipView)?.contentHeight = height
            return height
        }

        private func positionAtLatest() {
            guard let scroll else { return }
            position(y: max(0, refreshContentExtent() - scroll.contentView.bounds.height))
        }

        private func setFollowing(_ following: Bool) {
            guard parent.tracker.follow.following != following else { return }
            if following { parent.tracker.follow.resume(); readingAnchor = nil }
            else { parent.tracker.follow.pause() }
            parent.onFollowChange(following)
        }

        private func observe(_ scroll: TranscriptTableScrollView) {
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.parent.tracker.userScrolling = true
                    self.setFollowing(false)
                    self.readingAnchor = self.captureAnchor()
                }
            })
            tokens.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrolled(ended: false) }
            })
            tokens.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.parent.tracker.userScrolling = false
                    self?.userScrolled(ended: true)
                }
            })
            tokens.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.applying else { return }
                    self.parent.tracker.viewport = scroll.contentView.bounds.size
                }
            })
        }

        private func userScrolled(ended: Bool) {
            guard let scroll, !applying else { return }
            let distance = max(0, refreshContentExtent() - scroll.contentView.bounds.maxY)
            let atBottom = distance <= TranscriptFollow.slack
            setFollowing(atBottom && (ended || !parent.tracker.userScrolling))
            if !parent.tracker.follow.following { readingAnchor = captureAnchor() }
        }

        func scrollToLatest() {
            setFollowing(true)
            applying = true
            scroll?.tableView.layoutSubtreeIfNeeded()
            positionAtLatest()
            applying = false
            scheduleAdjustment()
        }

        func scroll(to id: AnyHashable, anchor: UnitPoint) {
            guard let typed = id.base as? ID, let index = indexes[typed], let scroll else { return }
            setFollowing(false)
            applying = true
            let rect = scroll.tableView.rect(ofRow: index)
            position(y: rect.minY + rect.height * anchor.y - scroll.contentView.bounds.height * anchor.y)
            applying = false
            readingAnchor = captureAnchor()
            scheduleAdjustment()
        }
    }
}

/// A small pool of hosting controllers is reused by the table. Width is explicit so measuring a tall
/// markdown reply never falls back to a one-character-wide intrinsic proposal.
@MainActor
private final class TranscriptHostingCell: NSTableCellView {
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var hostedHeight: NSLayoutConstraint!
    private var width: CGFloat = 1
    private var measuredHeight: CGFloat = 1
    private var intrinsicCheckScheduled = false
    var rowID: AnyHashable?
    var onIntrinsicChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        let view = host.view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        hostedHeight = view.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor), hostedHeight,
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(id: AnyHashable, width: CGFloat, content: AnyView) {
        rowID = id
        self.width = width
        host.rootView = AnyView(content.id(id).frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        needsLayout = true
    }

    func requiresMeasurement(id: AnyHashable, width: CGFloat) -> Bool {
        rowID != id || abs(self.width - width) > 0.5
    }

    func measure() -> CGFloat {
        let value = max(1, ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height))
        if value.isFinite {
            measuredHeight = value
            if abs(hostedHeight.constant - value) > 0.5 { hostedHeight.constant = value }
        }
        return measuredHeight
    }

    override func layout() {
        super.layout()
        let intrinsic = host.view.intrinsicContentSize.height
        guard intrinsic.isFinite, intrinsic > 0, abs(ceil(intrinsic) - measuredHeight) > 0.5,
              !intrinsicCheckScheduled else { return }
        intrinsicCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.intrinsicCheckScheduled = false
            self.onIntrinsicChange?()
        }
    }
}

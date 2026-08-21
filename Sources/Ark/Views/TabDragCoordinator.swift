import Observation
import SwiftUI

/// Sidebar drag and drop, rewritten to use no drag-and-drop API at all.
///
/// History, so nobody reintroduces it: six attempts failed here, each for a
/// different reason, and the causes are all structural rather than fixable.
///   • `.draggable` + `.onDrop` — crossed APIs; the drop never sees the item.
///   • `.onDrag` + `.dropDestination` — same mismatch, other direction.
///   • An overlay `NSView` — a bare NSView reports `fittingSize` zero, so
///     SwiftUI lays it out 0×0 and nothing can hit it.
///   • The same view gated on "drag active" — created mid-drag, and AppKit
///     resolves drop destinations at session start, so it is never consulted.
///   • An always-present, correctly sized `NSView` — verified by trace to exist
///     and be registered, yet AppKit still never delivered `draggingEntered`,
///     because SwiftUI's hosting view intercepts a SwiftUI-initiated session and
///     does not route it to nested NSViews.
///   • Always-present SwiftUI drop zones — worked, but `contentShape` on a
///     full-row overlay swallowed clicks.
///
/// So this tracks the pointer itself. Rows publish their frames in global
/// coordinates; a `DragGesture` reports the live position; the target is plain
/// geometry. Nothing depends on pasteboards, item providers, Transferable, or
/// AppKit destination resolution — and because it is a gesture rather than an
/// overlay, it cannot intercept a click.
@Observable
final class TabDragCoordinator {
    /// Where a dragged tab would land.
    enum Target: Equatable {
        case none
        /// Insert next to a sidebar row.
        case beside(UUID, before: Bool)
        /// Drop into a group.
        case intoGroup(UUID)
        /// Lift to the top level of a section.
        case root(pinned: Bool)
        /// Open as another pane, on a side of an existing pane.
        case split(UUID, left: Bool)
    }

    /// Row and pane rectangles, in global coordinates.
    enum Region: Hashable {
        case row(UUID)
        case group(UUID)
        case rootStrip(pinned: Bool)
        case pane(UUID)
    }

    /// The node being dragged — a tab or a group.
    var draggingID: UUID?
    var draggingIsGroup: Bool = false
    /// Every id at or below the dragged node, so a group can't be dropped into
    /// itself or one of its own descendants.
    @ObservationIgnored private var draggingSubtree: Set<UUID> = []

    /// Existing call sites read this; nil while a group is being dragged.
    var draggingTabID: UUID? { draggingIsGroup ? nil : draggingID }

    var pointerLocation: CGPoint = .zero
    var target: Target = .none
    /// Label shown on the ghost that follows the pointer.
    var ghostTitle: String = ""
    var ghostHost: String?

    var isDragging: Bool { draggingID != nil }

    @ObservationIgnored private var regions: [Region: CGRect] = [:]

    /// Bumped when every row should re-publish its frame. Retained because a
    /// deferred resize commits one layout change, and rows must re-report after.
    var geometryEpoch: Int = 0

    // MARK: - Geometry

    func setFrame(_ rect: CGRect, for region: Region) {
        regions[region] = rect
    }

    /// Read-only view of the registered frames. Used by the window probe to
    /// measure the gap around the page instead of eyeballing a screenshot.
    var registeredFrames: [Region: CGRect] { regions }

    func clearFrame(for region: Region) {
        regions[region] = nil
    }

    // MARK: - Drag lifecycle

    func begin(tab: BrowserTab, at point: CGPoint) {
        draggingID = tab.id
        draggingIsGroup = false
        draggingSubtree = [tab.id]
        ghostTitle = tab.displayTitle
        ghostHost = tab.faviconHost
        pointerLocation = point
        target = .none
    }

    func begin(group: SidebarItem, at point: CGPoint) {
        draggingID = group.id
        draggingIsGroup = true
        // Collect the whole subtree so it can be excluded as a target.
        var ids: Set<UUID> = [group.id]
        func walk(_ items: [SidebarItem]) {
            for item in items {
                ids.insert(item.id)
                walk(item.children)
            }
        }
        walk(group.children)
        draggingSubtree = ids
        ghostTitle = group.groupName ?? "Group"
        ghostHost = nil
        pointerLocation = point
        target = .none
    }

    func update(to point: CGPoint) {
        pointerLocation = point
        let resolved = resolve(point)
        if resolved != target { trace(point, resolved) }
        target = resolved
    }

    func end() {
        draggingID = nil
        draggingIsGroup = false
        draggingSubtree = []
        target = .none
    }

    /// Region under the pointer, resolved in a **fixed priority order**.
    ///
    /// `regions` is a dictionary, so iterating it directly gave arbitrary order —
    /// a stale or overlapping rect could win over the group header and swallow
    /// the drop. Priority is explicit now: strips, then groups, then rows, then
    /// panes. Panes are last so a sidebar row overlapping a pane edge still wins.
    /// Among equals the smallest rect wins, since a tighter target is the more
    /// specific one.
    private func resolve(_ point: CGPoint) -> Target {
        func hits(_ matching: (Region) -> Bool) -> [(Region, CGRect)] {
            regions
                .filter { matching($0.key) && $0.value.contains(point) }
                .sorted { $0.value.height * $0.value.width < $1.value.height * $1.value.width }
                .map { ($0.key, $0.value) }
        }

        if case let strips = hits({ if case .rootStrip = $0 { return true }; return false }),
           let (region, _) = strips.first, case .rootStrip(let pinned) = region {
            return .root(pinned: pinned)
        }
        if case let groups = hits({ if case .group = $0 { return true }; return false }),
           let (region, rect) = groups.first, case .group(let id) = region {
            // A group can't go into itself or its own descendants; offer a
            // reorder beside it instead, which is what you actually want.
            if id == draggingID || draggingSubtree.contains(id) { return .none }
            if draggingIsGroup { return .beside(id, before: point.y < rect.midY) }
            return .intoGroup(id)
        }
        if case let rows = hits({ if case .row = $0 { return true }; return false }),
           let (region, rect) = rows.first, case .row(let id) = region {
            guard id != draggingID, !draggingSubtree.contains(id) else { return .none }
            return .beside(id, before: point.y < rect.midY)
        }
        if case let panes = hits({ if case .pane = $0 { return true }; return false }),
           let (region, rect) = panes.first, case .pane(let id) = region {
            return .split(id, left: point.x < rect.midX)
        }
        return .none
    }

    /// `ARK_DRAG_DEBUG=1` traces resolution, so a wrong target names itself.
    @ObservationIgnored private static let debug =
        ProcessInfo.processInfo.environment["ARK_DRAG_DEBUG"] == "1"

    private func trace(_ point: CGPoint, _ resolved: Target) {
        guard Self.debug else { return }
        let counts = regions.keys.reduce(into: [String: Int]()) { tally, region in
            switch region {
            case .row: tally["row", default: 0] += 1
            case .group: tally["group", default: 0] += 1
            case .rootStrip: tally["strip", default: 0] += 1
            case .pane: tally["pane", default: 0] += 1
            }
        }
        FileHandle.standardError.write(Data(
            "DRAGTRACE at (\(Int(point.x)),\(Int(point.y))) -> \(resolved) regions=\(counts)\n".utf8))
    }

    // MARK: - Indicator queries, kept cheap for row bodies

    func insertEdge(for rowID: UUID) -> VerticalEdge? {
        guard case .beside(let id, let before) = target, id == rowID else { return nil }
        return before ? .top : .bottom
    }

    func isGroupTargeted(_ groupID: UUID) -> Bool {
        target == .intoGroup(groupID)
    }

    func isRootTargeted(pinned: Bool) -> Bool {
        target == .root(pinned: pinned)
    }

    func splitSide(for paneTabID: UUID) -> Bool? {
        guard case .split(let id, let left) = target, id == paneTabID else { return nil }
        return left
    }
}

// MARK: - Frame reporting

/// Publishes a view's global frame to the coordinator.
///
/// Attached as a `.background` containing only a non-hit-testable `Color.clear`,
/// so it reports geometry without ever taking a click — the mistake that broke
/// clicking on tabs.
struct ReportsFrame: ViewModifier {
    let coordinator: TabDragCoordinator
    let region: TabDragCoordinator.Region

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { coordinator.setFrame(geo.frame(in: .global), for: region) }
                    .onChange(of: geo.frame(in: .global)) { _, rect in
                        coordinator.setFrame(rect, for: region)
                    }
                    // Re-publish once after a resize, since updates were skipped.
                    .onChange(of: coordinator.geometryEpoch) { _, _ in
                        coordinator.setFrame(geo.frame(in: .global), for: region)
                    }
                    .onDisappear { coordinator.clearFrame(for: region) }
            }
            .allowsHitTesting(false)
        )
    }
}

extension View {
    func reportsFrame(_ coordinator: TabDragCoordinator,
                      as region: TabDragCoordinator.Region) -> some View {
        modifier(ReportsFrame(coordinator: coordinator, region: region))
    }
}

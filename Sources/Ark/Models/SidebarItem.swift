import Foundation
import Observation

/// A node in the pinned section: either a tab or a group of nodes.
/// One class rather than an enum tree, because SwiftUI's `ForEach` and the
/// move/rename operations are far simpler against a uniform identity.
@Observable
final class SidebarItem: Identifiable {
    let id: UUID
    /// Non-nil means this node is a group.
    var groupName: String?
    /// Non-nil means this node is a tab.
    var tab: BrowserTab?
    var isExpanded: Bool = true
    var children: [SidebarItem] = []

    var isGroup: Bool { groupName != nil }

    init(tab: BrowserTab) {
        self.id = tab.id
        self.tab = tab
    }

    init(id: UUID = UUID(), groupName: String, children: [SidebarItem] = [], isExpanded: Bool = true) {
        self.id = id
        self.groupName = groupName
        self.children = children
        self.isExpanded = isExpanded
    }

    /// Every tab at or below this node.
    var allTabs: [BrowserTab] {
        if let tab { return [tab] }
        return children.flatMap(\.allTabs)
    }

    var tabCount: Int { allTabs.count }
}

extension Array where Element == SidebarItem {
    /// Removes a node by id anywhere in the tree, returning it.
    @discardableResult
    mutating func removeNode(id: UUID) -> SidebarItem? {
        if let idx = firstIndex(where: { $0.id == id }) {
            return remove(at: idx)
        }
        for item in self where item.isGroup {
            if let found = item.children.removeNode(id: id) { return found }
        }
        return nil
    }

    /// Finds a node by id anywhere in the tree.
    func findNode(id: UUID) -> SidebarItem? {
        for item in self {
            if item.id == id { return item }
            if item.isGroup, let found = item.children.findNode(id: id) { return found }
        }
        return nil
    }

    /// Finds the group containing a given node id.
    func findParentGroup(of id: UUID) -> SidebarItem? {
        for item in self where item.isGroup {
            if item.children.contains(where: { $0.id == id }) { return item }
            if let deeper = item.children.findParentGroup(of: id) { return deeper }
        }
        return nil
    }

    var allTabs: [BrowserTab] { flatMap(\.allTabs) }

    /// Depth-first order of visible rows, honoring collapsed groups.
    func visibleTabsInOrder() -> [BrowserTab] {
        flatMap { item -> [BrowserTab] in
            if let tab = item.tab { return [tab] }
            return item.isExpanded ? item.children.visibleTabsInOrder() : []
        }
    }
}


extension Array where Element == SidebarItem {
    /// Inserts an already-detached node next to `target`, staying inside
    /// whatever container holds the target.
    @discardableResult
    mutating func insertNode(_ node: SidebarItem, besideNodeID target: UUID,
                            before: Bool) -> Bool {
        if let parent = findParentGroup(of: target),
           let found = parent.children.firstIndex(where: { $0.id == target }) {
            let at = Swift.min(Swift.max(before ? found : found + 1, 0), parent.children.count)
            parent.children.insert(node, at: at)
            parent.isExpanded = true
            return true
        }
        if let found = firstIndex(where: { $0.id == target }) {
            insert(node, at: Swift.min(Swift.max(before ? found : found + 1, 0), count))
            return true
        }
        append(node)
        return true
    }

    /// Moves the node with `id` next to `target`, staying inside whatever
    /// container holds the target — a group's children or this top level.
    ///
    /// Extracted so reordering is unit-testable: the bug this replaced only
    /// showed up inside Today groups, which no test could reach while the logic
    /// lived inside `BrowserState` behind real tabs and web views.
    @discardableResult
    mutating func moveNode(id: UUID, besideNodeID target: UUID, before: Bool) -> Bool {
        guard id != target else { return false }
        guard let node = removeNode(id: id) else { return false }

        // Index resolved after removal, so dragging downward past the node's own
        // former slot lands where the indicator promised.
        if let parent = findParentGroup(of: target),
           let found = parent.children.firstIndex(where: { $0.id == target }) {
            let at = Swift.min(Swift.max(before ? found : found + 1, 0), parent.children.count)
            parent.children.insert(node, at: at)
            parent.isExpanded = true
            return true
        }
        if let found = firstIndex(where: { $0.id == target }) {
            insert(node, at: Swift.min(Swift.max(before ? found : found + 1, 0), count))
            return true
        }
        append(node)
        return true
    }
}

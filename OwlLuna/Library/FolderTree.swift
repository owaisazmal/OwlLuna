import Foundation

/// Folders arranged by their parents, in sidebar order. A folder whose parent is missing, or whose parents loop
/// back to it, sits at the top level, so a damaged `folders.json` never hides a folder.
struct FolderTree: Sendable {
    struct Node: Sendable, Hashable, Identifiable {
        let id: UUID
        var parent: UUID?
        var name: String
        var sortIndex: Int
    }

    struct Row: Sendable, Hashable, Identifiable {
        let id: UUID
        let depth: Int
        let hasChildren: Bool
    }

    /// Folders can sit this many levels below the top one.
    static let maximumDepth = 4

    private var nodes: [UUID: Node] = [:]
    private var children: [UUID?: [UUID]] = [:]
    private var parents: [UUID: UUID] = [:]

    init(_ list: [Node] = []) {
        for node in list where nodes[node.id] == nil { nodes[node.id] = node }
        for node in nodes.values {
            guard let parent = node.parent, nodes[parent] != nil, !Self.loops(from: node.id, in: nodes) else { continue }
            parents[node.id] = parent
        }
        for node in nodes.values { children[parents[node.id], default: []].append(node.id) }
        for key in children.keys {
            children[key]?.sort { a, b in
                let first = nodes[a]!, second = nodes[b]!
                if first.sortIndex != second.sortIndex { return first.sortIndex < second.sortIndex }
                let byName = first.name.localizedStandardCompare(second.name)
                // Two devices can number their folders alike; the ID keeps namesakes from swapping on every redraw.
                if byName != .orderedSame { return byName == .orderedAscending }
                return a.uuidString < b.uuidString
            }
        }
    }

    private static func loops(from id: UUID, in nodes: [UUID: Node]) -> Bool {
        var seen: Set<UUID> = [id]
        var current = nodes[id]?.parent
        while let next = current {
            guard seen.insert(next).inserted else { return true }
            current = nodes[next]?.parent
        }
        return false
    }

    func parent(of id: UUID) -> UUID? { parents[id] }

    func children(of id: UUID?) -> [UUID] { children[id] ?? [] }

    func name(of id: UUID) -> String { nodes[id]?.name ?? "" }

    /// Nearest first.
    func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var current = parents[id]
        while let next = current {
            result.append(next)
            current = parents[next]
        }
        return result
    }

    func depth(of id: UUID) -> Int { ancestors(of: id).count }

    /// The folder and everything inside it.
    func subtree(_ id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for child in children(of: next) where result.insert(child).inserted { queue.append(child) }
        }
        return result
    }

    /// How many levels of folders sit below this one.
    func height(of id: UUID) -> Int {
        (children(of: id).map { height(of: $0) + 1 }).max() ?? 0
    }

    /// "Science › Physics › Labs".
    func path(of id: UUID, from root: UUID? = nil) -> String {
        var names = [name(of: id)]
        for ancestor in ancestors(of: id) {
            if ancestor == root { break }
            names.append(name(of: ancestor))
        }
        return names.reversed().joined(separator: " › ")
    }

    /// Every folder, parents before their children.
    var ordered: [UUID] { rows().map(\.id) }

    /// The sidebar's rows: a collapsed folder keeps its children out of sight.
    func rows(collapsed: Set<UUID> = []) -> [Row] {
        var result: [Row] = []
        func visit(_ parent: UUID?, depth: Int) {
            for id in children(of: parent) {
                let inside = children(of: id)
                result.append(Row(id: id, depth: depth, hasChildren: !inside.isEmpty))
                if !collapsed.contains(id) { visit(id, depth: depth + 1) }
            }
        }
        visit(nil, depth: 0)
        return result
    }

    /// A folder can't go inside itself or anything inside it, or so deep that the sidebar can't show it.
    func canMove(_ id: UUID, into parent: UUID?) -> Bool {
        guard nodes[id] != nil else { return false }
        guard let parent else { return true }
        guard nodes[parent] != nil, !subtree(id).contains(parent) else { return false }
        return depth(of: parent) + 1 + height(of: id) <= Self.maximumDepth
    }

    func canAddFolder(inside parent: UUID?) -> Bool {
        guard let parent else { return true }
        return nodes[parent] != nil && depth(of: parent) + 1 <= Self.maximumDepth
    }
}

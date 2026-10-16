import CoreGraphics
import Foundation

/// Places the tables of a relationship diagram. Each group of related tables is laid out in layers from
/// left to right, every table to the right of the tables it references, ordered within a layer to keep
/// lines short. Groups are packed in rows, and tables without any relation go in a grid after them.
enum DiagramLayout {
    struct Node: Equatable {
        var id: String
        var size: CGSize
    }

    /// A foreign key: `from` (the referencing table) points at `to` (the referenced table).
    struct Edge: Equatable {
        var from: String
        var to: String
    }

    static let gap = CGSize(width: 90, height: 32)
    static let margin: CGFloat = 40

    /// The top-left corner of every node, all at least `margin` from the origin.
    static func positions(nodes: [Node], edges: [Edge]) -> [String: CGPoint] {
        let sizes = Dictionary(nodes.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
        var parents: [String: Set<String>] = [:]
        var children: [String: Set<String>] = [:]
        for edge in edges where edge.from != edge.to && sizes[edge.from] != nil && sizes[edge.to] != nil {
            parents[edge.from, default: []].insert(edge.to)
            children[edge.to, default: []].insert(edge.from)
        }

        var blocks: [Block] = []
        var isolated: [String] = []
        for component in components(nodes.map(\.id), parents: parents, children: children) {
            if component.count == 1 {
                isolated.append(component[0])
            } else {
                blocks.append(layered(component, sizes: sizes, parents: parents, children: children))
            }
        }
        blocks.sort { $0.ids.count > $1.ids.count }

        let totalArea = blocks.reduce(0) { $0 + $1.size.width * $1.size.height }
            + isolated.reduce(0) { total, id in
                let size = sizes[id] ?? .zero
                return total + (size.width + gap.width) * (size.height + gap.height)
            }
        let widest = blocks.map(\.size.width).max() ?? 0
        let rowWidth = max(widest, sqrt(totalArea) * 1.6, 900)
        if !isolated.isEmpty {
            blocks.append(grid(isolated, sizes: sizes, width: rowWidth))
        }
        return pack(blocks, rowWidth: rowWidth)
    }

    /// A laid-out group: positions relative to its own top-left corner.
    private struct Block {
        var ids: [String]
        var origins: [String: CGPoint]
        var size: CGSize
    }

    // MARK: Groups

    /// Connected groups, each in the order of `ids`, the groups ordered by their first member.
    private static func components(_ ids: [String], parents: [String: Set<String>],
                                   children: [String: Set<String>]) -> [[String]] {
        var groupOf: [String: Int] = [:]
        var groups: [[String]] = []
        for id in ids where groupOf[id] == nil {
            let group = groups.count
            var members: Set<String> = [id]
            var stack = [id]
            groupOf[id] = group
            while let current = stack.popLast() {
                for next in parents[current, default: []].union(children[current, default: []]) where groupOf[next] == nil {
                    groupOf[next] = group
                    members.insert(next)
                    stack.append(next)
                }
            }
            groups.append(ids.filter(members.contains))
        }
        return groups
    }

    // MARK: Layers

    private static func layered(_ ids: [String], sizes: [String: CGSize],
                                parents: [String: Set<String>], children: [String: Set<String>]) -> Block {
        let layerOf = layers(ids, parents: parents, children: children)
        let layerCount = (layerOf.values.max() ?? 0) + 1
        var layers = Array(repeating: [String](), count: layerCount)
        for id in ids { layers[layerOf[id] ?? 0].append(id) }
        orderWithinLayers(&layers, parents: parents, children: children)

        // A layer taller than this wraps into several columns, so one hub table doesn't make a tower.
        let area = ids.reduce(CGFloat(0)) { total, id in
            let size = sizes[id] ?? .zero
            return total + (size.width + gap.width) * (size.height + gap.height)
        }
        let maxColumnHeight = max(700, sqrt(area) * 1.2)

        var columns: [[String]] = []
        for layer in layers {
            var column: [String] = []
            var height: CGFloat = 0
            for id in layer {
                let h = (sizes[id]?.height ?? 0) + gap.height
                if !column.isEmpty, height + h > maxColumnHeight {
                    columns.append(column)
                    column = []
                    height = 0
                }
                column.append(id)
                height += h
            }
            if !column.isEmpty { columns.append(column) }
        }

        let heights = columns.map { column in
            column.reduce(CGFloat(0)) { $0 + (sizes[$1]?.height ?? 0) } + gap.height * CGFloat(max(column.count - 1, 0))
        }
        let blockHeight = heights.max() ?? 0
        var origins: [String: CGPoint] = [:]
        var x: CGFloat = 0
        for (index, column) in columns.enumerated() {
            let width = column.map { sizes[$0]?.width ?? 0 }.max() ?? 0
            // Columns are centred vertically, so lines between neighbouring layers stay short.
            var y = ((blockHeight - heights[index]) / 2).rounded()
            for id in column {
                origins[id] = CGPoint(x: x, y: y)
                y += (sizes[id]?.height ?? 0) + gap.height
            }
            x += width + gap.width
        }
        return Block(ids: ids, origins: origins, size: CGSize(width: max(x - gap.width, 0), height: blockHeight))
    }

    /// Layer 0 holds tables that reference nothing; every other table sits one layer right of the furthest
    /// table it references. A table that only gets referenced moves up next to its nearest referencing table.
    /// Cycles are broken where the walk meets them.
    private static func layers(_ ids: [String], parents: [String: Set<String>],
                               children: [String: Set<String>]) -> [String: Int] {
        var layer: [String: Int] = [:]
        var visiting: Set<String> = []
        func depth(_ id: String) -> Int {
            if let known = layer[id] { return known }
            guard visiting.insert(id).inserted else { return 0 }
            defer { visiting.remove(id) }
            let result = parents[id, default: []].sorted().map { depth($0) + 1 }.max() ?? 0
            layer[id] = result
            return result
        }
        for id in ids { _ = depth(id) }

        for id in ids where parents[id, default: []].isEmpty {
            if let nearest = children[id, default: []].compactMap({ layer[$0] }).min(), nearest - 1 > layer[id] ?? 0 {
                layer[id] = nearest - 1
            }
        }
        return layer
    }

    /// A few barycenter sweeps: each table moves towards the average place of the tables it's linked to.
    private static func orderWithinLayers(_ layers: inout [[String]], parents: [String: Set<String>],
                                          children: [String: Set<String>]) {
        guard layers.count > 1 else { return }
        func place() -> [String: Double] {
            var place: [String: Double] = [:]
            for layer in layers {
                for (index, id) in layer.enumerated() {
                    place[id] = (Double(index) + 0.5) / Double(layer.count)
                }
            }
            return place
        }
        for sweep in 0..<6 {
            let current = place()
            let order = sweep.isMultiple(of: 2) ? Array(layers.indices) : layers.indices.reversed()
            for index in order {
                let keys = layers[index].map { id -> Double in
                    let linked = parents[id, default: []].union(children[id, default: []]).compactMap { current[$0] }
                    return linked.isEmpty ? current[id] ?? 0 : linked.reduce(0, +) / Double(linked.count)
                }
                layers[index] = zip(layers[index], keys)
                    .enumerated()
                    .sorted { a, b in a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 < b.element.1 }
                    .map(\.element.0)
            }
        }
    }

    // MARK: Packing

    /// Unrelated tables in columns of equal width, each table going to the currently shortest column.
    private static func grid(_ ids: [String], sizes: [String: CGSize], width: CGFloat) -> Block {
        let cellWidth = (ids.map { sizes[$0]?.width ?? 0 }.max() ?? 0) + gap.width
        let columnCount = max(1, min(ids.count, Int((width + gap.width) / max(cellWidth, 1))))
        var heights = Array(repeating: CGFloat(0), count: columnCount)
        var origins: [String: CGPoint] = [:]
        for id in ids {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            origins[id] = CGPoint(x: CGFloat(column) * cellWidth, y: heights[column])
            heights[column] += (sizes[id]?.height ?? 0) + gap.height
        }
        return Block(ids: ids, origins: origins,
                     size: CGSize(width: CGFloat(columnCount) * cellWidth - gap.width,
                                  height: max((heights.max() ?? 0) - gap.height, 0)))
    }

    /// Blocks left to right in rows no wider than `rowWidth` (a wider block gets a row of its own).
    private static func pack(_ blocks: [Block], rowWidth: CGFloat) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let blockGap = gap.width * 1.5
        for block in blocks {
            if x > 0, x + block.size.width > rowWidth {
                x = 0
                y += rowHeight + blockGap
                rowHeight = 0
            }
            for (id, origin) in block.origins {
                positions[id] = CGPoint(x: margin + x + origin.x, y: margin + y + origin.y)
            }
            x += block.size.width + blockGap
            rowHeight = max(rowHeight, block.size.height)
        }
        return positions
    }
}

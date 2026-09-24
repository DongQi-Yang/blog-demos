extension Graph: Codable {
    /// 从磁盘读回来的图绕过了 connect 的校验——必须重新走一遍不变量，否则一个手改过的
    /// 工程文件就能把环、悬空连线、类型不符的连线带进图里。
    public enum CorruptGraph: Error, Equatable {
        case duplicateNode(NodeID)
        case invalidEdge(Edge)
    }

    private struct Stored: Codable {
        var nodes: [Node]
        var edges: [Edge]
        var structureVersion: UInt64
    }

    public init(from decoder: any Decoder) throws {
        let stored = try Stored(from: decoder)
        var graph = Graph()
        for node in stored.nodes {
            do { try graph.insert(node) } catch { throw CorruptGraph.duplicateNode(node.id) }
        }
        for edge in stored.edges {
            guard !graph.edges.contains(where: { $0.to == edge.to }) else { throw CorruptGraph.invalidEdge(edge) }
            do { try graph.connect(edge) } catch { throw CorruptGraph.invalidEdge(edge) }
        }
        graph.structureVersion = stored.structureVersion
        self = graph
    }

    public func encode(to encoder: any Encoder) throws {
        let sortedNodes = nodes.values.sorted { $0.id < $1.id }
        let sortedEdges = edges.sorted { Graph.sortKey($0) < Graph.sortKey($1) }
        try Stored(nodes: sortedNodes, edges: sortedEdges, structureVersion: structureVersion).encode(to: encoder)
    }

    static func sortKey(_ edge: Edge) -> String {
        "\(edge.from.node.raw.uuidString)/\(edge.from.name)>\(edge.to.node.raw.uuidString)/\(edge.to.name)"
    }
}

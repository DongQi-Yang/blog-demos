import Foundation
import XCTest
@testable import FilterGraph

/// 固定的节点 ID：n=1 → 00000000-0000-0000-0000-000000000001。拓扑排序同层按 ID 排，测试结果因此确定。
func nid(_ n: Int) -> NodeID {
    NodeID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
}

func image(_ name: String) -> PinSpec { PinSpec(name: name, type: .image) }

func source(_ n: Int) -> Node { Node(id: nid(n), kind: "source", outputs: [image("out")]) }

func unary(_ n: Int, kind: String = "blur") -> Node {
    Node(id: nid(n), kind: kind, inputs: [image("in")], outputs: [image("out")])
}

func blend(_ n: Int) -> Node {
    Node(id: nid(n), kind: "blend", inputs: [image("a"), image("b")], outputs: [image("out")])
}

func maskSource(_ n: Int) -> Node {
    Node(id: nid(n), kind: "matte", outputs: [PinSpec(name: "out", type: .mask)])
}

func edge(_ from: Int, _ to: Int, _ input: String = "in", output: String = "out") -> Edge {
    Edge(from: PinID(node: nid(from), name: output), to: PinID(node: nid(to), name: input))
}

func makeGraph(_ nodes: [Node], _ edges: [Edge]) throws -> Graph {
    var graph = Graph()
    for node in nodes { try graph.insert(node) }
    for edge in edges { try graph.connect(edge) }
    return graph
}

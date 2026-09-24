import XCTest
@testable import FilterGraph

final class CommandTests: XCTestCase {
    func test_撤销等于把做的时候记下的旧值写回去_而不是做相反的操作() throws {
        var graph = try makeGraph([source(1), unary(2), unary(3)], [edge(1, 2), edge(2, 3)])
        let original = graph
        let paramInverse = try Command.setParam(nid(2), "radius", .scalar(8)).apply(to: &graph)
        XCTAssertEqual(paramInverse, .setParam(nid(2), "radius", nil))       // 旧值在改之前才存在
        let removeInverse = try Command.removeNode(nid(2)).apply(to: &graph)
        guard case let .restoreNode(node, edges) = removeInverse else { return XCTFail("\(removeInverse)") }
        XCTAssertEqual(node.params["radius"], .scalar(8))
        XCTAssertEqual(Set(edges), [edge(1, 2), edge(2, 3)])                  // 被删的连线在删之前才存在
        _ = try removeInverse.apply(to: &graph)
        _ = try paramInverse.apply(to: &graph)
        XCTAssertEqual(graph.nodes, original.nodes)
        XCTAssertEqual(graph.edges, original.edges)
    }

    func test_connect的逆可能不是disconnect_顶掉的旧线撤销时必须接回去() throws {
        var graph = try makeGraph([source(1), source(2), unary(3)], [edge(1, 3)])
        let inverse = try Command.connect(edge(2, 3)).apply(to: &graph)
        XCTAssertEqual(inverse, .group([.disconnect(edge(2, 3)), .connect(edge(1, 3))]))
        _ = try inverse.apply(to: &graph)
        XCTAssertEqual(graph.edges, [edge(1, 3)])
    }

    func test_group的逆必须逆序_否则连线会先于它依赖的节点恢复() throws {
        var graph = try makeGraph([source(1), unary(2)], [edge(1, 2)])
        let original = graph
        // UI 上的"删除节点"一步 = 先断线再删节点
        let inverse = try Command.group([.disconnect(edge(1, 2)), .removeNode(nid(1))]).apply(to: &graph)
        _ = try inverse.apply(to: &graph)          // 不逆序的话：先 connect 到还不存在的节点 1 → unknownPin
        XCTAssertEqual(graph.nodes, original.nodes)
        XCTAssertEqual(graph.edges, original.edges)
    }

    func test_删除再撤销后旧ID依然有效_因为图里只有ID没有对象() throws {
        var graph = try makeGraph([source(1), unary(2)], [edge(1, 2)])
        let heldByPanel = nid(2)                                  // 属性面板、选中态只持有 ID
        let inverse = try Command.removeNode(heldByPanel).apply(to: &graph)
        _ = try inverse.apply(to: &graph)
        XCTAssertEqual(graph.setParam(heldByPanel, "radius", .scalar(3)), .changed(old: nil))
        XCTAssertEqual(graph.edges, [edge(1, 2)])
    }

    func test_给原本没有的参数赋值_撤销后参数消失而不是报节点不存在() throws {
        var graph = try makeGraph([unary(1)], [])
        let inverse = try Command.setParam(nid(1), "radius", .scalar(8)).apply(to: &graph)
        _ = try inverse.apply(to: &graph)
        XCTAssertNil(graph.nodes[nid(1)]?.params["radius"])
    }

    func test_断开一条不存在的连线_撤销不应凭空多出这条线() throws {
        var graph = try makeGraph([source(1), unary(2)], [])
        let inverse = try Command.disconnect(edge(1, 2)).apply(to: &graph)
        _ = try inverse.apply(to: &graph)
        XCTAssertTrue(graph.edges.isEmpty)
    }

    func test_恢复节点时它的input已被别人占用必须报错而不是静默顶掉() throws {
        var graph = try makeGraph([source(1), source(2), unary(3)], [edge(1, 3)])
        let inverse = try Command.removeNode(nid(1)).apply(to: &graph)
        try graph.connect(edge(2, 3))                                 // 有人绕过撤销栈直接改了图
        XCTAssertThrowsError(try inverse.apply(to: &graph)) {
            XCTAssertEqual($0 as? UndoError, .inputOccupied(PinID(node: nid(3), name: "in")))
        }
    }

    func test_命令指向不存在的节点时报targetMissing() throws {
        var graph = Graph()
        XCTAssertThrowsError(try Command.setParam(nid(7), "radius", .scalar(1)).apply(to: &graph)) {
            XCTAssertEqual($0 as? UndoError, .targetMissing(nid(7)))
        }
        XCTAssertThrowsError(try Command.removeNode(nid(7)).apply(to: &graph)) {
            XCTAssertEqual($0 as? UndoError, .targetMissing(nid(7)))
        }
    }
}

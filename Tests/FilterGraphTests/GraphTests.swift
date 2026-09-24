import XCTest
@testable import FilterGraph

final class GraphTests: XCTestCase {
    func test_成环的连线在connect时就被拒绝_非法的图不进入图() throws {
        var graph = try makeGraph([unary(1), unary(2)], [edge(1, 2)])
        let before = graph
        XCTAssertThrowsError(try graph.connect(edge(2, 1))) {
            XCTAssertEqual($0 as? Graph.ConnectError, .wouldCycle)
        }
        XCTAssertThrowsError(try graph.connect(edge(1, 1))) {      // 自环也是环
            XCTAssertEqual($0 as? Graph.ConnectError, .wouldCycle)
        }
        XCTAssertEqual(graph, before)                              // 被拒绝的连线不留任何痕迹
    }

    func test_pin有类型_mask接到image上在编辑时就报错而不是渲染出一张全黑的帧() throws {
        var graph = try makeGraph([maskSource(1), unary(2)], [])
        XCTAssertThrowsError(try graph.connect(edge(1, 2))) {
            XCTAssertEqual($0 as? Graph.ConnectError, .typeMismatch)
        }
    }

    func test_连到不存在的pin必须拒绝() throws {
        var graph = try makeGraph([source(1), unary(2)], [])
        XCTAssertThrowsError(try graph.connect(edge(1, 2, "nope"))) {
            XCTAssertEqual($0 as? Graph.ConnectError, .unknownPin)
        }
        XCTAssertThrowsError(try graph.connect(edge(9, 2))) {
            XCTAssertEqual($0 as? Graph.ConnectError, .unknownPin)
        }
    }

    func test_一个input最多一条入边_往已占用的input上连线等于替换并返回被顶掉的旧线() throws {
        var graph = try makeGraph([source(1), source(2), unary(3)], [edge(1, 3)])
        let displaced = try graph.connect(edge(2, 3))
        XCTAssertEqual(displaced, edge(1, 3))
        XCTAssertEqual(graph.edges, [edge(2, 3)])
    }

    func test_一个output可以连出任意多条线() throws {
        let graph = try makeGraph([source(1), unary(2), unary(3)], [edge(1, 2), edge(1, 3)])
        XCTAssertEqual(graph.edges.count, 2)
    }

    func test_结构版本号只随节点和连线变化_改参数不动它() throws {
        var graph = try makeGraph([source(1), unary(2)], [edge(1, 2)])
        let version = graph.structureVersion
        graph.setParam(nid(2), "radius", .scalar(4))
        XCTAssertEqual(graph.structureVersion, version)
        graph.disconnect(edge(1, 2))
        XCTAssertEqual(graph.structureVersion, version + 1)
    }

    func test_删除节点返回节点本身和它的全部连线_撤销要靠这份返回值() throws {
        var graph = try makeGraph([source(1), unary(2), unary(3)], [edge(1, 2), edge(2, 3)])
        let removed = try XCTUnwrap(graph.remove(nid(2)))
        XCTAssertEqual(removed.node, unary(2))
        XCTAssertEqual(Set(removed.edges), [edge(1, 2), edge(2, 3)])
        XCTAssertTrue(graph.edges.isEmpty)
        XCTAssertNil(graph.remove(nid(2)))
    }

    func test_setParam返回旧值_原来没有这个参数时旧值是nil而不是节点不存在() throws {
        var graph = try makeGraph([unary(1)], [])
        XCTAssertEqual(graph.setParam(nid(1), "radius", .scalar(2)), .changed(old: nil))
        XCTAssertEqual(graph.setParam(nid(1), "radius", .scalar(5)), .changed(old: .scalar(2)))
        XCTAssertEqual(graph.setParam(nid(9), "radius", .scalar(5)), .nodeMissing)
    }

    func test_插入同ID节点必须拒绝而不是静默覆盖() throws {
        var graph = try makeGraph([unary(1)], [])
        let before = graph
        XCTAssertThrowsError(try graph.insert(source(1))) {
            XCTAssertEqual($0 as? Graph.InsertError, .duplicateNode(nid(1)))
        }
        XCTAssertEqual(graph, before)
    }
}

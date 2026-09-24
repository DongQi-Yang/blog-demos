import XCTest
@testable import FilterGraph

final class PersistenceTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func test_命令就是变更日志_上次快照加重放日志等于崩溃前的图() throws {
        var graph = try makeGraph([source(1), unary(2)], [edge(1, 2)])
        let snapshot = try encoder.encode(graph)                 // 上一次完整保存
        var history = History()
        var journal: [Data] = []                                 // 每条命令几十字节，追加写
        func record(_ command: Command?) throws { if let command { journal.append(try encoder.encode(command)) } }

        try record(history.perform(.insertNode(blend(3)), on: &graph))
        try record(history.perform(.connect(edge(2, 3, "a")), on: &graph))
        for frame in 1...30 {
            try record(history.perform(.setParam(nid(2), "radius", .scalar(Float(frame))), key: "drag", on: &graph))
        }
        try record(history.perform(.removeNode(nid(1)), on: &graph))
        try record(history.undo(on: &graph))
        try record(history.undo(on: &graph))
        try record(history.redo(on: &graph))
        // —— 进程在这里被杀 ——

        var recovered = try decoder.decode(Graph.self, from: snapshot)
        for line in journal { _ = try decoder.decode(Command.self, from: line).apply(to: &recovered) }
        XCTAssertEqual(recovered, graph)
    }

    func test_图的序列化往返无损() throws {
        var graph = try makeGraph([source(1), unary(2), blend(3)], [edge(1, 2), edge(2, 3, "a"), edge(1, 3, "b")])
        graph.setParam(nid(2), "tint", .color(SIMD4(1, 0.5, 0, 1)))
        XCTAssertEqual(try decoder.decode(Graph.self, from: encoder.encode(graph)), graph)
    }

    func test_手改过的工程文件带环时解码必须失败_不能绕过connect的校验() throws {
        let graph = try makeGraph([unary(1), unary(2)], [edge(1, 2)])
        var json = try XCTUnwrap(String(data: encoder.encode(graph), encoding: .utf8))
        // 在 edges 数组里再塞一条 2 → 1，构成环
        let reversed = String(data: try encoder.encode(edge(2, 1)), encoding: .utf8)!
        json = json.replacingOccurrences(of: "\"edges\":[", with: "\"edges\":[\(reversed),")
        XCTAssertThrowsError(try decoder.decode(Graph.self, from: Data(json.utf8))) {
            // 先接上的那条会被接受，后接的那条闭合了环——被拒绝的必然是环上的两条边之一
            guard case let .invalidEdge(rejected)? = $0 as? Graph.CorruptGraph else { return XCTFail("\($0)") }
            XCTAssertTrue([edge(1, 2), edge(2, 1)].contains(rejected))
        }
    }

    func test_工程文件里同一个input有两条入边时解码必须失败() throws {
        let graph = try makeGraph([source(1), source(2), unary(3)], [edge(1, 3)])
        var json = try XCTUnwrap(String(data: encoder.encode(graph), encoding: .utf8))
        let second = String(data: try encoder.encode(edge(2, 3)), encoding: .utf8)!
        json = json.replacingOccurrences(of: "\"edges\":[", with: "\"edges\":[\(second),")
        XCTAssertThrowsError(try decoder.decode(Graph.self, from: Data(json.utf8)))
    }

    func test_解码恢复存盘时的结构版本号_而不是按重建的次数重新累加() throws {
        // 删过节点的图：版本号（6）已经不等于"节点数 + 连线数"（3），重建时顺带累加出来的会是 3
        var graph = try makeGraph([source(1), unary(2), unary(3)], [edge(1, 2), edge(2, 3)])
        graph.remove(nid(3))
        XCTAssertEqual(graph.structureVersion, 6)
        let decoded = try decoder.decode(Graph.self, from: encoder.encode(graph))
        XCTAssertEqual(decoded.structureVersion, graph.structureVersion)
    }
}

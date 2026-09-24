import XCTest
@testable import FilterGraph

final class HistoryTests: XCTestCase {
    private func brightness(_ value: Float) -> Command { .setParam(nid(2), "brightness", .scalar(value)) }

    func test_拖一次滑杆120帧只产生一个撤销步骤_合并的边界是手势() throws {
        var graph = try makeGraph([source(1), unary(2, kind: "brightness")], [edge(1, 2)])
        graph.setParam(nid(2), "brightness", .scalar(0))
        var history = History()
        let gesture = UUID().uuidString
        for frame in 1...120 {
            try history.perform(brightness(Float(frame) / 120), key: "\(nid(2).raw)/brightness/\(gesture)", on: &graph)
        }
        XCTAssertEqual(history.undoCount, 1)
        try history.undo(on: &graph)
        XCTAssertEqual(graph.nodes[nid(2)]?.params["brightness"], .scalar(0))     // 一步回到手势开始前
        try history.redo(on: &graph)
        XCTAssertEqual(graph.nodes[nid(2)]?.params["brightness"], .scalar(1))     // 一步跳到手势结束
    }

    func test_两次拖动是两个意图_中间停顿再短也不合并() throws {
        var graph = try makeGraph([source(1), unary(2, kind: "brightness")], [edge(1, 2)])
        var history = History()
        for gesture in ["g1", "g2"] {
            for frame in 1...10 {
                try history.perform(brightness(Float(frame)), key: "\(nid(2).raw)/brightness/\(gesture)", on: &graph)
            }
        }
        XCTAssertEqual(history.undoCount, 2)
    }

    func test_新操作清空重做栈() throws {
        var graph = try makeGraph([source(1), unary(2)], [])
        var history = History()
        try history.perform(.connect(edge(1, 2)), on: &graph)
        try history.undo(on: &graph)
        XCTAssertEqual(history.redoCount, 1)
        try history.perform(brightness(1), on: &graph)
        XCTAssertEqual(history.redoCount, 0)
    }

    func test_撤销时目标节点已不在_清空撤销栈并上报而不是吞掉错误() throws {
        var graph = try makeGraph([source(1), unary(2)], [edge(1, 2)])
        var history = History()
        try history.perform(brightness(0.5), on: &graph)
        try history.perform(brightness(0.7), on: &graph)
        graph.remove(nid(2))                                  // 有人绕过命令直接改了图
        let before = graph
        XCTAssertThrowsError(try history.undo(on: &graph)) {
            XCTAssertEqual($0 as? UndoError, .targetMissing(nid(2)))
        }
        XCTAssertEqual(history.undoCount, 0)                  // 对不上的撤销栈比没有撤销栈更危险
        XCTAssertEqual(history.redoCount, 0)
        XCTAssertEqual(graph, before)
    }

    func test_用户操作非法时图不变且撤销历史保留() throws {
        var graph = try makeGraph([unary(1), unary(2)], [])
        var history = History()
        try history.perform(.connect(edge(1, 2)), on: &graph)
        let before = graph
        XCTAssertThrowsError(try history.perform(.connect(edge(2, 1)), on: &graph))
        XCTAssertEqual(graph, before)
        XCTAssertEqual(history.undoCount, 1)
    }

    func test_group执行到一半失败时图保持原样_值语义白送的原子性() throws {
        var graph = try makeGraph([maskSource(1), unary(2)], [])
        let before = graph
        var history = History()
        let paste: Command = .group([.insertNode(unary(3)), .connect(edge(1, 2))])   // 第二步类型不符
        XCTAssertThrowsError(try history.perform(paste, on: &graph)) {
            XCTAssertEqual($0 as? Graph.ConnectError, .typeMismatch)
        }
        XCTAssertEqual(graph, before)                         // 节点 3 没有被插进去一半
        XCTAssertEqual(history.undoCount, 0)
    }
}

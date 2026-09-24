import XCTest
@testable import FilterGraph

final class RenderPlanTests: XCTestCase {
    func test_20个节点的直链只要1个槽位_先释放再分配才能原地复用() throws {
        let nodes = [source(1)] + (2...20).map { unary($0) }
        let edges = (1..<20).map { edge($0, $0 + 1) }
        let graph = try makeGraph(nodes, edges)
        let plan = RenderPlan.compile(graph)
        XCTAssertEqual(plan.steps.map(\.node), (1...20).map(nid))
        XCTAssertEqual(plan.slotCount, 1)          // 而不是 20 张中间纹理
        assertNoLiveSlotConflict(plan, graph)
    }

    func test_画中画的菱形图_源被两处引用时两条分支各要一个槽位() throws {
        // 源 → 模糊 → blend.a；源 → 缩小 → blend.b
        let graph = try makeGraph([source(1), unary(2), unary(3, kind: "scale"), blend(4)],
                                  [edge(1, 2), edge(1, 3), edge(2, 4, "a"), edge(3, 4, "b")])
        let plan = RenderPlan.compile(graph)
        XCTAssertEqual(plan.slotCount, 2)
        assertNoLiveSlotConflict(plan, graph)
    }

    func test_同一个上游输出接进同一节点的两个输入时槽位只能释放一次() throws {
        // S → M.a、S → M.b；M → U；M.out 与 U.out 同时进 F
        // 原文的释放循环按"边"释放，S 的槽位会进两次空闲表，U 的输出会被分到 M.out 仍在用的槽位
        let graph = try makeGraph([source(1), blend(2), unary(3), blend(4)],
                                  [edge(1, 2, "a"), edge(1, 2, "b"), edge(2, 3), edge(2, 4, "a"), edge(3, 4, "b")])
        let plan = RenderPlan.compile(graph)
        assertNoLiveSlotConflict(plan, graph)
        XCTAssertEqual(plan.slotCount, 2)
    }

    func test_同一张图不论插入顺序都编译出同一份计划() throws {
        let nodes = [source(1), unary(2), unary(3, kind: "scale"), blend(4)]
        let edges = [edge(1, 2), edge(1, 3), edge(2, 4, "a"), edge(3, 4, "b")]
        let forward = try makeGraph(nodes, edges)
        let backward = try makeGraph(nodes.reversed(), edges.reversed())
        XCTAssertEqual(RenderPlan.compile(forward).steps, RenderPlan.compile(backward).steps)
    }

    func test_没接线的input在计划里是nil() throws {
        let graph = try makeGraph([source(1), blend(2)], [edge(1, 2, "a")])
        let step = try XCTUnwrap(RenderPlan.compile(graph).steps.last)
        XCTAssertEqual(step.inputSlots.count, 2)
        XCTAssertNotNil(step.inputSlots[0])
        XCTAssertNil(step.inputSlots[1])
    }

    func test_图是源码计划是编译产物_拖参数不重编译_改结构才重编译() throws {
        var graph = try makeGraph([source(1), unary(2)], [edge(1, 2)])
        var state = RenderState(graph)
        for value in stride(from: Float(0), to: 1, by: 0.01) {       // 拖一次滑杆，100 帧
            graph.setParam(nid(2), "radius", .scalar(value))
            state.publish(graph)
        }
        XCTAssertEqual(state.compileCount, 1)
        try graph.insert(unary(3))
        try graph.connect(edge(2, 3))
        state.publish(graph)
        XCTAssertEqual(state.compileCount, 2)
        XCTAssertEqual(state.plan.steps.count, 3)
    }

    func test_渲染侧拿到的是图的快照_之后的编辑不会改到它() throws {
        var editing = try makeGraph([source(1), unary(2)], [edge(1, 2)])
        let state = RenderState(editing)
        editing.setParam(nid(2), "radius", .scalar(9))
        editing.remove(nid(1))
        XCTAssertNil(state.graph.nodes[nid(2)]?.params["radius"])
        XCTAssertNotNil(state.graph.nodes[nid(1)])
    }

    func test_回滚到旧的图值再做另一处结构修改_版本号撞上也必须重编译() throws {
        // 图是值，"回到某个版本再改"是这套模型鼓励的用法；两条分支的结构版本号可能相同
        var graph = try makeGraph([source(1), unary(2)], [edge(1, 2)])
        let saved = graph
        try graph.insert(unary(3))
        try graph.connect(edge(2, 3))
        var state = RenderState(graph)
        graph = saved
        try graph.insert(unary(4))
        try graph.connect(edge(2, 4))
        XCTAssertEqual(graph.structureVersion, state.plan.structureVersion)   // 版本号确实撞上了
        state.publish(graph)
        XCTAssertEqual(state.plan.steps.map(\.node), [nid(1), nid(2), nid(4)])   // 计划必须对应当前的图
        assertNoLiveSlotConflict(state.plan, graph)
    }
}

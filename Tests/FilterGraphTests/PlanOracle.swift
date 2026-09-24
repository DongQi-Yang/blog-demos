import XCTest
@testable import FilterGraph

/// 独立的预言机：按计划模拟执行，检查每一步读到的槽位里装的确实是它上游的那个值。
/// 两个同时活着的值被分到同一个槽位时，后写的会覆盖先写的，这里就会报错。
func assertNoLiveSlotConflict(_ plan: RenderPlan, _ graph: Graph,
                              file: StaticString = #filePath, line: UInt = #line) {
    var holder: [Int: PinID] = [:]
    for step in plan.steps {
        let node = graph.nodes[step.node]!
        for (index, spec) in node.inputs.enumerated() {
            let pin = PinID(node: step.node, name: spec.name)
            guard let upstream = graph.edges.first(where: { $0.to == pin })?.from else { continue }
            guard let slot = step.inputSlots[index] else {
                return XCTFail("\(pin) 接了线却没有分到输入槽位", file: file, line: line)
            }
            XCTAssertEqual(holder[slot], upstream, "\(pin) 从槽位 \(slot) 读到的不是它的上游值——槽位被覆盖了",
                           file: file, line: line)
        }
        for (index, spec) in node.outputs.enumerated() {
            holder[step.outputSlots[index]] = PinID(node: step.node, name: spec.name)
        }
    }
}

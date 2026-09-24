/// 执行计划：图是源码，计划是编译产物（原文坑 3）。渲染线程只认一个线性的 steps 数组。
public struct RenderPlan: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let node: NodeID
        /// 按 node.inputs 顺序；nil = 该 input 没接线
        public let inputSlots: [Int?]
        /// 按 node.outputs 顺序
        public let outputSlots: [Int]
    }

    public let steps: [Step]
    /// 需要几块中间纹理
    public let slotCount: Int
    public let structureVersion: UInt64

    /// Kahn 拓扑排序 + 槽位分配。槽位分配就是寄存器分配：每个值在最后一次被使用之后，槽位回收给别人（原文坑 4）。
    public static func compile(_ graph: Graph) -> RenderPlan {
        let order = topologicalOrder(graph)
        var position: [NodeID: Int] = [:]
        for (index, id) in order.enumerated() { position[id] = index }

        // input pin → 上游 output pin（单入边规则保证唯一）
        var source: [PinID: PinID] = [:]
        var lastUse: [PinID: Int] = [:]
        for edge in graph.edges {
            source[edge.to] = edge.from
            lastUse[edge.from] = max(lastUse[edge.from] ?? -1, position[edge.to.node]!)
        }

        var slotOf: [PinID: Int] = [:]
        var free: [Int] = []
        var next = 0
        var steps: [Step] = []

        for (index, id) in order.enumerated() {
            let node = graph.nodes[id]!
            let upstream: [PinID?] = node.inputs.map { source[PinID(node: id, name: $0.name)] }
            let inputSlots: [Int?] = upstream.map { $0.flatMap { slotOf[$0] } }

            // 先释放再分配，才能原地复用。同一个上游输出可能接进本节点的多个输入——只能释放一次，
            // 否则同一个槽位进两次空闲表，之后会被分给两个同时活着的值（原文示例代码的问题）。
            var released = Set<PinID>()
            for case let pin? in upstream where lastUse[pin] == index && released.insert(pin).inserted {
                if let slot = slotOf[pin] { free.append(slot) }
            }

            let outputSlots: [Int] = node.outputs.map { spec in
                let slot: Int
                if let reused = free.popLast() {
                    slot = reused
                } else {
                    slot = next
                    next += 1
                }
                slotOf[PinID(node: id, name: spec.name)] = slot
                return slot
            }
            steps.append(Step(node: id, inputSlots: inputSlots, outputSlots: outputSlots))
        }
        return RenderPlan(steps: steps, slotCount: next, structureVersion: graph.structureVersion)
    }

    /// Kahn 算法；同时就绪的节点按 NodeID 排序，保证同一张图永远编译出同一份计划。
    static func topologicalOrder(_ graph: Graph) -> [NodeID] {
        var indegree: [NodeID: Int] = [:]
        for id in graph.nodes.keys { indegree[id] = 0 }
        var successors: [NodeID: [NodeID]] = [:]
        for edge in graph.edges {
            indegree[edge.to.node, default: 0] += 1
            successors[edge.from.node, default: []].append(edge.to.node)
        }
        var ready = indegree.filter { $0.value == 0 }.map(\.key).sorted()
        var order: [NodeID] = []
        while !ready.isEmpty {
            let id = ready.removeFirst()
            order.append(id)
            for next in successors[id] ?? [] {
                indegree[next]! -= 1
                if indegree[next] == 0 {
                    ready.append(next)
                    ready.sort()
                }
            }
        }
        precondition(order.count == graph.nodes.count, "图里有环——Graph 的不变量被破坏")
        return order
    }
}

/// 渲染侧持有的「图快照 + 编译产物」。Graph 是值类型，渲染侧拿到的是一份不会再变的值；
/// 只有结构真的变了才重新编译，参数变化只是换一份快照（原文坑 3、坑 7）。
///
/// 结构版本号只在同一条编辑历史里单调递增：把图回滚到某个旧值再做另一处结构修改，
/// 两条分支的版本号可能相同。所以版本号只当快速路径——不同就一定重编译；相同时再比对结构本身。
public struct RenderState: Sendable {
    public private(set) var graph: Graph
    public private(set) var plan: RenderPlan
    /// 编译次数（可观测性：参数拖动时它不该涨）
    public private(set) var compileCount = 1
    /// 编出当前 plan 的那张图
    private var compiledFrom: Graph

    public init(_ graph: Graph) {
        self.graph = graph
        self.plan = RenderPlan.compile(graph)
        self.compiledFrom = graph
    }

    public mutating func publish(_ graph: Graph) {
        self.graph = graph
        guard plan.structureVersion != graph.structureVersion
                || !Self.sameStructure(compiledFrom, graph) else { return }
        plan = RenderPlan.compile(graph)
        compiledFrom = graph
        compileCount += 1
    }

    /// 结构 = 节点集合 + 每个节点的 pin + 连线；参数不算。只比较、不分配，拖参数时每帧调用也便宜。
    static func sameStructure(_ a: Graph, _ b: Graph) -> Bool {
        guard a.nodes.count == b.nodes.count, a.edges == b.edges else { return false }
        for (id, node) in a.nodes {
            guard let other = b.nodes[id], other.inputs == node.inputs, other.outputs == node.outputs else { return false }
        }
        return true
    }
}

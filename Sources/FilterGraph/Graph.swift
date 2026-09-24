/// 编辑器的图：值类型，任何一个版本都是完整的值，可拷贝、比较、序列化（原文坑 2、坑 7）。
/// 每个 mutating 方法都把被覆盖的旧信息返回出去——撤销系统一行额外状态都不用存（原文坑 1、坑 5）。
public struct Graph: Equatable, Sendable {
    public private(set) var nodes: [NodeID: Node] = [:]
    public private(set) var edges: Set<Edge> = []
    /// 结构版本号：节点/连线变化时递增；参数变化不动它（原文坑 3）
    /// 解码时要恢复存盘的版本号，所以 setter 是 internal（GraphCoding.swift）
    public internal(set) var structureVersion: UInt64 = 0

    public enum ConnectError: Error, Equatable {
        case unknownPin, typeMismatch, wouldCycle
    }

    public enum InsertError: Error, Equatable {
        case duplicateNode(NodeID)
    }

    /// setParam 的结果。原文用 `Param?` 同时表示"节点不存在"和"原来没有这个参数"，两者撞在一起。
    public enum ParamChange: Equatable, Sendable {
        case nodeMissing
        case changed(old: Param?)
    }

    public init() {}

    public func pinType(_ pin: PinID, isInput: Bool) -> PinType? {
        guard let node = nodes[pin.node] else { return nil }
        let specs = isInput ? node.inputs : node.outputs
        return specs.first { $0.name == pin.name }?.type
    }

    /// 往已占用的 input 上连线 = 替换旧连线；返回被顶掉的旧连线，撤销要靠它。
    /// 非法的连线（未知 pin、类型不符、成环）在进入图之前就被拦住。
    @discardableResult
    public mutating func connect(_ edge: Edge) throws -> Edge? {
        guard let fromType = pinType(edge.from, isInput: false),
              let toType = pinType(edge.to, isInput: true) else { throw ConnectError.unknownPin }
        guard fromType == toType else { throw ConnectError.typeMismatch }
        guard !reaches(from: edge.to.node, to: edge.from.node) else { throw ConnectError.wouldCycle }

        let displaced = edges.first { $0.to == edge.to }
        if let displaced { edges.remove(displaced) }
        edges.insert(edge)
        structureVersion += 1
        return displaced
    }

    /// 返回是否真的断开了一条线。原文不区分，导致"断开不存在的线"的逆命令会凭空接出一条线。
    @discardableResult
    public mutating func disconnect(_ edge: Edge) -> Bool {
        guard edges.remove(edge) != nil else { return false }
        structureVersion += 1
        return true
    }

    /// 同 ID 的节点已存在时拒绝：静默覆盖会让旧连线指向不存在的 pin，逆命令也会删掉原来的节点。
    public mutating func insert(_ node: Node) throws {
        guard nodes[node.id] == nil else { throw InsertError.duplicateNode(node.id) }
        nodes[node.id] = node
        structureVersion += 1
    }

    /// 删除节点并返回它和所有受影响的连线。撤销要靠这份返回值。
    @discardableResult
    public mutating func remove(_ id: NodeID) -> (node: Node, edges: [Edge])? {
        guard let node = nodes.removeValue(forKey: id) else { return nil }
        let touched = edges.filter { $0.from.node == id || $0.to.node == id }
        edges.subtract(touched)
        structureVersion += 1
        return (node, Array(touched))
    }

    /// value 为 nil 表示删除这个参数。参数变化不动 structureVersion。
    @discardableResult
    public mutating func setParam(_ id: NodeID, _ key: String, _ value: Param?) -> ParamChange {
        guard var node = nodes[id] else { return .nodeMissing }
        let old = node.params[key]
        node.params[key] = value
        nodes[id] = node
        return .changed(old: old)
    }

    /// a 能否沿有向边走到 b（成环检测）
    func reaches(from a: NodeID, to b: NodeID) -> Bool {
        var stack = [a]
        var seen = Set<NodeID>()
        while let current = stack.popLast() {
            if current == b { return true }
            guard seen.insert(current).inserted else { continue }
            for edge in edges where edge.from.node == current { stack.append(edge.to.node) }
        }
        return false
    }
}

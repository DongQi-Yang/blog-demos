public enum UndoError: Error, Equatable {
    /// 命令指向的节点不在图里：撤销栈和图已经对不上了
    case targetMissing(NodeID)
    /// 恢复连线时目标 input 已被占用：静默顶掉会丢一条用户的连线
    case inputOccupied(PinID)
}

/// 命令是 enum，不是闭包：闭包会捕获对象引用，而且不能序列化（原文坑 5、坑 8）。
public indirect enum Command: Codable, Equatable, Sendable {
    /// value 为 nil 表示删除这个参数
    case setParam(NodeID, String, Param?)
    case insertNode(Node)
    case removeNode(NodeID)
    /// removeNode 的逆
    case restoreNode(Node, [Edge])
    case connect(Edge)
    case disconnect(Edge)
    /// 复合命令，作为一个撤销步骤
    case group([Command])

    /// 应用到图上，返回逆命令。逆命令在「做」的时候捕获，而不是在撤销时计算——
    /// 撤销需要的旧值、被顶掉的边、被删节点的连线，在操作之后就不存在了。
    public func apply(to graph: inout Graph) throws -> Command {
        switch self {
        case let .setParam(id, key, value):
            guard case let .changed(old) = graph.setParam(id, key, value) else { throw UndoError.targetMissing(id) }
            return .setParam(id, key, old)

        case let .insertNode(node):
            try graph.insert(node)
            return .removeNode(node.id)

        case let .removeNode(id):
            guard let removed = graph.remove(id) else { throw UndoError.targetMissing(id) }
            return .restoreNode(removed.node, removed.edges)

        case let .restoreNode(node, touched):
            try graph.insert(node)
            for edge in touched {
                // 原文用 try? 吞掉错误；但恢复失败恰恰说明撤销栈和图对不上了，必须抛出
                guard !graph.edges.contains(where: { $0.to == edge.to }) else { throw UndoError.inputOccupied(edge.to) }
                try graph.connect(edge)
            }
            return .removeNode(node.id)

        case let .connect(edge):
            if let displaced = try graph.connect(edge) {
                // 顶掉了旧连线：撤销 = 断开新的 + 接回旧的
                return .group([.disconnect(edge), .connect(displaced)])
            }
            return .disconnect(edge)

        case let .disconnect(edge):
            // 什么都没断开时，逆命令也什么都不做——否则撤销会凭空接出一条原来没有的线
            return graph.disconnect(edge) ? .connect(edge) : .group([])

        case let .group(commands):
            var inverses: [Command] = []
            for command in commands { inverses.append(try command.apply(to: &graph)) }
            return .group(inverses.reversed())      // 逆序！
        }
    }
}

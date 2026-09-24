/// 命令式撤销（原文坑 5、坑 6）。撤销的单位是「变更」，不是「状态」。
public struct History: Sendable {
    struct Entry: Sendable {
        var forward: Command
        var inverse: Command
        var coalesceKey: String?
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    public init() {}

    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }

    /// 执行一条命令。key 相同的连续命令合并成一个撤销步骤——合并的边界是手势，所以 key 里要带手势 ID，
    /// 不能按时间窗口合并。返回实际作用到图上的命令，崩溃恢复日志记录它（原文坑 8）。
    @discardableResult
    public mutating func perform(_ command: Command, key: String? = nil, on graph: inout Graph) throws -> Command {
        let inverse = try Self.applyAtomically(command, to: &graph)
        redoStack.removeAll()
        if let key, let last = undoStack.last, last.coalesceKey == key {
            // forward 用最新的，inverse 保留最早的：撤销一步回到手势开始前，重做一步跳到手势结束
            undoStack[undoStack.count - 1].forward = command
        } else {
            undoStack.append(Entry(forward: command, inverse: inverse, coalesceKey: key))
        }
        return command
    }

    /// 撤销时重新 apply 并重新捕获逆命令，而不是复用缓存的 forward。返回实际作用到图上的命令。
    @discardableResult
    public mutating func undo(on graph: inout Graph) throws -> Command? {
        guard let entry = undoStack.popLast() else { return nil }
        let redoInverse = try applyOrReset(entry.inverse, to: &graph)
        redoStack.append(Entry(forward: entry.inverse, inverse: redoInverse, coalesceKey: nil))
        return entry.inverse
    }

    @discardableResult
    public mutating func redo(on graph: inout Graph) throws -> Command? {
        guard let entry = redoStack.popLast() else { return nil }
        let undoInverse = try applyOrReset(entry.inverse, to: &graph)
        undoStack.append(Entry(forward: entry.inverse, inverse: undoInverse, coalesceKey: nil))
        return entry.inverse
    }

    /// 撤销/重做失败说明撤销栈和图已经对不上：清空撤销栈并把错误抛给调用方上报，不吞掉继续。
    /// 一个对不上的撤销栈比没有撤销栈更危险。
    private mutating func applyOrReset(_ command: Command, to graph: inout Graph) throws -> Command {
        do {
            return try Self.applyAtomically(command, to: &graph)
        } catch {
            undoStack.removeAll()
            redoStack.removeAll()
            throw error
        }
    }

    /// 在图的副本上应用，成功才提交：group 执行到一半失败时，图保持原样。
    /// 这是值语义白送的原子性——图若是引用类型，这里就得手写回滚。
    private static func applyAtomically(_ command: Command, to graph: inout Graph) throws -> Command {
        var draft = graph
        let inverse = try command.apply(to: &draft)
        graph = draft
        return inverse
    }
}

# Plan 2：FilterGraph（B1 滤镜图内核与撤销重做）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `blog-demos` 里交付第二个 demo `FilterGraph`，对应掘金 B1《视频编辑器的滤镜图内核》：Node/Pin/Edge 图模型、编译成渲染计划（拓扑序 + 槽位分配）、命令式撤销重做（逆命令在做的时候捕获、按手势合并）、命令即变更日志的崩溃恢复。34 条测试，每条论断测试都用 mutation 证明过能变红。

**Architecture:** 纯 Swift 值类型、只依赖 Foundation，不含任何 GPU 资源（这正是原文的核心边界）。`Graph` 是值，所有 `mutating` 方法把被覆盖的旧信息返回出去；`Command` 是可序列化的 enum，`apply` 返回逆命令；`History` 在图的副本上应用命令保证原子性；`RenderPlan.compile` 做 Kahn 拓扑排序 + 生命周期分析分配槽位；`RenderState` 只在结构版本变化时重编译。

**Tech Stack:** Swift 6.0 tools / Swift 6 语言模式，macOS 14+，XCTest。

**Spec:** `docs/superpowers/specs/2026-09-22-blog-demos-design.md`（本计划实现 §9 第 3 步的 FilterGraph；§5.1 B1 首条测试名按原文更正，见下）

**文章原文（论断来源）：** `~/Desktop/个人资料/博客03-滤镜图内核与撤销重做.md`，线上 https://juejin.cn/post/7682406523184316454

**计划的可信度：** 本计划的全部代码在编写时已在 scratchpad 的独立包里跑通：34/34 通过、0 warning；并对 10 处关键行为逐一做了 mutation（把原文写法或错误写法放回去），对应测试全部变红。

## Global Constraints

- 沿用 Plan 1：`// swift-tools-version: 6.0`，`platforms: [.macOS(.v14)]`，零第三方依赖，只用 XCTest
- `FilterGraph` library 只 `import Foundation`，**不得 import `FMP4Muxer`**（demo 之间零耦合）；本计划不给 `DemoCLI` 增加子命令（spec §6 没有为 B1 规定产物）
- 论断测试方法名 = 原文里的那句话；断言必须"实现写错就会红"，并在对应 Task 的 mutation 步骤里当场证明
- 与原文示例代码不同的地方一律写进 README，不静默改
- 执行时测试命令统一加 `--disable-swift-testing`（Plan 1 的 Ruling：否则最后一行是 swift-testing 的空运行结果）
- 每个 commit message 结尾：`Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`
- 推送在最终审查通过、合并 `main` 之后执行（沿用 Plan 1 Task 9 的 Ruling）；gh token 已有 `workflow` scope

## 对 spec 的一处更正（Task 6 落盘）

spec §5.1 B1 首条测试名写的是"成环的连接必须被拒绝**而不是在渲染时栈溢出**"。原文没有"渲染时栈溢出"的说法，原文是："成环检测放在 `connect` 里而不是渲染时……**图的非法状态要在进入图之前拦住**"。本计划按原文命名：`test_成环的连线在connect时就被拒绝_非法的图不进入图()`。

## Review Focus

以下输入类最可能在真实使用中出问题；每条都已在对应 Task 里有测试锁住：

1. **同一个上游输出接进同一节点的多个输入** —— 槽位只能释放一次，否则两个同时活着的值共用一个槽位（Task 2：`test_同一个上游输出接进同一节点的两个输入时槽位只能释放一次`，由独立的槽位预言机 `assertNoLiveSlotConflict` 判定）
2. **撤销栈和图对不上（有人绕过命令直接改了图）** —— 撤销必须报错、清空撤销栈，图不变（Task 4：`test_撤销时目标节点已不在_清空撤销栈并上报而不是吞掉错误`；Task 3：`test_恢复节点时它的input已被别人占用必须报错而不是静默顶掉`）
3. **复合命令执行到一半失败** —— 图必须保持原样（Task 4：`test_group执行到一半失败时图保持原样_值语义白送的原子性`）
4. **手改过或损坏的工程文件** —— 带环、同一 input 两条入边的图必须解码失败（Task 5：`test_手改过的工程文件带环时解码必须失败_不能绕过connect的校验`、`test_工程文件里同一个input有两条入边时解码必须失败`）
5. **重复 ID 的节点** —— 插入必须拒绝而不是静默覆盖（Task 1：`test_插入同ID节点必须拒绝而不是静默覆盖`）

已知限制（不在本计划范围，写进代码注释即可）：`RenderState` 用结构版本号判断是否重编译，只适用于同一编辑会话内的同一张图；换工程应新建 `RenderState`。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `Package.swift` | 增加 `FilterGraph` library 与 `FilterGraphTests` |
| `Sources/FilterGraph/Model.swift` | `NodeID` / `PinID` / `PinType` / `PinSpec` / `Param` / `Node` / `Edge`，全部纯数据 |
| `Sources/FilterGraph/Graph.swift` | 图与编辑操作：连线规则（类型、单入边、成环）、返回旧信息的 mutating 方法 |
| `Sources/FilterGraph/RenderPlan.swift` | 编译：Kahn 拓扑排序 + 槽位分配；`RenderState`（快照 + 只在结构变化时重编译） |
| `Sources/FilterGraph/Command.swift` | 命令 enum 与逆命令、`UndoError` |
| `Sources/FilterGraph/History.swift` | 撤销/重做栈、按手势合并、原子应用、对不上时清栈 |
| `Sources/FilterGraph/GraphCoding.swift` | `Graph` 的 Codable：解码时重新校验不变量 |
| `Tests/FilterGraphTests/TestSupport.swift` | 固定 ID、节点/连线构造器 |
| `Tests/FilterGraphTests/PlanOracle.swift` | 独立的槽位冲突预言机 |
| `Tests/FilterGraphTests/*Tests.swift` | 各组测试 |
| `README.md` | 表格加 B1 一行 + 「与原文示例代码的差异」一节 |

---
### Task 1: 图模型与编辑规则

**Files:**
- Modify: `Package.swift`
- Create: `Sources/FilterGraph/Model.swift`, `Sources/FilterGraph/Graph.swift`
- Test: `Tests/FilterGraphTests/TestSupport.swift`, `Tests/FilterGraphTests/GraphTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `NodeID(_ raw: UUID = UUID())`（`Comparable`，按 uuidString）、`PinID(node:name:)`、`PinType { image, mask, scalar, color }`、`PinSpec(name:type:)`、`Param { scalar(Float), color(SIMD4<Float>), string(String) }`、`Node(id:kind:params:inputs:outputs:)`、`Edge(from:to:)`
  - `Graph`：`nodes: [NodeID: Node]`、`edges: Set<Edge>`、`structureVersion: UInt64`（`internal(set)`）；`connect(_:) throws -> Edge?`、`disconnect(_:) -> Bool`、`insert(_:) throws`、`remove(_:) -> (node: Node, edges: [Edge])?`、`setParam(_:_:_: Param?) -> ParamChange`、`pinType(_:isInput:)`
  - `Graph.ConnectError { unknownPin, typeMismatch, wouldCycle }`、`Graph.InsertError { duplicateNode(NodeID) }`、`Graph.ParamChange { nodeMissing, changed(old: Param?) }`
  - 测试辅助：`nid(_:)`、`image(_:)`、`source(_:)`、`unary(_:kind:)`、`blend(_:)`、`maskSource(_:)`、`edge(_:_:_:output:)`、`makeGraph(_:_:) throws -> Graph`

- [ ] **Step 1: 修改 `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlogDemos",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FMP4Muxer", targets: ["FMP4Muxer"]),
        .library(name: "FilterGraph", targets: ["FilterGraph"]),
        .executable(name: "blog-demos", targets: ["DemoCLI"]),
    ],
    targets: [
        .target(name: "FMP4Muxer"),
        .target(name: "FilterGraph"),
        .executableTarget(name: "DemoCLI", dependencies: ["FMP4Muxer"]),
        .testTarget(name: "FMP4MuxerTests", dependencies: ["FMP4Muxer"]),
        .testTarget(name: "FilterGraphTests", dependencies: ["FilterGraph"]),
    ]
)
```

- [ ] **Step 2: 写测试辅助 `Tests/FilterGraphTests/TestSupport.swift`**

```swift
import Foundation
import XCTest
@testable import FilterGraph

/// 固定的节点 ID：n=1 → 00000000-0000-0000-0000-000000000001。拓扑排序同层按 ID 排，测试结果因此确定。
func nid(_ n: Int) -> NodeID {
    NodeID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
}

func image(_ name: String) -> PinSpec { PinSpec(name: name, type: .image) }

func source(_ n: Int) -> Node { Node(id: nid(n), kind: "source", outputs: [image("out")]) }

func unary(_ n: Int, kind: String = "blur") -> Node {
    Node(id: nid(n), kind: kind, inputs: [image("in")], outputs: [image("out")])
}

func blend(_ n: Int) -> Node {
    Node(id: nid(n), kind: "blend", inputs: [image("a"), image("b")], outputs: [image("out")])
}

func maskSource(_ n: Int) -> Node {
    Node(id: nid(n), kind: "matte", outputs: [PinSpec(name: "out", type: .mask)])
}

func edge(_ from: Int, _ to: Int, _ input: String = "in", output: String = "out") -> Edge {
    Edge(from: PinID(node: nid(from), name: output), to: PinID(node: nid(to), name: input))
}

func makeGraph(_ nodes: [Node], _ edges: [Edge]) throws -> Graph {
    var graph = Graph()
    for node in nodes { try graph.insert(node) }
    for edge in edges { try graph.connect(edge) }
    return graph
}
```

- [ ] **Step 3: 写失败的测试 `Tests/FilterGraphTests/GraphTests.swift`**

```swift
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
```

- [ ] **Step 4: 运行，确认失败**

Run: `mkdir -p Sources/FilterGraph && swift test --disable-swift-testing --filter FilterGraphTests.GraphTests`
Expected: 失败。若报 `target 'FilterGraph' referenced in product 'FilterGraph' is empty`（空 target，Plan 1 Task 1 同款），先完成 Step 5 的 `Model.swift` 再跑，此时应报 `cannot find 'Graph' in scope`

- [ ] **Step 5: 实现 `Sources/FilterGraph/Model.swift`**

```swift
import Foundation

/// 节点身份。图里没有对象，只有 ID（原文坑 2）：撤销恢复节点时用原 ID，所有持有它的地方自动重新有效。
public struct NodeID: Hashable, Codable, Sendable, Comparable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public static func < (lhs: NodeID, rhs: NodeID) -> Bool { lhs.raw.uuidString < rhs.raw.uuidString }
}

/// Pin 用「节点 ID + 名字」定位，不用索引：索引会在节点增删 pin 后失效，名字不会。
public struct PinID: Hashable, Codable, Sendable {
    public let node: NodeID
    public let name: String
    public init(node: NodeID, name: String) {
        self.node = node
        self.name = name
    }
}

public enum PinType: String, Codable, Sendable {
    case image, mask, scalar, color
}

public struct PinSpec: Hashable, Codable, Sendable {
    public let name: String
    public let type: PinType
    public init(name: String, type: PinType) {
        self.name = name
        self.type = type
    }
}

public enum Param: Codable, Equatable, Sendable {
    case scalar(Float)
    case color(SIMD4<Float>)
    case string(String)
}

/// 纯数据，不持有任何 GPU 资源——撤销、多线程、崩溃恢复都靠这条边界（原文坑 1 第 3 条）。
public struct Node: Codable, Equatable, Sendable {
    public let id: NodeID
    public var kind: String
    public var params: [String: Param]
    public var inputs: [PinSpec]
    public var outputs: [PinSpec]

    public init(id: NodeID = NodeID(), kind: String, params: [String: Param] = [:],
                inputs: [PinSpec] = [], outputs: [PinSpec] = []) {
        self.id = id
        self.kind = kind
        self.params = params
        self.inputs = inputs
        self.outputs = outputs
    }
}

/// from 是某个节点的 output，to 是某个节点的 input
public struct Edge: Hashable, Codable, Sendable {
    public let from: PinID
    public let to: PinID
    public init(from: PinID, to: PinID) {
        self.from = from
        self.to = to
    }
}
```

- [ ] **Step 6: 实现 `Sources/FilterGraph/Graph.swift`**

```swift
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
```

- [ ] **Step 7: 运行，确认通过**

Run: `swift test --disable-swift-testing --filter FilterGraphTests.GraphTests`
Expected: `Executed 9 tests, with 0 failures`

- [ ] **Step 8: mutation 验证**

   - **M7 insert 静默覆盖**：在 `Sources/FilterGraph/Graph.swift` 里把
```swift
guard nodes[node.id] == nil else { throw InsertError.duplicateNode(node.id) }
```
     临时改成
```swift
// （删掉这一行）
```
     运行 `swift test --disable-swift-testing --filter "FilterGraphTests.GraphTests/test_插入同ID节点必须拒绝而不是静默覆盖"`，Expected: 红。**改回原样**，再跑一次确认绿。

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/FilterGraph Tests/FilterGraphTests
git commit -m "feat(FilterGraph): Node/Pin/Edge 图模型与连线规则（类型、单入边、成环在 connect 时拒绝）

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---
### Task 2: 渲染计划编译（拓扑序 + 槽位分配）与 RenderState

**Files:**
- Create: `Sources/FilterGraph/RenderPlan.swift`
- Test: `Tests/FilterGraphTests/PlanOracle.swift`, `Tests/FilterGraphTests/RenderPlanTests.swift`

**Interfaces:**
- Consumes: `Graph`、`NodeID`、`PinID`、测试辅助（Task 1）
- Produces:
  - `RenderPlan { steps: [Step], slotCount: Int, structureVersion: UInt64; static func compile(_:) -> RenderPlan }`，`Step { node: NodeID, inputSlots: [Int?], outputSlots: [Int] }`
  - `RenderState { init(_ graph: Graph); graph; plan; compileCount: Int; mutating func publish(_:) }`
  - 测试预言机：`assertNoLiveSlotConflict(_ plan: RenderPlan, _ graph: Graph)`

- [ ] **Step 1: 写独立的槽位预言机 `Tests/FilterGraphTests/PlanOracle.swift`**

它不看槽位分配算法怎么写，只按计划模拟执行，检查每一步读到的槽位里装的是不是它的上游值。

```swift
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
```

- [ ] **Step 2: 写失败的测试 `Tests/FilterGraphTests/RenderPlanTests.swift`**

```swift
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
}
```

- [ ] **Step 3: 运行，确认失败**

Run: `swift test --disable-swift-testing --filter FilterGraphTests.RenderPlanTests`
Expected: 编译失败，`cannot find 'RenderPlan' in scope`

- [ ] **Step 4: 实现 `Sources/FilterGraph/RenderPlan.swift`**

```swift
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
/// 只有结构版本变了才重新编译，参数变化只是换一份快照（原文坑 3、坑 7）。
public struct RenderState: Sendable {
    public private(set) var graph: Graph
    public private(set) var plan: RenderPlan
    /// 编译次数（可观测性：参数拖动时它不该涨）
    public private(set) var compileCount = 1

    public init(_ graph: Graph) {
        self.graph = graph
        self.plan = RenderPlan.compile(graph)
    }

    public mutating func publish(_ graph: Graph) {
        self.graph = graph
        if plan.structureVersion != graph.structureVersion {
            plan = RenderPlan.compile(graph)
            compileCount += 1
        }
    }
}
```

- [ ] **Step 5: 运行，确认通过**

Run: `swift test --disable-swift-testing --filter FilterGraphTests.RenderPlanTests`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 6: mutation 验证（证明两条核心论断测试能变红）**

   - **M1 原文按边释放**：在 `Sources/FilterGraph/RenderPlan.swift` 里把
```swift
for case let pin? in upstream where lastUse[pin] == index && released.insert(pin).inserted {
```
     临时改成
```swift
for case let pin? in upstream where lastUse[pin] == index {
```
     运行 `swift test --disable-swift-testing --filter "FilterGraphTests.RenderPlanTests/test_同一个上游输出接进同一节点的两个输入时槽位只能释放一次"`，Expected: 红（预言机报"槽位被覆盖"）。**改回原样**，再跑一次确认绿。
   - **M10 先分配后释放**：把 `compile` 里"先释放"那段 `var released …` 循环整体挪到 `let outputSlots …` 之后，运行 `swift test --disable-swift-testing --filter "FilterGraphTests.RenderPlanTests/test_20个节点的直链只要1个槽位_先释放再分配才能原地复用"`，Expected: 红，`("2") is not equal to ("1")`。**改回原样**，再跑一次确认绿。

- [ ] **Step 7: Commit**

```bash
git add Sources/FilterGraph/RenderPlan.swift Tests/FilterGraphTests/PlanOracle.swift Tests/FilterGraphTests/RenderPlanTests.swift
git commit -m "feat(FilterGraph): 图编译成渲染计划，槽位分配即寄存器分配

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---
### Task 3: 命令与逆命令

**Files:**
- Create: `Sources/FilterGraph/Command.swift`
- Test: `Tests/FilterGraphTests/CommandTests.swift`

**Interfaces:**
- Consumes: `Graph` 的全部 mutating 方法与 `ParamChange`（Task 1）
- Produces:
  - `indirect enum Command: Codable, Equatable, Sendable { setParam(NodeID, String, Param?), insertNode(Node), removeNode(NodeID), restoreNode(Node, [Edge]), connect(Edge), disconnect(Edge), group([Command]) }`，`func apply(to: inout Graph) throws -> Command`（返回逆命令）
  - `UndoError { targetMissing(NodeID), inputOccupied(PinID) }`

- [ ] **Step 1: 写失败的测试 `Tests/FilterGraphTests/CommandTests.swift`**

```swift
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
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --disable-swift-testing --filter FilterGraphTests.CommandTests`
Expected: 编译失败，`cannot find 'Command' in scope`

- [ ] **Step 3: 实现 `Sources/FilterGraph/Command.swift`**

```swift
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
```

- [ ] **Step 4: 运行，确认通过**

Run: `swift test --disable-swift-testing --filter FilterGraphTests.CommandTests`
Expected: `Executed 8 tests, with 0 failures`

- [ ] **Step 5: mutation 验证（原文示例代码的写法逐条放回去，必须变红）**

   - **M2 原文 setParam 的 nil 二义性**：在 `Sources/FilterGraph/Command.swift` 里把
```swift
guard case let .changed(old) = graph.setParam(id, key, value) else { throw UndoError.targetMissing(id) }
```
     临时改成
```swift
guard case let .changed(old) = graph.setParam(id, key, value), old != nil else { throw UndoError.targetMissing(id) }
```
     运行 `swift test --disable-swift-testing --filter "FilterGraphTests.CommandTests/test_给原本没有的参数赋值_撤销后参数消失而不是报节点不存在"`，Expected: 红。**改回原样**，再跑一次确认绿。
   - **M3 原文 disconnect 的逆恒为 connect**：在 `Sources/FilterGraph/Command.swift` 里把
```swift
return graph.disconnect(edge) ? .connect(edge) : .group([])
```
     临时改成
```swift
graph.disconnect(edge); return .connect(edge)
```
     运行 `swift test --disable-swift-testing --filter "FilterGraphTests.CommandTests/test_断开一条不存在的连线_撤销不应凭空多出这条线"`，Expected: 红。**改回原样**，再跑一次确认绿。
   - **M4 原文 restoreNode 用 try? 吞错**：在 `Sources/FilterGraph/Command.swift` 里把
```swift
guard !graph.edges.contains(where: { $0.to == edge.to }) else { throw UndoError.inputOccupied(edge.to) }
try graph.connect(edge)
```
     临时改成
```swift
_ = try? graph.connect(edge)
```
     运行 `swift test --disable-swift-testing --filter "FilterGraphTests.CommandTests/test_恢复节点时它的input已被别人占用必须报错而不是静默顶掉"`，Expected: 红。**改回原样**，再跑一次确认绿。
   - **M5 group 的逆不逆序**：在 `Sources/FilterGraph/Command.swift` 里把
```swift
return .group(inverses.reversed())      // 逆序！
```
     临时改成
```swift
return .group(inverses)
```
     运行 `swift test --disable-swift-testing --filter "FilterGraphTests.CommandTests/test_group的逆必须逆序_否则连线会先于它依赖的节点恢复"`，Expected: 红（unknownPin）。**改回原样**，再跑一次确认绿。

- [ ] **Step 6: Commit**

```bash
git add Sources/FilterGraph/Command.swift Tests/FilterGraphTests/CommandTests.swift
git commit -m "feat(FilterGraph): 命令式撤销——逆命令在做的时候捕获，修正原文示例代码三处边界

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---
### Task 4: 撤销历史（按手势合并、原子应用、对不上时清栈）

**Files:**
- Create: `Sources/FilterGraph/History.swift`
- Test: `Tests/FilterGraphTests/HistoryTests.swift`

**Interfaces:**
- Consumes: `Command.apply(to:)`、`UndoError`（Task 3）
- Produces: `struct History { init(); undoCount: Int; redoCount: Int; mutating func perform(_:key:on:) throws -> Command; mutating func undo(on:) throws -> Command?; mutating func redo(on:) throws -> Command? }`——三个方法都返回实际作用到图上的命令（Task 5 的日志记录它）

- [ ] **Step 1: 写失败的测试 `Tests/FilterGraphTests/HistoryTests.swift`**

```swift
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
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --disable-swift-testing --filter FilterGraphTests.HistoryTests`
Expected: 编译失败，`cannot find 'History' in scope`

- [ ] **Step 3: 实现 `Sources/FilterGraph/History.swift`**

```swift
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
```

- [ ] **Step 4: 运行，确认通过**

Run: `swift test --disable-swift-testing --filter FilterGraphTests.HistoryTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: mutation 验证**

   - **M6 不在副本上应用**：在 `Sources/FilterGraph/History.swift` 里把
```swift
var draft = graph
let inverse = try command.apply(to: &draft)
graph = draft
return inverse
```
     临时改成
```swift
return try command.apply(to: &graph)
```
     运行 `swift test --disable-swift-testing --filter "FilterGraphTests.HistoryTests/test_group执行到一半失败时图保持原样_值语义白送的原子性"`，Expected: 红。**改回原样**，再跑一次确认绿。
   - **M8 撤销失败不清栈**：在 `Sources/FilterGraph/History.swift` 里把
```swift
undoStack.removeAll()
redoStack.removeAll()
throw error
```
     临时改成
```swift
throw error
```
     运行 `swift test --disable-swift-testing --filter "FilterGraphTests.HistoryTests/test_撤销时目标节点已不在_清空撤销栈并上报而不是吞掉错误"`，Expected: 红。**改回原样**，再跑一次确认绿。
   - **M9 不合并**：在 `Sources/FilterGraph/History.swift` 里把
```swift
undoStack[undoStack.count - 1].forward = command
```
     临时改成
```swift
undoStack.append(Entry(forward: command, inverse: inverse, coalesceKey: key))
```
     运行 `swift test --disable-swift-testing --filter "FilterGraphTests.HistoryTests/test_拖一次滑杆120帧只产生一个撤销步骤_合并的边界是手势"`，Expected: 红。**改回原样**，再跑一次确认绿。

- [ ] **Step 6: Commit**

```bash
git add Sources/FilterGraph/History.swift Tests/FilterGraphTests/HistoryTests.swift
git commit -m "feat(FilterGraph): 撤销历史——合并边界是手势，group 失败图不变，栈与图对不上时清栈上报

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---
### Task 5: 序列化与崩溃恢复（命令即变更日志）

**Files:**
- Create: `Sources/FilterGraph/GraphCoding.swift`
- Test: `Tests/FilterGraphTests/PersistenceTests.swift`

**Interfaces:**
- Consumes: `Graph`（`structureVersion` 的 internal setter）、`Command`（Codable）、`History`（返回实际应用的命令）
- Produces: `extension Graph: Codable`，`Graph.CorruptGraph { duplicateNode(NodeID), invalidEdge(Edge) }`

- [ ] **Step 1: 写失败的测试 `Tests/FilterGraphTests/PersistenceTests.swift`**

```swift
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
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --disable-swift-testing --filter FilterGraphTests.PersistenceTests`
Expected: 编译失败，`Graph` 不遵循 `Decodable`/`Encodable`（或 `cannot find type 'CorruptGraph'`）

- [ ] **Step 3: 实现 `Sources/FilterGraph/GraphCoding.swift`**

```swift
extension Graph: Codable {
    /// 从磁盘读回来的图绕过了 connect 的校验——必须重新走一遍不变量，否则一个手改过的
    /// 工程文件就能把环、悬空连线、类型不符的连线带进图里。
    public enum CorruptGraph: Error, Equatable {
        case duplicateNode(NodeID)
        case invalidEdge(Edge)
    }

    private struct Stored: Codable {
        var nodes: [Node]
        var edges: [Edge]
        var structureVersion: UInt64
    }

    public init(from decoder: any Decoder) throws {
        let stored = try Stored(from: decoder)
        var graph = Graph()
        for node in stored.nodes {
            do { try graph.insert(node) } catch { throw CorruptGraph.duplicateNode(node.id) }
        }
        for edge in stored.edges {
            guard !graph.edges.contains(where: { $0.to == edge.to }) else { throw CorruptGraph.invalidEdge(edge) }
            do { try graph.connect(edge) } catch { throw CorruptGraph.invalidEdge(edge) }
        }
        graph.structureVersion = stored.structureVersion
        self = graph
    }

    public func encode(to encoder: any Encoder) throws {
        let sortedNodes = nodes.values.sorted { $0.id < $1.id }
        let sortedEdges = edges.sorted { Graph.sortKey($0) < Graph.sortKey($1) }
        try Stored(nodes: sortedNodes, edges: sortedEdges, structureVersion: structureVersion).encode(to: encoder)
    }

    static func sortKey(_ edge: Edge) -> String {
        "\(edge.from.node.raw.uuidString)/\(edge.from.name)>\(edge.to.node.raw.uuidString)/\(edge.to.name)"
    }
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `swift test --disable-swift-testing --filter FilterGraphTests.PersistenceTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: 全量回归**

Run: `swift build 2>&1 | grep -c "warning:"; swift test --disable-swift-testing 2>&1 | tail -1`
Expected: warning 数 `0`；`Executed 75 tests, with 0 failures`（FMP4Muxer 41 + FilterGraph 34）

- [ ] **Step 6: Commit**

```bash
git add Sources/FilterGraph/GraphCoding.swift Tests/FilterGraphTests/PersistenceTests.swift
git commit -m "feat(FilterGraph): 命令即变更日志——快照加重放恢复崩溃前的图，解码时重校验不变量

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---
### Task 6: README、spec 更正

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-22-blog-demos-design.md`

**Interfaces:**
- Consumes: 全部前序 Task 的测试名（README 引用它们，名字必须逐字一致）
- Produces: 可对外展示的 B1 部分

- [ ] **Step 1: README 表格加一行**

在 `## 文章 ↔ demo` 表格的 A2 那一行之后插入：

```markdown
| [视频编辑器的滤镜图内核：Node/Pin 模型怎么设计，撤销重做怎么才不崩](https://juejin.cn/post/7682406523184316454) | [`FilterGraph`](Sources/FilterGraph) | 成环的连线在 `connect` 时就拒绝；撤销 = 写回做的时候记下的旧值；`group` 的逆必须逆序；拖一次滑杆 120 帧只算一个撤销步骤（合并边界是手势）；20 个节点的直链只要 1 张中间纹理 | `swift test --filter FilterGraphTests` |
```

- [ ] **Step 2: README 论断清单补 B1 的几条**

在论断清单代码块里 `…` 那一行之前插入：

```text
test_成环的连线在connect时就被拒绝_非法的图不进入图
test_撤销等于把做的时候记下的旧值写回去_而不是做相反的操作
test_拖一次滑杆120帧只产生一个撤销步骤_合并的边界是手势
test_20个节点的直链只要1个槽位_先释放再分配才能原地复用
```

- [ ] **Step 3: README 在 `## 测试码流` 之前插入一节**

```markdown
## 与原文示例代码的差异：B1《滤镜图内核》

独立重写时，原文里的示例代码有 4 处在测试下站不住。每一处都是先把原文写法原样放回去、看着对应测试变红，再改成现在的实现：

| 原文写法 | 问题 | 锁住它的测试 |
|---|---|---|
| 槽位按"边"逐条释放 | 同一个上游输出接进同一节点的两个输入（blend 的 a、b 接同一个源）时，槽位进两次空闲表，之后被分给两个同时活着的值——画面被覆盖 | `test_同一个上游输出接进同一节点的两个输入时槽位只能释放一次` |
| `setParam` 返回 `Param?`，nil 表示节点不存在 | 给原本没有的参数赋值时旧值也是 nil，命令被误判为"节点不存在"而报错 | `test_给原本没有的参数赋值_撤销后参数消失而不是报节点不存在` |
| `disconnect` 的逆恒为 `connect` | 断开一条本来就不存在的线，撤销时会凭空接出这条线 | `test_断开一条不存在的连线_撤销不应凭空多出这条线` |
| `restoreNode` 里 `try? g.connect(e)` | 吞掉恢复失败；而恢复失败恰恰说明撤销栈和图对不上了（原文自己的立场） | `test_恢复节点时它的input已被别人占用必须报错而不是静默顶掉` |

另外两处是在原文思路上补的：`History` 在图的副本上应用命令、成功才提交（`group` 执行一半失败时图保持原样——值语义白送的原子性）；从磁盘解码的图重新走一遍 `connect` 的校验（手改过的工程文件不能把环带进来）。
```

- [ ] **Step 4: 核对 README 引用的测试名都真实存在**

Run: `for t in $(grep -oE 'test_[^` |]+' README.md | sort -u); do grep -rq "func $t(" Tests || echo "MISSING $t"; done; echo done`
Expected: 只输出 `done`，没有任何 `MISSING`

- [ ] **Step 5: 更正 spec**

在 `docs/superpowers/specs/2026-09-22-blog-demos-design.md` §5.1 表格里，把 `test_成环的连接必须被拒绝而不是在渲染时栈溢出()` 改为 `test_成环的连线在connect时就被拒绝_非法的图不进入图()`。

- [ ] **Step 6: 全量验证并提交**

Run: `swift test --disable-swift-testing 2>&1 | tail -1`
Expected: `Executed 75 tests, with 0 failures`

```bash
git add README.md docs/superpowers/specs/2026-09-22-blog-demos-design.md
git commit -m "docs: README 加 B1 与原文示例代码差异，spec 更正 B1 首条测试名

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review（计划作者已完成）

1. **Spec 覆盖**：§5（契约、首条论断测试已按原文更正）、§7（README 一行 + 差异说明）、§9 第 3 步（FilterGraph）、§10 铁律（零耦合：不 import FMP4Muxer；鲁棒性：Review Focus 五项全有测试）。§6 没有为 B1 规定产物，本计划不加 CLI 子命令。
2. **占位扫描**：无 TBD/TODO；每个代码步骤都是完整文件内容（由已跑通的 scratchpad 包原样导出）。
3. **类型一致性**：`Graph.ParamChange`、`Command.setParam(NodeID, String, Param?)`、`History.perform(_:key:on:) -> Command`、`RenderState.compileCount`、`assertNoLiveSlotConflict(_:_:)` 在各 Task 与测试中一致；Task 5 依赖 `structureVersion` 的 `internal(set)`，已在 Task 1 的 `Graph.swift` 里声明。
4. **测试计数**：Graph 9 + RenderPlan 7 + Command 8 + History 6 + Persistence 4 = 34；全量 41 + 34 = 75。
5. **mutation 清单**：M1–M10 共 10 处，编写计划时已在 scratchpad 全部实测变红。

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

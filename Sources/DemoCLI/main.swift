import Foundation
import FMP4Muxer

/// 生成 README 引用的产物。必须在包根目录运行：swift run blog-demos <子命令>
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artifacts = root.appendingPathComponent("docs/artifacts")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func runMux() throws {
    let fixtureURL = root.appendingPathComponent("Fixtures/solid_160x120_30f.h264fix")
    guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
        fail("找不到 \(fixtureURL.path)——请在包根目录运行")
    }
    let fixture = try H264Fixture(bytes: [UInt8](try Data(contentsOf: fixtureURL)))
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    let output = artifacts.appendingPathComponent("sample.mp4")
    try Data(try FMP4Writer.write(fixture: fixture)).write(to: output)
    print("wrote \(output.path)")
}

let commands: [String: () throws -> Void] = ["mux": runMux]

guard let name = CommandLine.arguments.dropFirst().first, let command = commands[name] else {
    fail("用法: swift run blog-demos <\(commands.keys.sorted().joined(separator: "|"))>")
}
do {
    try command()
} catch {
    fail("\(name) 失败：\(error)")
}

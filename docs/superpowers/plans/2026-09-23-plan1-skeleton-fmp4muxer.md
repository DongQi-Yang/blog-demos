# Plan 1：仓库骨架 + FMP4Muxer + 首次推送 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建好 `blog-demos` Swift Package 骨架，交付第一个 demo `FMP4Muxer`（对应掘金 A2《手写 fMP4 muxer》），让 `swift test` 全绿、产出一个能播的 `docs/artifacts/sample.mp4`，并首次推送到 `github.com/DongQi-Yang/blog-demos`（公开，CI 绿标）。

**Architecture:** 单一 Swift Package。`FMP4Muxer` 是只依赖 Foundation 的 library；`MP4Inspector` 是库内自带的"严格读者"，按 ISO/IEC 14496-12 解析 box 树并计算数据偏移，作为测试预言机；AVFoundation 只在测试里当第二个预言机使用。`DemoCLI` 是生成产物的可执行 target。测试 fixture 是一段用 VideoToolbox 一次性生成、随仓库提交的 H.264 码流，CI 不依赖编码器。

**Tech Stack:** Swift 6.0 tools / Swift 6 语言模式，macOS 14+，XCTest，GitHub Actions（macos-latest）。

**Spec:** `docs/superpowers/specs/2026-09-22-blog-demos-design.md`（本计划实现其 §9 第 1–2 步；其余 5 个 demo 各自单独成计划）

**文章原文（论断来源，测试名必须能在原文中找到依据）：** `~/Desktop/个人资料/博客07-手写fMP4muxer.md`，线上 https://juejin.cn/post/7683935700154056713

## Global Constraints

- `// swift-tools-version: 6.0`，`platforms: [.macOS(.v14)]`
- 零第三方依赖；`FMP4Muxer` library 只 `import Foundation`；测试 target 允许 `import AVFoundation` 作为预言机
- 测试框架只用 XCTest，不用 swift-testing
- 论断测试的方法名 = 文章里的那句话（中文，已实测 XCTest 能发现中文方法名），断言必须"实现写错就会红"，禁止 `XCTAssertNotNil` 式占位断言
- demo library 之间禁止互相 import；只有 `DemoCLI` 可以依赖多个 demo
- 所有代码为基于公开规范与文章结论的独立重写，不含任何雇主代码
- 产物写到 `docs/artifacts/`；仓库 `.gitignore` 已有 `!docs/` 覆盖全局规则，不得删除
- 每个 commit message 结尾：`Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## 对 spec 的两处更正（本计划 Task 9 落盘）

1. spec §5.1 A2 首条测试名写成了"tfhd 必须显式写 base_data_offset"。**原文第五节的解法是设 `default-base-is-moof`（0x020000）**。本计划按原文命名：`test_单轨能播加上第二条轨就坏_tfhd必须设default_base_is_moof()`。
2. 原文第三节说"缺了空索引表，AVFoundation 会直接拒绝"。**计划编写时在 macOS 26.5.2 实测：删掉 stts/stsc/stsz/stco 后，`AVURLAsset.isPlayable`、`AVAssetImageGenerator`、`AVAssetReader`（30 帧全解）、passthrough 导出全部成功。** 原文当时的观察对象是 iOS 相册。因此本计划**不写**"AVFoundation 拒绝缺表文件"的测试（那会是一条撒谎的测试），改为用 `MP4Inspector` 按规范的 "exactly one" 校验结构，并在 README 如实记录这一实测差异。

## Review Focus

以下输入/状态 spec 没有明说，但最可能在真实使用中出问题；每条都已在对应 Task 里补了测试：

1. **截断或魔数错误的 fixture 文件** —— 必须抛错，不能读出半帧或越界崩溃（Task 1：`test_截断的fixture必须报错而不是读出半帧`、`test_魔数不对必须拒绝`）
2. **box size 字段非法（< 8 或越过父容器）** —— 解析器必须抛错，不能死循环或越界（Task 3：`test_box尺寸非法必须报错而不是死循环或越界`）
3. **解码时间不单调的 sample** —— FragmentBuilder 必须拒绝，不能算出负 duration 再截断成巨大的 u32（Task 5：`test_解码时间不单调必须拒绝`）
4. **flush 之后才 finish** —— 最后一帧的兜底 duration 必须仍是"最后一个已知的真实值"，而不是退化成 1（Task 5：`test_正常结束时最后一帧用最后一个已知duration兜底_即使之前已经flush过`）
5. **第一帧不是关键帧的码流** —— writer 必须拒绝，因为那样写出的第一个分片不可独立解码（Task 7：`test_第一帧不是关键帧必须拒绝写出`）

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `Package.swift` | 包定义 |
| `Scripts/make-h264-fixture.swift` | 一次性工具：VideoToolbox 编 30 帧 160×120 H.264 → fixture 文件（不参与包构建） |
| `Fixtures/solid_160x120_30f.h264fix` | 入库的测试码流（约 4 KB） |
| `Sources/FMP4Muxer/ByteWriter.swift` | 大端字节写入器 + `box` / `fullBox` |
| `Sources/FMP4Muxer/ByteReader.swift` | 带越界检查的大端字节读取器 |
| `Sources/FMP4Muxer/H264Fixture.swift` | fixture 格式解析 |
| `Sources/FMP4Muxer/MP4Inspector.swift` | 严格读者：box 树、必需 box 校验、按 tfhd 规则解析数据偏移 |
| `Sources/FMP4Muxer/HeaderBoxes.swift` | `ftyp` + `moov`（单视频轨） |
| `Sources/FMP4Muxer/TickMath.swift` | 纳秒 → tick；写法 A / 写法 B |
| `Sources/FMP4Muxer/FragmentBuilder.swift` | `Sample` + 滞后一帧的分片缓冲 |
| `Sources/FMP4Muxer/FragmentWriter.swift` | `moof` + `mdat`、`data_offset` 回填、`TfhdBaseMode`、`SampleFlags` |
| `Sources/FMP4Muxer/FMP4Writer.swift` | 端到端：fixture → 完整 fMP4（关键帧驱动切分片） |
| `Sources/DemoCLI/main.swift` | `swift run blog-demos mux` → `docs/artifacts/sample.mp4` |
| `Tests/FMP4MuxerTests/TestSupport.swift` | 定位包根目录、读 fixture、读 u32 |
| `Tests/FMP4MuxerTests/*Tests.swift` | 每个源文件一组测试 |
| `.github/workflows/ci.yml` | CI |
| `README.md` | 作品集门面 |

---

### Task 1: 包骨架 + H.264 fixture + fixture 解析

**Files:**
- Create: `Package.swift`
- Create: `Scripts/make-h264-fixture.swift`
- Create: `Fixtures/solid_160x120_30f.h264fix`（由脚本生成）
- Create: `Sources/FMP4Muxer/ByteReader.swift`
- Create: `Sources/FMP4Muxer/H264Fixture.swift`
- Test: `Tests/FMP4MuxerTests/TestSupport.swift`, `Tests/FMP4MuxerTests/FixtureTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `struct ByteReader { init(_ bytes: [UInt8], offset: Int = 0); var offset: Int { get }; var isAtEnd: Bool; mutating func take(_ n: Int) throws -> [UInt8]; mutating func u8/u16/u32/u64() throws -> UInt8/UInt16/UInt32/UInt64; mutating func i32() throws -> Int32 }`（internal）
  - `public enum ByteReaderError: Error, Equatable { case truncated(at: Int) }`
  - `public struct H264Fixture { width: UInt16; height: UInt16; fps: UInt32; avcC: [UInt8]; frames: [Frame]; init(bytes: [UInt8]) throws }`，`Frame { isSync: Bool; bytes: [UInt8] }`，`ParseError { badMagic, trailingBytes(Int) }`
  - `TestSupport.packageRoot: URL`、`TestSupport.fixtureBytes() throws -> [UInt8]`、`TestSupport.u32(_ bytes: [UInt8], at: Int) -> UInt32`

- [ ] **Step 1: 写 Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlogDemos",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FMP4Muxer", targets: ["FMP4Muxer"]),
    ],
    targets: [
        .target(name: "FMP4Muxer"),
        .testTarget(name: "FMP4MuxerTests", dependencies: ["FMP4Muxer"]),
    ]
)
```

- [ ] **Step 2: 写 fixture 生成脚本 `Scripts/make-h264-fixture.swift`**

（此脚本已在计划编写时实测：输出 3990 字节，关键帧在第 0/10/20 帧。）

```swift
// 一次性工具：用 VideoToolbox 编码 30 帧 160x120 的 H.264，写成 blog-demos 的测试 fixture。
// 用法：swiftc -O Scripts/make-h264-fixture.swift -o .build/make-h264-fixture
//       .build/make-h264-fixture Fixtures/solid_160x120_30f.h264fix
// 生成物随仓库提交；CI 与测试从不重新生成它，所以不依赖任何机器上的编码器。
//
// 格式："H264FIX1" | u16 width | u16 height | u32 fps | u32 frameCount
//       | u16 avcCLength | avcC payload | frameCount × (u8 isSync | u32 size | AVCC bytes)
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

let outputPath = CommandLine.arguments.dropFirst().first ?? "Fixtures/solid_160x120_30f.h264fix"
let width = 160, height = 120, fps: Int32 = 30, frameCount = 30, gop = 10

var avcCPayload: Data?
var encoded = [Int: (sync: Bool, data: Data)]()
let lock = NSLock()

var sessionOut: VTCompressionSession?
let createStatus = VTCompressionSessionCreate(
    allocator: nil, width: Int32(width), height: Int32(height),
    codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
    compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
guard createStatus == noErr, let session = sessionOut else {
    FileHandle.standardError.write("VTCompressionSessionCreate failed: \(createStatus)\n".data(using: .utf8)!)
    exit(1)
}
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gop as CFNumber)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)

for i in 0..<frameCount {
    var pixelBufferOut: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBufferOut)
    guard let pixelBuffer = pixelBufferOut else { exit(1) }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let v = UInt8(i * 255 / (frameCount - 1))          // 每帧颜色渐变，保证帧间确实有差异
    for y in 0..<height {
        for x in 0..<width {
            let p = base + y * bytesPerRow + x * 4
            p[0] = 255 - v; p[1] = v; p[2] = 128; p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let frameProperties: CFDictionary? = (i % gop == 0)
        ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
    let index = i
    VTCompressionSessionEncodeFrame(
        session, imageBuffer: pixelBuffer,
        presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: fps),
        duration: CMTime(value: 1, timescale: fps),
        frameProperties: frameProperties, infoFlagsOut: nil
    ) { status, _, sampleBuffer in
        guard status == noErr, let sb = sampleBuffer, let block = CMSampleBufferGetDataBuffer(sb) else {
            FileHandle.standardError.write("encode failed at frame \(index): \(status)\n".data(using: .utf8)!)
            return
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &pointer)
        let data = Data(bytes: pointer!, count: length)
        var isSync = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }
        lock.lock()
        if avcCPayload == nil,
           let desc = CMSampleBufferGetFormatDescription(sb),
           let atoms = CMFormatDescriptionGetExtension(
               desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let avcC = atoms["avcC"] as? Data {
            avcCPayload = avcC
        }
        encoded[index] = (isSync, data)
        lock.unlock()
    }
}
VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
VTCompressionSessionInvalidate(session)

guard let avcC = avcCPayload, encoded.count == frameCount else {
    FileHandle.standardError.write("missing avcC or frames (\(encoded.count)/\(frameCount))\n".data(using: .utf8)!)
    exit(1)
}

var out = Data("H264FIX1".utf8)
func appendBE16(_ v: Int) { var x = UInt16(v).bigEndian; out.append(Data(bytes: &x, count: 2)) }
func appendBE32(_ v: Int) { var x = UInt32(v).bigEndian; out.append(Data(bytes: &x, count: 4)) }
appendBE16(width); appendBE16(height); appendBE32(Int(fps)); appendBE32(frameCount)
appendBE16(avcC.count); out.append(avcC)
for i in 0..<frameCount {
    let (sync, data) = encoded[i]!
    out.append(sync ? 1 : 0)
    appendBE32(data.count)
    out.append(data)
}
try out.write(to: URL(fileURLWithPath: outputPath))
let syncIndices = (0..<frameCount).filter { encoded[$0]!.sync }
print("wrote \(outputPath): \(out.count) bytes, avcC \(avcC.count) bytes, keyframes at \(syncIndices)")
```

- [ ] **Step 3: 生成 fixture**

Run:
```bash
cd ~/Projects/blog-demos
mkdir -p Fixtures .build
swiftc -O Scripts/make-h264-fixture.swift -o .build/make-h264-fixture
.build/make-h264-fixture Fixtures/solid_160x120_30f.h264fix
```
Expected: `wrote Fixtures/solid_160x120_30f.h264fix: 3990 bytes, avcC 25 bytes, keyframes at [0, 10, 20]`（字节数可能因机器编码器略有不同；**关键帧位置必须是 [0, 10, 20]**，否则后续测试不成立，需排查 GOP 设置）

- [ ] **Step 4: 写测试支撑 `Tests/FMP4MuxerTests/TestSupport.swift`**

```swift
import Foundation

enum TestSupport {
    /// 包根目录：本文件位于 <root>/Tests/FMP4MuxerTests/TestSupport.swift
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func fixtureBytes() throws -> [UInt8] {
        let url = packageRoot.appendingPathComponent("Fixtures/solid_160x120_30f.h264fix")
        return [UInt8](try Data(contentsOf: url))
    }

    /// 从字节数组的指定位置读一个大端 u32（测试里核对字段值用）
    static func u32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
```

- [ ] **Step 5: 写失败的测试 `Tests/FMP4MuxerTests/FixtureTests.swift`**

```swift
import XCTest
@testable import FMP4Muxer

final class FixtureTests: XCTestCase {
    func test_fixture是30帧160x120且每10帧一个关键帧() throws {
        let fixture = try H264Fixture(bytes: TestSupport.fixtureBytes())
        XCTAssertEqual(fixture.width, 160)
        XCTAssertEqual(fixture.height, 120)
        XCTAssertEqual(fixture.fps, 30)
        XCTAssertEqual(fixture.frames.count, 30)
        XCTAssertEqual(fixture.frames.indices.filter { fixture.frames[$0].isSync }, [0, 10, 20])
        // AVCDecoderConfigurationRecord 的第一个字节 configurationVersion 恒为 1
        XCTAssertEqual(fixture.avcC.first, 0x01)
    }

    func test_截断的fixture必须报错而不是读出半帧() throws {
        let bytes = try TestSupport.fixtureBytes()
        XCTAssertThrowsError(try H264Fixture(bytes: Array(bytes.dropLast(1)))) { error in
            guard case ByteReaderError.truncated = error else {
                return XCTFail("期望 truncated，实际 \(error)")
            }
        }
    }

    func test_魔数不对必须拒绝() throws {
        var bytes = try TestSupport.fixtureBytes()
        bytes[0] = 0x00
        XCTAssertThrowsError(try H264Fixture(bytes: bytes)) { error in
            XCTAssertEqual(error as? H264Fixture.ParseError, .badMagic)
        }
    }

    func test_末尾多出字节必须拒绝() throws {
        let bytes = try TestSupport.fixtureBytes() + [0xFF, 0xFF]
        XCTAssertThrowsError(try H264Fixture(bytes: bytes)) { error in
            XCTAssertEqual(error as? H264Fixture.ParseError, .trailingBytes(2))
        }
    }
}
```

- [ ] **Step 6: 运行，确认失败**

Run: `swift test --filter FMP4MuxerTests.FixtureTests`
Expected: 编译失败，`error: cannot find 'H264Fixture' in scope`

- [ ] **Step 7: 实现 `Sources/FMP4Muxer/ByteReader.swift`**

```swift
/// 大端字节读取器。所有读取都做越界检查——解析外部输入时，越界要变成错误，而不是崩溃。
public enum ByteReaderError: Error, Equatable {
    case truncated(at: Int)
}

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var isAtEnd: Bool { offset == bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, n <= remaining else { throw ByteReaderError.truncated(at: offset) }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 { try take(2).reduce(0) { $0 << 8 | UInt16($1) } }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
}
```

- [ ] **Step 8: 实现 `Sources/FMP4Muxer/H264Fixture.swift`**

```swift
/// 测试码流：由 Scripts/make-h264-fixture.swift 用 VideoToolbox 一次性生成并入库。
/// 格式："H264FIX1" | u16 width | u16 height | u32 fps | u32 frameCount
///       | u16 avcCLength | avcC payload | frameCount × (u8 isSync | u32 size | AVCC bytes)
public struct H264Fixture: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public let isSync: Bool
        /// AVCC 格式：每个 NALU 前有 4 字节大端长度，可直接放进 mdat
        public let bytes: [UInt8]
    }

    public enum ParseError: Error, Equatable {
        case badMagic
        case trailingBytes(Int)
    }

    public let width: UInt16
    public let height: UInt16
    public let fps: UInt32
    /// AVCDecoderConfigurationRecord（avcC box 的 payload，不含 box 头）
    public let avcC: [UInt8]
    public let frames: [Frame]

    public init(bytes: [UInt8]) throws {
        var reader = ByteReader(bytes)
        guard try reader.take(8) == Array("H264FIX1".utf8) else { throw ParseError.badMagic }
        width = try reader.u16()
        height = try reader.u16()
        fps = try reader.u32()
        let frameCount = Int(try reader.u32())
        avcC = try reader.take(Int(try reader.u16()))
        var parsed: [Frame] = []
        parsed.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            let isSync = try reader.u8() == 1
            let size = Int(try reader.u32())
            parsed.append(Frame(isSync: isSync, bytes: try reader.take(size)))
        }
        guard reader.isAtEnd else { throw ParseError.trailingBytes(reader.remaining) }
        frames = parsed
    }
}
```

- [ ] **Step 9: 运行，确认通过**

Run: `swift test --filter FMP4MuxerTests.FixtureTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 10: Commit**

```bash
git add Package.swift Scripts Fixtures Sources Tests
git commit -m "feat(FMP4Muxer): 包骨架 + VideoToolbox 生成的 H.264 fixture 与解析

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: 大端字节写入器与 box 构造

**Files:**
- Create: `Sources/FMP4Muxer/ByteWriter.swift`
- Test: `Tests/FMP4MuxerTests/ByteWriterTests.swift`

**Interfaces:**
- Consumes: 无
- Produces（internal，测试用 `@testable import`）:
  - `struct ByteWriter { var bytes: [UInt8] { get }; mutating func u8/u16/u32/u64/i16/i32; mutating func fourcc(_ s: String); mutating func raw(_ b: [UInt8]); mutating func zeros(_ n: Int) }`
  - `func box(_ type: String, _ body: (inout ByteWriter) -> Void) -> [UInt8]`
  - `func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ body: (inout ByteWriter) -> Void) -> [UInt8]`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import FMP4Muxer

final class ByteWriterTests: XCTestCase {
    func test_小端写size会被读成402653184_所以必须大端() {
        // 原文：播放器会把 size = 24 读成 size = 402653184，然后从文件里跳出去
        let littleEndian = withUnsafeBytes(of: UInt32(24).littleEndian, Array.init)
        XCTAssertEqual(littleEndian.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, 402_653_184)

        var writer = ByteWriter()
        writer.u32(24)
        XCTAssertEqual(writer.bytes, [0x00, 0x00, 0x00, 0x18])
    }

    func test_box先占位再回填_size等于整个box的长度() {
        let bytes = box("free") { $0.raw([1, 2, 3, 4]) }
        XCTAssertEqual(bytes, [0, 0, 0, 12, 0x66, 0x72, 0x65, 0x65, 1, 2, 3, 4])
    }

    func test_fullBox的version和flags占4字节且flags只取低24位() {
        let bytes = fullBox("tfhd", version: 1, flags: 0xFF02_0000) { _ in }
        XCTAssertEqual(bytes.count, 12)
        XCTAssertEqual(Array(bytes[8..<12]), [0x01, 0x02, 0x00, 0x00])
    }

    func test_各宽度整数都按大端写出() {
        var writer = ByteWriter()
        writer.u16(0x0102)
        writer.u64(0x0102_0304_0506_0708)
        writer.i16(-1)
        writer.i32(-2)
        XCTAssertEqual(writer.bytes, [1, 2, 1, 2, 3, 4, 5, 6, 7, 8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
    }
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter FMP4MuxerTests.ByteWriterTests`
Expected: 编译失败，`error: cannot find 'ByteWriter' in scope`

- [ ] **Step 3: 实现 `Sources/FMP4Muxer/ByteWriter.swift`**

```swift
/// 大端字节写入器。MP4 里所有多字节整数都是大端；
/// `withUnsafeBytes(of: v)` 直接写出来的是小端，这是 Swift 开发者手写 muxer 的第一个坑。
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
    mutating func u32(_ v: UInt32) { bytes.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
    mutating func u64(_ v: UInt64) { bytes.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

    mutating func fourcc(_ s: String) {
        precondition(s.utf8.count == 4, "fourcc 必须正好 4 个字节：\(s)")
        bytes.append(contentsOf: Array(s.utf8))
    }

    mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func zeros(_ n: Int) { bytes.append(contentsOf: repeatElement(0, count: n)) }
}

/// 普通 box：先占 4 字节 size，写完 body 再回填
func box(_ type: String, _ body: (inout ByteWriter) -> Void) -> [UInt8] {
    var writer = ByteWriter()
    writer.u32(0)
    writer.fourcc(type)
    body(&writer)
    var out = writer.bytes
    precondition(out.count <= Int(UInt32.max), "box 超过 32 位 size 上限：\(type)")
    out.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(out.count).bigEndian, Array.init))
    return out
}

/// FullBox：在 box 头之后多 1 字节 version + 3 字节 flags
func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0,
             _ body: (inout ByteWriter) -> Void) -> [UInt8] {
    box(type) { writer in
        writer.u32((UInt32(version) << 24) | (flags & 0x00FF_FFFF))
        body(&writer)
    }
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `swift test --filter FMP4MuxerTests.ByteWriterTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/FMP4Muxer/ByteWriter.swift Tests/FMP4MuxerTests/ByteWriterTests.swift
git commit -m "feat(FMP4Muxer): 大端字节写入器与 box/fullBox

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: 严格读者 MP4Inspector（box 树 + 必需 box 校验）

**Files:**
- Create: `Sources/FMP4Muxer/MP4Inspector.swift`
- Test: `Tests/FMP4MuxerTests/InspectorTests.swift`

**Interfaces:**
- Consumes: `ByteReader`（Task 1）、`box` / `fullBox`（Task 2，仅测试里构造输入）
- Produces:
  - `public struct MP4Box: Equatable, Sendable { type: String; offset: Int /*文件内绝对偏移*/; size: Int; children: [MP4Box]; payload: [UInt8] /*box 头之后的字节，容器为 []*/; func child(_ type: String) -> MP4Box?; func children(_ type: String) -> [MP4Box]; var fullBoxHeader: (version: UInt8, flags: UInt32)? }`
  - `extension Array where Element == MP4Box { public func find(_ path: String...) -> MP4Box? }`
  - `public enum MP4Inspector { static func parse(_ bytes: [UInt8]) throws -> [MP4Box]; static func missingSampleTableBoxes(in stbl: MP4Box) -> [String]; enum InspectError: Error, Equatable { badBoxSize(offset: Int, size: Int), missingBox(String), unsupported(String) } }`
  - （Task 6 会在此文件追加 `resolveTrackData`）

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import FMP4Muxer

final class InspectorTests: XCTestCase {
    func test_容器box递归解析并记录每个box在文件里的绝对偏移() throws {
        let file = box("ftyp") { $0.fourcc("iso5") } + box("moov") { $0.raw(box("free") { $0.raw([9]) }) }
        let top = try MP4Inspector.parse(file)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov"])
        XCTAssertEqual(top[1].offset, 12)
        XCTAssertEqual(top[1].children.map(\.type), ["free"])
        XCTAssertEqual(top[1].children[0].offset, 20)
        XCTAssertEqual(top[1].children[0].payload, [9])
        XCTAssertEqual(top.find("moov", "free")?.payload, [9])
    }

    func test_box尺寸非法必须报错而不是死循环或越界() {
        // size = 4：小于 box 头本身，按字面前进会原地打转
        XCTAssertThrowsError(try MP4Inspector.parse([0, 0, 0, 4, 0x66, 0x72, 0x65, 0x65])) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badBoxSize(offset: 0, size: 4))
        }
        // size = 99：越过文件末尾
        XCTAssertThrowsError(try MP4Inspector.parse([0, 0, 0, 99, 0x66, 0x72, 0x65, 0x65])) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badBoxSize(offset: 0, size: 99))
        }
        // 剩余字节连一个 box 头都不够
        XCTAssertThrowsError(try MP4Inspector.parse([0, 0, 0])) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badBoxSize(offset: 0, size: 3))
        }
    }

    func test_规范要求stbl里五个必选box各恰好一个_空表也算() throws {
        let complete = box("stbl") { w in
            for t in ["stsd", "stts", "stsc", "stsz", "stco"] { w.raw(fullBox(t) { $0.u32(0) }) }
        }
        let onlyStsd = box("stbl") { w in w.raw(fullBox("stsd") { $0.u32(0) }) }
        XCTAssertEqual(MP4Inspector.missingSampleTableBoxes(in: try MP4Inspector.parse(complete)[0]), [])
        XCTAssertEqual(MP4Inspector.missingSampleTableBoxes(in: try MP4Inspector.parse(onlyStsd)[0]),
                       ["stts", "stsc", "stsz", "stco"])
    }

    func test_fullBox头读出version与flags() throws {
        let parsed = try MP4Inspector.parse(fullBox("tkhd", version: 0, flags: 0x000007) { $0.u32(0) })
        XCTAssertEqual(parsed[0].fullBoxHeader?.version, 0)
        XCTAssertEqual(parsed[0].fullBoxHeader?.flags, 0x000007)
    }
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter FMP4MuxerTests.InspectorTests`
Expected: 编译失败，`error: cannot find 'MP4Inspector' in scope`

- [ ] **Step 3: 实现 `Sources/FMP4Muxer/MP4Inspector.swift`**

```swift
/// 一个解析出来的 box。offset 是它在整个文件里的绝对位置——
/// 算数据偏移时要用到，这是"严格读者"和"把 box 当字典读"的区别。
public struct MP4Box: Equatable, Sendable {
    public let type: String
    public let offset: Int
    public let size: Int
    public let children: [MP4Box]
    /// box 头（8 字节）之后的字节；容器 box 为空，内容在 children 里
    public let payload: [UInt8]

    public func child(_ type: String) -> MP4Box? { children.first { $0.type == type } }
    public func children(_ type: String) -> [MP4Box] { children.filter { $0.type == type } }

    /// FullBox 的 version 与 flags（payload 前 4 字节）；payload 不足 4 字节时为 nil
    public var fullBoxHeader: (version: UInt8, flags: UInt32)? {
        guard payload.count >= 4 else { return nil }
        return (payload[0], UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3]))
    }
}

extension Array where Element == MP4Box {
    /// 按路径逐级查找，例如 `find("moov", "trak", "tkhd")`
    public func find(_ path: String...) -> MP4Box? {
        guard let head = path.first, var node = first(where: { $0.type == head }) else { return nil }
        for type in path.dropFirst() {
            guard let next = node.child(type) else { return nil }
            node = next
        }
        return node
    }
}

/// 严格读者：按 ISO/IEC 14496-12 解析，不猜、不容错。
/// 原文第九节：测试一个格式写出器，要用最严格的读者，而不是最宽容的读者。
public enum MP4Inspector {
    public enum InspectError: Error, Equatable {
        case badBoxSize(offset: Int, size: Int)
        case missingBox(String)
        case unsupported(String)
    }

    /// 需要递归进入的容器 box（本 demo 只写这些）
    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "dinf", "stbl", "mvex", "moof", "traf"]

    public static func parse(_ bytes: [UInt8]) throws -> [MP4Box] {
        try parse(bytes, from: 0, to: bytes.count)
    }

    static func parse(_ bytes: [UInt8], from start: Int, to end: Int) throws -> [MP4Box] {
        var boxes: [MP4Box] = []
        var cursor = start
        while cursor < end {
            guard end - cursor >= 8 else { throw InspectError.badBoxSize(offset: cursor, size: end - cursor) }
            let size = Int(bytes[cursor..<cursor + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            // size 0（延伸到文件尾）和 1（64 位 largesize）本 demo 不写，读到即视为非法
            guard size >= 8, size <= end - cursor else { throw InspectError.badBoxSize(offset: cursor, size: size) }
            let type = String(decoding: bytes[cursor + 4..<cursor + 8], as: UTF8.self)
            let bodyStart = cursor + 8, boxEnd = cursor + size
            if containers.contains(type) {
                boxes.append(MP4Box(type: type, offset: cursor, size: size,
                                    children: try parse(bytes, from: bodyStart, to: boxEnd), payload: []))
            } else {
                boxes.append(MP4Box(type: type, offset: cursor, size: size,
                                    children: [], payload: Array(bytes[bodyStart..<boxEnd])))
            }
            cursor = boxEnd
        }
        return boxes
    }

    /// ISO/IEC 14496-12：stbl 必须各含恰好一个 stsd、stts、stsc、stsz（或 stz2）、stco（或 co64）。
    /// 规范定义的是"结构的完整性"，不是"信息的有无"——表是空的也必须在。
    public static func missingSampleTableBoxes(in stbl: MP4Box) -> [String] {
        var missing: [String] = []
        for type in ["stsd", "stts", "stsc"] where stbl.children(type).count != 1 { missing.append(type) }
        if stbl.children("stsz").count + stbl.children("stz2").count != 1 { missing.append("stsz") }
        if stbl.children("stco").count + stbl.children("co64").count != 1 { missing.append("stco") }
        return missing
    }
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `swift test --filter FMP4MuxerTests.InspectorTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/FMP4Muxer/MP4Inspector.swift Tests/FMP4MuxerTests/InspectorTests.swift
git commit -m "feat(FMP4Muxer): 严格读者 MP4Inspector（box 树 + 必选表校验）

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: 头部 ftyp + moov

**Files:**
- Create: `Sources/FMP4Muxer/HeaderBoxes.swift`
- Test: `Tests/FMP4MuxerTests/HeaderBoxesTests.swift`

**Interfaces:**
- Consumes: `box` / `fullBox`（Task 2）、`MP4Inspector` / `find`（Task 3，测试用）
- Produces:
  - `public struct VideoTrackConfig: Equatable, Sendable { trackID: UInt32; timescale: UInt32; width: UInt16; height: UInt16; avcC: [UInt8]; init(width: UInt16, height: UInt16, avcC: [UInt8], trackID: UInt32 = 1, timescale: UInt32 = 90_000) }`
  - `enum HeaderBoxes { static func ftyp() -> [UInt8]; static func moov(video: VideoTrackConfig, movieTimescale: UInt32 = 1000) -> [UInt8] }`（internal）

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import FMP4Muxer

final class HeaderBoxesTests: XCTestCase {
    private let config = VideoTrackConfig(width: 160, height: 120, avcC: [0x01, 0x42, 0x00, 0x1E, 0xFF, 0xE0, 0x00])

    private func parsedHeader() throws -> [MP4Box] {
        try MP4Inspector.parse(HeaderBoxes.ftyp() + HeaderBoxes.moov(video: config))
    }

    func test_ftyp主品牌是iso5因为default_base_is_moof语义从iso5才有_且不能写qt() throws {
        let ftyp = try XCTUnwrap(try parsedHeader().find("ftyp"))
        XCTAssertEqual(String(decoding: ftyp.payload[0..<4], as: UTF8.self), "iso5")
        let compatible = stride(from: 8, to: ftyp.payload.count, by: 4)
            .map { String(decoding: ftyp.payload[$0..<$0 + 4], as: UTF8.self) }
        XCTAssertTrue(compatible.contains("iso5"))
        XCTAssertFalse(compatible.contains("qt  "))
    }

    func test_空索引表虽然没有内容但四张都必须存在() throws {
        let stbl = try XCTUnwrap(try parsedHeader().find("moov", "trak", "mdia", "minf", "stbl"))
        XCTAssertEqual(MP4Inspector.missingSampleTableBoxes(in: stbl), [])
    }

    func test_tkhd的flags必须是7_填0轨道存在但不启用会黑屏无声且不报错() throws {
        let tkhd = try XCTUnwrap(try parsedHeader().find("moov", "trak", "tkhd"))
        XCTAssertEqual(tkhd.fullBoxHeader?.flags, 0x000007)
    }

    func test_mvhd_tkhd_mdhd三个duration在第0秒都填0() throws {
        let top = try parsedHeader()
        let mvhd = try XCTUnwrap(top.find("moov", "mvhd"))
        let tkhd = try XCTUnwrap(top.find("moov", "trak", "tkhd"))
        let mdhd = try XCTUnwrap(top.find("moov", "trak", "mdia", "mdhd"))
        // version 0 布局（payload 含 4 字节 version/flags）：
        // mvhd: creation 4 | modification 8 | timescale 12 | duration 16
        // tkhd: creation 4 | modification 8 | track_ID 12 | reserved 16 | duration 20
        // mdhd: creation 4 | modification 8 | timescale 12 | duration 16
        XCTAssertEqual(TestSupport.u32(mvhd.payload, at: 12), 1_000)     // 先确认字段位置没读错
        XCTAssertEqual(TestSupport.u32(mvhd.payload, at: 16), 0)
        XCTAssertEqual(TestSupport.u32(tkhd.payload, at: 12), 1)
        XCTAssertEqual(TestSupport.u32(tkhd.payload, at: 20), 0)
        XCTAssertEqual(TestSupport.u32(mdhd.payload, at: 12), 90_000)
        XCTAssertEqual(TestSupport.u32(mdhd.payload, at: 16), 0)
    }

    func test_有mvex和trex解析器才会去找moof() throws {
        let trex = try XCTUnwrap(try parsedHeader().find("moov", "mvex", "trex"))
        XCTAssertEqual(TestSupport.u32(trex.payload, at: 4), 1)          // track_ID
    }

    func test_avcC原样放进sample_entry不自己拼() throws {
        let stsd = try XCTUnwrap(try parsedHeader().find("moov", "trak", "mdia", "minf", "stbl", "stsd"))
        let expected = box("avcC") { $0.raw(config.avcC) }
        // avc1 是 stsd 里唯一的 sample entry，avcC 是 avc1 的最后一个子 box
        XCTAssertEqual(Array(stsd.payload.suffix(expected.count)), expected)
    }
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter FMP4MuxerTests.HeaderBoxesTests`
Expected: 编译失败，`error: cannot find 'VideoTrackConfig' in scope`

- [ ] **Step 3: 实现 `Sources/FMP4Muxer/HeaderBoxes.swift`**

（以下 box 布局已在计划编写时实测：生成文件被 AVFoundation 判定可播并完整解码。）

```swift
/// 单视频轨的配置。avcC 直接用编码器给的 AVCDecoderConfigurationRecord，不要自己拼。
public struct VideoTrackConfig: Equatable, Sendable {
    public var trackID: UInt32
    /// 媒体时间基。90000 能被 24/25/30/60 整除
    public var timescale: UInt32
    public var width: UInt16
    public var height: UInt16
    public var avcC: [UInt8]

    public init(width: UInt16, height: UInt16, avcC: [UInt8], trackID: UInt32 = 1, timescale: UInt32 = 90_000) {
        self.width = width
        self.height = height
        self.avcC = avcC
        self.trackID = trackID
        self.timescale = timescale
    }
}

/// ftyp + moov：在第 0 秒就定死的部分。fMP4 的 moov 只有骨架，索引下放到每个 moof。
enum HeaderBoxes {
    static let unityMatrix: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]

    static func ftyp() -> [UInt8] {
        box("ftyp") { w in
            w.fourcc("iso5")                                    // major brand：default-base-is-moof 从 iso5 起才有
            w.u32(512)                                          // minor version
            for brand in ["isom", "iso5", "iso6", "mp41"] { w.fourcc(brand) }
        }
    }

    static func moov(video: VideoTrackConfig, movieTimescale: UInt32 = 1000) -> [UInt8] {
        box("moov") { w in
            w.raw(mvhd(timescale: movieTimescale, nextTrackID: video.trackID + 1))
            w.raw(box("trak") { w in
                w.raw(tkhd(trackID: video.trackID, width: video.width, height: video.height))
                w.raw(box("mdia") { w in
                    w.raw(mdhd(timescale: video.timescale))
                    w.raw(hdlr())
                    w.raw(box("minf") { w in
                        w.raw(vmhd())
                        w.raw(dinf())
                        w.raw(emptyStbl(sampleEntry: avc1(width: video.width, height: video.height, avcC: video.avcC)))
                    })
                })
            })
            w.raw(box("mvex") { $0.raw(trex(trackID: video.trackID)) })
        }
    }

    // duration 在第 0 秒未知，填 0（合法，表示"未知"）
    static func mvhd(timescale: UInt32, nextTrackID: UInt32) -> [UInt8] {
        fullBox("mvhd") { w in
            w.u32(0); w.u32(0)                  // creation_time, modification_time
            w.u32(timescale)
            w.u32(0)                            // duration
            w.u32(0x0001_0000)                  // rate 1.0
            w.u16(0x0100)                       // volume 1.0
            w.zeros(2 + 8)                      // reserved
            for m in unityMatrix { w.u32(m) }
            w.zeros(6 * 4)                      // pre_defined
            w.u32(nextTrackID)
        }
    }

    // flags 必须是 7（enabled | in_movie | in_preview）；填 0 轨道被标记为不启用，黑屏无声且不报错
    static func tkhd(trackID: UInt32, width: UInt16, height: UInt16) -> [UInt8] {
        fullBox("tkhd", flags: 0x000007) { w in
            w.u32(0); w.u32(0)                  // creation_time, modification_time
            w.u32(trackID)
            w.u32(0)                            // reserved
            w.u32(0)                            // duration
            w.zeros(8)                          // reserved
            w.u16(0); w.u16(0)                  // layer, alternate_group
            w.u16(0)                            // volume（视频轨为 0）
            w.u16(0)                            // reserved
            for m in unityMatrix { w.u32(m) }
            w.u32(UInt32(width) << 16)          // 16.16 定点
            w.u32(UInt32(height) << 16)
        }
    }

    static func mdhd(timescale: UInt32) -> [UInt8] {
        fullBox("mdhd") { w in
            w.u32(0); w.u32(0)                  // creation_time, modification_time
            w.u32(timescale)
            w.u32(0)                            // duration
            w.u16(0x55C4)                       // language = "und"
            w.u16(0)                            // pre_defined
        }
    }

    static func hdlr() -> [UInt8] {
        fullBox("hdlr") { w in
            w.u32(0)                            // pre_defined
            w.fourcc("vide")
            w.zeros(12)                         // reserved
            w.raw(Array("VideoHandler".utf8)); w.u8(0)
        }
    }

    static func vmhd() -> [UInt8] { fullBox("vmhd", flags: 1) { $0.zeros(8) } }

    static func dinf() -> [UInt8] {
        box("dinf") { w in
            w.raw(fullBox("dref") { w in
                w.u32(1)
                w.raw(fullBox("url ", flags: 1) { _ in })   // flags=1：数据就在本文件里
            })
        }
    }

    static func avc1(width: UInt16, height: UInt16, avcC: [UInt8]) -> [UInt8] {
        box("avc1") { w in
            w.zeros(6); w.u16(1)                // reserved, data_reference_index
            w.zeros(2 + 2 + 12)                 // pre_defined, reserved, pre_defined[3]
            w.u16(width); w.u16(height)
            w.u32(0x0048_0000); w.u32(0x0048_0000)   // 72 dpi
            w.u32(0)                            // reserved
            w.u16(1)                            // frame_count
            w.zeros(32)                         // compressorname
            w.u16(0x0018)                       // depth
            w.i16(-1)                           // pre_defined
            w.raw(box("avcC") { $0.raw(avcC) })
        }
    }

    // 四张表虽然是空的，但必须存在：规范定义的是结构完整性，不是信息的有无
    static func emptyStbl(sampleEntry: [UInt8]) -> [UInt8] {
        box("stbl") { w in
            w.raw(fullBox("stsd") { w in w.u32(1); w.raw(sampleEntry) })
            w.raw(fullBox("stts") { $0.u32(0) })
            w.raw(fullBox("stsc") { $0.u32(0) })
            w.raw(fullBox("stsz") { w in w.u32(0); w.u32(0) })
            w.raw(fullBox("stco") { $0.u32(0) })
        }
    }

    // 默认值全填 0，每个分片在 trun 里逐 sample 写完整信息——分片自解释，排查时一眼看全
    static func trex(trackID: UInt32) -> [UInt8] {
        fullBox("trex") { w in
            w.u32(trackID)
            w.u32(1)                            // default_sample_description_index
            w.u32(0); w.u32(0); w.u32(0)        // default duration / size / flags
        }
    }
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `swift test --filter FMP4MuxerTests.HeaderBoxesTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/FMP4Muxer/HeaderBoxes.swift Tests/FMP4MuxerTests/HeaderBoxesTests.swift
git commit -m "feat(FMP4Muxer): ftyp + moov 头部（空表必须存在、tkhd flags=7、duration 填 0）

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: 时间换算（写法 A / B）与滞后一帧的分片缓冲

**Files:**
- Create: `Sources/FMP4Muxer/TickMath.swift`
- Create: `Sources/FMP4Muxer/FragmentBuilder.swift`
- Test: `Tests/FMP4MuxerTests/TickMathTests.swift`, `Tests/FMP4MuxerTests/FragmentBuilderTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `public enum TickMath { static func ticks(fromNanoseconds: Int64, timescale: Int64) -> Int64; static func durationsConvertingEachPTS(_ ptsNs: [Int64], timescale: Int64) -> [Int64]; static func durationsConvertingEachDelta(_ ptsNs: [Int64], timescale: Int64) -> [Int64] }`
  - `public struct Sample: Equatable, Sendable { decodeTick: Int64; duration: UInt32; bytes: [UInt8]; isSync: Bool; init(decodeTick: Int64, bytes: [UInt8], isSync: Bool, duration: UInt32 = 0) }`
  - `public struct FragmentBuilder: Sendable { init(); var hasPending: Bool; mutating func push(_ s: Sample) throws; mutating func flush() -> [Sample]; mutating func finish() -> [Sample]; enum PushError: Error, Equatable { nonMonotonicDecodeTick(previous: Int64, got: Int64) } }`

- [ ] **Step 1: 写失败的测试 `TickMathTests.swift`**

```swift
import XCTest
@testable import FMP4Muxer

final class TickMathTests: XCTestCase {
    func test_写法B逐个换算duration_30fps录10分钟最坏偏差9000tick即0点1秒() {
        // 帧间隔 33_338_889ns → 3000.50001 tick：每次四舍五入都往同一个方向多出约 0.5 tick
        let pts = (0...18_000).map { Int64($0) * 33_338_889 }
        let truth = TickMath.ticks(fromNanoseconds: pts.last!, timescale: 90_000)
        let a = TickMath.durationsConvertingEachPTS(pts, timescale: 90_000)
        let b = TickMath.durationsConvertingEachDelta(pts, timescale: 90_000)
        XCTAssertEqual(truth, 54_009_000)
        XCTAssertEqual(a.reduce(0, +), truth)          // 写法 A：duration 之和恒等于末帧 PTS 的换算值
        XCTAssertEqual(b.reduce(0, +) - truth, 9_000)  // 写法 B：多出 9000 tick = 0.1 秒
    }

    func test_写法A在任意抖动的可变帧率下duration之和都等于末帧PTS() {
        var state: UInt64 = 42
        var ns: Int64 = 0
        var pts: [Int64] = [0]
        for _ in 0..<5_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407   // 确定性伪随机
            ns += 16_000_000 + Int64(state >> 40)                                     // 16ms ~ 32.7ms 抖动
            pts.append(ns)
        }
        XCTAssertEqual(TickMath.durationsConvertingEachPTS(pts, timescale: 90_000).reduce(0, +),
                       TickMath.ticks(fromNanoseconds: pts.last!, timescale: 90_000))
    }

    func test_纳秒换tick按四舍五入远离零() {
        XCTAssertEqual(TickMath.ticks(fromNanoseconds: 33_333_333, timescale: 90_000), 3_000)   // 2999.99997
        XCTAssertEqual(TickMath.ticks(fromNanoseconds: 33_338_889, timescale: 90_000), 3_001)   // 3000.50001
        XCTAssertEqual(TickMath.ticks(fromNanoseconds: 0, timescale: 90_000), 0)
    }
}
```

- [ ] **Step 2: 写失败的测试 `FragmentBuilderTests.swift`**

```swift
import XCTest
@testable import FMP4Muxer

final class FragmentBuilderTests: XCTestCase {
    private func sample(_ tick: Int64, sync: Bool = false) -> Sample {
        Sample(decodeTick: tick, bytes: [UInt8(truncatingIfNeeded: tick)], isSync: sync)
    }

    func test_最后一个sample的duration在写它时还不知道_滞后一帧后每个duration都是真实值() throws {
        // 可变帧率：画面静止时，第三帧和第四帧之间隔了 3 秒
        var builder = FragmentBuilder()
        for (i, tick) in [0, 3_000, 6_000, 276_000, 279_000].enumerated() {
            try builder.push(sample(Int64(tick), sync: i == 0))
        }
        XCTAssertEqual(builder.flush().map(\.duration), [3_000, 3_000, 270_000, 3_000])
        XCTAssertTrue(builder.hasPending)   // 最后一帧的 duration 要等下一帧，仍在等待
    }

    func test_解码时间不单调必须拒绝() throws {
        var builder = FragmentBuilder()
        try builder.push(sample(6_000))
        XCTAssertThrowsError(try builder.push(sample(3_000))) {
            XCTAssertEqual($0 as? FragmentBuilder.PushError, .nonMonotonicDecodeTick(previous: 6_000, got: 3_000))
        }
        XCTAssertThrowsError(try builder.push(sample(6_000)))   // 相等也不行：duration 会是 0
    }

    func test_正常结束时最后一帧用最后一个已知duration兜底_即使之前已经flush过() throws {
        var builder = FragmentBuilder()
        try builder.push(sample(0, sync: true))
        try builder.push(sample(3_000))
        try builder.push(sample(9_000))
        XCTAssertEqual(builder.flush().map(\.duration), [3_000, 6_000])   // ready 被取空
        let tail = builder.finish()
        XCTAssertEqual(tail.map(\.decodeTick), [9_000])
        XCTAssertEqual(tail.map(\.duration), [6_000])                      // 不是 1
        XCTAssertFalse(builder.hasPending)
    }

    func test_只有一帧就结束时duration兜底为1() throws {
        var builder = FragmentBuilder()
        try builder.push(sample(0, sync: true))
        XCTAssertEqual(builder.finish().map(\.duration), [1])
    }
}
```

- [ ] **Step 3: 运行，确认失败**

Run: `swift test --filter "FMP4MuxerTests.(TickMathTests|FragmentBuilderTests)"`
Expected: 编译失败，`error: cannot find 'TickMath' in scope`

- [ ] **Step 4: 实现 `Sources/FMP4Muxer/TickMath.swift`**

```swift
/// tfdt / trun duration 的两种算法（原文第四节）。全程整数，不经过浮点。
public enum TickMath {
    /// 纳秒 → 目标 timescale 的 tick，四舍五入（远离零）。
    /// 适用范围：ns × timescale 不超过 Int64（90kHz 下约 28 小时）
    public static func ticks(fromNanoseconds ns: Int64, timescale: Int64) -> Int64 {
        precondition(ns >= 0 && timescale > 0, "只处理非负时间与正 timescale")
        let (product, overflow) = ns.multipliedReportingOverflow(by: timescale)
        precondition(!overflow, "ns × timescale 溢出 Int64：\(ns) × \(timescale)")
        return (product + 500_000_000) / 1_000_000_000
    }

    /// 写法 A（正确）：先把每个 PTS 相对首帧换算成 tick，再用相邻差做 duration。
    /// 所有 duration 之和恒等于末帧 PTS 的换算值，误差不累积。
    public static func durationsConvertingEachPTS(_ ptsNs: [Int64], timescale: Int64) -> [Int64] {
        guard let t0 = ptsNs.first else { return [] }
        let ticks = ptsNs.map { ticks(fromNanoseconds: $0 - t0, timescale: timescale) }
        return zip(ticks.dropFirst(), ticks).map { $0 - $1 }
    }

    /// 写法 B（错误）：先做相邻差，再逐个换算。每个 duration 各自舍入，误差同向时累积。
    public static func durationsConvertingEachDelta(_ ptsNs: [Int64], timescale: Int64) -> [Int64] {
        zip(ptsNs.dropFirst(), ptsNs).map { ticks(fromNanoseconds: $0 - $1, timescale: timescale) }
    }
}
```

- [ ] **Step 5: 实现 `Sources/FMP4Muxer/FragmentBuilder.swift`**

```swift
/// 一个已编码的 sample。duration 由 FragmentBuilder 在下一帧到来时填上。
public struct Sample: Equatable, Sendable {
    public var decodeTick: Int64
    public var duration: UInt32
    public var bytes: [UInt8]
    public var isSync: Bool

    public init(decodeTick: Int64, bytes: [UInt8], isSync: Bool, duration: UInt32 = 0) {
        self.decodeTick = decodeTick
        self.bytes = bytes
        self.isSync = isSync
        self.duration = duration
    }
}

/// 滞后一帧（原文第四节）：一个 sample 的 duration 是它到下一个 sample 的时间差，
/// 收到它的时候下一帧还没来。所以只把"duration 已确定"的 sample 交出去，最后一个留着等。
public struct FragmentBuilder: Sendable {
    public enum PushError: Error, Equatable {
        case nonMonotonicDecodeTick(previous: Int64, got: Int64)
    }

    private var pending: Sample?
    private var ready: [Sample] = []
    private var lastKnownDuration: UInt32?

    public init() {}

    public var hasPending: Bool { pending != nil }

    public mutating func push(_ sample: Sample) throws {
        if var previous = pending {
            guard sample.decodeTick > previous.decodeTick else {
                throw PushError.nonMonotonicDecodeTick(previous: previous.decodeTick, got: sample.decodeTick)
            }
            previous.duration = UInt32(clamping: sample.decodeTick - previous.decodeTick)
            lastKnownDuration = previous.duration
            ready.append(previous)
        }
        pending = sample
    }

    /// 取出 duration 已确定的 sample；pending 的那一个留给下一个分片
    public mutating func flush() -> [Sample] {
        defer { ready.removeAll(keepingCapacity: true) }
        return ready
    }

    /// 正常结束：pending 的真实 duration 无从得知，用最后一个已知的真实 duration 兜底（一帧都没有则为 1）。
    /// 注意兜底值来自 lastKnownDuration 而不是 ready.last——ready 可能刚被 flush 取空。
    public mutating func finish() -> [Sample] {
        if var last = pending {
            last.duration = lastKnownDuration ?? 1
            ready.append(last)
            pending = nil
        }
        return flush()
    }
}
```

- [ ] **Step 6: 运行，确认通过**

Run: `swift test --filter "FMP4MuxerTests.(TickMathTests|FragmentBuilderTests)"`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
git add Sources/FMP4Muxer/TickMath.swift Sources/FMP4Muxer/FragmentBuilder.swift Tests/FMP4MuxerTests/TickMathTests.swift Tests/FMP4MuxerTests/FragmentBuilderTests.swift
git commit -m "feat(FMP4Muxer): 整数时间换算（写法 A/B）与滞后一帧的分片缓冲

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: moof + mdat、data_offset 回填、tfhd 基址

**Files:**
- Create: `Sources/FMP4Muxer/FragmentWriter.swift`
- Modify: `Sources/FMP4Muxer/MP4Inspector.swift`（追加 `TrackFragmentData` 与 `resolveTrackData`）
- Test: `Tests/FMP4MuxerTests/FragmentWriterTests.swift`

**Interfaces:**
- Consumes: `box` / `fullBox`（Task 2）、`Sample`（Task 5）、`MP4Inspector.parse` / `ByteReader`（Task 1、3）
- Produces:
  - `public enum SampleFlags { static let sync: UInt32 = 0x0200_0000; static let nonSync: UInt32 = 0x0101_0000 }`
  - `public enum TfhdBaseMode: Sendable { case defaultBaseIsMoof, implicit }`
  - `public struct TrackFragment: Sendable { trackID: UInt32; baseMediaDecodeTime: UInt64; samples: [Sample]; init(trackID:baseMediaDecodeTime:samples:) }`
  - `public enum FragmentWriter { static func fragment(sequence: UInt32, tracks: [TrackFragment], baseMode: TfhdBaseMode = .defaultBaseIsMoof) -> [UInt8] }`
  - `public struct MP4Inspector.TrackFragmentData: Equatable, Sendable { trackID: UInt32; dataStart: Int; dataLength: Int }`
  - `public static func MP4Inspector.resolveTrackData(moof: MP4Box) throws -> [TrackFragmentData]`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import FMP4Muxer

final class FragmentWriterTests: XCTestCase {
    private let video = TrackFragment(trackID: 1, baseMediaDecodeTime: 0, samples: [
        Sample(decodeTick: 0, bytes: [UInt8](repeating: 0xAA, count: 100), isSync: true, duration: 3_000),
    ])
    private let audio = TrackFragment(trackID: 2, baseMediaDecodeTime: 0, samples: [
        Sample(decodeTick: 0, bytes: [UInt8](repeating: 0xBB, count: 40), isSync: true, duration: 1_024),
    ])

    private func resolve(_ fragment: [UInt8]) throws -> [MP4Inspector.TrackFragmentData] {
        try MP4Inspector.resolveTrackData(moof: try XCTUnwrap(try MP4Inspector.parse(fragment).find("moof")))
    }

    func test_单轨能播加上第二条轨就坏_tfhd必须设default_base_is_moof() throws {
        // 正确版本：两条轨的基址都是 moof 起始，各自读到自己的字节
        let good = FragmentWriter.fragment(sequence: 1, tracks: [video, audio], baseMode: .defaultBaseIsMoof)
        let goodData = try resolve(good)
        XCTAssertEqual(Array(good[goodData[0].dataStart..<goodData[0].dataStart + 100]), [UInt8](repeating: 0xAA, count: 100))
        XCTAssertEqual(Array(good[goodData[1].dataStart..<goodData[1].dataStart + 40]), [UInt8](repeating: 0xBB, count: 40))

        // 第一版：不设 flag。规范规定第二条 traf 的基址是"上一条 traf 的数据末尾"，
        // 而 data_offset 是按"相对 moof 起始"算的——两者叠加，音频的读取位置被推出了 mdat
        let bad = FragmentWriter.fragment(sequence: 1, tracks: [video, audio], baseMode: .implicit)
        let badData = try resolve(bad)
        XCTAssertEqual(badData[0].dataStart, goodData[0].dataStart)                           // 视频轨：恰好正确
        let endOfVideo = goodData[0].dataStart + 100
        XCTAssertEqual(badData[1].dataStart, endOfVideo + goodData[1].dataStart)             // 音频轨：基址 + 同样的偏移值
        XCTAssertGreaterThan(badData[1].dataStart + 40, bad.count)                            // 读位置已越过文件末尾
    }

    func test_单轨时不设flag也恰好正确_所以这个bug在第一版里永远看不见() throws {
        let good = try resolve(FragmentWriter.fragment(sequence: 1, tracks: [video], baseMode: .defaultBaseIsMoof))
        let bad = try resolve(FragmentWriter.fragment(sequence: 1, tracks: [video], baseMode: .implicit))
        XCTAssertEqual(bad, good)
    }

    func test_trun的sample_flags_关键帧0x02000000_非关键帧0x01010000() throws {
        let track = TrackFragment(trackID: 1, baseMediaDecodeTime: 0, samples: [
            Sample(decodeTick: 0, bytes: [1], isSync: true, duration: 3_000),
            Sample(decodeTick: 3_000, bytes: [2], isSync: false, duration: 3_000),
        ])
        let trun = try XCTUnwrap(try MP4Inspector.parse(FragmentWriter.fragment(sequence: 1, tracks: [track]))
            .find("moof", "traf", "trun"))
        // payload: version/flags 4 | sample_count 4 | data_offset 4 | 每 sample 12 字节（duration, size, flags）
        XCTAssertEqual(TestSupport.u32(trun.payload, at: 4), 2)
        XCTAssertEqual(TestSupport.u32(trun.payload, at: 12 + 8), SampleFlags.sync)
        XCTAssertEqual(TestSupport.u32(trun.payload, at: 24 + 8), SampleFlags.nonSync)
        XCTAssertEqual(SampleFlags.sync, 0x0200_0000)
        XCTAssertEqual(SampleFlags.nonSync, 0x0101_0000)
    }

    func test_tfdt用64位写入baseMediaDecodeTime() throws {
        let track = TrackFragment(trackID: 1, baseMediaDecodeTime: 0x1_0000_0001, samples: video.samples)
        let tfdt = try XCTUnwrap(try MP4Inspector.parse(FragmentWriter.fragment(sequence: 1, tracks: [track]))
            .find("moof", "traf", "tfdt"))
        XCTAssertEqual(tfdt.fullBoxHeader?.version, 1)
        XCTAssertEqual(Array(tfdt.payload[4..<12]), [0, 0, 0, 1, 0, 0, 0, 1])
    }
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter FMP4MuxerTests.FragmentWriterTests`
Expected: 编译失败，`error: cannot find 'TrackFragment' in scope`

- [ ] **Step 3: 实现 `Sources/FMP4Muxer/FragmentWriter.swift`**

```swift
/// trun 里每个 sample 的 flags（原文第六节）
public enum SampleFlags {
    /// sample_depends_on = 2（不依赖其他帧），sample_is_non_sync = 0（可从此处开始解码）
    public static let sync: UInt32 = 0x0200_0000
    /// sample_depends_on = 1（依赖其他帧），sample_is_non_sync = 1
    public static let nonSync: UInt32 = 0x0101_0000
}

/// tfhd 的基址模式（原文第五节）。
/// `.implicit` 只为复现"单轨能播、加第二条轨就坏"而存在；产品代码永远用 `.defaultBaseIsMoof`。
public enum TfhdBaseMode: Sendable {
    case defaultBaseIsMoof
    case implicit

    var tfhdFlags: UInt32 {
        switch self {
        case .defaultBaseIsMoof: 0x020000
        case .implicit: 0
        }
    }
}

public struct TrackFragment: Sendable {
    public var trackID: UInt32
    public var baseMediaDecodeTime: UInt64
    public var samples: [Sample]

    public init(trackID: UInt32, baseMediaDecodeTime: UInt64, samples: [Sample]) {
        self.trackID = trackID
        self.baseMediaDecodeTime = baseMediaDecodeTime
        self.samples = samples
    }
}

public enum FragmentWriter {
    /// 生成一个 moof + mdat。每条轨的 trun.data_offset 都按"相对 moof 起始"计算，
    /// 这只在 tfhd 声明了 default-base-is-moof 时成立。
    public static func fragment(sequence: UInt32, tracks: [TrackFragment],
                                baseMode: TfhdBaseMode = .defaultBaseIsMoof) -> [UInt8] {
        let trunFlags: UInt32 = 0x000001 | 0x000100 | 0x000200 | 0x000400   // data_offset | duration | size | flags
        let trafs: [[UInt8]] = tracks.map { track in
            box("traf") { w in
                w.raw(fullBox("tfhd", flags: baseMode.tfhdFlags) { $0.u32(track.trackID) })
                w.raw(fullBox("tfdt", version: 1) { $0.u64(track.baseMediaDecodeTime) })
                w.raw(fullBox("trun", flags: trunFlags) { w in
                    w.u32(UInt32(track.samples.count))
                    w.i32(0)                                       // data_offset 占位，下面回填
                    for s in track.samples {
                        w.u32(s.duration)
                        w.u32(UInt32(s.bytes.count))
                        w.u32(s.isSync ? SampleFlags.sync : SampleFlags.nonSync)
                    }
                })
            }
        }
        let mfhd = fullBox("mfhd") { $0.u32(sequence) }
        var moof = box("moof") { w in
            w.raw(mfhd)
            for traf in trafs { w.raw(traf) }
        }

        // data_offset 是固定 4 字节，它的值不影响 moof 大小——所以构建一次、回填即可（"一趟半"）。
        // 它在 traf 内的位置是常量：traf 头 8 + tfhd 16 + tfdt(v1) 20 + trun 头 12 + sample_count 4
        let dataOffsetFieldInTraf = 8 + 16 + 20 + 12 + 4
        var trafStart = 8 + mfhd.count
        var dataOffset = moof.count + 8                             // 第一条轨：moof 大小 + mdat 头
        for (index, track) in tracks.enumerated() {
            precondition(dataOffset <= Int(Int32.max), "data_offset 超出 Int32")
            let at = trafStart + dataOffsetFieldInTraf
            moof.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: Int32(dataOffset).bigEndian, Array.init))
            dataOffset += track.samples.reduce(0) { $0 + $1.bytes.count }
            trafStart += trafs[index].count
        }

        let mdat = box("mdat") { w in
            for track in tracks { for s in track.samples { w.raw(s.bytes) } }   // 按轨顺序连续放
        }
        return moof + mdat
    }
}
```

- [ ] **Step 4: 在 `Sources/FMP4Muxer/MP4Inspector.swift` 末尾追加数据偏移解析**

```swift
extension MP4Inspector {
    public struct TrackFragmentData: Equatable, Sendable {
        public let trackID: UInt32
        /// 该 traf 第一个 sample 在文件里的绝对偏移
        public let dataStart: Int
        /// 该 traf 所有 sample 的字节数之和
        public let dataLength: Int
    }

    /// 按 ISO/IEC 14496-12 §8.8.7 计算一个 moof 里每条 traf 的数据真正落在文件哪里。
    /// 播放器只信 flags，不信你"以为"的基址：
    /// - tfhd 带 base-data-offset-present（0x000001）：基址是显式写的 64 位绝对偏移
    /// - tfhd 带 default-base-is-moof（0x020000）：基址是 moof 第一个字节
    /// - 都没带：第一条 traf 的基址是 moof 起始，之后每条 traf 的基址是上一条 traf 的数据末尾
    public static func resolveTrackData(moof: MP4Box) throws -> [TrackFragmentData] {
        guard moof.type == "moof" else { throw InspectError.missingBox("moof") }
        var result: [TrackFragmentData] = []
        var previousEnd: Int?
        for traf in moof.children("traf") {
            guard let tfhd = traf.child("tfhd"), let tfhdHeader = tfhd.fullBoxHeader else {
                throw InspectError.missingBox("tfhd")
            }
            guard let trun = traf.child("trun"), let trunHeader = trun.fullBoxHeader else {
                throw InspectError.missingBox("trun")
            }
            guard trunHeader.flags & 0x000200 != 0 else {
                throw InspectError.unsupported("trun 未携带 sample_size，本读者不回退到 tfhd/trex 默认值")
            }

            var tfhdReader = ByteReader(tfhd.payload, offset: 4)
            let trackID = try tfhdReader.u32()
            let base: Int
            if tfhdHeader.flags & 0x000001 != 0 {
                base = Int(try tfhdReader.u64())
            } else if tfhdHeader.flags & 0x020000 != 0 {
                base = moof.offset
            } else {
                base = previousEnd ?? moof.offset
            }

            var trunReader = ByteReader(trun.payload, offset: 4)
            let sampleCount = Int(try trunReader.u32())
            let dataOffset = trunHeader.flags & 0x000001 != 0 ? Int(try trunReader.i32()) : 0
            if trunHeader.flags & 0x000004 != 0 { _ = try trunReader.u32() }          // first_sample_flags
            var length = 0
            for _ in 0..<sampleCount {
                if trunHeader.flags & 0x000100 != 0 { _ = try trunReader.u32() }      // duration
                length += Int(try trunReader.u32())                                   // size（上面已确认存在）
                if trunHeader.flags & 0x000400 != 0 { _ = try trunReader.u32() }      // flags
                if trunHeader.flags & 0x000800 != 0 { _ = try trunReader.u32() }      // composition time offset
            }

            let start = base + dataOffset
            result.append(TrackFragmentData(trackID: trackID, dataStart: start, dataLength: length))
            previousEnd = start + length
        }
        return result
    }
}
```

- [ ] **Step 5: 运行，确认通过**

Run: `swift test --filter FMP4MuxerTests.FragmentWriterTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/FMP4Muxer/FragmentWriter.swift Sources/FMP4Muxer/MP4Inspector.swift Tests/FMP4MuxerTests/FragmentWriterTests.swift
git commit -m "feat(FMP4Muxer): moof/mdat 与 data_offset 回填，复现 tfhd 隐式基址的双轨 bug

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: 端到端写出 + AVFoundation 预言机

**Files:**
- Create: `Sources/FMP4Muxer/FMP4Writer.swift`
- Test: `Tests/FMP4MuxerTests/FMP4WriterTests.swift`

**Interfaces:**
- Consumes: `H264Fixture`（Task 1）、`HeaderBoxes` / `VideoTrackConfig`（Task 4）、`FragmentBuilder` / `Sample`（Task 5）、`FragmentWriter` / `TrackFragment` / `SampleFlags`（Task 6）、`MP4Inspector`（Task 3、6）
- Produces:
  - `public enum FMP4Writer { static func write(fixture: H264Fixture, timescale: UInt32 = 90_000) throws -> [UInt8]; enum WriteError: Error, Equatable { firstFrameNotSync, timescaleNotDivisible(timescale: UInt32, fps: UInt32), emptyFixture } }`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@preconcurrency import AVFoundation
@testable import FMP4Muxer

final class FMP4WriterTests: XCTestCase {
    private func writtenFile() throws -> [UInt8] {
        try FMP4Writer.write(fixture: H264Fixture(bytes: TestSupport.fixtureBytes()))
    }

    func test_产出的fMP4能被AVFoundation完整解码30帧且时长1秒() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data(try writtenFile()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.0, accuracy: 0.0001)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)   // await 不能放进 XCTUnwrap 的 autoclosure
        let track = try XCTUnwrap(videoTracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 120))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var decodedFrames = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sampleBuffer) != nil { decodedFrames += 1 }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(decodedFrames, 30)
    }

    func test_分片由关键帧驱动_每个moof都从同步帧开始且tfdt连续() throws {
        let top = try MP4Inspector.parse(try writtenFile())
        let moofs = top.filter { $0.type == "moof" }
        XCTAssertEqual(moofs.count, 3)
        var tfdts: [UInt64] = []
        for moof in moofs {
            let trun = try XCTUnwrap(moof.child("traf")?.child("trun"))
            XCTAssertEqual(TestSupport.u32(trun.payload, at: 4), 10)                    // 每个分片 10 帧
            XCTAssertEqual(TestSupport.u32(trun.payload, at: 12 + 8), SampleFlags.sync)  // 第一帧是同步点
            let tfdt = try XCTUnwrap(moof.child("traf")?.child("tfdt"))
            tfdts.append(tfdt.payload[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        }
        XCTAssertEqual(tfdts, [0, 30_000, 60_000])
    }

    func test_写出的文件通过严格结构校验且每个分片的数据都落在自己的mdat里() throws {
        let file = try writtenFile()
        let top = try MP4Inspector.parse(file)
        let stbl = try XCTUnwrap(top.find("moov", "trak", "mdia", "minf", "stbl"))
        XCTAssertEqual(MP4Inspector.missingSampleTableBoxes(in: stbl), [])
        for (index, moof) in top.enumerated() where moof.type == "moof" {
            let mdat = top[index + 1]
            XCTAssertEqual(mdat.type, "mdat")
            let data = try XCTUnwrap(try MP4Inspector.resolveTrackData(moof: moof).first)
            XCTAssertEqual(data.dataStart, mdat.offset + 8)
            XCTAssertEqual(data.dataStart + data.dataLength, mdat.offset + mdat.size)
        }
    }

    func test_第一帧不是关键帧必须拒绝写出() throws {
        let fixture = try H264Fixture(bytes: TestSupport.fixtureBytes())
        let broken = try H264Fixture(bytes: Self.encode(fixture, dropFirst: 1))   // 从第 1 帧（P 帧）开始
        XCTAssertThrowsError(try FMP4Writer.write(fixture: broken)) {
            XCTAssertEqual($0 as? FMP4Writer.WriteError, .firstFrameNotSync)
        }
    }

    func test_timescale不能被帧率整除时拒绝而不是悄悄截断duration() throws {
        let fixture = try H264Fixture(bytes: TestSupport.fixtureBytes())
        XCTAssertThrowsError(try FMP4Writer.write(fixture: fixture, timescale: 1_000)) {
            XCTAssertEqual($0 as? FMP4Writer.WriteError, .timescaleNotDivisible(timescale: 1_000, fps: 30))
        }
    }

    /// 把 fixture 重新编码成字节（可丢掉前几帧），用来构造非法输入
    private static func encode(_ fixture: H264Fixture, dropFirst: Int) -> [UInt8] {
        var w = ByteWriter()
        w.raw(Array("H264FIX1".utf8))
        w.u16(fixture.width); w.u16(fixture.height); w.u32(fixture.fps)
        let frames = Array(fixture.frames.dropFirst(dropFirst))
        w.u32(UInt32(frames.count))
        w.u16(UInt16(fixture.avcC.count)); w.raw(fixture.avcC)
        for f in frames { w.u8(f.isSync ? 1 : 0); w.u32(UInt32(f.bytes.count)); w.raw(f.bytes) }
        return w.bytes
    }
}
```

注：`1000 % 30 != 0`，所以 timescale=1000 必须被拒绝。

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter FMP4MuxerTests.FMP4WriterTests`
Expected: 编译失败，`error: cannot find 'FMP4Writer' in scope`

- [ ] **Step 3: 实现 `Sources/FMP4Muxer/FMP4Writer.swift`**

```swift
/// 端到端：把一段已编码的 H.264 写成单视频轨 fMP4。
/// 分片由关键帧驱动（原文第六节）：新关键帧到来时，上一个 GOP 所有 sample 的 duration
/// 都已确定（滞后一帧），正好落成一个从同步帧开始、可独立解码的分片。
public enum FMP4Writer {
    public enum WriteError: Error, Equatable {
        case emptyFixture
        case firstFrameNotSync
        case timescaleNotDivisible(timescale: UInt32, fps: UInt32)
    }

    public static func write(fixture: H264Fixture, timescale: UInt32 = 90_000) throws -> [UInt8] {
        guard let first = fixture.frames.first else { throw WriteError.emptyFixture }
        guard first.isSync else { throw WriteError.firstFrameNotSync }
        guard fixture.fps > 0, timescale % fixture.fps == 0 else {
            throw WriteError.timescaleNotDivisible(timescale: timescale, fps: fixture.fps)
        }

        let config = VideoTrackConfig(width: fixture.width, height: fixture.height,
                                      avcC: fixture.avcC, timescale: timescale)
        let ticksPerFrame = Int64(timescale / fixture.fps)
        var out = HeaderBoxes.ftyp() + HeaderBoxes.moov(video: config)
        var builder = FragmentBuilder()
        var sequence: UInt32 = 1

        func emit(_ samples: [Sample]) {
            guard let head = samples.first else { return }
            out += FragmentWriter.fragment(sequence: sequence, tracks: [
                TrackFragment(trackID: config.trackID, baseMediaDecodeTime: UInt64(head.decodeTick), samples: samples),
            ])
            sequence += 1
        }

        for (index, frame) in fixture.frames.enumerated() {
            try builder.push(Sample(decodeTick: Int64(index) * ticksPerFrame, bytes: frame.bytes, isSync: frame.isSync))
            if frame.isSync { emit(builder.flush()) }   // 关键帧到来：上一个 GOP 的 duration 全部确定
        }
        emit(builder.finish())
        return out
    }
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `swift test --filter FMP4MuxerTests.FMP4WriterTests`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: 全量回归**

Run: `swift test`
Expected: `Executed 34 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/FMP4Muxer/FMP4Writer.swift Tests/FMP4MuxerTests/FMP4WriterTests.swift
git commit -m "feat(FMP4Muxer): 端到端写出，AVFoundation 完整解码 30 帧

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: 产物生成 CLI

**Files:**
- Modify: `Package.swift`（增加 `DemoCLI` 可执行 target 与 product）
- Create: `Sources/DemoCLI/main.swift`
- Create: `docs/artifacts/sample.mp4`（由 CLI 生成并入库）

**Interfaces:**
- Consumes: `H264Fixture`、`FMP4Writer`（Task 1、7）
- Produces: `swift run blog-demos mux` → `docs/artifacts/sample.mp4`；后续 demo 在同一个 `switch` 里加子命令

- [ ] **Step 1: 修改 `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlogDemos",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FMP4Muxer", targets: ["FMP4Muxer"]),
        .executable(name: "blog-demos", targets: ["DemoCLI"]),
    ],
    targets: [
        .target(name: "FMP4Muxer"),
        .executableTarget(name: "DemoCLI", dependencies: ["FMP4Muxer"]),
        .testTarget(name: "FMP4MuxerTests", dependencies: ["FMP4Muxer"]),
    ]
)
```

- [ ] **Step 2: 写 `Sources/DemoCLI/main.swift`**

```swift
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
```

- [ ] **Step 3: 运行 CLI 生成产物**

Run: `cd ~/Projects/blog-demos && swift run blog-demos mux`
Expected: `wrote /Users/ghostoo/Projects/blog-demos/docs/artifacts/sample.mp4`

- [ ] **Step 4: 验证产物能被系统工具打开**

Run: `mdls -name kMDItemDurationSeconds -name kMDItemPixelWidth -name kMDItemPixelHeight docs/artifacts/sample.mp4 ; afinfo docs/artifacts/sample.mp4 2>/dev/null | head -3 ; ls -l docs/artifacts/sample.mp4`
Expected: 文件约 5 KB；若 Spotlight 已索引，`kMDItemDurationSeconds = 1`、宽高 160×120（Spotlight 未索引时这两项可能为 `(null)`，以 Task 7 的 AVFoundation 测试为准）

- [ ] **Step 5: 用错误参数确认 CLI 不会静默成功**

Run: `swift run blog-demos nope; echo "exit=$?"`
Expected: 输出 `用法: swift run blog-demos <mux>` 且 `exit=1`

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/DemoCLI docs/artifacts/sample.mp4
git commit -m "feat(DemoCLI): swift run blog-demos mux 生成可播放的 sample.mp4

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: README、CI、spec 更正、首次推送

**Files:**
- Create: `README.md`
- Create: `.github/workflows/ci.yml`
- Modify: `docs/superpowers/specs/2026-09-22-blog-demos-design.md`（§5.1 A2 测试名、§11 风险表、§12 验收说明）

**Interfaces:**
- Consumes: 全部前序 Task
- Produces: 远程公开仓库 `github.com/DongQi-Yang/blog-demos`，CI 绿

- [ ] **Step 1: 写 `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Toolchain
        run: swift --version
      - name: Build
        run: swift build
      - name: Test
        run: swift test
      - name: Regenerate artifacts
        run: swift run blog-demos mux
      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: artifacts
          path: docs/artifacts
```

- [ ] **Step 2: 写 `README.md`**

````markdown
# blog-demos

[![CI](https://github.com/DongQi-Yang/blog-demos/actions/workflows/ci.yml/badge.svg)](https://github.com/DongQi-Yang/blog-demos/actions/workflows/ci.yml)

**这是什么**：我在掘金发表的 iOS / 音视频技术文章的配套 demo。每篇文章里的关键论断，在这里都是一条能重跑的测试。
**30 秒验证**：`git clone https://github.com/DongQi-Yang/blog-demos && cd blog-demos && swift test` —— 不需要 Xcode 工程、真机或签名。
**代码归属**：所有 demo 均为基于公开规范与文章结论的独立重写实现，不含任何雇主代码。

## 文章 ↔ demo

| 文章 | demo | 它证明了哪句论断 | 怎么跑 |
|---|---|---|---|
| [手写 fMP4 muxer：从 ISO 14496-12 到能播的文件](https://juejin.cn/post/7683935700154056713) | [`FMP4Muxer`](Sources/FMP4Muxer) | 单轨能播、加第二条轨就坏——`tfhd` 必须设 `default-base-is-moof`；最后一个 sample 的 duration 在写它时还不知道，要滞后一帧；逐帧换算 duration 录 10 分钟会漂 0.1 秒 | `swift test --filter FMP4MuxerTests` |

测试方法名就是论断本身，`swift test` 的输出就是一份结论清单：

```
test_单轨能播加上第二条轨就坏_tfhd必须设default_base_is_moof
test_最后一个sample的duration在写它时还不知道_滞后一帧后每个duration都是真实值
test_写法B逐个换算duration_30fps录10分钟最坏偏差9000tick即0点1秒
test_产出的fMP4能被AVFoundation完整解码30帧且时长1秒
…
```

## 产物

`swift run blog-demos mux` 生成 [`docs/artifacts/sample.mp4`](docs/artifacts/sample.mp4)：一个完全由手写 muxer 封装的 fMP4（160×120，30 帧，3 个分片，每个分片从关键帧开始），用系统播放器就能打开。

## 实测笔记：与原文不一致的地方

> 结论必须由可重跑的测试支撑——包括我自己文章里的结论。

**A2 原文第三节**说：`stbl` 里的四张空索引表（`stts`/`stsc`/`stsz`/`stco`）省掉之后，"AVFoundation 会直接拒绝"。
**2026-09 在 macOS 26.5.2 上实测**：删掉这四张表后，`AVURLAsset.isPlayable`、`AVAssetImageGenerator`、`AVAssetReader`（30 帧全部解码）和 passthrough 导出**全部成功**。原文当时的观察对象是 iOS 相册，比 macOS 上的 AVFoundation 更严格。

所以这个仓库**没有**写"AVFoundation 拒绝缺表文件"的测试——那会是一条撒谎的测试。结构完整性改由库内的严格读者 [`MP4Inspector`](Sources/FMP4Muxer/MP4Inspector.swift) 按 ISO/IEC 14496-12 的 "exactly one" 规则校验。原文的工程建议（空表必须写）不变：规范要求它，而且你不知道你的文件最终会被哪个最严格的读者打开。

## 测试码流

[`Fixtures/solid_160x120_30f.h264fix`](Fixtures) 是用 [`Scripts/make-h264-fixture.swift`](Scripts/make-h264-fixture.swift) 在本机 VideoToolbox 上一次性生成的 30 帧纯色 H.264（GOP = 10），随仓库提交。测试与 CI 从不重新生成它，所以不依赖任何机器上的硬件编码器。

## 环境

Swift 6.0+，macOS 14+。只用 Foundation；测试额外用 AVFoundation 作为预言机。
````

- [ ] **Step 3: 更正 spec**

在 `docs/superpowers/specs/2026-09-22-blog-demos-design.md` 中：

1. §5.1 表格 `FMP4Muxer` 一行的首条论断测试改为 `test_单轨能播加上第二条轨就坏_tfhd必须设default_base_is_moof()`
2. §11 风险表 "中文测试方法名" 一行的处理列改为：`已于 2026-09-23 实测：XCTest 能发现中文方法名，红灯与绿灯均正常，风险关闭`
3. §11 风险表末尾追加一行：`| 文章论断在当前系统上不复现 | 以实测为准，不写会撒谎的测试；差异如实写进 README「实测笔记」。首例：A2「缺空表 AVFoundation 拒绝」在 macOS 26.5.2 不复现 |`

- [ ] **Step 4: 全量验证**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: `Executed 34 tests, with 0 failures`

- [ ] **Step 5: 本地 commit**

```bash
git add README.md .github/workflows/ci.yml docs/superpowers/specs/2026-09-22-blog-demos-design.md
git commit -m "docs: README（作品集门面 + 实测笔记）、CI、spec 更正

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: 【需要用户操作】GitHub 授权**

执行者**停下来问用户**。推送 `.github/workflows/` 需要 token 带 `workflow` scope，当前 `gh` 的 keyring token 已失效。请用户在会话里运行：

```
! gh auth login -h github.com -s repo,workflow
! gh auth setup-git
```

确认：`gh auth status` 显示已登录且 scopes 含 `repo`、`workflow`。

- [ ] **Step 7: 创建公开仓库并推送**

```bash
cd ~/Projects/blog-demos
gh repo create DongQi-Yang/blog-demos --public --source . --remote origin \
  --description "掘金 iOS/音视频文章的配套 demo：每个论断都是一条能重跑的测试" --push
```

Expected: 输出仓库地址 `https://github.com/DongQi-Yang/blog-demos`，`git status` 显示与 `origin/main` 同步

- [ ] **Step 8: 确认 CI 变绿**

Run: `gh run watch --exit-status $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')`
Expected: 所有步骤通过，exit 0。
若只有 `test_产出的fMP4能被AVFoundation完整解码30帧且时长1秒` 在 runner 上失败：先用 `gh run view --log-failed` 读失败原因，**不得放宽断言**，按 superpowers:systematic-debugging 排查（runner 环境差异要用确定性输入解决，而不是删断言）。

- [ ] **Step 9: 验收对照（spec §12 与 §1 原话）**

逐条填写证据后汇报给用户：

| spec 条目 | 证据 |
|---|---|
| G1 扫描文章 | README 表格含 A2 链接（其余 5 篇由后续计划补齐） |
| G2 形成 demo | `swift test` 34 个测试全绿；`docs/artifacts/sample.mp4` 存在 |
| G3 放到 git 上 | 远程仓库 URL；CI 运行 URL 与结果 |
| 无雇主代码 | README 声明；代码全部为本计划内新写 |

---

## Self-Review（计划作者已完成）

1. **Spec 覆盖**：本计划覆盖 spec §4（骨架）、§5（A2 的契约与首条论断测试，已按原文更正）、§6（sample.mp4）、§7（README 形态，A2 一行）、§8（CI）、§9 第 1–2 步、§11（风险更正）、§12（部分验收）。§5.1 其余 5 个 demo、§6 另两个产物、§7 其余表格行 → 后续 Plan 2–6，每份在写之前重读对应文章原文。
2. **占位扫描**：无 TBD/TODO；每个代码步骤都有完整代码。
3. **类型一致性**：`Sample(decodeTick:bytes:isSync:duration:)`、`TrackFragment(trackID:baseMediaDecodeTime:samples:)`、`MP4Inspector.TrackFragmentData`、`SampleFlags.sync/.nonSync`、`VideoTrackConfig(width:height:avcC:trackID:timescale:)`、`TestSupport.u32(_:at:)` 在各 Task 中一致。
4. **Review Focus**：五项均已落到具体 Task 的具体测试。
5. **测试计数**：Fixture 4 + ByteWriter 4 + Inspector 4 + HeaderBoxes 6 + TickMath 3 + FragmentBuilder 4 + FragmentWriter 4 + FMP4Writer 5 = 34，Task 7 Step 5 与 Task 9 Step 4 已按 34 写。
6. **自查时修掉的问题**：测试总数 30→34；`XCTUnwrap(try await …)` 改为先 await 再 unwrap（autoclosure 不支持 await）；删掉 `MP4Box` 多余的手写 `==`（所有字段都是 Equatable，可自动合成）。

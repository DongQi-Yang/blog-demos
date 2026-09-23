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

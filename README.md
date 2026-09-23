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

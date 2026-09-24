# blog-demos

[![CI](https://github.com/DongQi-Yang/blog-demos/actions/workflows/ci.yml/badge.svg)](https://github.com/DongQi-Yang/blog-demos/actions/workflows/ci.yml)

**这是什么**：我在掘金发表的 iOS / 音视频技术文章的配套 demo。每篇文章里的关键论断，在这里都是一条能重跑的测试。
**30 秒验证**：`git clone https://github.com/DongQi-Yang/blog-demos && cd blog-demos && swift test` —— 不需要 Xcode 工程、真机或签名。
**代码归属**：所有 demo 均为基于公开规范与文章结论的独立重写实现，不含任何雇主代码。

## 文章 ↔ demo

| 文章 | demo | 它证明了哪句论断 | 怎么跑 |
|---|---|---|---|
| [手写 fMP4 muxer：从 ISO 14496-12 到能播的文件](https://juejin.cn/post/7683935700154056713) | [`FMP4Muxer`](Sources/FMP4Muxer) | 单轨能播、加第二条轨就坏——`tfhd` 必须设 `default-base-is-moof`；最后一个 sample 的 duration 在写它时还不知道，要滞后一帧；逐帧换算 duration 录 10 分钟会漂 0.1 秒 | `swift test --filter FMP4MuxerTests` |
| [视频编辑器的滤镜图内核：Node/Pin 模型怎么设计，撤销重做怎么才不崩](https://juejin.cn/post/7682406523184316454) | [`FilterGraph`](Sources/FilterGraph) | 成环的连线在 `connect` 时就拒绝；撤销 = 写回做的时候记下的旧值；`group` 的逆必须逆序；拖一次滑杆 120 帧只算一个撤销步骤（合并边界是手势）；20 个节点的直链只要 1 张中间纹理 | `swift test --filter FilterGraphTests` |

测试方法名就是论断本身，`swift test` 的输出就是一份结论清单：

```
test_单轨能播加上第二条轨就坏_tfhd必须设default_base_is_moof
test_最后一个sample的duration在写它时还不知道_滞后一帧后每个duration都是真实值
test_写法B逐个换算duration_30fps录10分钟最坏偏差9000tick即0点1秒
test_产出的fMP4能被AVFoundation完整解码30帧且时长1秒
test_tkhd的flags填0时轨道存在但被标为不启用_播不出来且不报错
test_没有mvex时解析器不去找moof_文件被当成0帧且不报错
test_成环的连线在connect时就被拒绝_非法的图不进入图
test_撤销等于把做的时候记下的旧值写回去_而不是做相反的操作
test_拖一次滑杆120帧只产生一个撤销步骤_合并的边界是手势
test_20个节点的直链只要1个槽位_先释放再分配才能原地复用
…
```

## 产物

`swift run blog-demos mux` 生成 [`docs/artifacts/sample.mp4`](docs/artifacts/sample.mp4)：一个完全由手写 muxer 封装的 fMP4（160×120，30 帧，3 个分片，每个分片从关键帧开始），用系统播放器就能打开。

## 实测笔记：与原文不一致的地方

> 结论必须由可重跑的测试支撑——包括我自己文章里的结论。

**A2 原文第三节**说：`stbl` 里的四张空索引表（`stts`/`stsc`/`stsz`/`stco`）省掉之后，"AVFoundation 会直接拒绝"。
**2026-09 在 macOS 26.5.2 上实测**：删掉这四张表后，`AVURLAsset.isPlayable`、`AVAssetImageGenerator`、`AVAssetReader`（30 帧全部解码）和 passthrough 导出**全部成功**。原文当时的观察对象是 iOS 相册，比 macOS 上的 AVFoundation 更严格。

**A2 原文第三节**还说：`ftyp` 不要写 `qt  `，否则按 QuickTime 语义读"就是损坏"。
**同一环境实测**：把主品牌改成 `qt  ` 后，文件照样可播、30 帧全部解码。这一条同样不复现。

所以这个仓库**没有**写"AVFoundation 拒绝缺表文件 / 拒绝 qt 品牌"的测试——那会是撒谎的测试。结构完整性改由库内的严格读者 [`MP4Inspector`](Sources/FMP4Muxer/MP4Inspector.swift) 按 ISO/IEC 14496-12 的 "exactly one" 规则校验。原文的工程建议不变：空表必须写、品牌按 ISO 声明——规范要求它，而且你不知道你的文件最终会被哪个最严格的读者打开。

反过来，原文另外两条关于播放器行为的论断**在同一环境复现成立**，已写成 AVFoundation 测试：`tkhd` 的 flags 填 0，轨道还在但被标为不启用、播不出来且不报错；删掉 `mvex`，解析器不去找 `moof`，文件被当成 0 帧且不报错。

| 原文论断 | macOS 26.5.2 实测 | 仓库里怎么处理 |
|---|---|---|
| 缺空索引表 → AVFoundation 拒绝 | 不复现（照常播放） | 只做结构校验，不写播放器测试 |
| 主品牌写 `qt  ` → 损坏 | 不复现（照常播放） | 只断言主品牌是 `iso5` |
| `tkhd` flags 填 0 → 黑屏且不报错 | 复现 | AVFoundation 测试 |
| 没有 `mvex` → 0 帧且不报错 | 复现 | AVFoundation 测试 |

还有一处是**原文示例代码**的问题：第四节 `finish()` 用 `ready.last?.duration` 兜底最后一帧，但 `flush()` 刚把 `ready` 取空时它会退化成 1。这里的实现改用"最后一个已知的真实 duration"，并由 `test_正常结束时最后一帧用最后一个已知duration兜底_即使之前已经flush过` 锁住。

## 与原文示例代码的差异：B1《滤镜图内核》

独立重写时，原文里的示例代码有 4 处在测试下站不住。每一处都是先把原文写法原样放回去、看着对应测试变红，再改成现在的实现：

| 原文写法 | 问题 | 锁住它的测试 |
|---|---|---|
| 槽位按"边"逐条释放 | 同一个上游输出接进同一节点的两个输入（blend 的 a、b 接同一个源）时，槽位进两次空闲表，之后被分给两个同时活着的值——画面被覆盖 | `test_同一个上游输出接进同一节点的两个输入时槽位只能释放一次` |
| `setParam` 返回 `Param?`，nil 表示节点不存在 | 给原本没有的参数赋值时旧值也是 nil，命令被误判为"节点不存在"而报错 | `test_给原本没有的参数赋值_撤销后参数消失而不是报节点不存在` |
| `disconnect` 的逆恒为 `connect` | 断开一条本来就不存在的线，撤销时会凭空接出这条线 | `test_断开一条不存在的连线_撤销不应凭空多出这条线` |
| `restoreNode` 里 `try? g.connect(e)` | 吞掉恢复失败；而恢复失败恰恰说明撤销栈和图对不上了（原文自己的立场） | `test_恢复节点时它的input已被别人占用必须报错而不是静默顶掉` |

另外两处是在原文思路上补的：`History` 在图的副本上应用命令、成功才提交（`group` 执行一半失败时图保持原样——值语义白送的原子性）；从磁盘解码的图重新走一遍 `connect` 的校验（手改过的工程文件不能把环带进来）。

## 测试码流

[`Fixtures/solid_160x120_30f.h264fix`](Fixtures) 是用 [`Scripts/make-h264-fixture.swift`](Scripts/make-h264-fixture.swift) 在本机 VideoToolbox 上一次性生成的 30 帧纯色 H.264（GOP = 10），随仓库提交。测试与 CI 从不重新生成它，所以不依赖任何机器上的硬件编码器。

## 环境

Swift 6.0+，macOS 14+。只用 Foundation；测试额外用 AVFoundation 作为预言机。

# blog-demos 设计文档

- 日期：2026-09-22
- 作者：杨东奇（与 Claude 协作）
- 状态：已通过设计评审，待转实施计划

---

## 1. Goal（用户原话，逐字）

> 「扫描我现在的掘金文章最好能形成 demo，放到我的 git 上」

拆成三条可验收的事：

| # | 用户原话片段 | 本设计如何满足 | 验收证据 |
|---|---|---|---|
| G1 | 扫描我现在的掘金文章 | 以 `~/.claude/skills/tech-blog/state.json` 里 14 篇已发布文章为全集，筛出 6 篇可脱离真机验证的做首批 | README 的文章 ↔ demo 对照表覆盖这 6 篇，每行带掘金链接 |
| G2 | 最好能形成 demo | 每篇 → 一个可运行 library + 一个 test target，至少一条测试直接对应文章论断；三个 demo 额外产出可看的产物 | `swift test` 全绿；`docs/artifacts/` 下有 mp4 / PNG |
| G3 | 放到我的 git 上 | 本地 `~/Projects/blog-demos` → 远程 `github.com/DongQi-Yang/blog-demos`（公开） | 远程仓库存在、CI 绿标、README 可直接发给客户 |

**用途定位（用户选定）**：接单作品集，读者是潜在客户。因此「客户三十秒内能看到它真的在跑」优先于覆盖面。

## 2. 非目标（明确不做）

- **不做真机/签名类 demo**：ReplayKit 录屏、Live Activity、Action Extension、Metal 零拷贝、macOS ScreenCaptureKit 全部排除在首批之外。客户跑不起来的 demo 对作品集是负资产。
- **不改已发布文章**：掘金每改一次重新审核一次，13 篇 = 13 次审核风险。只做单向链接（仓库 → 文章）。后续新文发布时自然带上仓库地址。
- **不引入第三方依赖**：只用 Foundation / CoreGraphics。依赖越少，客户 clone 后跑绿的概率越高。
- **不搬运任何雇主代码**：所有 demo 是基于公开 API 与文章结论的独立重写实现。

## 3. 选型结论

| 方案 | 取舍 | 结论 |
|---|---|---|
| **A. 单一 Swift Package**（6 library + 6 test target + 1 CLI） | 一条 `swift test` 全绿；无 Xcode/真机/签名门槛；CI 简单 | **采用** |
| B. 每个 demo 独立 Package | 隔离彻底，但客户要跑 6 次、6 份 CI、README 分散 | 否决 |
| C. Xcode workspace + 示例 App | 视觉最好，但需签名、CI 挂不绿 | 否决（与「一键跑绿」冲突） |

环境已验证：Swift 6.3.3 / Xcode 26.6；`~/Projects/blog-demos` 与 `github.com/DongQi-Yang/blog-demos` 均无冲突。

## 4. 仓库结构

```
blog-demos/
├── Package.swift                 # swift-tools 6.x，无第三方依赖
├── README.md                     # 作品集门面（§7）
├── .github/workflows/ci.yml      # macos-latest: swift build && swift test
├── Sources/
│   ├── FMP4Muxer/                # A2 手写 fMP4 muxer
│   ├── FilterGraph/              # B1 Node/Pin 图内核 + 撤销重做
│   ├── KeyframeTimeline/         # B3 关键帧三个时间 + 裁剪/变速重建
│   ├── MaterialProtocol/         # B2 素材协议解析 + 校验器
│   ├── ColorRange/               # C2 YUV→RGB range 与矩阵
│   ├── AVSyncDrift/              # C5 音画同步漂移模型
│   └── DemoCLI/                  # 产物生成命令行
├── Tests/
│   ├── FMP4MuxerTests/ …（每个 demo 一个）
├── Fixtures/                     # 预编码 H.264 片段等测试数据（KB 级）
└── docs/
    ├── artifacts/                # 生成的 mp4 / 对比 PNG（进仓库，小体积）
    └── superpowers/specs/        # 本文档
```

## 5. 每个 demo 的统一契约

一个 demo = **一个 library target + 一个 test target + 可选产物生成器**。三条硬性约定：

1. **论断测试**：至少一条测试直接对应文章里的一句论断，测试名就是那句话。测试列表 = 结论清单。
2. **零外部依赖**：library target 不依赖其他 demo，彼此不可互相 import（低耦合）。共用的只有 Foundation。
3. **可证伪**：断言必须是「实现写错就会红」的，禁止 `XCTAssertNotNil` 这类占位断言。

**测试框架统一用 XCTest**，不用 swift-testing。理由：`swift test` 在任何装了 Xcode 的机器上都能直接跑，作品集要的是客户 clone 下来零意外，不是用新框架。

### 5.1 六个 demo 的首条论断测试（实施时按此为红灯起点）

| Demo | 对应文章 | 首条论断测试（名字即论断） |
|---|---|---|
| `FMP4Muxer` | [A2 手写 fMP4 muxer](https://juejin.cn/post/7683935700154056713) | `test_单轨能播加上第二条轨就坏_tfhd必须设default_base_is_moof()` |
| `FilterGraph` | [B1 滤镜图内核](https://juejin.cn/post/7682406523184316454) | `test_成环的连接必须被拒绝而不是在渲染时栈溢出()` |
| `KeyframeTimeline` | [B3 关键帧动画系统](https://juejin.cn/spost/7688246386425118758) | `test_裁剪后区间外关键帧被删除且保留帧的局部时间按speed重算()` |
| `MaterialProtocol` | [B2 特效素材协议](https://juejin.cn/post/7688180809025110067) | `test_曲线采样数必须等于duration乘fps加2否则校验器报红()` |
| `ColorRange` | [C2 YUV 颜色范围与矩阵](https://juejin.cn/post/7683133522291441702) | `test_601与709在纯灰阶上逐比特相同所以UI录屏测不出矩阵错配()` |
| `AVSyncDrift` | [C5 音画同步](https://juejin.cn/post/7682796606999347238) | `test_毫秒取整累加每秒漂9_47ms而有理数时间基零漂移()` |

> 每个 demo 的后续测试在实施计划里展开，但**首条测试必须先红后绿**（TDD）。

## 6. 产物（客户能看见的东西）

| 产物 | 由谁生成 | 说明 |
|---|---|---|
| `docs/artifacts/sample.mp4` | `FMP4Muxer` + CLI | 用 `Fixtures/` 里几 KB 的预编码 H.264 封装成 fMP4，**能播**。不依赖硬件编码器，CI 稳定 |
| `docs/artifacts/color-range.png` | `ColorRange` + CLI | full/video range、601/709 四格对比图，CoreGraphics 直接写 PNG |
| `docs/artifacts/drift.png` | `AVSyncDrift` + CLI | 跑满一小时的漂移曲线 + 控制台数值报告 |

产物同时进仓库（便于 README 直接引用）和 CI artifact（便于验证可复现）。

## 7. README 形态

顶部三行回答：这是什么 / 30 秒怎么验证 / 代码归属。主体是一张表：

| 文章 | demo | 它证明了哪句论断 | 怎么跑 |
|---|---|---|---|

必须包含的一句声明：**所有 demo 均为基于公开 API 与文章结论的独立重写实现，不含任何雇主代码。**

注意：B3《关键帧动画系统》当前为审核中的 `spost/` 链接，过审后会变成 `post/` 形式，README 与本文档需同步更新一次。

## 8. CI

GitHub Actions，`macos-latest`，两步：`swift build` → `swift test`，再上传 `docs/artifacts/`。README 顶部挂绿标。CI 失败即视为仓库不可用，优先修。

## 9. 交付顺序

1. 骨架：`Package.swift` + README 框架 + CI + `.gitignore`
2. `FMP4Muxer`（含 fixture 与产物）跑绿 → **首次推送远程**
3. 之后每个 demo 一个 commit：`FilterGraph` → `KeyframeTimeline` → `MaterialProtocol` → `ColorRange` → `AVSyncDrift`
4. 收尾：README 表格补全、产物图入库、CI 绿标确认

仓库从第一天起就是绿的，不会出现半成品挂主页。

## 10. 与铁律的对应（CLAUDE.md）

| 铁律 | 本设计如何满足 |
|---|---|
| 高内聚 | 一个 demo 一个 target，只讲一篇文章的一件事；产物生成与核心逻辑分离（CLI vs library） |
| 低耦合 | demo 之间禁止互相 import；对外只暴露各自的公开类型；共用依赖仅 Foundation |
| 极强稳定性 | 无网络、无硬件编码器依赖；fixture 随仓库走；CI 失败可本地一比一复现 |
| 极高并发 | 首批 demo 为纯计算与解析，不涉阻塞 IO；CLI 产物生成为一次性批处理，不引入隐式共享状态 |
| 极强鲁棒性 | 解析类 demo（MaterialProtocol）的核心卖点就是边界校验：坏输入必须红，且区分「包坏了」与「包太新了」 |
| 极强扩展性 | 加第 7 个 demo = 新增一个 Sources 目录 + 一个 Tests 目录 + README 一行，不改任何既有 target |
| 结论必有可复现测试 | 整个仓库就是这条铁律的产物：每句文章论断对应一条可重跑的测试 |
| 防需求漂移 | §1 的 G1/G2/G3 表格用用户原话逐字对齐，每轮 Check 以此表为准 |
| 软件安装规范 | 不安装任何系统级依赖；仅用已有的 Xcode/Swift 工具链 |

## 11. 风险与已知约束

| 风险 | 处理 |
|---|---|
| `gh` CLI 的 keyring token 已失效 | `git push` 不受影响；新建远程仓库前需用户跑一次 `gh auth refresh -h github.com`，推送前会先问过用户 |
| 6 个 demo 工作量为数个工作日 | 按 §9 增量交付，每个 demo 单独 commit 并汇报，随时可叫停 |
| H.264 fixture 的来源与版权 | 使用自行生成的极短纯色测试码流，不引用任何第三方样片 |
| 中文测试方法名 | 已于 2026-09-23 实测：XCTest 能发现中文方法名，红灯与绿灯均正常，风险关闭 |
| 文章论断在当前系统上不复现 | 以实测为准，不写会撒谎的测试；差异如实写进 README「实测笔记」。首例：A2「缺空表 AVFoundation 拒绝」在 macOS 26.5.2 不复现 |
| macOS runner 行为差异 | 首批 demo 全部为纯计算，无硬件依赖；若某测试出现 runner 差异，改为确定性输入而非放宽断言 |

## 12. 验收标准

- [ ] `git clone && swift test` 在干净机器上全绿
- [ ] 每个 demo 至少一条「名字即论断」的测试，且实现写错会红
- [ ] `docs/artifacts/sample.mp4` 能被系统播放器打开
- [ ] README 表格覆盖 6 篇文章，每行有掘金链接与跑法
- [ ] CI 绿标可见
- [ ] 仓库内无任何雇主代码，声明已写入 README

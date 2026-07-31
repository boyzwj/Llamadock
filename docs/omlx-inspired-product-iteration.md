# LlamaDock 产品形态改进计划

> 状态：Complete — M0 through M6 implemented, verified, packaged, and installed
> 日期：2026-07-30
> 参考：oMLX 0.5.x macOS App 的信息架构、服务状态面板和菜单栏控制
> 原则：学习产品模式，不复制品牌、图标、文案或 oMLX 专属引擎能力

## 1. 目标

将 LlamaDock 从“功能页面集合”改造成一个面向本地 `llama.cpp`
服务生命周期的原生 macOS 控制台，使用户能在 5 秒内回答：

1. 服务是否正在运行？
2. 当前使用哪个 Runtime、模型和 Profile？
3. API 在哪里，是否可以连接？
4. 现在最重要的操作是什么？
5. 出错后应该去哪里查看和处理？

本轮成功标准：

- 主窗口形成稳定的分组侧栏和统一内容层级；
- 服务状态与主要控制在主窗口、菜单栏中持续可见；
- 模型、下载、Runtime、Profile 和日志各有清晰入口；
- 不改变外置 `llama.cpp`、透明 GGUF、真实启动命令等产品边界；
- 所有展示数据都来自现有状态或经过验证的新采集逻辑；
- 中英文、浅色/深色、键盘、VoiceOver 和窗口缩放均可用；
- 最终 Release 构建、全新本地打包和 `/Applications/Llamadock.app`
  重装验证通过。

## 2. 当前问题

### 2.1 信息架构

- 现有 `Overview / Runtimes / Models / Servers` 四个平级入口按工程模块划分，
  没有体现“运行服务 → 管理资源 → 调整配置”的用户心智。
- 下载任务藏在 Hugging Face 模型页面，Profile 编辑藏在模型详情，日志与服务控制
  挤在同一个页面，入口不稳定。
- Settings 使用标准 macOS Settings Scene 是正确的，但主窗口没有明确的设置入口和
  全局状态区域。

### 2.2 状态与操作

- 服务状态只在 Overview 摘要和 Servers 页局部出现，窗口关闭后完全不可见。
- Start / Stop / Restart 依赖用户先进入 Servers 页。
- Runtime、模型、Profile、endpoint 和运行指标没有组成一个完整的“当前服务”对象。
- 失败状态主要通过全局 Alert 和日志表达，缺少可恢复的就地提示。

### 2.3 视觉与布局

- 页面大量直接使用系统默认 `Form`、`GroupBox`、`List` 和工具栏，缺少统一的
  间距、容器、状态徽标和操作层级。
- 同一页面重复出现大标题、navigation title 和 toolbar，内容密度不一致。
- 代码中已有多种独立实现的 badge/card，但没有共享的视觉语义层。

## 3. 参考 oMLX 后的 LlamaDock 方案

### 3.1 采用

- 按领域分组的侧栏，而不是继续增加平级模块；
- 页面顶部持续可见的服务 Hero 卡；
- 状态、关键数据、主操作、次操作分层；
- macOS 菜单栏状态项作为服务 Dock；
- 模型、下载、日志等高密度页面采用列表/详情或摘要/明细布局；
- Appearance 中提供菜单栏和 Dock 图标行为设置；
- 空状态直接给出下一步，不只解释“当前为空”。

### 3.2 不采用

- 不复制 oMLX 品牌、鸟形图标、配色或逐字文案；
- 不展示 llama.cpp 当前不能可靠提供的 KV Cache 命中率、Prefill Token、
  Token Generation 等 oMLX 专属统计；
- 不因为视觉改造而引入常驻 daemon、隐藏服务或改变 App 退出即停止自有服务的边界；
- 不把标准 macOS Settings 的所有内容搬进主窗口；
- 不在本轮增加 Benchmark、量化、Integrations 等尚未形成产品闭环的一级模块。

## 4. 目标信息架构

侧栏建议保持 220–248 pt，使用 SF Symbols 和系统 selection appearance：

```text
运行
  总览             当前服务、环境、快捷操作
  服务             Profile、启动命令、启动/停止/重启
  日志             实时日志、级别过滤、复制/清空

资源
  模型             本地模型库、Hugging Face 与 ModelScope 浏览
  下载             下载队列、进度、暂停/继续/取消
  Runtime          安装、更新、切换、回滚

底部
  设置…            打开标准 Settings Scene
```

实现说明：

- `AppSection` 扩展为上述入口，并按 section group 输出；
- 第一阶段允许“服务”和“日志”复用同一份 `ServerSnapshot`；
- “下载”使用现有 `ModelDownloadSnapshot`，不新建第二套下载状态；
- Profile 仍属于服务配置，不单独制造“配置管理器”概念；
- 监听地址和端口属于全局服务网络配置，集中放在“服务”页；模型 Profile
  只保存模型与推理参数，旧 Profile 中的 host/port 在首次升级时迁移为全局值；
- Settings 继续使用独立 Scene，侧栏底部只提供入口和快捷键。

## 5. 视觉方向

### 5.1 原生优先

- 使用系统背景材料、动态颜色、SF Symbols 和系统控件；
- 不硬编码接近 oMLX 截图的深色面板；
- 浅色和深色模式拥有相同的信息层级；
- 保留 macOS 标准窗口、侧栏折叠和 toolbar 行为。

### 5.2 共享组件

建立轻量 UI primitives，避免抽象成复杂 Design System：

- `LlamaDockPageHeader`
- `ServiceHeroCard`
- `MetricCard`
- `StatusBadge`
- `SectionCard`
- `InlineNotice`
- `EmptyStateAction`

统一语义：

- 页面内边距：24–28 pt；
- 区块间距：20–24 pt；
- 卡片内边距：16–20 pt；
- Ready 使用 green，进行中使用 blue，Degraded 使用 orange，Failed 使用 red，
  Stopped 使用 secondary；
- 每个页面只保留一个 prominent primary action；
- 路径、命令和日志使用 monospaced，其余使用系统字体。

## 6. 里程碑

### M0 — 基线与改造护栏

目标：冻结行为基线，降低大范围 SwiftUI 重排的回归风险。

交付：

- 记录当前工作树基线和现有用户流程；
- 为导航、服务控制 enablement、状态文本映射补充可测试的纯状态模型；
- 建立 UI primitives 和 Preview fixtures；
- 把共享颜色、间距和 badge 语义集中管理；
- 保持所有现有功能入口可达。

验收：

- Core 全量测试通过；
- Debug App build 通过；
- 导航模型、状态映射和关键按钮禁用逻辑有测试；
- 不改变 server/profile/runtime/download 持久化格式。

### M1 — 主窗口骨架与分组侧栏

目标：先完成用户可感知最大的结构改造，不改业务实现。

交付：

- 新的分组侧栏与底部 Settings 入口；
- 统一页面 header、内容宽度、滚动和 toolbar 策略；
- Overview、Models、Runtimes 迁移到共享容器；
- 拆出独立 Logs 和 Downloads 入口；
- Command 菜单和快捷键同步新导航。

验收：

- 所有旧功能在新结构中最多两次点击可达；
- 900×600 最小窗口无裁切，1080×720 为舒适默认尺寸；
- 侧栏折叠、窗口恢复、键盘导航可用；
- 中英文无关键截断；
- 浅色/深色模式均通过截图检查。

### M2 — 菜单栏服务 Dock

目标：无需打开主窗口也能确认和控制 LlamaDock 服务。

交付：

- 使用原生 `MenuBarExtra` 或等价 AppKit 状态项展示 Stopped / Starting /
  Ready / Degraded / Failed；
- 菜单中展示当前模型、Profile、endpoint 和 uptime；
- 提供 Start、Stop、Restart、Open WebUI、Copy API URL、Settings、Quit；
- App 默认仅保留菜单栏图标；Settings 打开主窗口时显示 Dock 图标，最后一个
  App 窗口关闭后恢复为仅菜单栏模式；
- 正确处理窗口关闭、重新打开、App 退出和运行中服务；
- VoiceOver label 与禁用原因完整。

验收：

- 主窗口关闭后菜单栏状态继续更新；
- 菜单栏与主窗口控制共享同一状态、不会重复启动；
- Stop/Restart 的 enablement 与现有安全边界一致；
- Quit 仍执行 owned server shutdown，不引入后台 daemon；
- Dock 图标隐藏时仍能从菜单栏恢复主窗口。

### M3 — 服务总览 Dashboard

目标：让总览页成为当前运行环境的可信控制台。

交付：

- 顶部 Service Hero：状态、Runtime 版本、endpoint、Start/Stop/Restart；
- 全局网络配置：监听地址、端口，以及修改后重启生效的明确反馈；
- 当前配置：模型、Profile、context、真实启动命令入口；
- 可靠指标卡：PID、CPU、resident memory、threads、uptime；
- Runtime、模型库、下载队列、最近错误的摘要卡；
- 日志预览和“查看全部日志”；
- 缺少 Runtime / 模型 / Profile 时给出单一明确下一步。

验收：

- 不展示无法从 LlamaDock 或 llama-server 验证的数据；
- 运行状态变化在 500 ms 级别更新，进程指标保持现有低频采样；
- 错误以 inline notice 表达并带恢复动作，全局 Alert 仅保留真正阻塞错误；
- Ready 状态下两次点击内可以复制 API URL 或打开 WebUI。

### M4 — 模型、下载、Runtime 工作流精修

目标：让资源管理页面达到桌面管理工具应有的信息密度与操作确定性。

交付：

- Models 保留本地/Hugging Face/ModelScope 分段，但统一列表行、详情、badge
  和空状态；
- Downloads 成为稳定页面，展示队列、总进度、速度/剩余时间（仅在数据可靠时）、
  暂停、继续、取消和失败重试；
- Runtimes 将“当前激活”“可更新”“已安装”分层，危险操作移入上下文菜单；
- Profile 编辑按 Basic / Performance / Advanced 渐进披露；
- destructive action 保留现有精确目标确认和保护规则。

验收：

- 扫描、搜索和下载期间界面保持响应；
- 选中项在刷新后尽量稳定；
- 暂停/恢复/取消与重启恢复测试通过；
- Profile 生成的真实命令与改造前语义一致；
- 所有高风险操作都有明确对象、原因和不可逆提示。

### M5 — 首次使用、设置与产品细节

目标：补齐“第一次打开就知道怎么用”和长期使用的品质感。

交付：

- 只在必要时出现的首次使用引导：Runtime → 模型 → Profile → Start；
- Settings 分为 General、Appearance、Updates、Hugging Face、Diagnostics、About；
- 统一成功、警告、失败、进行中反馈；
- 完成简体中文和英文文案审校；
- Reduce Motion、Increase Contrast、VoiceOver、键盘焦点适配；
- 统一 app icon 在窗口、About 和菜单栏中的使用。

验收：

- 新用户无需 Terminal 完成首次启动；
- 老用户升级后不被强制重新 onboarding；
- 所有关键控件有可理解的 accessibility label/help；
- 设置即时生效且重启后保持；
- 无新增凭据、路径或日志隐私泄露。

### M6 — 视觉回归、发布与本地安装

目标：以可运行的 Release App 完成本轮，而不是停在源码和 Debug build。

交付：

- Core 全量测试、App Debug/Release build 和 release contract 验证；
- 对 900×600、1080×720、宽窗口进行中英文、浅色/深色截图审查；
- 手工 smoke：首次空状态、安装/选择 Runtime、选择模型、Profile、Start、
  Ready、Copy API、Open WebUI、Restart、Stop、日志和下载；
- 从最终 workspace 状态创建全新本地 Release 包；
- 重装 `/Applications/Llamadock.app`；
- 校验安装包 version/build、arm64 架构和 code signature；
- 将结果和遗留问题记录到本文档的实施记录。

验收：

- 不能复用旧构建产物；
- 安装后的 App 可启动，核心 smoke 通过；
- `codesign --verify --deep --strict` 通过；
- 版本、build 与最终源码配置一致；
- 如因本机签名/权限无法完成，任务必须明确标记为 incomplete，不得只汇报
  “代码已完成”。

## 7. 实施顺序和变更策略

1. 严格按 M0 → M6 顺序推进；
2. 每个里程碑开始前先检查当前工作树，保留用户已有变更；
3. 每个里程碑结束时更新本文档的实施记录、测试证据和已知问题；
4. 结构重排优先复用 `AppModel` 和 Core 状态，不在 View 中新建平行状态源；
5. 业务逻辑变更与纯视觉重排分开，便于定位回归；
6. 不为追求截图相似度牺牲 macOS 原生行为；
7. 遇到指标数据缺口时先降级 UI，不伪造或估算数据。

## 8. 实施记录

| 里程碑 | 状态 | 证据 | 遗留问题 |
| --- | --- | --- | --- |
| M0 基线与护栏 | Complete | 保留起始 dirty worktree；新增 `ProductState` 纯状态模型和测试；Core 154 tests / 42 suites 通过；最终 Debug build 通过 | 未改变现有持久化 schema；既有默认端口、日志严重级别和失败状态改动均保留 |
| M1 主窗口与侧栏 | Complete | 分组侧栏、独立 Logs/Downloads、底部状态/设置、Cmd-1…6 与 Shift-Cmd-L；Computer Use 验证中英文 AX 树、侧栏折叠入口和 900 宽窗口 | 统一标题栏使内容区高度与整窗高度相差约 52 pt，已将内容下限校正为 548 pt 以支持 900×600 整窗 |
| M2 菜单栏 Dock | Complete | 原生 `MenuBarExtra` 共享 `AppModel` 控制；关闭主窗口后进程仍运行；Appearance 双入口护栏实测为另一开关 disabled | 自动化无法单独展开系统菜单栏 extra 的弹出菜单；菜单内容、enablement、VoiceOver label 和主窗口恢复路径已由源码/AX 检查 |
| M3 服务总览 | Complete | Overview/Service Hero、可信 PID/CPU/RSS/threads/uptime、配置/命令/资源/日志摘要；深浅色与中英文截图/AX 检查 | 未增加 KV Cache、Prefill 或 Token Generation 等不可验证指标 |
| M4 资源工作流 | Complete | Models 渐进式 Profile；Hugging Face/ModelScope 双在线源；稳定 Downloads 队列与恢复操作；Runtime 当前/已安装分层和上下文危险操作；现有下载、Profile、Runtime 测试全通过 | 13k+ 本地模型行会超过 Computer Use 的全量 AX 序列化上限；应用进程保持运行，列表使用 SwiftUI 虚拟化，后续可增加分页/分段扫描 |
| M5 Onboarding 与设置 | Complete | 条件式 Runtime→模型→Profile→Start 引导；六组 Settings；Reduce Motion；中英文即时切换；浅/深色、键盘和 VoiceOver/AX 检查 | macOS 自带 File/Edit/Window 菜单继续跟随系统语言，产品自定义 Navigate/Server 菜单跟随应用语言 |
| M6 发布与本地安装 | Complete | 从最终 workspace 新建 Release archive 和本地 ZIP；重装 `/Applications/Llamadock.app`；版本 `1.0.0 (1)`、bundle ID `io.github.boyzwj.LlamaDock`、thin arm64、严格 codesign、安装前后 SHA-256/目录一致性和真实服务 smoke 均通过 | 本地包使用 ad-hoc hardened-runtime 签名；公开分发仍需 Developer ID 签名与 notarization |

### 8.1 实施摘要

- 业务状态继续以 `AppModel`、`ServerSnapshot`、`ModelDownloadSnapshot`
  和 Core registry/store 为唯一来源；新 View 只做派生展示和路由。
- `ServiceControlState` 集中计算 Start/Stop/Restart enablement 与阻塞原因，
  主窗口、菜单栏和 Commands 共用同一 `AppModel` 操作。
- Logs 复用现有 bounded log buffer，Downloads 复用现有下载 manager；
  没有新建并行 server、download、runtime 或 profile 状态源。
- 本地化 catalog 的简体中文条目已补齐。对于必须返回 `String` 的动态文案，
  `appLocalizedString` 显式选择语言 bundle，避免应用内即时切换时沿用系统语言。
- Computer Use 检查了空 onboarding、已有用户状态、Overview、Service、Logs、
  Downloads、Runtime 和六组 Settings；键盘 Cmd-3 可直接进入 Logs。

### 8.2 M6 最终测试与安装证据

- `swift test --disable-sandbox --package-path Packages/LlamadockCore`：
  154 tests / 42 suites passed；FSEvents 真实文件事件用例通过。
- `xcodebuild ... -configuration Debug -destination
  'platform=macOS,arch=arm64' ... build`：`BUILD SUCCEEDED`。
- `Scripts/verify-release-contract.sh`：`Release contract verified.`。
- 视觉/AX：深色中文和浅色中英文均检查；900×600、1080×720 和
  1234×768 宽窗口均覆盖，主操作、空状态、侧栏底部状态与 Settings 仍可达。
  Computer Use 验收还发现并修正了应用内切换语言时动态字符串沿用系统语言，以及
  标题栏高度导致整窗最小尺寸超过 900×600 的问题。
- 最终 Release 使用新的临时目录
  `/private/tmp/llamadock-final-release.nJvk2N`，从当时最新 workspace 状态执行
  arm64 Release archive；没有复用 Debug 或旧 Release 产物。
- 新包：
  `dist/local/LlamaDock-1.0.0-build1-20260730T040950Z-macOS-arm64-local.zip`；
  ZIP SHA-256 为
  `9c796991204f82e2e996cefd5796044bbec2cef12da2fa3970cc69472c78a2dc`，
  配套 `.sha256` 校验通过。
- 重装前将旧 App 移至可恢复备份
  `/private/tmp/Llamadock.app.previous-20260730T040950Z`，随后从新 archive
  安装 `/Applications/Llamadock.app`。archive 与安装目录 `diff -qr` 无差异，
  两侧可执行文件 SHA-256 均为
  `9f161f2bdd4315cf5fe8d62025bc77a265b920df751416c7c3c99070998b9dec`。
- 安装包校验：`CFBundleShortVersionString=1.0.0`、`CFBundleVersion=1`、
  bundle ID `io.github.boyzwj.LlamaDock`、Mach-O thin arm64；
  `codesign --verify --deep --strict` 通过，签名为本机 ad-hoc，
  hardened runtime version `26.5.0`。
- 安装后真实 smoke：恢复受管 Runtime b10182、GGUF 模型与 Profile；
  Start 进入 Ready，Copy API URL 和 Open WebUI 动作可用；首次 PID `91267`，
  Restart 后 PID `21730`；日志显示模型加载及监听 `127.0.0.1:39281`；
  下载页恢复已完成/失败任务；`GET /v1/models` 返回 200，
  gzip WebUI `GET /` 返回 200 `text/html`；Stop 后回到已停止状态。

### 8.3 剩余风险

- 当前产物是面向本机安装的 ad-hoc 签名包，不等同于可公开分发的
  Developer ID + notarized release。
- 13k+ 模型库的全量 Accessibility 序列化超过 Computer Use 工具上限；
  App 进程和 SwiftUI 虚拟列表保持运行。后续若继续增长，可评估分段扫描或分页。
- 系统菜单栏 extra 的弹出层无法由当前自动化单独展开；其内容、enablement、
  VoiceOver label、双入口护栏和关闭主窗口后的进程存活已分别由源码、AX 和实机
  状态检查覆盖。

### 8.4 运行时探测卡住回归修复

- 2026-07-30 实机复现：窗口重新打开后，已安装 Runtime 刷新和 b10184
  安装验证同时停留在进行中超过 45 秒；事务停在 `validatingBinaries`。
  同一组 b10184 二进制在命令行和单实例 Core smoke 中均能在约 0.02 秒内
  完成版本/帮助输出，因此排除了损坏 Runtime。
- 根因是 Runtime 安装在 App bootstrap/刷新尚未结束时仍可被触发，同时
  `FoundationProcessRunner` 不仅将阻塞式 `waitUntilExit` 和
  `readDataToEndOfFile` 放在 Swift cooperative executor 上，而且最前面的
  `Process.run()` 发生在超时竞速开始之前。并发大输出会造成执行器饥饿；
  Hardened Release 中若启动调用自身不返回，则后续 timeout 根本没有机会生效。
  已有 `refreshRuntimes` 也没有阻止重入。
- 修复后，进程启动、等待和管道读取均转移到 GCD utility queue；启动阶段单独
  参与 timeout/cancellation 竞速，迟到的启动会被终止并安全释放资源。
  Runtime 探测默认每个命令最多 5 秒，并在每个候选项结束后渐进发布结果，
  不再因为最后一个异常候选项让整个列表保持空白。
- bootstrap、刷新、server/runtime 操作期间禁用 Runtime 变更；重复 refresh
  直接合并；服务启动也把 Runtime 刷新视为 busy。对应 policy 放入
  `ManagedRuntimeControlState` 纯状态模型，没有增加并行状态源。
- 新增启动阶段阻塞超时、并发大输出进程和 Runtime 变更护栏回归测试。
  定向 16 tests / 3 suites 通过；完整 Core 157 tests / 42 suites 通过。
  Debug build、Release archive、Release contract、xcstrings compile、
  `git diff --check` 均通过。
- 修复后的 Debug App 和最终安装 Release 均在冷启动 7 秒检查点前结束探测，
  Runtime 页恢复刷新操作并列出 b10184、b10182、b10176 和自定义 Runtime。
  安装后的手动 Refresh 也在 7 秒检查点前完成；此前已从官方缓存重新下载、
  验证、注册并激活 b10184，确认安装链路完整。
- 最终 Release 使用全新 archive
  `/private/tmp/llamadock-runtime-probe-final.21XgWh/LlamaDock.xcarchive`；
  新本地包为
  `dist/local/LlamaDock-1.0.0-build1-20260730T072458Z-macOS-arm64-runtime-probe-fix.zip`，
  ZIP SHA-256 为
  `2cecdd48adfdb38887c613396415f5b509048359cb0f836b3d603314f0102d8f`，
  `unzip -t` 通过。
- 安装前版本已移到可恢复备份
  `/private/tmp/Llamadock.app.pre-runtime-probe-final-20260730T072458Z`。
  新 `/Applications/Llamadock.app` 为 `1.0.0 (1)`、
  `io.github.boyzwj.LlamaDock`、thin arm64、ad-hoc hardened runtime 签名；
  `codesign --verify --deep --strict` 和 archive/安装目录 `diff -qr` 通过，
  两侧可执行文件 SHA-256 均为
  `c4ec2abbb8bf719ed6a625ab93cf74c9496c369c92cbf4214bff4f1101c44751`。
- 安装后以 b10184 启动真实 GGUF 服务，PID `44472` 约 4 秒进入 Ready；
  `/health` 返回 `{"status":"ok"}`，`/v1/models` 返回模型列表。Stop 后回到
  已停止状态，`127.0.0.1:39281` 无遗留监听进程。

## 9. 参考资料

- oMLX README: <https://github.com/jundot/omlx/blob/main/README.md>
- oMLX Releases: <https://github.com/jundot/omlx/releases>
- 用户提供的 oMLX 0.5.3 服务统计界面截图

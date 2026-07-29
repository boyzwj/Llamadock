# Llamadock 产品与技术设计文档

> 状态：Draft v0.1  
> 目标平台：Apple Silicon Mac，macOS 14+  
> 实现语言：Swift 6 / SwiftUI  
> 核心原则：原生、轻量、外置内核、透明文件、可回滚、紧跟上游  
> 项目目录：`~/ws/Llamadock`

---

## 1. 项目摘要

Llamadock 是一个面向 macOS 的原生 `llama.cpp` 管理软件。它负责：

1. 自动发现、安装、验证、切换和升级 `llama.cpp` runtime；
2. 搜索、下载、校验和整理 Hugging Face 上的 GGUF 模型；
3. 为每个模型保存一个或多个可读、可复制、可迁移的 `llama-server` 配置；
4. 启动、停止和监控 `llama-server`，并提供 OpenAI-compatible endpoint 与上游 WebUI 的入口。

Llamadock **不把 `libllama` 静态或动态链接进 App**，也不重新实现推理引擎。GUI 和 runtime 有独立生命周期：即使 Llamadock 没有发布新版本，用户仍可直接升级到最新的官方 `llama.cpp` build。

产品定位不是“另一个 LM Studio”，而是：

> **一个原生、薄、透明的 llama.cpp runtime + model + profile + server 管理器。**

---

## 2. 背景与问题

现有方案的问题：

- LM Studio 使用 Electron，功能和资源占用偏重，推理内核升级取决于应用发布节奏；
- Ollama 使用自己的模型存储与配置抽象，普通 GGUF 文件和完整 `llama-server` 参数不够透明；
- 原生 SwiftUI 应用大多把某一版 llama.cpp 编译进 App，仍然需要等待应用作者更新；
- 轻量 launcher 往往只会启动已有 binary，不负责模型下载或 runtime 更新；
- 完整 runtime manager 多为 Tauri/Web 技术栈，不符合原生 macOS 体验目标。

`llama.cpp` 上游目前已提供统一 `llama` 命令入口，并包含 `serve`、`download`、`update` 等能力；官方 GitHub Release 也提供 macOS arm64 binary。因此，Llamadock 应尽量编排上游能力，而不是复制上游实现。

---

## 3. 产品目标

### 3.1 必须实现

- SwiftUI 原生界面，无 Electron、Tauri、Python runtime；
- 支持 Apple Silicon 与 Metal；
- 检测本机已有 `llama` / `llama-server`；
- 管理由 Llamadock 下载的多个官方 llama.cpp runtime；
- 比较当前 build 与上游最新 build；
- 一键安装、升级、切换和回滚 runtime；
- 本地 GGUF 目录扫描和 metadata 展示；
- Hugging Face GGUF 搜索、量化选择和下载；
- 普通文件存储，不使用 opaque blob store；
- 每模型、多 profile 的 `llama-server` 参数管理；
- 启动/停止/重启服务，显示日志和健康状态；
- 对外暴露标准 OpenAI-compatible API；
- 可复制真实启动命令；
- 所有关键错误可见，不静默吞错。

### 3.2 明确不做（至少 v1.0 前）

- 不实现 RAG、知识库、Agent、MCP host；
- 不实现云端模型 API 聚合；
- 不自行实现 Chat UI（优先使用 `llama-server` WebUI）；
- 不实现模型训练、转换或量化 GUI；
- 不链接 llama.cpp XCFramework；
- 不在 App 退出后维持隐藏 daemon；
- 不接管用户通过终端启动的进程；
- 不自动修改 shell 初始化文件；
- 不建立 Ollama 式内容寻址 blob store；
- 不承诺 Intel Mac 支持；
- v1.0 前不支持多台远程主机或多机调度。

### 3.3 成功指标

- 初次安装到启动一个可用模型，用户无需打开终端；
- Llamadock App 不更新时，仍可安装最新 llama.cpp runtime；
- 升级失败不会破坏当前可用 runtime；
- 删除 App 不会删除用户选择的外部模型目录；
- 用户能从 UI 复制一条可在 Terminal 独立运行的等价命令；
- 空闲且未启动 server 时，App 不持有大量内存或后台计算资源；
- 任何运行时参数不被 Llamadock 隐式改写而不告知用户。

---

## 4. 设计原则

### 4.1 Runtime 与 App 解耦

禁止采用：

```text
SwiftUI App -> linked llama.xcframework -> inference
```

采用：

```text
SwiftUI App -> Foundation.Process -> llama / llama-server -> GGUF
```

好处：

- llama.cpp 可独立升级；
- server 崩溃不会直接带崩 GUI；
- 用户可选官方、Homebrew 或自编译 runtime；
- 可保留多个版本并快速回滚；
- 参数和行为可通过真实 binary 的 `--help` / `--version` 检测；
- 调试时用户可复现同一条命令。

### 4.2 上游优先

优先顺序：

1. 调用上游 `llama` 已有能力；
2. 使用上游官方 GitHub Release；
3. 使用 Hugging Face 公共 API；
4. 只有在上游没有稳定接口时，才在 App 内实现对应逻辑。

### 4.3 文件透明

- 模型是普通 `.gguf` 文件；
- profile 是带 schema version 的 JSON；
- runtime 放在按 build 命名的目录；
- 下载中的文件使用清楚的临时后缀；
- UI 提供 Reveal in Finder；
- 不要求模型只能放在 App 私有目录。

### 4.4 安全升级

新 runtime 必须经历：下载 → 校验 → 解压到临时目录 → binary 验证 → 原子注册 → 切换。任何一步失败，现有 active runtime 保持不变。

### 4.5 能力检测而非版本猜测

llama.cpp 参数变化快。Llamadock 不应只靠 build number 推测能力，而应执行：

```bash
llama --version
llama-server --version
llama-server --help
```

将真实输出解析为 `RuntimeCapabilities`。无法识别的参数仍可通过 `Extra Arguments` 传入。

---

## 5. 用户与主要场景

### 5.1 目标用户

- 使用 Apple Silicon Mac 的本地 LLM 高级用户；
- 希望及时使用 llama.cpp 新模型支持和性能改进；
- 不喜欢 Electron 和常驻 daemon；
- 希望直接管理 GGUF 与完整 server 参数；
- 需要为 IDE、Hermes、脚本等提供本地 OpenAI-compatible endpoint。

### 5.2 核心用户旅程

#### 首次使用

1. 启动 Llamadock；
2. App 检测系统 runtime；
3. 用户选择“安装由 Llamadock 管理的最新 runtime”；
4. App 下载官方 macOS arm64 release 并验证；
5. 用户进入 Models，搜索 HF repo；
6. 选择量化文件并下载；
7. App 创建默认 profile；
8. 点击 Start；
9. 健康检查通过后打开 WebUI 或复制 API 地址。

#### runtime 更新

1. App 启动时做非阻塞版本检查；
2. UI 显示 `Installed bXXXXX / Latest bYYYYY`；
3. 用户点击 Update；
4. 若 active runtime 正被 Llamadock server 使用，提示需先停止；
5. 下载和验证新版本；
6. 原子切换 active runtime；
7. 保留上一版；
8. 若新版本启动失败，用户一键 rollback。

#### 使用外部 runtime

1. App 发现 `/opt/homebrew/bin/llama-server`；
2. 展示来源为 Homebrew；
3. 可以使用，但 Llamadock 不直接覆盖其文件；
4. 更新按钮执行受控的 Homebrew 流程，或提示用户手动升级；
5. Custom runtime 仅检测和使用，永不覆盖。

---

## 6. 信息架构与界面

主窗口使用 `NavigationSplitView`，左侧四个一级页面：

1. **Overview**
2. **Runtimes**
3. **Models**
4. **Servers**

Settings 使用标准 macOS Settings Scene。

### 6.1 Overview

显示：

- active runtime 与 latest build；
- 当前模型数量、磁盘占用；
- server 状态；
- 最近 profile；
- 更新提示和错误摘要；
- 快捷操作：Start Last Profile、Add Model、Check Updates。

Overview 只做摘要，不复制完整管理功能。

### 6.2 Runtimes

列表字段：

- 来源：Managed / Official Installer / Homebrew / Custom；
- build/tag；
- architecture；
- backend/capabilities；
- binary 路径；
- active 状态；
- validation 状态；
- 安装时间；
- 是否有更新。

操作：

- Install latest；
- Check updates；
- Activate；
- Validate；
- Roll back；
- Delete inactive managed runtime；
- Add custom runtime；
- Reveal in Finder；
- Copy version output。

约束：

- active runtime 不可删除；
- 正在运行 server 使用的 runtime 不可删除或替换；
- 外部 runtime 不可由 App 删除；
- managed runtime 默认保留 active + previous 两版。

### 6.3 Models

#### Library tab

- 扫描一个或多个目录；
- 搜索、排序、筛选；
- 显示名称、架构、参数量、量化、大小、context、路径；
- 标记 split GGUF、mmproj、draft/MTP companion；
- 显示内存适配估算，并明确标为 estimate；
- Import、Delete、Reveal、Create Profile。

#### Discover tab

- HF 搜索；
- 排序：Trending、Downloads、Likes、Recently Updated；
- repo detail；
- 列出实际 `.gguf` 文件与大小；
- 区分 main model、split shard、mmproj、其他 auxiliary；
- 显示 gated/private 状态；
- quant picker；
- 下载队列。

#### Downloads tab/panel

- 下载进度、速度、ETA；
- Pause、Resume、Cancel、Retry；
- 断点续传；
- 下载完成后的 GGUF magic、大小和可选 checksum 校验；
- 下载完成前不得作为可运行模型注册。

### 6.4 Model detail 与 Profiles

一个模型可保存多个 profile。模型详情页包含：

- metadata；
- 文件与 companion；
- profiles 列表；
- 创建、复制、重命名、导入、导出 profile；
- 选定 profile 的 typed fields；
- Extra Arguments；
- capability warning；
- Generated Command Preview。

首版 typed fields：

- model path；
- alias；
- host；
- port；
- context size；
- GPU layers；
- threads；
- parallel slots；
- batch / ubatch；
- flash attention；
- KV cache K/V type；
- temperature；
- top-k；
- top-p；
- min-p；
- repeat penalty；
- seed；
- system prompt（如果由 server flag 支持）；
- mmproj path；
- draft model path；
- extra arguments。

参数 UI 必须基于 active runtime capabilities 标记：Supported、Unsupported、Unknown。

### 6.5 Servers

v1.0 允许保存多个 server definition，但默认只启动一个。是否支持并发运行由里程碑逐步开放。

显示：

- State：Stopped / Starting / Ready / Degraded / Failed / Stopping；
- runtime + model + profile；
- PID 和 process start time；
- host / port / endpoint；
- uptime；
- CPU、resident memory；
- health response；
- bounded stdout/stderr logs。

操作：

- Start、Stop、Restart；
- Open WebUI；
- Copy API Base URL；
- Copy curl example；
- Copy launch command；
- Save logs；
- Reveal model/runtime。

---

## 7. 总体架构

```text
┌──────────────────────────────────────────────┐
│                 SwiftUI Views                │
│ Overview | Runtimes | Models | Profiles | UI │
└──────────────────────┬───────────────────────┘
                       │ @Observable app state
┌──────────────────────▼───────────────────────┐
│              Application Services            │
│ RuntimeService | ModelService | ServerService│
│ DownloadService | ProfileService             │
└──────────┬───────────┬───────────┬───────────┘
           │           │           │
┌──────────▼───┐ ┌─────▼──────┐ ┌──▼──────────┐
│ GitHub/HF API│ │ File Stores │ │ Process I/O │
│ URLSession   │ │ JSON/GGUF   │ │ Foundation  │
└──────────────┘ └─────────────┘ └──────┬──────┘
                                       │
                              ┌────────▼────────┐
                              │ llama binaries │
                              │ llama-server   │
                              └────────┬────────┘
                                       │
                              ┌────────▼────────┐
                              │ GGUF / HTTP API │
                              └─────────────────┘
```

### 7.1 代码模块

建议先使用一个 Xcode app target + 一个可测试的 Swift Package 核心层：

```text
Llamadock/
├── Llamadock.xcodeproj
├── App/
│   ├── LlamadockApp.swift
│   ├── AppModel.swift
│   ├── AppCommands.swift
│   └── AppDelegate.swift
├── Packages/
│   └── LlamadockCore/
│       ├── Package.swift
│       ├── Sources/LlamadockCore/
│       │   ├── Runtime/
│       │   ├── Models/
│       │   ├── Profiles/
│       │   ├── Server/
│       │   ├── Downloads/
│       │   ├── Persistence/
│       │   └── Shared/
│       └── Tests/LlamadockCoreTests/
├── Features/
│   ├── Overview/
│   ├── Runtimes/
│   ├── Models/
│   ├── Profiles/
│   ├── Servers/
│   └── Settings/
├── Resources/
├── LlamadockUITests/
├── Scripts/
├── docs/
└── THIRD_PARTY_NOTICES.md
```

核心层尽量只依赖 Foundation，以便 `swift test` 快速运行。SwiftUI、NSOpenPanel、NSWorkspace、Settings Scene 留在 App target。

### 7.2 并发模型

- UI state：`@MainActor @Observable final class AppModel`；
- Runtime registry：actor；
- Download manager：actor；
- Server process owner：actor；
- Profile/model stores：actor；
- URLSession 使用 async/await；
- `Process` stdout/stderr 通过 Pipe 转成 `AsyncStream<LogEvent>`；
- 所有长操作都支持 cancellation；
- UI 更新统一回到 MainActor。

禁止：

- 在主线程同步读取大 GGUF；
- 在主线程等待 subprocess；
- 使用 `/bin/zsh -c` 拼接用户输入；
- 将共享 mutable dictionary 暴露给多个 Task。

---

## 8. 数据与持久化设计

### 8.1 默认目录

```text
~/Library/Application Support/Llamadock/
├── runtimes/
│   ├── b10175-macos-arm64/
│   ├── b10142-macos-arm64/
│   ├── downloads/
│   └── registry.json
├── models/
├── profiles/
│   └── <profile-id>.json
├── downloads/
│   └── state.json
├── logs/
│   └── <server-run-id>.log
├── cache/
│   ├── github/
│   └── huggingface/
└── settings.json
```

外部模型目录通过 security-scoped bookmark 持久化访问权限。不要假设 sandbox 外目录重启后仍可访问。

### 8.2 Runtime schema

```json
{
  "schemaVersion": 1,
  "id": "managed:b10175:macos-arm64",
  "source": "managed",
  "tag": "b10175",
  "build": 10175,
  "architecture": "arm64",
  "installDirectory": "/Users/me/Library/Application Support/Llamadock/runtimes/b10175-macos-arm64",
  "llamaPath": ".../llama",
  "serverPath": ".../llama-server",
  "installedAt": "2026-07-29T08:05:26Z",
  "validatedAt": "2026-07-29T08:06:12Z",
  "versionOutput": "...",
  "validation": "valid"
}
```

`source` 枚举：

- `managed`
- `officialInstaller`
- `homebrew`
- `custom`

外部 runtime 记录路径和检测结果，但不声明文件所有权。

### 8.3 Profile schema

```json
{
  "schemaVersion": 1,
  "id": "9D4A85F7-2A82-4E46-A49B-A9C879F0DB4F",
  "name": "Coding 32K",
  "model": {
    "mainPath": "/Users/me/AI-Models/Qwen.gguf",
    "mmprojPath": null,
    "draftPath": null
  },
  "runtimeSelection": {
    "policy": "activeManaged",
    "runtimeID": null
  },
  "server": {
    "alias": "qwen-local",
    "host": "127.0.0.1",
    "port": 8080,
    "contextSize": 32768,
    "gpuLayers": 99,
    "threads": 8,
    "parallel": 1,
    "batchSize": 2048,
    "ubatchSize": 512,
    "flashAttention": true,
    "cacheTypeK": "q8_0",
    "cacheTypeV": "q8_0"
  },
  "sampling": {
    "temperature": 0.7,
    "topK": 40,
    "topP": 0.95,
    "minP": 0.05,
    "repeatPenalty": 1.05,
    "seed": -1
  },
  "extraArguments": [],
  "createdAt": "2026-07-29T08:10:00Z",
  "updatedAt": "2026-07-29T08:10:00Z"
}
```

规则：

- JSON key 由 Llamadock schema 管理，不直接使用任意 dictionary；
- 生成命令时映射到当前 runtime 的真实 flag；
- schema migration 必须是显式、可测试、逐版本的；
- 未识别字段在迁移时尽量保留，避免未来版本回退造成数据丢失；
- 保存使用临时文件 + `FileManager.replaceItemAt` 原子替换。

### 8.4 模型身份

不要只用路径作为模型 ID。建议：

```text
modelID = volumeResourceIdentifier + fileResourceIdentifier
fallback = standardizedPath + fileSize + modificationDate
```

首版不必计算整个多 GB 文件的 SHA256。下载时若 HF 提供 LFS oid/checksum，可保存远端校验信息；用户导入的模型只做 magic、大小和 metadata 合理性检查。

---

## 9. Runtime 管理详细设计

### 9.1 Discovery 顺序

候选路径：

```text
官方 llama installer 的已知安装位置（以实际安装脚本为准动态确认）
/opt/homebrew/bin/llama
/opt/homebrew/bin/llama-server
/usr/local/bin/llama
/usr/local/bin/llama-server
用户选择的 custom 路径
Llamadock managed registry
```

不可依赖 GUI App 的 `PATH` 与用户终端一致。所有进程使用绝对 executable URL。

每个候选执行：

```text
<binary> --version
<server> --version
<server> --help
```

记录 exit code、stdout、stderr 和超时。单个探测建议 5 秒超时。

### 9.2 上游版本检查

GitHub endpoint：

```text
GET https://api.github.com/repos/ggml-org/llama.cpp/releases/latest
```

解析：

- `tag_name`，形如 `b10175`；
- `published_at`；
- `assets[]`；
- Apple Silicon asset：名称匹配官方当前约定的 macOS arm64 archive；
- 不把文件名模式写死为唯一判断，需同时验证 OS、arch、archive 类型。

网络响应需支持：

- ETag / If-None-Match；
- User-Agent；
- 速率限制错误；
- 离线缓存；
- 手动刷新。

“Latest”只是查询结果，不等于已验证可用。

### 9.3 Managed runtime 安装事务

状态机：

```text
idle
  -> fetchingRelease
  -> downloading
  -> verifyingArchive
  -> extracting
  -> validatingBinaries
  -> registering
  -> ready
  -> failed
```

步骤：

1. 在 `runtimes/downloads/` 创建唯一临时目录；
2. 下载到 `asset.part`；
3. 校验 HTTP status、Content-Length；
4. 若 release 提供 checksum，校验 checksum；
5. 安全解压，拒绝 `../`、绝对路径和 symlink escape；
6. 搜索 `llama` 与 `llama-server`，限制递归深度；
7. 检查 executable bit，必要时仅在 managed 目录内修复；
8. 执行 `--version`；
9. 校验架构为 arm64 或 universal；
10. 将临时目录原子移动到 build 目录；
11. 原子更新 registry；
12. 用户选择后更新 active runtime ID；
13. 清理临时文件。

任何失败：

- 不修改 active runtime；
- 保留可诊断错误；
- 清理不完整目录，或标为 quarantine；
- UI 提供 Retry 和 Copy Diagnostics。

### 9.4 更新策略

- 默认启动后最多每天检查一次，不自动下载；
- 用户可启用“自动下载，手动切换”，但 v1.0 不默认启用；
- 不建议无提示自动切换最新 runtime，因为上游高频更新可能引入回归；
- 切换前如果该 runtime 正在服务，要求 stop；
- 默认保留 active 与 previous；
- rollback 只改变 active runtime 指针，不重新下载。

### 9.5 外部 runtime 更新

- `officialInstaller`：若真实 binary 支持 `llama update`，可调用；
- `homebrew`：显示 `brew outdated llama.cpp` 检测结果；执行更新前明确展示将运行的 `brew upgrade llama.cpp`；
- `custom`：只提示上游更新，不覆盖；
- 所有外部更新都必须由用户显式触发；
- 不修改 `.zshrc`、PATH 或 Homebrew 配置。

MVP 可以先只做 managed runtime 自动更新，外部来源仅检测和提示。

---

## 10. 模型管理详细设计

### 10.1 GGUF 扫描

- 允许配置多个模型根目录；
- 使用目录枚举器扫描 `.gguf`；
- 忽略 `.part`、隐藏下载目录和已知临时文件；
- 不跟随会逃出根目录的 symlink；
- 大目录扫描放后台 task；
- 使用文件系统 watcher 增量刷新；
- metadata 读取只读 header 和 tensor metadata，不 mmap/load 完整权重；
- 解析失败不从列表消失，显示 Invalid/Unsupported 与错误原因。

至少提取：

- general.name；
- architecture；
- parameter count（可得时）；
- context length（可得时）；
- quantization；
- tensor count；
- file size；
- split information；
- chat template presence；
- vision/mmproj 线索。

### 10.2 Hugging Face 搜索

Repo 搜索优先使用带 GGUF/llama.cpp filter 的 Hub API。详情页使用 tree API 确认文件：

```text
GET https://huggingface.co/api/models/<repo>/tree/main?recursive=true
```

规则：

- 只把 `type=file` 且 `.gguf` 结尾的条目列为 GGUF；
- main model、`mmproj-*`、split shard 分组；
- 不把 BF16 shard、README、imatrix 当作可运行模型；
- 保留 repo 原始 quant label，如 `UD-Q4_K_M`；
- gated repo 未配置 token 时不伪装成可下载；
- token 存 Keychain，不写 settings JSON 或日志；
- 用户粘贴 repo URL、`owner/repo:QUANT`、`llama serve -hf ...` 都能解析。

### 10.3 下载设计

下载单元 `DownloadJob`：

- job ID；
- repo/revision/path；
- destination；
- expected size；
- received bytes；
- ETag；
- resume data 或 Range offset；
- state；
- error；
- created/updated time。

状态：

```text
queued -> resolving -> downloading -> paused
                              -> verifying -> importing -> completed
                              -> failed / cancelled
```

要求：

- 支持 Range resume；
- destination 先写 `.part`；
- split GGUF 作为一个 group job，全部完成才注册；
- mmproj 可与主模型一起选择；
- 完成后验证 `GGUF` magic；
- Content-Length 不符则失败；
- 文件替换前检查同名冲突；
- 不默认覆盖用户文件；
- App 重启后恢复未完成任务；
- token、Authorization header 不进入日志。

### 10.4 并发下载

中国网络环境下单连接可能很慢，因此架构应允许分段并发，但分阶段实现：

- MVP：URLSession 单任务 + 系统 resume；
- v0.3：可配置 1/2/4/8 段 Range 下载；
- 分段写入必须避免多个 task 无保护写同一 file handle；
- 合并后做 size/checksum 校验；
- 服务端不支持 Range 时自动退回单连接；
- 默认并发数保守，用户可在 Settings 调整。

---

## 11. Profile 与参数系统

### 11.1 参数分层

1. **Typed parameters**：UI 有明确类型、范围、说明；
2. **Extra arguments**：用户直接添加 token 数组；
3. **Generated arguments**：由模型 companion、路径和 runtime 生成；
4. **Prohibited arguments**：会破坏进程归属、安全边界或与 App 管理冲突的参数。

禁止把 extra arguments 保存为一整条 shell string。保存为：

```json
["--some-flag", "value", "--boolean-flag"]
```

### 11.2 命令生成

实现纯函数：

```swift
func makeServerInvocation(
    profile: LaunchProfile,
    runtime: RuntimeInstallation,
    capabilities: RuntimeCapabilities
) throws -> ProcessInvocation
```

输出：

```swift
struct ProcessInvocation {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let displayCommand: String
}
```

规则：

- Process 直接使用 arguments array；
- `displayCommand` 只用于复制/展示，使用可靠的 shell quoting；
- 用户输入永远不经过 shell；
- Llamadock 管理的 host/port/model flags 不允许在 Extra Arguments 重复；
- 重复冲突在保存前报错；
- unsupported typed flag 给出明确 warning；
- 不静默丢弃未知 flag。

### 11.3 动态 capabilities

`llama-server --help` 解析结果保存：

```swift
struct RuntimeCapabilities: Codable, Sendable {
    var supportedFlags: Set<String>
    var rawHelpHash: String
    var supportsWebUI: Bool
    var supportsMetrics: Bool
    var supportsPropsEndpoint: Bool
    var detectedAt: Date
}
```

解析器不必理解所有 flag 的语义，只要能确认存在。若 help 格式变化导致解析失败：

- typed UI 标为 Unknown，不标为 Unsupported；
- Extra Arguments 仍可用；
- 保留 raw help 用于诊断。

---

## 12. Server 进程管理

### 12.1 所有权

Llamadock 只管理自己创建的 `Process`。每次运行生成 `ServerRun`：

```swift
struct ServerRun {
    let id: UUID
    let processIdentifier: Int32
    let processStartTime: Date
    let runtimeID: String
    let profileID: UUID
    let command: ProcessInvocation
}
```

不可通过进程名批量 `killall llama-server`。Stop 只向持有的子进程发送信号。

### 12.2 启动流程

1. 验证 runtime、模型和 companion 文件仍存在；
2. 验证 profile；
3. 检查 host/port；
4. 创建 Process 与 stdout/stderr Pipe；
5. 写入 run log header（不含 token）；
6. 启动 Process；
7. 立即开始消费两路 pipe，避免缓冲区阻塞；
8. 轮询 `/health`；
9. 超时前若 process 退出，状态为 Failed；
10. health ready 后状态为 Ready；
11. 可选查询 `/props`、`/v1/models`；
12. UI 开放 WebUI 与 API 操作。

默认 readiness timeout 可设 120 秒，并按模型大小允许用户调整。轮询使用退避，初始 200ms，上限 2s。

### 12.3 停止流程

1. 状态改为 Stopping；
2. `process.terminate()`（SIGTERM）；
3. 等待宽限期，例如 5 秒；
4. 未退出时提示用户是否强制停止；
5. 强制停止仅针对已核验 PID + start time 的 owned process；
6. drain pipe；
7. 保存最终 exit status；
8. 状态改为 Stopped/Failed。

App 正常退出时对 owned process 执行有界停止。系统强杀 App 无法保证清理，因此下一次启动要检测 run registry 中遗留 PID，但在 start time 与 executable path 未完全匹配时不得自动杀进程，只提示用户。

### 12.4 日志

- stdout 与 stderr 标记来源；
- 每条事件有 timestamp；
- UI 内存 ring buffer，例如 5,000 行或 5 MB；
- 完整日志可滚动写文件；
- token 和 Authorization header 必须脱敏；
- 下载 URL 若包含签名 query，应在日志中移除 query；
- 提供 Copy Diagnostics，包含 App/runtime/build/profile 摘要，但不包含密钥和完整用户 prompt。

### 12.5 进程指标

使用 macOS 原生 API 获取 owned PID 的：

- resident memory；
- CPU usage；
- elapsed time。

指标是辅助信息，不作为 readiness source of truth。readiness 以 server health endpoint 和进程存活为准。

---

## 13. 网络与 API

### 13.1 默认安全策略

- 默认 host 为 `127.0.0.1`；
- 用户改为 `0.0.0.0` 或局域网地址时显示安全警告；
- 不自动开放防火墙；
- 不自动生成公网 tunnel；
- 不把 HF token 传给 `llama-server`，除非用户明确选择 server 直接从 HF 下载；
- 推荐由 Llamadock 下载到本地后再启动。

### 13.2 Health adapter

上游 endpoint 可能随版本变化。实现适配顺序：

1. `/health`；
2. 若 capabilities 指示其他 endpoint，则使用对应 adapter；
3. `/v1/models` 仅作为 API 可用性补充检查；
4. HTTP 200 但 payload 不可识别时状态为 Degraded，而非 Ready。

所有解析都需要 fixture tests，不能把某个 build 的 JSON 永久写死。

### 13.3 对外集成

Ready 后显示：

```text
API Base URL: http://127.0.0.1:8080/v1
WebUI:       http://127.0.0.1:8080/
```

提供可复制示例，但不要自动修改第三方应用配置：

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen-local","messages":[{"role":"user","content":"Hello"}]}'
```

---

## 14. 安全设计

### 14.1 二进制供应链

- 只从配置的 `ggml-org/llama.cpp` 官方 GitHub repo 下载 managed runtime；
- UI 显示来源 URL、tag、发布时间；
- 如果上游提供 checksum/signature，必须校验；
- 没有上游 checksum 时至少记录 archive size、GitHub asset ID、ETag，并在 UI 明示验证级别；
- 解压防 path traversal；
- 不执行 archive 内安装脚本；
- validation 进程使用绝对路径与最小环境变量。

### 14.2 凭据

- HF Token 存 Keychain；
- 不存 UserDefaults、JSON、日志；
- UI 只能显示 masked token；
- 删除 token 时同步清除 Keychain item；
- 网络请求通过 URLSession header 注入；
- 错误对象不得携带完整 Authorization header。

### 14.3 文件删除

- 外部模型删除默认移到 Trash，而非永久删除；
- managed runtime 仅能删除 App-owned 路径；
- 删除前标准化并验证目标位于预期根目录；
- symlink 目标不跟随删除；
- 删除 active/used runtime 被禁止。

### 14.4 Sandbox 与签名

早期开发可 non-sandboxed 方便迭代，但发布前必须明确选择：

- 若启用 App Sandbox：模型目录使用 security-scoped bookmarks；运行外部 executable 的权限和分发限制需做真实签名测试；
- 若不启用 Sandbox：仍需 Developer ID 签名、公证、Hardened Runtime，并将文件操作限制在用户明确选择范围。

该决策必须在 v0.2 前完成，避免后期重构文件访问层。

---

## 15. 错误模型

定义统一错误：

```swift
public enum LlamadockError: Error, Sendable {
    case runtimeNotFound
    case runtimeInvalid(reason: String)
    case releaseUnavailable(reason: String)
    case downloadFailed(reason: String)
    case archiveUnsafe(entry: String)
    case modelInvalid(reason: String)
    case profileInvalid(fields: [String])
    case portInUse(port: UInt16)
    case processLaunchFailed(reason: String)
    case readinessTimedOut(seconds: Int)
    case processExited(code: Int32, stderrTail: String)
    case permissionDenied(path: String)
}
```

UI 错误应包含：

- 用户可理解的标题；
- 发生了什么；
- 没有发生什么（例如旧 runtime 未被替换）；
- 可执行操作：Retry、Choose Path、Rollback、Copy Diagnostics；
- 技术详情折叠区。

禁止仅显示 `Something went wrong`。

---

## 16. 性能目标

- 冷启动到主界面：目标 < 1 秒（不阻塞等待网络/全盘扫描）；
- 模型扫描增量展示，不等全部完成；
- GGUF metadata 解析不读取整个文件；
- 日志 ring buffer 有硬上限；
- HF/GitHub 缓存有 TTL 与磁盘上限；
- 未运行 server 时不进行持续高频轮询；
- metrics 采样默认 2–4 秒；
- server logs 高频输出时应批量合并 UI 更新，避免每行触发 view refresh；
- 大模型下载不把数据完整加载进内存。

---

## 17. 可访问性与原生体验

- 使用标准 SwiftUI controls 与 macOS Settings；
- 完整键盘导航；
- 所有 icon 有 accessibility label；
- 不只靠颜色区分状态；
- progress 可被 VoiceOver 读取；
- 支持浅色/深色；
- 避免自制 Web 风格 titlebar；
- 支持菜单命令和快捷键：Start/Stop、Open Model、Show Logs；
- destructive actions 使用系统 confirmation dialog；
- Finder、Keychain、OpenPanel、Trash 使用系统 API。

---

## 18. 测试策略

### 18.1 单元测试

`LlamadockCoreTests` 至少覆盖：

- runtime version/tag parsing；
- GitHub asset selection；
- architecture filtering；
- archive path traversal rejection；
- runtime registry atomic update；
- active/previous rollback；
- profile encode/decode/migration；
- argument generation及冲突检测；
- shell display quoting（仅展示）；
- `--help` capability parser；
- GGUF header parsing fixtures；
- split GGUF grouping；
- HF repo/ref/command parser；
- tree API classification；
- download state transitions；
- health payload parsing；
- log redaction；
- bounded ring buffer。

### 18.2 Fake executable 集成测试

在 tests fixtures 创建可执行 shell/Swift helper，模拟：

- `--version` 正常/失败/超时；
- `--help` 多种格式；
- server 写 stdout/stderr；
- server 延迟 ready；
- server 立即崩溃；
- 忽略 SIGTERM；
- 返回不同 health payload。

测试重点是 Llamadock 的进程管理，不依赖真实模型。

### 18.3 网络测试

使用 `URLProtocol` mock：

- GitHub latest release；
- ETag 304；
- rate limit；
- HF search/tree；
- gated 401/403；
- Range resume；
- server 不支持 Range；
- Content-Length mismatch。

### 18.4 真实 smoke test

不放入 CI 默认流程；本机可运行：

1. 选已安装的真实 `llama-server`；
2. 选一个小 GGUF；
3. Start；
4. 等待 `/health`；
5. 调 `/v1/models`；
6. 发最短 completion/chat 请求；
7. Stop；
8. 验证无 owned orphan process。

脚本建议：

```text
Scripts/smoke-real-runtime.sh
```

脚本不得下载大模型；模型路径由环境变量传入。

### 18.5 UI 测试

优先覆盖关键旅程而不是像素细节：

- 首次无 runtime；
- 添加 custom runtime；
- runtime 更新确认；
- 模型导入；
- profile validation；
- server start/ready/stop；
- 错误详情与 rollback。

---

## 19. 构建、发布与更新

### 19.1 开发要求

- Swift 6；
- 当前主机为 arm64 macOS；
- Xcode 项目生成后记录最低 Xcode 版本；
- 格式化可使用 `swift-format`，但不让额外工具成为普通构建的硬依赖。

基础质量门：

```bash
swift test --package-path Packages/LlamadockCore
xcodebuild -project Llamadock.xcodeproj \
  -scheme Llamadock \
  -configuration Debug \
  -destination 'platform=macOS' build
```

### 19.2 App 自更新

App 更新和 runtime 更新必须是两个独立概念：

- **Llamadock Update**：更新 SwiftUI App；
- **llama.cpp Runtime Update**：更新上游 binary。

UI 文案和设置页必须明确区分。App 自更新可使用 Sparkle，但在 MVP 后加入。

### 19.3 分发

正式发布要求：

- Developer ID Application 签名；
- Hardened Runtime；
- Apple notarization；
- DMG 或 ZIP；
- SHA256SUMS；
- GitHub Release；
- 可选 Homebrew Cask；
- Privacy 文档；
- 第三方许可证与 attribution。

---

## 20. 许可与参考实现

可参考：

- `ggml-org/llama.cpp`：上游 CLI、release 和 server API；
- Llamaboard：SwiftUI、GGUF/HF/模型配置思路（MIT，使用代码时保留许可）；
- Catapult：runtime versioning、asset selection 和 rollback 思路（Apache-2.0，避免无 attribution 复制）；
- Sparkle：App 自更新。

原则：

- 优先独立实现小型 adapter；
- 若复制或修改第三方源码，记录来源文件、commit、license；
- `THIRD_PARTY_NOTICES.md` 在第一次引入代码时就建立；
- 不把 llama.cpp binary 的许可义务与 App 源码许可混淆。

建议 Llamadock 自身采用 MIT 或 Apache-2.0，最终由项目所有者决定。

---

## 21. 里程碑

### Milestone 0：仓库与可构建骨架

交付：

- Git repo；
- macOS SwiftUI App；
- `LlamadockCore` package；
- CI 执行 core tests + xcodebuild；
- 基础导航和 Settings；
- README、LICENSE、THIRD_PARTY_NOTICES。

退出标准：Debug build 和 tests 在干净 checkout 通过。

### Milestone 1：外部 Runtime + 单 Server 垂直切片

交付：

- Homebrew/custom runtime discovery；
- `--version` 与 `--help` capability detection；
- NSOpenPanel 选择 GGUF；
- 单个 profile；
- 真实 command preview；
- Process 启停；
- stdout/stderr logs；
- health polling；
- Open WebUI。

退出标准：能用本机真实小 GGUF 完成 start → ready → API request → stop，且无 orphan。

### Milestone 2：Managed Runtime

交付：

- GitHub latest release 查询；
- macOS arm64 asset 选择；
- 安全下载/解压；
- binary validation；
- registry；
- activate、保留 previous、rollback；
- 更新提示。

退出标准：模拟失败不会改变 active；真实安装能运行 `--version`。

### Milestone 3：本地模型库与 Profiles

交付：

- 多目录 bookmarks；
- GGUF metadata parser；
- 模型列表；
- 多 profile；
- typed settings + extra arguments；
- JSON migration；
- command conflict detection。

退出标准：重启 App 后目录、模型和 profiles 可恢复；不同 runtime 下 unsupported flags 被正确提示。

### Milestone 4：Hugging Face 与下载管理

交付：

- search/detail/tree；
- quant picker；
- HF token Keychain；
- pause/resume/cancel；
- split GGUF；
- mmproj；
- 校验和冲突处理。

退出标准：能从 repo 搜索到下载、导入、创建 profile 并启动。

### Milestone 5：发布质量

交付：

- App 自更新；
- 签名和公证；
- 完整诊断；
- accessibility；
- 性能优化；
- release automation；
- 用户文档。

退出标准：在至少两代 Apple Silicon 和不同内存规格 Mac 上 smoke test 通过。

---

## 22. Codex 推进规则

后续使用 Codex 时，每个任务必须遵循：

1. 先读本设计文档；
2. 只实现当前 milestone 的一个纵向小切片；
3. 先写失败测试，再实现；
4. 不在没有测试的情况下重构核心 process/download/persistence；
5. 不引入 Electron、Tauri、Python 或 `libllama` linkage；
6. 不使用 shell 拼接执行用户输入；
7. 不自动修改 `.zshrc` 或其他 shell init；
8. 不用假数据冒充真实 benchmark/telemetry；
9. 所有网络和 subprocess 行为应可注入 mock/fake；
10. 完成后必须运行测试和 build，报告真实输出；
11. 每次提交保持单一目的；
12. 发现设计冲突时先更新 ADR，不静默改变架构。

推荐每轮 Codex prompt 模板：

```text
Read DESIGN.md first. Implement only: <one narrow task>.

Constraints:
- Follow the architecture and non-goals in DESIGN.md.
- Use TDD: add a failing focused test first.
- Do not invoke a shell; Foundation.Process must receive an absolute executable URL and argument array.
- Keep external behavior injectable for tests.
- Do not add unrelated features or dependencies.

Acceptance criteria:
- <criterion 1>
- <criterion 2>
- <criterion 3>

Verification:
- Run the focused tests.
- Run the complete LlamadockCore test suite.
- Run the macOS app build if app code changed.
- Report actual command output and changed files.
```

### 22.1 建议最初的 Codex 任务序列

1. 建立 Xcode App + Core package 骨架；
2. 为 `ProcessRunning` 定义 protocol 与 fake；
3. TDD 实现 runtime candidate discovery；
4. TDD 实现 `--version` probe 和 timeout；
5. TDD 实现 `--help` capabilities parser；
6. 建立 Runtime 页面并接入真实 probe；
7. TDD 定义 `LaunchProfile` schema；
8. TDD 实现 profile 原子存储；
9. TDD 实现 server argument builder；
10. 实现 NSOpenPanel 模型选择；
11. TDD 实现 bounded log buffer 和 redaction；
12. TDD 实现 ServerProcess actor；
13. TDD 实现 health adapter；
14. 接入 Start/Stop/Restart UI；
15. 用本地小 GGUF 做真实 smoke test；
16. 再开始 Managed Runtime，不提前做 HF UI。

---

## 23. 架构决策记录（ADR）

应在 `docs/adr/` 保存独立 ADR。首批 ADR：

- `0001-external-runtime-process-boundary.md`
- `0002-profile-json-schema.md`
- `0003-managed-runtime-transaction.md`
- `0004-model-directory-security-scoped-bookmarks.md`
- `0005-app-sandbox-decision.md`
- `0006-no-shell-process-execution.md`

每个 ADR 包含 Context、Decision、Consequences、Alternatives。

本设计已确定的首要决策：

### ADR-0001 摘要

**Decision：** Llamadock 不链接 llama.cpp；使用绝对路径启动外部 `llama` / `llama-server`。

**Consequences：**

- 优点：runtime 独立升级、崩溃隔离、命令透明；
- 代价：需要管理 subprocess、版本差异和 HTTP readiness；
- 不允许为了“更方便拿 token stream”重新引入 XCFramework，除非未来另立产品分支并重做架构评审。

---

## 24. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| llama.cpp CLI/help 变化快 | 参数解析失效 | capability detection；Unknown 状态；Extra Arguments |
| 官方 release asset 命名变化 | 找不到下载 | 解析 asset metadata；错误可诊断；测试多种 fixture |
| 新 runtime 回归 | server 无法启动 | 多版本共存；验证；保留 previous；一键 rollback |
| 大模型下载不稳定 | 用户体验差 | resume、Range、重试、持久 job state |
| GGUF 规格扩展 | parser 不兼容 | 宽容读取；invalid 可见；fixture 持续更新 |
| HF gated/private | 401/403 | Keychain token；明确 gated 状态 |
| macOS 权限/sandbox | 外部目录重启失效 | security-scoped bookmark；早做发布架构决策 |
| orphan process | 占内存/端口 | owned process registry；graceful termination；启动时诊断 |
| 误杀用户进程 | 数据/服务中断 | 禁止 killall；PID + start time + executable 验证 |
| scope creep | 变成臃肿 LM Studio | 明确 non-goals；milestone gate；ADR 审查 |
| 第三方代码许可 | 发布风险 | THIRD_PARTY_NOTICES；记录来源与 commit |

---

## 25. v1.0 验收标准

### Runtime

- [ ] 自动检测 managed、Homebrew、custom runtime；
- [ ] 显示真实 version/build；
- [ ] 能查询上游 latest；
- [ ] 能安装官方 macOS arm64 runtime；
- [ ] 安装失败不影响 active；
- [ ] 能切换和 rollback；
- [ ] 不覆盖 custom runtime。

### Models

- [ ] 多目录扫描；
- [ ] GGUF metadata 可见；
- [ ] HF 搜索与实际文件列表；
- [ ] 下载、暂停、恢复、取消；
- [ ] gated token 存 Keychain；
- [ ] split GGUF 与 mmproj 正确分组；
- [ ] 普通文件可在 Finder 管理。

### Profiles

- [ ] 每模型多 profile；
- [ ] JSON 可读、可导入导出；
- [ ] typed fields + extra arguments；
- [ ] capabilities warning；
- [ ] 命令预览与实际 Process arguments 等价；
- [ ] schema migration 有测试。

### Server

- [ ] Start/Stop/Restart；
- [ ] health state 准确；
- [ ] stdout/stderr 实时且有界；
- [ ] 显示 endpoint、PID、内存与 CPU；
- [ ] Open WebUI、Copy API URL；
- [ ] App 不误杀外部进程；
- [ ] 正常退出无 owned orphan。

### Release

- [ ] Swift tests 和 xcodebuild 通过；
- [ ] Developer ID 签名、公证；
- [ ] Apple Silicon 实机验证；
- [ ] App update 与 runtime update 清晰分离；
- [ ] 无明文 token；
- [ ] 第三方许可完整。

---

## 26. 开放问题

这些问题不阻塞 Milestone 1，但应在对应阶段前做 ADR：

1. App Sandbox 是否启用；
2. managed runtime 是否默认自动下载更新；
3. 是否允许多 server 并发，还是 v1.0 保持单实例；
4. 是否内置一个极小测试 GGUF，或完全由用户提供；
5. Range multi-part downloader 自研还是复用轻量依赖；
6. profile 中 sampling 参数应全部转为 server flags，还是部分交给 API 请求；
7. 是否在 v1.0 支持官方 `llama` unified binary，或同时维护独立 `llama-server` 路径；
8. runtime archive 没有官方 checksum 时采用何种信任提示；
9. App 名称最终使用 `Llamadock` 还是 `LlamaDock`，bundle ID 与 GitHub repo 命名需统一。

建议命名：产品显示名 **LlamaDock**，仓库/目录 `Llamadock`，Swift module `LlamadockCore`。

---

## 27. 第一阶段 Definition of Done

Milestone 1 只有满足以下所有条件才算完成：

- App 从绝对路径检测到真实 `llama-server`；
- UI 显示实际 `--version` 输出；
- 用户通过系统 OpenPanel 选择本地 GGUF；
- profile 保存到 JSON，重启后恢复；
- command preview 与 Process arguments 来自同一个 builder；
- Start 不经过 shell；
- stdout/stderr 在 UI 实时显示且不会无限增长；
- readiness 由真实 HTTP health adapter 判定；
- Stop 只终止 Llamadock 创建的子进程；
- 使用真实小模型完成一次 API 请求；
- focused tests、完整 Core tests、macOS Debug build 均通过；
- README 记录真实验证环境与已知限制，不宣称未测试能力。

完成该垂直切片后，Llamadock 已经具有日用价值；后续 runtime manager 和 HF download 可以在稳定进程边界上迭代，而无需推翻架构。

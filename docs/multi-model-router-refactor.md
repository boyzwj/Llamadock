# LlamaDock 多模型 Router 与界面重构方案

> 状态：第一阶段已实现，待 Release 验收
> 日期：2026-08-04
> 基线：llama.cpp `llama-server --models-preset` router mode

## 1. 重构目标

把“模型文件、模型启动参数、服务网络参数、服务生命周期”从同一个模型页面中拆开，
建立四个边界清晰的对象：

1. **Models**：浏览 GGUF 文件、查看 metadata，以及查看 router 返回的当前加载状态；
2. **Model Settings**：维护每个可路由模型的标识与 `llama-server` 启动参数；
3. **Global Settings**：维护 router、runtime 与所有模型共享的默认加载参数；
4. **Dashboard**：只负责服务状态、启动/停止、endpoint、资源和错误摘要；
5. **Benchmark**：选择一个 router model identifier，按上下文和并发组合测量吞吐量；
6. **About**：集中展示版本、项目入口、许可证、技术基础和当前运行环境。

## 2. 目标信息架构

```text
菜单栏
  Dashboard                 打开主控制台

主窗口
  Dashboard                 服务生命周期与运行摘要
  Logs                      router 与模型子进程日志
  Benchmark                 Prompt/Generation/Batch 吞吐量测试

  Models                    本地模型浏览、下载源、实际加载状态
  Downloads                 下载队列
  Runtime                   llama.cpp runtime

  Settings
    Global Settings         网络、router、runtime 与 [*] 模型默认参数
    Model Settings          每模型 preset 与可选覆盖参数

  About                     版本、项目、许可证与运行环境
```

Models 不再内嵌参数编辑器。它只允许跳转到 Model Settings，不在模型详情中修改
router 配置。

## 3. 配置与启动架构

每份旧 Launch Profile 升级为一份 Model Setting，并新增：

- `router.identifier`：API 请求的 `model` 标识，同时作为 INI section；
- `router.isEnabled`：是否写入生成配置；
- `router.loadOnStartup`：是否随 router 预加载；
- `router.stopTimeout`：卸载模型子进程的等待时间。

启动前从所有启用的 Model Settings 生成透明文件：

```ini
version = 1

[*]
ctx-size = 32768
cache-type-k = q8_0
cache-type-v = q8_0
n-gpu-layers = auto
fit = on
fit-target = 1024
fit-ctx = 4096
flash-attn = auto
parallel = -1
batch-size = 2048
ubatch-size = 512

[qwen-coder]
model = /absolute/path/qwen.gguf
n-gpu-layers = 99
load-on-startup = true

[embedding]
model = /absolute/path/embedding.gguf
embeddings = true
load-on-startup = false
```

文件位置：

```text
~/Library/Application Support/Llamadock/server/models.ini
```

真实启动命令：

```text
llama-server \
  --host 127.0.0.1 \
  --port 39281 \
  --models-preset ".../server/models.ini" \
  --models-max 4 \
  --models-autoload
```

网络参数和 router 参数只进入主进程命令。context、KV cache、GPU/KV offload、
内存适配、线程、并发、batch 和 Flash Attention 写入 `[*]` 全局 section；每个
model section 只写模型路径和显式覆盖项。llama.cpp 的优先级保证单模型设置覆盖
`[*]`，未设置的字段自动继承全局默认值。

## 4. 运行状态模型

Dashboard 的服务状态仍来自 owned `llama-server` 主进程和 `/health`。Models 页
的模型状态来自 router 的 `GET /models`，不根据本地选择推测：

- `loaded`
- `loading`
- `unloaded`
- `sleeping`
- `downloading`
- `failed`

轮询只在 router ready/degraded 时进行；停止后立即清空运行态，避免把旧状态显示为
当前状态。

## 5. 数据迁移与兼容

- Profile schema 已升级到 v5；
- v1/v2 首次读取时补充 router 字段并原子写回；
- 未知 JSON 字段继续通过 deep merge 保留；
- 旧 host/port 仍只做一次全局迁移，之后由 Global Settings 独立持久化；
- 旧 profile 默认启用，但默认不预加载，避免升级后一次性占满内存；
- v4 中的 32K/q8 默认值迁移为全局继承，自定义过的单模型值继续保留；
- runtime 不支持 `--models-preset` 时阻止启动并提示更换新版 runtime。

## 6. 分阶段交付

### Phase 1 — 信息架构与 router 基础（本轮）

- 菜单栏 Settings 改为 Dashboard；
- 主侧栏增加 Settings；
- 拆分 Global Settings / Model Settings；
- Models 变为浏览与状态页面；
- 生成 INI 并以 router mode 启动；
- 增加 `/models` 状态适配；
- 增加基于 `/v1/completions` 与响应 `timings` 的吞吐量 Benchmark；
- 增加与其他页面同层的 About 页面；
- 完成 schema v3 迁移和单元测试。

### Phase 2 — 运行中模型控制

- Models 页增加显式 Load / Unload；
- 接入 `POST /models/load` 与 `POST /models/unload`；
- 展示 loading progress 和失败 exit code；
- 防止对 loading/unloading 模型执行冲突操作。

### Phase 3 — 配置质量与能力检测

- Extra Arguments 改为结构化 key/value 编辑；
- 区分 router-only、model-only 和 request-level 参数；
- 为 embedding、rerank、vision、speculative decoding 提供 preset 模板；
- 导入、导出原生 `models.ini`；
- 展示配置 diff 与 restart-required 状态。

### Phase 4 — 多模型可观测性

- Dashboard 展示各模型 resident memory、请求数和状态；
- 日志按 router/model identifier 过滤；
- 记录最近 load/unload 和自动休眠事件；
- 对内存容量和 `models-max` 给出明确但非强制的建议。

## 7. 验收标准

- 模型页不再出现启动参数 Form；
- 两个以上启用设置生成两个独立 INI section；
- 启动命令不含单模型 `--model`；
- host/port 只由 Global Settings 控制；
- `/models` 的 loaded 状态能映射回本地 GGUF；
- 旧 v1/v2 Profile 可无损升级；
- runtime 缺少 router flags 时失败可见；
- Benchmark 默认使用 1K context、单请求，并可选择多个 context 和并发级别；
- Prompt TPS、Generation TPS 和 TPOT 直接读取 llama-server `timings`；
- Batch Output TPS 使用同批并发请求的总输出 token 与墙钟时间计算；
- About 能显示当前 app version/build、项目链接、MIT 许可证和 runtime；
- Debug、Core 全量测试、Release 构建、全新打包、`/Applications/Llamadock.app`
  重装、版本/build 元数据和签名检查全部通过。

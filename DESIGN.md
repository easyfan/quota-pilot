# quota-pilot 设计文档

quota-pilot 是**额度感知的任务调度插件**：在 Claude 订阅额度（5h/7d 窗口）耗尽**之前**，让会话主动评估剩余工作量、优雅存档、自设闹钟，额度重置后自动续跑——长任务从此不需要人守着限流时钟。

状态：设计阶段（2026-07-10），三条核心链路已实机验证，未开始实现。

---

## 1. 问题与现状

### 痛点
长任务（committee review、批量重构、媒体流水线）跑到一半撞上 5 小时限流窗口，Claude Code 硬停，人必须回来手动恢复。官方 `--auto-resume` 是社区高呼但未实现的需求（anthropics/claude-code #36320、#62788、#18980 等至少 6 个 issue 开放中）。

### 社区方案的共同缺陷
现有工具（claude-auto-retry、terryso/claude-auto-resume 等）全部是**被动式**：放任会话撞限报错，然后从外部（tmux send-keys）盲发 "continue"。三个问题：
1. 撞限瞬间往往是残缺的半个 turn（edit 已做、测试没跑），盲续后模型对"哪些已验证完成"认知错误
2. 依赖 tmux 往已死会话里敲键盘，通用性差
3. 无额度预判——不知道还能干多少活，只会撞死

### 为什么现在能做
两个新原语近期才可用：
- **statusline 官方下发 `rate_limits`**（文档化字段，Pro/Max 订阅）——额度数据首次有了零成本官方来源
- **后台任务完成自动唤醒会话**——会话可以自设闹钟自己醒

窗口刚打开，还没有人用新原语重新解这个问题。官方 marketplace（13 个插件）无任何额度类插件。

---

## 2. 核心设计原则

### 主动式：会话不死，恢复通道问题消解
被动式方案的一切复杂度都源于"会话已撞死，要从外面救活"。quota-pilot 反过来：**在额度耗尽前触发，会话全程存活**——评估、存档、进入 idle 等待（零 token 消耗）、被闹钟唤醒，全部在会话进程内完成。tmux/launchd/AppleScript 的存在前提被消除。

### 纯 CC 原生原语，零外部依赖
核心链路只用三个 Claude Code 原生机制：statusline（采数）、PostToolUse hook（注入决策）、后台 Bash + 自动唤醒（定时续跑）。标准 plugin 形态，marketplace 可分发。happy/远程可见是加分项而非依赖。

### 评估是 LLM 判断，不是脚本计算
"下一个不可分割工作单元能否在剩余额度内完成"无法脚本化——只有会话内的模型知道任务结构。插件的职责是**把额度事实和行为协议注入给模型**，判断由模型做。这是插件形态相对外部脚本的本质优势。

### checkpoint 是保险，不是省钱手段
等待数小时后 prompt cache（5min TTL）必然全冷，续原会话多付一次全量 cache write（约占新窗口 2-5%），差距不致命。写 checkpoint 的真实理由：
1. **保险**——进程死亡（关终端/重启/崩溃）时闹钟陪葬，checkpoint 是唯一恢复凭据
2. **状态标记**——"已完成且已验证 / 进行中 / 下一步"防止续跑后的状态误判
3. 若 context 已接近 auto-compact 阈值，趁完整 context 主动写档优于被动有损压缩

默认策略：**写 checkpoint + 原会话续跑**。两个决策解耦：写档是无条件保险，换新会话只在 resume 失败或 context 臃肿时发生。

---

## 3. 架构总览

```
┌─ 采样层 ──────────────┐   ┌─ 决策层 ─────────────┐   ┌─ 行为层（模型执行）──────┐
│ 主：oauth/usage 轮询  │   │ PostToolUse hook     │   │ skill 行为协议           │
│ （hook 内节流调用，   │ → │ 读 state.json        │ → │ 1. 评估最小单元          │
│  全环境可用，已验证） │   │ 阈值判断+节流        │   │ 2. 写 checkpoint         │
│ 辅：statusline wrapper│   │ 注入告警指令         │   │ 3. 后台墙钟循环闹钟      │
│ （仅 TUI，显示用）    │   └──────────────────────┘   │ 4. idle → 唤醒 → 续跑    │
└───────────────────────┘                              └──────────────────────────┘
```

> 2026-07-10 O1 验证后调整：statusline 在 happy/SDK 会话中不运行（V4），原"statusline 唯一采样源"方案会使主用户环境失效。改为 `oauth/usage` 端点轮询为主采样源（V6，全环境可用），statusline wrapper 降级为 TUI 环境的可视化增强。

数据新鲜度天然保证：statusline 在每次 API 响应后刷新，额度只在 API 调用时消耗——**采样频率与消耗速率天然同步**，不存在"额度在烧但数据陈旧"的窗口。

---

## 4. 组件明细

### 4.1 采样层

**主后端：oauth/usage 轮询（`scripts/sample_usage.sh`，由决策层 hook 节流调用）**

- 端点：`GET https://api.anthropic.com/api/oauth/usage`，header `Authorization: Bearer <accessToken>` + `anthropic-beta: oauth-2025-04-20`（V6 实测可用）
- 凭据来源：macOS Keychain `security find-generic-password -s "Claude Code-credentials" -w` → `.claudeAiOauth.accessToken`；Linux 为 `~/.claude/.credentials.json`。token 过期（401）→ 重读凭据库即可（CC 自身会刷新 token），仍失败则静默跳过本次采样
- 返回字段比 statusline 的 `rate_limits` 更全：`five_hour/seven_day.{utilization,resets_at}` + `limits[]`（含 severity、is_active、按模型 scoped 的 weekly 额度）
- 节流：写入 state.json 带时间戳，距上次采样 < 60s 直接复用缓存，不发请求；网络失败保留旧值（决策层的陈旧检查兜底）
- 同时向 `~/.claude/quota-pilot/history.jsonl` 追加采样（供 burn rate 估算，按大小轮转）
- 风险：端点未见于公开文档（statusline 的 rate_limits 才是文档化来源），字段可能变动——实现时 schema 校验失败即静默休眠，不误报
- 采样开销：一次 HTTPS GET（实测 <1s），60s 节流下对 hook 延迟影响可忽略

**辅后端：statusline wrapper（`scripts/statusline.sh`，仅 TUI 环境，可选）**

- 读 stdin JSON，抽取 `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`，同样写 state.json（与主后端 last-writer-wins，数据同源不冲突），价值在零网络成本+事件驱动+可视化
- **与用户已有 statusline 共存**：安装时若 settings 已有 `statusLine`，把原命令保存到插件配置，wrapper 完成采数后把同一份 stdin 透传给原命令并原样输出其结果；无原命令则输出自带显示 `5h 24% ⏳21:50 | 7d 8%`（色阶：<60% 绿 / 60-85% 黄 / >85% 红）
- 字段缺失（非订阅用户、首次响应前）：静默跳过采数，不影响显示透传
- happy/SDK 会话不驱动 statusline（V4），此后端在这些环境天然不工作——主后端不受影响

### 4.2 决策层：PostToolUse hook（`hooks/quota_gate.sh`）

- matcher `*`；入口先调用 `sample_usage.sh`（60s 节流，命中缓存时开销 ms 级，发请求时 <1s）刷新 state.json，再做阈值判断
- 退出条件（全部静默 exit 0）：state.json 不存在 / 陈旧超过 10min（采样连续失败时触发）/ utilization 低于阈值 / 冷却期内已注入过
- 触发逻辑（边沿触发 + 冷却）：
  | 档位 | 默认阈值 | 注入内容 |
  |------|---------|---------|
  | warn | 5h ≥ 88% | 额度事实 + 行为协议：评估下一个不可分割单元，能完成则继续，不能则执行存档流程 |
  | critical | 5h ≥ 95% | 立即存档：跳过评估，直接写 checkpoint + 定闹钟 |
- 注入机制：`{"decision":"block","reason":"..."}`（已验证模型收到并遵从）；`reason` 内含当前百分比、resets_at 本地时间、协议指令
- 防重复：注入后在 state.json 记录 `last_injected_{level,ts}`，同档位冷却期（默认 10min）内不再注入

### 4.3 行为层：skill（`skills/quota-pilot/SKILL.md`）

hook 注入的指令引用本 skill，模型按协议执行：

**评估协议**：剩余额度 = 100 − used_percentage − reserve（默认 3%，checkpoint 预算）。对照下一个不可分割单元的预计消耗（启发式基准：一个 tool 密集的 turn ≈ 1-2%，一次 subagent 委员会 ≈ 5-15%，实现期校准后写入 skill）。能完成 → 继续干；不能 → 存档流程。

**checkpoint 格式**（写入 `<project>/.claude/quota-checkpoint.md`）：
```markdown
# Quota Checkpoint — {ISO 时间}
## 任务目标        ← 原始要求，一段话
## 已完成且已验证   ← 只列真正验证过的
## 进行中/未验证    ← 半成品状态如实记录（哪些 edit 已做、哪些测试没跑）
## 下一步          ← 醒来后第一件事，具体到命令/文件
## 关键上下文      ← 文件路径、决策记录、踩过的坑
## 恢复方式        ← 默认原会话自动续跑；若进程已死，新会话读本文件恢复
```

**闹钟协议**（后台 Bash，`run_in_background`）：
```bash
TARGET=$((RESETS_AT + 120))   # +2min 缓冲
while [ "$(date +%s)" -lt "$TARGET" ]; do
  [ -f ~/.claude/quota-pilot/cancel ] && exit 0   # 手动提前恢复
  sleep 60
done
echo "QUOTA-RESET-WAKE"
```
**必须用墙钟循环，禁用一发长 sleep**：macOS monotonic clock 在系统睡眠期间不走表，长 sleep 在合盖场景晚醒数小时；循环版机器唤醒后 ≤60s 发现 deadline 已过。启动闹钟后结束 turn 进入 idle（零消耗）。

**唤醒协议**：核对 checkpoint 的"进行中/未验证"段 → 先验证半成品状态 → 按"下一步"继续。

### 4.4 查询入口：`/quota` command

读 state.json + history.jsonl，输出当前 5h/7d 百分比、重置倒计时、近 1h burn rate、按当前速度的耗尽预测。无数据时提示原因（未配 statusline / 会话尚无 API 响应 / 非订阅账户）。

### 4.5 可选兜底：盲重试 watcher（默认不装）

估算失误真撞限时，会话报错停在 prompt，模型无法自救。可选组件提供 claude-auto-retry 式外部兜底（需 tmux，安装文档明示前置条件）。阈值调保守可把撞限概率压到很低，故默认不装。

---

## 5. 边界策略

| 场景 | 策略 |
|------|------|
| 7d 窗口耗尽（5h 重置救不了） | 不傻等数天：等待时长超过 `max_wait_hours`（默认 6h）→ 写 checkpoint + 系统通知（osascript）+ 结束，交人工 |
| 多会话并发 | rate_limits 是账户级；多个会话同时挂闹钟会同时唤醒争抢新窗口 → 闹钟加 0-5min 随机抖动；文档建议同时挂机的长任务 ≤2 个 |
| 非订阅（API key）用户 | 无 claudeAiOauth 凭据（主后端）也无 rate_limits 字段（辅后端），采样层写不出数据，hook 静默 no-op，插件等效休眠 |
| headless / SDK / happy 环境 | statusline 不运行（V4），但主后端 oauth/usage 轮询 + PostToolUse hook 均正常工作（V2/V6），插件全功能生效 |
| 用户 mid-task 手动改 statusline | 仅影响辅后端显示；主后端采样不受影响 |
| 进程死亡 | 闹钟陪葬，checkpoint 存活；新会话读 checkpoint 人工/脚本恢复 |

## 6. 配置（`~/.claude/quota-pilot/config.json`）

| 键 | 默认 | 说明 |
|----|------|------|
| `warn_threshold` | 88 | 评估档阈值（5h %） |
| `critical_threshold` | 95 | 立即存档档阈值 |
| `reserve` | 3 | checkpoint 预算（%） |
| `cooldown_minutes` | 10 | 同档位注入冷却 |
| `max_wait_hours` | 6 | 超过则通知人工而非傻等 |
| `wake_jitter_minutes` | 5 | 唤醒随机抖动上限 |
| `seven_day_warn` | 90 | 7d 窗口告警阈值（仅通知，不触发存档流程） |

## 7. 已验证事实（2026-07-10，本机 CC 2.1.204，macOS）

| # | 链路 | 方法 | 结果 |
|---|------|------|------|
| V1 | 后台任务自唤醒 | `sleep 90` run_in_background，结束 turn | 退出后 **9 秒**会话自动唤醒 ✅ |
| V2 | hook 注入 | PostToolUse `{"decision":"block","reason":...}`，headless haiku 会话 | 模型收到告警、复述标记、自发进入"评估-存档-停手"行为模式 ✅ |
| V3 | statusline rate_limits | pty 驱动真实 TUI 会话，statusline 配置为 dump stdin | 首次 API 响应后捕获 `five_hour: 24%/resets_at, seven_day: 8%/resets_at`，与官方文档一致 ✅ |
| V4 | happy/SDK 不驱动 statusline | happy 会话内配置 dump statusline，60s 内多次工具事件后 dump 文件未创建；进程树证实 claude 以 `--input-format/--output-format stream-json`（SDK headless）拉起，无 TUI 渲染方 | statusline 在 happy/SDK 会话不运行 ❌（O1 答案，2026-07-10 实测） |
| V5 | transcript JSONL 无主动额度数据 | 遍历当前会话 transcript 全部 JSON 键 | 仅 `.error.rateLimits`（api_error 事件，实测均为 null，属被动信号）与 `.message.usage`（token 计数，非额度），不可作主动采样源 ❌ |
| V6 | oauth/usage 端点 | Keychain 取 accessToken，curl `api.anthropic.com/api/oauth/usage`（happy/SDK 会话内） | 返回 `five_hour: 50%/resets_at, seven_day: 11%/resets_at` + scoped limits 数组，数据比 statusline 更全 ✅ |

验证原型：`prototypes/hook-inject/`（hook 注入）、`prototypes/statusline-capture/`（pty 驱动脚本 drive.py 可复用为集成测试；dump.jsonl 为 V3 实测捕获数据）、`prototypes/oauth-usage/`（V6 采样脚本 sample_usage.sh 可直接演化为正式 `scripts/sample_usage.sh`；response-sample.json 为实测返回快照）。注意前两个原型内部路径仍写死 `/tmp/*-exp`，复跑时需先拷回 /tmp 或改路径。

## 8. Open Questions

- ~~**O1**：happy/SDK 会话是否驱动 statusline 脚本？~~ **已解决（2026-07-10，V4/V5/V6）**：不驱动。transcript JSONL 无可用额度数据；oauth/usage 端点实测可用且数据更全 → 采样层改为 oauth/usage 轮询为主、statusline 为 TUI 辅（见 §3/§4.1）。遗留注意点：端点未文档化，实现时加 schema 校验 fail-safe
- **O2**：`decision:block` 在 PostToolUse 的语义副作用（tool_result 被标记 blocked 是否干扰特定流程）；备选注入通道 `additionalContext`/exit 2 stderr，实现期 A/B 验证
- **O3**：后台任务时长上限——文档称 detached 跨 turn 存活，需源码/文档核实无硬上限（即便有，60s 循环的单次阻塞也不受影响，但整个后台任务的生命周期需要确认）
- **O4**：checkpoint 与 CC 原生 auto-compact 的交互——若等待期间恰好触发 compact，唤醒后 checkpoint 是否仍在 context 中被正确引用（checkpoint 在磁盘上，重读即可，预期无碍，需实测）
- **O5**：critical 档注入时机——PostToolUse 意味着至少要等当前 tool 完成，若单个 tool（如长 Bash）执行期间烧穿额度则来不及；是否需要 PreToolUse 配对拦截，实现期评估

## 9. 与 packer 体系的关系

- 目录：`packer/quota-pilot/`，标准 plugin 结构（plugin.json + hooks + skills + commands + scripts + install.sh）
- 双安装路径：install.sh（Plan A）+ marketplace（Plan B），过 looper 验证
- README 各语言版 + install.sh 与功能同步（packer 同步规则）
- 发布节奏：MVP = 采样层 + hook + skill + /quota（够用）；v2 见下节

## 10. v2 集成路线（2026-07-12 规划；①-④ 已于 v0.2.0 实现，⑤⑥ 待做）

按优先级排序：

1. ✅ **subagent 行为分支**（修复已知缺陷）：hook 对 subagent 同样生效，但 subagent 按协议挂闹钟会产生孤儿进程（行为评测中实证）。SKILL.md 增加 "if you are a subagent" 分支：不挂闹钟、快速收尾、返回摘要，把存档决策交还主会话。
2. ✅ **`quota_report.sh --json`**（集成基石）：机器可读输出（utilization / resets_at_epoch / 建议 defer 秒数），使任何 loop prompt、workflow skill、agent 能一行调用做额度决策。hook 注入降级为兜底防线，主动查询成为常规集成方式。
3. ✅ **/loop 额度感知调度**（README §Integrations 落地）：loop 迭代开头读 state.json，额度紧张时把下次唤醒对齐 resets_at 之后（不存档不挂闹钟，间歇天然绕开枯竭期）。注意分工：短间歇用 loop 自身 wakeup（≤3600s 上限），长枯竭期切换 quota_alarm.sh（无上限）。示例写进 README。
4. ✅ **长工作流阶段边界额度门**（patterns/quota-phase-gate.md 分发；本机 committee-review 已示范接入 anchor）：多阶段 pipeline 在 Phase 边界查额度，不够则在边界存档（此时"进行中/未验证"天然为空，唤醒后直接进下一 Phase）。落地复用 patterns 的 patch-anchor 机制，`/patterns --patch` 批量补进已实例化工作流。
5. **spawn 前预检**：主会话启动昂贵操作（committee 一轮 5-15%）前主动查 state.json，事前预检替代事后告警。
6. 既有 v2 项：盲重试 watcher、7d 策略细化、burn rate 预测精化、O5 的 PreToolUse 配对拦截。

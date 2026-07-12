---
name: quota-phase-gate
description: >
  额度门模式。多阶段工作流在 Phase/Stage 边界检查订阅额度
  （quota-pilot 的 quota_report.sh --json），额度不足时在边界干净存档、
  设闹钟等待重置，而不是冲进下一阶段中途撞限。
patch-anchor: "## 额度门：阶段边界检查 quota"
---

# 额度门模式（quota-phase-gate）

依赖：[quota-pilot](https://github.com/easyfan/quota-pilot) 插件（未安装时本门静默跳过，不阻塞工作流）。

## 适用场景

多阶段、多 subagent 的长工作流（committee review、媒体流水线、批量重构）。
这类工作流有 quota-pilot 通用协议没有的东西：**干净的阶段边界**——
在边界存档时"进行中/未验证"天然为空，唤醒后直接进下一 Phase，
连验证半成品这一步都省了。比撞到 88% 才被动告警优雅。

## 机制

- quota-pilot 的采样层持续把额度写入 `~/.claude/quota-pilot/state.json`
- `quota_report.sh --json` 输出机器可读的 `suggested_defer_seconds`：
  低于 warn 阈值时为 0；高于阈值时为距 5h 窗口重置的秒数（+120s 缓冲）
- 协调者在阶段边界读这个值决定：继续 / 边界存档等待

## 额度门：阶段边界检查 quota

> 本节是 `/patterns --patch` 的回填锚点（patch-anchor）。实例化出的协调者命令若缺此步骤，`--patch` 会将本节内容追加到命令末尾。本节须自包含，可独立追加。

在每个 Phase/Stage 边界、以及 spawn 多 subagent 的昂贵操作（一轮委员会约消耗 5h 窗口的 5-15%）之前，协调者运行：

```bash
QR=""
for c in "$HOME/.claude/quota-pilot/bin/quota_report.sh" "${CLAUDE_PLUGIN_ROOT:-}/scripts/quota_report.sh"; do
  [ -n "$c" ] && [ -f "$c" ] && QR="$c" && break
done
[ -n "$QR" ] && bash "$QR" --json || echo '{"error":"quota-pilot-not-installed"}'
```

按输出决策：

- 含 `error`（未安装 / 无数据）→ 跳过本门继续执行，不阻塞
- `suggested_defer_seconds == 0` → 额度充足，进入下一阶段
- `suggested_defer_seconds > 0` → **不进入下一阶段**：
  1. 在阶段边界写 checkpoint 到 `<project>/.claude/quota-checkpoint.md`（quota-pilot skill 的格式；此时无半成品，"进行中/未验证"留空，"下一步"写"从 Phase N+1 继续"及产物路径）
  2. 用输出中 `five_hour.resets_at_epoch` 启动闹钟（`run_in_background: true`）：`~/.claude/quota-pilot/bin/quota_alarm.sh <resets_at_epoch>`
  3. 向用户一段话说明：完成到哪个阶段、checkpoint 位置、预计恢复时间、提前唤醒方式（`touch ~/.claude/quota-pilot/cancel`），然后结束 turn
  4. 唤醒（`QUOTA-RESET-WAKE`）后从 checkpoint 的"下一步"直接继续

## 给已有 pattern 复用本锚点

任何多阶段 pattern 都可以声明本门：把上面"额度门"整节拷贝到该 pattern 末尾，并在其 frontmatter 加 `patch-anchor: "## 额度门：阶段边界检查 quota"`（前提是该 pattern 尚未声明其他 patch-anchor——每个 pattern 只有一个锚点字段）。之后 `/patterns --patch` 即可把额度门批量补进该 pattern 的全部已实例化命令。

## 与 quota-pilot 组件的关系

- **PostToolUse hook（被动防线）**：撞到 88% 才告警，任意时刻可能触发，存档时可能有半成品。本门是**主动防线**：在最干净的时点检查，两者叠加使用。
- **subagent**：本门只由协调者（主会话）执行；subagent 收到 hook 告警时按 quota-pilot skill 的 subagent 分支快速收尾返回，不自行挂闹钟。

## 实例化约定

通过 `/patterns quota-phase-gate` 实例化时，生成的 command 文件须在 YAML front-matter 中包含 `generated-from: quota-phase-gate@<version>`。

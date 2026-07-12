# quota-pilot

**Claude Code 额度感知任务调度插件。** 长任务不再撞死在 5 小时限流墙上：额度耗尽之前，会话主动评估剩余工作量、写下 checkpoint、给自己定好墙钟闹钟、以零 token 成本挂起等待，重置后自动续跑。

[English](README.md) | [Deutsch](README-de.md) | [Français](README-fr.md) | [Русский](README-ru.md)

## 为什么是主动式？

现有工具（claude-auto-retry 等）全部是**被动式**：放任会话撞限死掉，再从 tmux 往里盲敲 "continue"。三个硬伤——撞限瞬间往往是半个 turn（edit 已做、测试没跑），盲续后模型对"哪些真正完成"认知错误；依赖 tmux 向已死会话注入按键，通用性差；对剩余额度零预判，只会撞死。

quota-pilot 反过来：**会话全程不死**。在耗尽*之前*收到告警，自行判断下一个不可分割工作单元是否还放得下，如实存档（包括哪些是半成品未验证），然后自己叫醒自己。不需要 tmux、launchd、外部保姆——只用 Claude Code 原生原语。

## 工作原理

```
┌─ 采样层 ──────────────┐   ┌─ 决策层 ─────────────┐   ┌─ 行为层（模型执行）──────┐
│ 主：oauth/usage 轮询  │   │ PostToolUse hook     │   │ quota-pilot skill        │
│ （hook 内节流调用，   │ → │ 读 state.json        │ → │ 1. 评估下一个单元        │
│  全部会话类型可用）   │   │ 阈值判断 + 冷却      │   │ 2. 写 checkpoint         │
│ 辅：statusline wrapper│   │ 注入告警             │   │ 3. 墙钟闹钟              │
│ （仅 TUI 显示）       │   └──────────────────────┘   │ 4. 挂起 → 唤醒 → 续跑    │
└───────────────────────┘                              └──────────────────────────┘
```

- **warn**（默认 88%）：模型评估下一个不可分割单元能否在剩余额度内完成（预留 3% checkpoint 预算）。能则继续干；不能则存档挂起。
- **critical**（默认 95%）：跳过评估，立即存档。
- checkpoint（`<项目>/.claude/quota-checkpoint.md`）把"已完成且已验证"与"进行中未验证"分开记录——正是这个区分消灭了盲续 bug。
- 闹钟是墙钟循环而非一发长 `sleep`：macOS 单调时钟在系统睡眠期间不走表，合盖场景下 `sleep 4h` 会晚醒数小时；循环版在机器唤醒后 60 秒内发现 deadline 已过。

## 安装

**方式 A —— 安装脚本：**

```bash
git clone https://github.com/easyfan/quota-pilot.git
cd quota-pilot
./install.sh                # hook + skill + /quota 命令
./install.sh --statusline   # 另装 TUI 额度显示
```

`--statusline` 保留已有 statusLine：原命令继续透过 wrapper 渲染，额度数据在旁路捕获。

**方式 B —— 插件市场：**

```
/plugin marketplace add easyfan/quota-pilot
/plugin install quota-pilot@quota-pilot
```

卸载：`./install.sh --uninstall`（恢复原 statusline 与 settings；保留 `~/.claude/quota-pilot/` 状态数据，不需要可手动删除）。

## 使用

无需任何操作——hook 在每次工具调用时看守额度（节流后最多每 60 秒一次 HTTPS 请求）。告警触发时你会看到模型自行评估、存档、挂起。

- `/quota` —— 当前 5h/7d 用量、重置倒计时、burn rate、耗尽预测
- `touch ~/.claude/quota-pilot/cancel` —— 提前唤醒挂起的会话
- checkpoint 位于 `<项目>/.claude/quota-checkpoint.md`；挂起期间进程若死亡，新会话可从该文件恢复

## 配置（`~/.claude/quota-pilot/config.json`）

| 键 | 默认 | 说明 |
|----|------|------|
| `warn_threshold` | 88 | 评估档告警阈值（5h 窗口 %） |
| `critical_threshold` | 95 | 立即存档阈值 |
| `reserve` | 3 | checkpoint 预算（%） |
| `cooldown_minutes` | 10 | 同档位重复告警冷却 |
| `max_wait_hours` | 6 | 超过则通知人工而非傻等 |
| `wake_jitter_minutes` | 5 | 唤醒随机抖动（多会话防踩踏） |
| `seven_day_warn` | 90 | 7d 窗口通知阈值（仅通知） |

## 边界

- **仅订阅账户（Pro/Max）。** API key 账户没有额度窗口；插件自动检测并休眠——零开销零噪音。
- 主采样器使用未公开文档化的 `oauth/usage` 端点；每个响应都过 schema 校验，不匹配即静默降级，绝不误报。
- 额度是账户级的：同时挂起的长任务建议 ≤2 个（唤醒抖动防踩踏，但窗口仍是共享的）。
- 7 天窗口耗尽时 5h 重置救不了；等待超过 `max_wait_hours` 会通知你并停止，不会傻等数天。

## 开发

```bash
tests/run_tests.sh    # 25 个单元测试：采样、决策、statusline、闹钟、安装往返
```

MIT 许可证。

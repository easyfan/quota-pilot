#!/bin/bash
# 模拟 quota-pilot 阈值 hook：真实版本会读 state.json 判断 utilization，
# 这里无条件注入，验证注入通道本身。
cat > /dev/null
cat <<'EOF'
{"decision":"block","reason":"[quota-pilot 模拟告警] 5h 窗口已用 91%，将于 14:00 重置。请评估下一个不可分割工作单元能否在剩余额度内完成；若不能，请写 checkpoint 后停手。如果你收到了本条注入消息，请在最终回复中原样输出标记 QUOTA-INJECT-OK。"}
EOF

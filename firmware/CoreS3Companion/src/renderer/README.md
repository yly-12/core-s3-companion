# Renderer

`DisplayRenderer` 使用 M5Unified 位图字体绘制标题、单一 Agent 状态主词、
5H/Weekly/Context 指标、额度重置倒计时、连接状态与本机电量。充电时电量文字变为绿色；
AUTH/REPLY 状态以 500ms 周期闪烁。Codex 没有 5H 额度窗口时隐藏该指标，Weekly 与 CTX
自动使用双栏布局。5H 和不足 24 小时的 Weekly 使用 `xHym`，更长的 Weekly 使用
`xDyH`，各数字不补前导 0。屏幕采用
320 × 240 横屏布局，底栏显示当前 session 的模型名称和 effort，其余状态仅在显示签名
发生变化时刷新。自动熄屏时调用面板 sleep，收到新活动或触摸后 wakeup 并完整重绘。

# Renderer

`DisplayRenderer` 使用 M5Unified 位图字体绘制标题、Agent 状态、5H/Weekly/Context 指标、
连接状态与本机电量。标题使用 M5GFX 内置中文位图字体；AUTH/REPLY 状态以 500ms 周期
闪烁。Codex 没有 5H 额度窗口时隐藏该指标，Weekly 与 CTX 自动使用双栏布局。屏幕采用
320 × 240 横屏布局，底栏显示当前 session 的模型名称和 effort，其余状态仅在显示签名
发生变化时刷新。自动熄屏时调用面板 sleep，收到新活动或触摸后 wakeup 并完整重绘。

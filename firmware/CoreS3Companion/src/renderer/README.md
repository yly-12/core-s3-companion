# Renderer

`DisplayRenderer` 使用 M5Unified 位图字体绘制标题、单一 Agent 状态主词、
5H/Weekly/Context 指标、额度重置倒计时、连接状态与本机电量。充电时电量文字变为绿色；
AUTH/REPLY 使用强调色，状态文字每 500 ms 闪烁。Codex 没有 5H 额度窗口时隐藏该指标，Weekly 与 CTX
自动使用双栏布局。5H 和不足 24 小时的 Weekly 使用 `xHym`，更长的 Weekly 使用
`xDyH`，各数字不补前导 0。屏幕采用
320 × 240 横屏布局，底栏显示当前 session 的模型名称和 effort。页面分为页眉、标题、状态、
指标和页脚五个独立脏区，只有实际显示内容变化的区域会清空并重绘；重复 BLE heartbeat 不触发
显示写入。自动熄屏时调用面板 sleep，收到新活动或触摸后 wakeup 并重绘五个区域。

状态词占状态行左侧，对应的 Pink-haired Madeline 动画占用右侧 `48 × 48` 区域（`x = 256`），
右边缘与页面内容边界 `x = 304` 对齐。PNG 帧由 `StatusAnimationAssets.cpp` 编译进 flash；
渲染器以非阻塞方式推进帧，只在帧变化时清空并重绘动画区域。各状态帧间隔记录在
`assets/animations/pink-madeline/README.md`。

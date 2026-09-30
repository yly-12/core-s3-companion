# CoreS3 Claude 状态屏设计稿

本目录包含可直接在浏览器、Figma、Sketch 或矢量编辑器中打开的 SVG 设计稿。
每一张设备画面均为 CoreS3 屏幕原生尺寸 `320 × 240`，不需要缩放后再交付固件。

主要目标是在 2 英寸屏幕上快速确认 Claude 当前是否需要用户介入，同时显示会话与资源信息。

## 设计方向

| 文件 | 方向 | 用途 |
|---|---|---|
| `01-minimal-status.svg` | Minimal Status | 推荐首版，状态占据视觉中心，信息位置固定 |
| `02-telemetry-status.svg` | Telemetry Status | 用卡片和进度条提高资源信息密度 |
| `03-pixel-terminal-status.svg` | Pixel Terminal Status | 更强烈的复古终端与开发工具感 |
| `10-dual-profile-personal.svg` | Dual Profile Focus | Personal 与 Work 同时活跃时的 Personal 轮换帧 |
| `11-dual-profile-work.svg` | Dual Profile Focus | Personal 与 Work 同时活跃时的 Work 轮换帧 |
| `12-pixel-accurate-personal.svg` | Pixel-accurate | 使用固件实际点阵字体生成的 Personal 落地稿 |
| `13-pixel-accurate-work.svg` | Pixel-accurate | 使用固件实际点阵字体生成的 Work 落地稿 |

## Codex 双账号主界面

Codex 使用 `Personal` 与 `Work` 两个独立 `CODEX_HOME` 时，仍只展示主界面，不增加总览页或触摸事件。两个账号同时活跃时沿用现有会话轮换逻辑：顶栏账号标签、标题、状态、额度、Context、模型与 effort 必须作为一个完整快照一起切换。

- `PERSONAL` 使用蓝色描边标签 `#58A6FF`。
- `WORK` 使用紫色描边标签 `#C084FC`。
- 不显示 `ACTIVE x/y` 计数，账号标签固定在顶栏水平中心，并随轮换帧切换。
- 账号颜色只标识来源，状态颜色继续表达运行、授权、回复、完成或错误。
- Usage 不跨账号合并，每帧只显示当前账号对应的数据。
- `AUTH` / `REPLY` 时左侧状态条与状态文字同步闪烁，保持原有强提醒效果。

## 状态稿

Minimal Status 同时提供完整状态：

- `04-state-idle.svg`：`IDLE`，空闲，可以接受新任务
- `01-minimal-status.svg`：`RUNNING`，正在运行
- `05-state-authorization.svg`：`AUTH`，等待工具授权
- `06-state-reply.svg`：`REPLY`，等待用户回复
- `07-state-complete.svg`：`DONE`，任务已经完成
- `08-state-cancelled.svg`：`CANCEL`，用户取消实施计划
- `09-state-error.svg`：`ERROR`，Claude API 请求失败

状态使用固定颜色，避免只依赖文案：

- `IDLE`：灰色 `#7C8782`
- `RUNNING`：绿色 `#46F59A`
- `AUTH`：黄色 `#FFC857`
- `REPLY`：蓝色 `#58A6FF`
- `DONE`：浅绿色 `#A7F3D0`
- `CANCEL`：橙色 `#FB923C`
- `ERROR`：红色 `#FF5C5C`

## 信息缩写

| 屏幕文案 | 含义 | 表达方式 |
|---|---|---|
| `5H` | 五小时额度 | 显示剩余百分比 |
| `WK` | Weekly 额度 | 显示剩余百分比 |
| `CTX` | 当前对话 Context | 显示已占用百分比 |
| `BAT` / `B` | CoreS3 电池 | 显示剩余百分比；充电时整组文字变为绿色 |
| `2H14m` / `3D8H` | Usage 重置倒计时 | 5H 使用 `xHym`；Weekly 大于等于 24 小时使用 `xDyH`；数字不补前导 0 |
| `SESSION` | Context 的作用域 | 表示 Context 随当前会话变化，没有定时重置 |
| `EFF` | 当前 reasoning effort | 例如 `EFF XHIGH` |

会话标题保持单行，客户端会按屏幕宽度截断。固件使用 M5GFX 的 `efontCN_16_b` 中文
位图字体，因此可以直接显示 UTF-8 中英文标题。底栏左侧显示当前 session 模型名称，
右侧显示 effort；字段不可用时显示 `MODEL -- / EFF --`。

状态区只保留 `IDLE / RUNNING / AUTH / REPLY / DONE / CANCEL / ERROR` 一个主词，不再重复显示 `READY`、
`WORKING` 等同义说明。Usage 区每列依次显示百分比、进度条和重置倒计时，倒计时不显示
额外前缀。5H 使用 `2H14m` 格式；Weekly 在剩余时间大于等于 24 小时
时使用 `3D8H` 格式，小于 24 小时时同样切换为 `xHym`。各数字不补前导 0。Context 第二行显示 `SESSION`。

状态动画与状态词位于同一行，使用对应状态的 `48 × 48` Pink-haired Madeline 四帧动画。
动画右边缘与页面内容右边缘对齐（`x = 256…304`），状态词保持左对齐；两者之间保留弹性空白，
最长状态 `CANCEL` 也不会与动画重叠。SVG 状态稿嵌入各动画第 1 帧作为静态设计预览，设备端按状态帧率循环播放。

电池状态位于顶栏右侧。外接电源并处于充电状态时，`BAT 83%`（Pixel Terminal 中
缩写为 `B83`）整组使用运行绿 `#46F59A`；使用电池供电时显示为主文字白
`#F2F5F3`。无障碍描述仍会明确标注是否正在充电。

## 字体与颜色

`01`–`11` 是概念稿，SVG 中的文字优先使用 `Silkscreen`，不存在时回退到 `Monaco` 或系统等宽字体。浏览器字体的实际字宽会随环境变化，不能用于验证固件的像素边界。

`12`、`13` 是落地用的逐像素稿，所有文字都已转换成 SVG 矩形像素，不调用浏览器字体：

- 普通文字使用 M5GFX 内置 `Font0`（经典 5×7 字形、6×8 字符格）。固件 `setTextSize(1 / 2 / 5)` 后，每个 ASCII 字符的固定字符格分别为 `6×8 / 12×16 / 30×40` 像素。
- 标题使用与固件相同的 `fonts::efontCN_16_b`，按 M5GFX 的 U8g2 位图数据解码。
- 顶栏账号框以屏幕中心 `x = 160` 对齐，并与左右两侧的 `CODEX`、最长电量文案 `BAT 100%` 保持充足留白。
- 可运行 `swift design/core-s3/build_pixel_accurate_previews.swift`，从当前 PlatformIO 安装的 M5GFX 字体数据重新生成两张逐像素稿。

核心颜色：

- 屏幕背景：`#000000`
- 主文字：`#F2F5F3`
- 次要文字：`#7C8782`
- 运行：`#46F59A`
- 空闲：`#7C8782`
- 等待授权：`#FFC857`
- 等待回复：`#58A6FF`
- 完成：`#A7F3D0`
- 取消：`#FB923C`
- 错误：`#FF5C5C`
- 网格：`#173128`

## 触摸边界

CoreS3 支持触摸，但 V1 只展示信息，因此设计稿中没有按钮、点击提示或手势入口。
后续若加入轻触切换页面、长按配对等动作，交互目标建议至少 `44 × 44`，并优先使用屏幕底部或四角区域，避免遮挡中央状态。

## 固件落地建议

首版建议采用 `01-minimal-status.svg` 的信息层级，并按风险从低到高逐步实现：

1. 扩展 Mac 到 CoreS3 的协议，传递状态、标题、模型、effort、额度、Context 和电池信息。
2. 固件按固定区域局部重绘；只有字段变化时更新对应区域。
3. 状态字段使用枚举，不要让固件解析任意状态字符串。
4. Telemetry Status 和 Pixel Terminal 更适合作为后续可切换页面，不建议同时塞入首版。

## 预览

直接打开 [`index.html`](./index.html) 可以并排查看全部方案。SVG 也可直接拖入 Figma，导入后仍可编辑各个图层。

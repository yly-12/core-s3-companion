# CoreS3 Companion

CoreS3 Companion 将 Claude Code 或 Codex 的当前运行状态通过 Bluetooth Low Energy
(BLE) 发送到 M5Stack CoreS3。设备显示会话标题、运行状态、五小时与 Weekly
剩余额度、Context 占用和自身电池电量。

## 数据流

```text
Claude hooks / status line ─┐
                            ├─→ 菜单栏 macOS 客户端
Codex hooks / rollout JSONL ┘
        ↓ BLE write with response
CoreS3 BLE 外设
        ↓ 协议校验 / 最新状态队列
M5Unified 屏幕 + 本机电池信息
```

## 目录

- `firmware/CoreS3Companion`：PlatformIO + Arduino 固件。
- `macos/CoreS3Companion`：SwiftUI macOS 客户端和 Xcode 工程。
- `design/core-s3`：CoreS3 `320 × 240` 横屏 SVG 设计稿和本地预览页。

## 界面设计稿

仓库内提供 Minimal Status、Telemetry Status 和 Pixel Terminal 三套 Claude 状态屏方向，
并覆盖空闲、运行中、等待授权、等待用户回复和已完成状态。直接用浏览器打开
`design/core-s3/index.html` 即可并排预览，单张 SVG 也可以拖入 Figma 继续编辑。

V1 设计中不包含触摸控件，但保留了后续使用至少 `44 × 44` 触控目标的扩展约束。

## 1. 编译并烧录固件

### 准备

1. 安装 [Visual Studio Code](https://code.visualstudio.com/)。
2. 在 VS Code 扩展商店安装 `PlatformIO IDE`。
3. 使用 USB-C 数据线连接 CoreS3。
4. 在 VS Code 中打开 `firmware/CoreS3Companion` 文件夹。

依赖和板卡配置已经固定在 `platformio.ini`，首次构建时 PlatformIO 会自动下载：

- Espressif32 `6.13.0`
- M5Stack CoreS3 (`m5stack-cores3`)
- M5Unified `0.2.19`

### 构建与烧录

在 VS Code 底部的 PlatformIO 工具栏依次点击：

1. **Build**：编译固件。
2. **Upload**：烧录到 CoreS3。
3. **Serial Monitor**：查看 BLE 连接和协议日志，波特率为 `115200`。

也可以使用 PlatformIO Core：

```bash
cd firmware/CoreS3Companion
pio run
pio run --target upload
pio device monitor
pio test -e native
```

固件启动后显示 `IDLE / OFFLINE`，设备以 `CoreS3 Companion` 名称开始广播。

## 2. 运行 macOS 客户端

### 准备

1. 从 App Store 安装完整 Xcode（仅 Command Line Tools 不足以构建 SwiftUI App）。
2. 打开 `macos/CoreS3Companion/CoreS3Companion.xcodeproj`。
3. 选择 `CoreS3Companion` scheme 和 `My Mac`。
4. 如果 Xcode 要求签名，在 Signing & Capabilities 中选择自己的 Personal Team。

点击 Run。应用不会显示 Dock 图标，而是在 macOS 菜单栏常驻一个状态图标；点击图标
直接打开配置窗口。首次启动时允许客户端访问蓝牙。

### 配对

1. 保持 CoreS3 开机并停留在 `IDLE / OFFLINE` 页面。
2. 客户端会自动搜索带有 Companion Service UUID 的设备。
3. 在列表中找到 `CoreS3 Companion`，点击“配对”。
4. 服务和写特征确认成功后，客户端才会保存设备 UUID，并进入状态预览页。

下次启动客户端会自动连接已配对设备。点击“取消配对”可以清除本地 UUID，
返回搜索页选择另一台设备。这里的配对是应用内绑定，不使用 PIN 或 BLE bonding。

### 配置 Claude / Codex

在“Claude / Codex”页签选择自动、Claude Code 或 Codex 数据源，然后分别点击“配置”：

- Claude：向 `~/.claude/settings.json` 合并最小 hooks，并安装每秒刷新的 status line 包装器采集
  5H、Weekly 和当前会话 Context；已有 hooks 与 status line 会保留并在移除时恢复。
- Codex：向 `~/.codex/hooks.json` 合并最小 hooks，在 `config.toml` 启用 hooks，额度和
  Context 则从最近的 `~/.codex/sessions/**/rollout-*.jsonl` 被动读取。额度窗口按实际
  `window_minutes` 分类；账号没有 5H 窗口时不显示该项。Codex 的 CTX 按最新一次
  token usage 除以该会话的模型 context window 计算，不使用跨请求累计 token。

同时有多个活跃会话时，客户端每 3 秒轮播一次。AUTH 与 REPLY 状态文字会在设备上闪烁。

首次改动已有配置时会生成 `.core-s3-companion.backup` 备份。配置完成后需要重启正在
运行的 Claude/Codex 会话。为了访问这些用户级配置，客户端不是 App Sandbox 应用。

## BLE 协议

Service UUID：

```text
7B3E0001-6F2B-4B7C-9B4E-3A8C1D5F2A10
```

Write Characteristic UUID：

```text
7B3E0002-6F2B-4B7C-9B4E-3A8C1D5F2A10
```

Agent 状态消息由 8 字节头部和最多 60 字节 UTF-8 标题组成：

| 字节 | 含义 | 值 |
|---|---|---|
| 0 | 协议版本 | `0x01` |
| 1 | 消息类型 | `0x02`（Agent status） |
| 2 | 状态 | `0=IDLE, 1=RUN, 2=AUTH, 3=REPLY, 4=DONE` |
| 3 | 来源 | `0=Auto, 1=Claude, 2=Codex` |
| 4 | 5H 剩余 | `0...100`，未知为 `0xFF` |
| 5 | Weekly 剩余 | `0...100`，未知为 `0xFF` |
| 6 | Context 已用 | `0...100`，未知为 `0xFF` |
| 7 | 标题字节数 | `0...60` |
| 8... | 会话标题 | 合法 UTF-8；内置中英文位图字体 |

旧的 `0x01` CPU 三字节帧解析仍保留用于协议兼容测试，但新版客户端只发送 Agent
状态帧。固件会拒绝长度、版本、状态、指标或标题不合法的消息。连接断开或 3 秒没有
收到有效消息时，屏幕切回等待/离线状态。

## 测试

固件协议测试：

```bash
cd firmware/CoreS3Companion
pio test -e native
```

macOS 核心逻辑测试可在 Xcode 中按 `Command-U`，或在工具链匹配的环境中执行：

```bash
cd macos/CoreS3Companion
swift test
```

真机测试仍然需要 CoreS3、支持 BLE 的 Mac 和蓝牙权限。

## GitHub Actions

仓库包含两条流水线：

- `.github/workflows/ci.yml`：推送到 `main`、Pull Request 或手动触发时，执行固件测试与构建，并使用完整 Xcode 构建和测试 macOS 客户端。
- `.github/workflows/release.yml`：推送 `vMAJOR.MINOR.PATCH` 标签时，生成两个固件镜像、ad-hoc 签名的 macOS 应用和未公证 DMG、计算 SHA-256，最后创建 GitHub Release。

CI 使用固定的 PlatformIO Core `6.1.19`。普通固件构建还会生成
`.pio/build/m5stack-cores3/firmware-factory.bin`：

- `firmware.bin` 是位于应用分区的镜像，PlatformIO Upload 会处理正确的偏移地址。
- `firmware-factory.bin` 合并了 bootloader、分区表、boot app 和应用，可从 `0x0` 一次烧录整台设备。

### GitHub 权限与 Secrets

这套发布流程不使用 Developer ID、不提交 Apple 公证，因此不需要 Apple 证书、App Store Connect API Key、Team ID 或任何自定义 GitHub Actions Secret。

创建 Release 使用 GitHub Actions 为每次任务自动生成的 `GITHUB_TOKEN`，无需手动创建或保存。只需确认仓库已启用 GitHub Actions；工作流已通过 `permissions: contents: write` 申请创建 Release 所需的最小写权限。

macOS 应用会在 Runner 上使用 ad-hoc 签名。它不代表开发者身份，DMG 也没有经过
Apple 公证；应用为读取 Claude/Codex 用户配置而不启用 App Sandbox。下载者首次打开时需要：

1. 将应用拖到“应用程序”并尝试打开一次。
2. 打开“系统设置 → 隐私与安全性”。
3. 在“安全性”区域点击“仍要打开”，验证后再次打开。

请保留 Release 中的 `SHA256SUMS.txt`，供下载者校验文件完整性。公司管理的 Mac 可能通过安全策略禁用“仍要打开”。

### 创建 Release

确认 CI 通过后创建并推送语义化版本标签：

```bash
git tag v0.0.1
git push origin v0.0.1
```

Release 流程成功后会生成：

- `CoreS3Companion-v0.0.1-app.bin`
- `CoreS3Companion-v0.0.1-factory.bin`
- `CoreS3Companion-v0.0.1-macOS-unsigned.dmg`
- `SHA256SUMS.txt`

上述 CI 和 Release 均不需要付费 Apple Developer 账号。

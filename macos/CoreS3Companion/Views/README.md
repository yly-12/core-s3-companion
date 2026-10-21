# Views

`ContentView` 提供设备、Claude/Codex、配置和关于四个页签。设备页负责搜索、配对、
重连与取消配对；Agent 页负责选择数据源、安装或移除集成，并预览即将发送到 CoreS3
的状态与 usage 倒计时；配置页分别设置未接电源和已接电源时的熄屏时间。

`SettingsTabsView` 不订阅状态或更新服务，各子页面独立订阅所需模型，更新弹窗由外层
`ContentView` 管理。避免每秒轮询或下载进度触发 TabView 重建，导致 macOS SwiftUI
持续保留页签元数据；隐藏设置窗口时同样需要保持该隔离。

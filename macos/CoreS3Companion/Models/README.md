# Models

包含 BLE 连接状态、发现设备、Agent 来源、默认工具、两种供电状态的熄屏档位、运行状态、
usage 重置时间与模型元数据，以及协调配对、数据采集和界面的 `CompanionViewModel`。
`AUTH` 与 `REPLY` 会抢占普通轮播，并在状态解除前锁定当前会话。

`AppUpdateModels` 包含数字版本比较、正式 Release 的安装包与来源校验、精确文件名
SHA-256 解析，以及更新检查、下载、安装和失败状态。

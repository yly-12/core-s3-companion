# Protocol

`AgentStatusMessage` 实现与硬件无关的变长状态帧解析，覆盖状态、来源、额度、Context 和
UTF-8 标题、模型名称和 effort，并供设备固件与 native 单元测试复用。解析器继续接受
不带模型后缀的旧 Agent 状态帧。

`CpuMessage` 只为第一版三字节协议的兼容测试保留。

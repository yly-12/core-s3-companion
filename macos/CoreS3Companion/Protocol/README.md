# Protocol

定义 BLE UUID、协议版本和 Agent 状态帧编码器。Agent 帧包含运行状态、来源、5H/Weekly
剩余额度、Context 占用和最多 60 字节的 UTF-8 显示标题。

三字节 CPU 编码器只为第一版协议兼容和回归测试保留，新客户端不再发送该消息。

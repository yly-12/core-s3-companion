# Communication

`BlePeripheral` 提供 BLE 广播、连接、写特征和断开后重新广播。
BLE 回调校验 Agent 状态帧后，只把最新状态写入 FreeRTOS 单元素队列。
连接变化或新状态到达时，回调还会通知 Arduino `loopTask`，让主循环从阻塞等待中立即醒来；没有 BLE 事件时由触摸和电源采样截止时间唤醒。

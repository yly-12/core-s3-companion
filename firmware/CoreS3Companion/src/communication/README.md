# Communication

`BlePeripheral` 提供 BLE 广播、连接、写特征和断开后重新广播。
BLE 回调校验 Agent 状态帧后，只把最新状态写入 FreeRTOS 单元素队列。

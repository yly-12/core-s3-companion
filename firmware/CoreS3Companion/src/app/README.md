# App

`CompanionState` 保存连接状态、最新 Agent 状态、自身电池电量和三秒数据超时状态。
它只在 Arduino 主循环中更新，BLE 回调不会直接修改屏幕状态。

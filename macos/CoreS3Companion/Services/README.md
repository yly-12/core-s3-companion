# Services

包含 Claude/Codex 状态采集、数据源偏好和集成配置管理：

- Claude hooks 与 status line 将当前状态、额度和 Context 写入应用数据目录。
- Codex hooks 提供事件状态，rollout JSONL 提供标题、额度和 Context。
- 集成管理器以可逆方式合并用户配置，并在首次修改前创建备份。

基于 Mach host statistics 的 CPU 采样器仅作为旧版兼容代码保留。

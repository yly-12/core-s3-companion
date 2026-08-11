# Services

包含 Claude/Codex 状态采集、数据源偏好和集成配置管理：

- Claude hooks 与 status line 提供当前状态、精确 Context、额度和重置时间；额度也会读取
  Claude 自身的 `~/.claude.json` 缓存。Transcript 提供最新 `ai-title` 模型摘要，并在
  Context 缺失时按明确模型对应的窗口计算；`nameSource=derived` 的内部代号不会作为标题。
- Codex hooks 提供事件状态，rollout JSONL 提供标题、额度、重置时间和 Context。
- 集成管理器以可逆方式合并用户配置，并在首次修改前创建备份。

基于 Mach host statistics 的 CPU 采样器仅作为旧版兼容代码保留。

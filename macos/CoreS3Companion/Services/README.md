# Services

包含 Claude/Codex 状态采集、数据源偏好和集成配置管理：

- Claude hooks 与 status line 提供当前状态、精确 Context、额度和重置时间；额度也会读取
  Claude 自身的 `~/.claude.json` 缓存。App 启动时及之后每 5 分钟在后台通过隔离的
  Claude CLI `/usage` 刷新额度；仅接受零 turn、零模型 token、零费用的结果。CLI 未推进
  `fetchedAtMs` 时，经过验证的 JSON 输出会在内存中优先使用，最多保留 10 分钟。
  Transcript 提供最新 `ai-title` 模型摘要，并在
  Context 缺失时按明确模型对应的窗口计算；`nameSource=derived` 的内部代号不会作为标题。
- Codex 同时监控 `~/.codex-personal` 与 `~/.codex-work`；各自的 hooks 提供事件状态，
  rollout JSONL 提供标题、额度、重置时间和 Context，账号之间不会合并 Usage。
  缓存 rollout 首行元数据，按 `session_meta.source.subagent` 排除所有子 agent 及其 hook
  记录（包括 guardian）；最近 12 个 rollout 的名额只计算主会话，活跃 hook 对应的主会话
  也会解析。子 agent 的额度与 Context 不会覆盖主会话。
  按 `turn_context` 和 `thread_settings_applied` 的 `approvals_reviewer` 区分审批模式：
  `auto_review` 审核命令或文件修改时保持 `RUNNING`，`user` 或未知模式保留 `AUTH`；
  明确的 `request_permissions` 用户权限请求仍显示 `AUTH`，用户提问仍显示 `REPLY`。
- 集成管理器以可逆方式合并用户配置，并在首次修改前创建备份。
- `AppUpdateService` 检查 GitHub 正式版、管理自动检查与跳过偏好、下载进度和取消，
  并验证 DMG 大小和 SHA-256；检查失败不会阻断蓝牙或 Agent 监控。
- `AppUpdateInstaller` 在后台挂载 DMG，验证 app 标识、版本、系统要求、架构和签名
  完整性，再交给独立安装脚本等待原进程退出、替换、重启和失败回滚。

基于 Mach host statistics 的 CPU 采样器仅作为旧版兼容代码保留。

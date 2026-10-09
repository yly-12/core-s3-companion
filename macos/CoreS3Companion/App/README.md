# App

包含菜单栏应用入口、AppKit 配置窗口、Info.plist 和签名 entitlement。

应用以 accessory 模式运行，不显示 Dock 图标；点击菜单栏图标直接显示或激活配置窗口。
为了安装 Claude/Codex 用户级 hooks，当前 target 不启用 App Sandbox。

入口持有独立的更新服务，启动后检查正式版并在发现新版本时打开更新窗口。
`update-helper.sh` 作为应用资源打包，在临时目录运行：先在安装目录准备候选应用，
告知 app 可以退出，再等待原 PID 消失后替换并通过 LaunchServices 重启。
替换或发起重启失败会恢复旧应用；结果写入用户 Application Support 的 Updates 目录。

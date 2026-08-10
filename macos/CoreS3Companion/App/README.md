# App

包含菜单栏应用入口、AppKit 配置窗口、Info.plist 和签名 entitlement。

应用以 accessory 模式运行，不显示 Dock 图标；点击菜单栏图标直接显示或激活配置窗口。
为了安装 Claude/Codex 用户级 hooks，当前 target 不启用 App Sandbox。

import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: CompanionViewModel

    var body: some View {
        TabView {
            DeviceSettingsView()
                .tabItem { Label("设备", systemImage: "display") }
            AgentSettingsView()
                .tabItem { Label("Claude / Codex", systemImage: "sparkles") }
            ConfigurationSettingsView()
                .tabItem { Label("配置", systemImage: "slider.horizontal.3") }
            GeneralSettingsView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

private struct DeviceSettingsView: View {
    @EnvironmentObject private var model: CompanionViewModel

    var body: some View {
        Group {
            if model.pairedDeviceID == nil {
                PairingView()
            } else {
                DeviceDashboardView()
            }
        }
        .padding(24)
    }
}

private struct PairingView: View {
    @EnvironmentObject private var model: CompanionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("查找 CoreS3")
                    .font(.largeTitle.bold())
                Text("打开 CoreS3 后，从下方列表选择设备完成应用内配对。")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if case .scanning = model.connectionState {
                    ProgressView().controlSize(.small)
                }
                Text(model.statusText)
                    .foregroundStyle(statusColor)
                Spacer()
                Button("重新搜索") { model.rescan() }
            }

            if model.devices.isEmpty {
                ContentUnavailableView(
                    "尚未发现设备",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("请确认 CoreS3 已烧录新固件、保持开机并靠近 Mac。")
                )
            } else {
                List(model.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "display")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.headline)
                            Text("设备 …\(device.shortIdentifier) · RSSI \(device.rssi)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.connectingDeviceID == device.id {
                            ProgressView().controlSize(.small)
                            Text("配对中").foregroundStyle(.secondary)
                        } else {
                            Button("配对") { model.pair(device) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.connectingDeviceID != nil)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .failed, .bluetoothUnavailable: .red
        default: .secondary
        }
    }
}

private struct DeviceDashboardView: View {
    @EnvironmentObject private var model: CompanionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.pairedDeviceName ?? "CoreS3 Companion")
                        .font(.title2.bold())
                    if let id = model.pairedDeviceID {
                        Text("设备 …\(String(id.uuidString.suffix(6)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ConnectionBadge(isConnected: model.isConnected, text: model.statusText)
            }

            AgentPreviewCard(snapshot: model.agentSnapshot)

            if let lastError = model.lastError, !model.isConnected {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                if !model.isConnected {
                    Button("重新连接") { model.retry() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("取消配对", role: .destructive) { model.unpair() }
            }
        }
    }
}

private struct AgentSettingsView: View {
    @EnvironmentObject private var model: CompanionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude / Codex")
                        .font(.largeTitle.bold())
                    Text("安装最小 hooks 后，客户端会读取本地状态并推送到已配对 CoreS3。")
                        .foregroundStyle(.secondary)
                }

                AgentPreviewCard(snapshot: model.agentSnapshot)

                GroupBox("显示来源") {
                    Picker("来源", selection: $model.selectedAgentSource) {
                        ForEach(AgentSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.vertical, 4)
                }

                VStack(spacing: 12) {
                    ForEach(AgentIntegrationKind.allCases) { kind in
                        IntegrationCard(
                            status: model.integrationStatuses[kind] ?? AgentIntegrationStatus(
                                kind: kind,
                                isInstalled: false,
                                detail: "尚未检查",
                                configPath: ""
                            ),
                            isBusy: model.configuringIntegration == kind,
                            install: { model.installIntegration(kind) },
                            uninstall: { model.uninstallIntegration(kind) }
                        )
                    }
                }

                if let message = model.configurationMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(message.contains("已") ? Color.secondary : Color.red)
                }

                Text("安装前会为已有配置创建一次 `.core-s3-companion.backup` 备份；已有 hooks 会被保留。Codex 额度来自 `~/.codex/sessions`，Claude 额度来自 status line 输入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

private struct IntegrationCard: View {
    let status: AgentIntegrationStatus
    let isBusy: Bool
    let install: () -> Void
    let uninstall: () -> Void

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: status.isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title2)
                    .foregroundStyle(status.isInstalled ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(status.kind.displayName).font(.headline)
                    Text(status.detail).foregroundStyle(.secondary)
                    if !status.configPath.isEmpty {
                        Text(status.configPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if status.isInstalled {
                    Button("移除", role: .destructive, action: uninstall)
                } else {
                    Button("配置", action: install)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct AgentPreviewCard: View {
    let snapshot: AgentSnapshot

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(snapshot.source.displayName, systemImage: snapshot.state.systemImage)
                        .foregroundStyle(stateColor)
                    Spacer()
                    Text(snapshot.updatedAt?.formatted(date: .omitted, time: .standard) ?? "尚无数据")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(snapshot.state.shortLabel)
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .foregroundStyle(stateColor)
                    Text(snapshot.state.displayName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(snapshot.title)
                    .font(.title3.bold())
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if snapshot.source != .codex || snapshot.fiveHourRemaining != nil {
                        MetricPill(label: "5H", value: snapshot.fiveHourRemaining)
                    }
                    MetricPill(label: "WK", value: snapshot.weeklyRemaining)
                    MetricPill(label: "CTX", value: snapshot.contextUsed)
                }
                Divider()
                HStack(spacing: 8) {
                    Text(snapshot.modelName ?? "MODEL --")
                        .font(.callout.monospaced())
                    Spacer()
                    Text(snapshot.effort.map { "EFF \($0.uppercased())" } ?? "EFF --")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var stateColor: Color {
        switch snapshot.state {
        case .idle: .secondary
        case .running: .green
        case .waitingAuthorization: .orange
        case .waitingReply: .blue
        case .completed: .mint
        }
    }
}

private struct ConfigurationSettingsView: View {
    @EnvironmentObject private var model: CompanionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("配置")
                    .font(.largeTitle.bold())
                Text("设置自动选择时的显示偏好。")
                    .foregroundStyle(.secondary)
            }

            GroupBox("默认工具") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("默认工具", selection: $model.defaultAgentTool) {
                        ForEach(DefaultAgentTool.allCases) { tool in
                            Text(tool.displayName).tag(tool)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text("当 Claude 和 Codex 都没有活跃 session 时，优先展示所选工具最近的状态。存在活跃 session 时仍按实时状态自动选择和轮播。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .padding(24)
    }
}

private struct MetricPill: View {
    let label: String
    let value: UInt8?

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(value.map { "\($0)%" } ?? "--")
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }
}

private struct ConnectionBadge: View {
    let isConnected: Bool
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            Text(text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }
}

private struct GeneralSettingsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "display.2")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("CoreS3 Companion")
                .font(.title.bold())
            Text("菜单栏中的 Claude / Codex 状态显示器")
                .foregroundStyle(.secondary)
            Button("退出 CoreS3 Companion") {
                NSApp.terminate(nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

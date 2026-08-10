import Combine
import Foundation

final class CompanionViewModel: ObservableObject {
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connectionState: BLEConnectionState = .idle
    @Published private(set) var pairedDeviceID: UUID?
    @Published private(set) var pairedDeviceName: String?
    @Published private(set) var lastError: String?
    @Published private(set) var agentSnapshot: AgentSnapshot = .idle
    @Published private(set) var agentSnapshots: [AgentSnapshot] = [.idle]
    @Published private(set) var integrationStatuses: [AgentIntegrationKind: AgentIntegrationStatus] = [:]
    @Published private(set) var configuringIntegration: AgentIntegrationKind?
    @Published private(set) var configurationMessage: String?
    @Published var selectedAgentSource: AgentSource {
        didSet {
            preferenceStore.selectedSource = selectedAgentSource
            monitor.selectedSource = selectedAgentSource
            monitor.refresh()
        }
    }
    @Published var defaultAgentTool: DefaultAgentTool {
        didSet {
            preferenceStore.defaultTool = defaultAgentTool
            monitor.defaultTool = defaultAgentTool
            monitor.refresh()
        }
    }
    @Published var displaySleepTimeout: DisplaySleepTimeout {
        didSet {
            preferenceStore.displaySleepTimeout = displaySleepTimeout
            sendCurrentSnapshot()
        }
    }

    private let transport: BLETransporting
    private let monitor: AgentStatusMonitoring
    private let pairedDeviceStore: PairedDeviceStoring
    private let preferenceStore: AgentPreferenceStoring
    private let integrationManager: AgentIntegrationManaging
    private var started = false
    private var rotationTimer: Timer?
    private var rotationIndex = 0

    init(
        transport: BLETransporting = BLETransport(),
        monitor: AgentStatusMonitoring = AgentStatusMonitor(),
        pairedDeviceStore: PairedDeviceStoring = UserDefaultsPairedDeviceStore(),
        preferenceStore: AgentPreferenceStoring = UserDefaultsAgentPreferenceStore(),
        integrationManager: AgentIntegrationManaging = AgentIntegrationManager()
    ) {
        self.transport = transport
        self.monitor = monitor
        self.pairedDeviceStore = pairedDeviceStore
        self.preferenceStore = preferenceStore
        self.integrationManager = integrationManager
        selectedAgentSource = preferenceStore.selectedSource
        defaultAgentTool = preferenceStore.defaultTool
        displaySleepTimeout = preferenceStore.displaySleepTimeout
        pairedDeviceID = pairedDeviceStore.deviceID
        pairedDeviceName = pairedDeviceStore.deviceName

        transport.onDevicesChange = { [weak self] devices in
            self?.devices = devices
        }
        transport.onStateChange = { [weak self] state in
            self?.connectionState = state
            if case let .failed(message) = state {
                self?.lastError = message
            }
        }
        transport.onReady = { [weak self] deviceID, name in
            guard let self else { return }
            self.pairedDeviceStore.deviceID = deviceID
            self.pairedDeviceStore.deviceName = name
            self.pairedDeviceID = deviceID
            self.pairedDeviceName = name
            self.lastError = nil
            self.sendCurrentSnapshot()
        }
        transport.onError = { [weak self] message in
            self?.lastError = message
        }
        monitor.onSnapshots = { [weak self] snapshots in
            guard let self else { return }
            self.receive(snapshots)
        }
        monitor.selectedSource = selectedAgentSource
        monitor.defaultTool = defaultAgentTool
    }

    func start() {
        guard !started else { return }
        started = true
        refreshIntegrationStatuses()
        monitor.start()
        transport.start(savedDeviceID: pairedDeviceID)
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.rotateSession()
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    func pair(_ device: DiscoveredDevice) {
        lastError = nil
        transport.pair(deviceID: device.id)
    }

    func rescan() {
        lastError = nil
        transport.scan()
    }

    func retry() {
        guard let pairedDeviceID else { return }
        lastError = nil
        transport.retry(deviceID: pairedDeviceID)
    }

    func unpair() {
        pairedDeviceStore.clear()
        pairedDeviceID = nil
        pairedDeviceName = nil
        lastError = nil
        transport.unpair()
    }

    func installIntegration(_ kind: AgentIntegrationKind) {
        configuringIntegration = kind
        configurationMessage = nil
        do {
            try integrationManager.install(kind)
            configurationMessage = "已配置 \(kind.displayName)，请重启正在运行的会话。"
        } catch {
            configurationMessage = error.localizedDescription
        }
        configuringIntegration = nil
        refreshIntegrationStatuses()
        monitor.refresh()
    }

    func uninstallIntegration(_ kind: AgentIntegrationKind) {
        configuringIntegration = kind
        configurationMessage = nil
        do {
            try integrationManager.uninstall(kind)
            configurationMessage = "已移除 \(kind.displayName) 的 CoreS3 配置。"
        } catch {
            configurationMessage = error.localizedDescription
        }
        configuringIntegration = nil
        refreshIntegrationStatuses()
    }

    func refreshIntegrationStatuses() {
        integrationStatuses = Dictionary(uniqueKeysWithValues: AgentIntegrationKind.allCases.map {
            ($0, integrationManager.status(for: $0))
        })
    }

    private func sendCurrentSnapshot() {
        guard isConnected,
              let packet = try? AgentStatusMessageEncoder.encode(
                  agentSnapshot,
                  screenTimeout: displaySleepTimeout,
                  activityAt: agentSnapshots.compactMap(\.updatedAt).max()
              ) else {
            return
        }
        _ = transport.send(packet)
    }

    private func receive(_ snapshots: [AgentSnapshot]) {
        let snapshots = snapshots.isEmpty ? [.idle] : snapshots
        let currentID = agentSnapshot.sessionID
        agentSnapshots = snapshots
        if let index = snapshots.firstIndex(where: { $0.sessionID == currentID }) {
            rotationIndex = index
        } else {
            rotationIndex = 0
        }
        agentSnapshot = snapshots[rotationIndex]
        sendCurrentSnapshot()
    }

    func rotateSession() {
        guard agentSnapshots.count > 1 else { return }
        rotationIndex = (rotationIndex + 1) % agentSnapshots.count
        agentSnapshot = agentSnapshots[rotationIndex]
        sendCurrentSnapshot()
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var connectingDeviceID: UUID? {
        switch connectionState {
        case let .connecting(id), let .discovering(id): id
        default: nil
        }
    }

    var statusText: String {
        switch connectionState {
        case .idle:
            "正在准备蓝牙…"
        case let .bluetoothUnavailable(message):
            message
        case .scanning:
            pairedDeviceID == nil ? "正在搜索附近的 CoreS3…" : "正在寻找已配对设备…"
        case .connecting:
            "正在连接设备…"
        case .discovering:
            "正在确认设备服务…"
        case .connected:
            "已连接"
        case let .failed(message):
            message
        }
    }

    var menuBarSymbolName: String {
        agentSnapshot.state.systemImage
    }

    deinit {
        rotationTimer?.invalidate()
    }
}

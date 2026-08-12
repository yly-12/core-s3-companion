import Combine
import Foundation

final class CompanionViewModel: ObservableObject {
    private static let statusHeartbeatInterval: TimeInterval = 15

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
    @Published var displaySleepTimeoutOnBattery: DisplaySleepTimeout {
        didSet {
            preferenceStore.displaySleepTimeoutOnBattery = displaySleepTimeoutOnBattery
            sendCurrentSnapshot()
        }
    }
    @Published var displaySleepTimeoutOnExternalPower: DisplaySleepTimeout {
        didSet {
            preferenceStore.displaySleepTimeoutOnExternalPower = displaySleepTimeoutOnExternalPower
            sendCurrentSnapshot()
        }
    }

    private let transport: BLETransporting
    private let monitor: AgentStatusMonitoring
    private let pairedDeviceStore: PairedDeviceStoring
    private let preferenceStore: AgentPreferenceStoring
    private let integrationManager: AgentIntegrationManaging
    private let currentDate: () -> Date
    private var started = false
    private var rotationTimer: Timer?
    private var rotationIndex = 0
    private var lastSentFingerprint: Data?
    private var lastSentAt: Date?

    init(
        transport: BLETransporting = BLETransport(),
        monitor: AgentStatusMonitoring = AgentStatusMonitor(
            claudeUsageRefresher: ClaudeCLIUsageRefresher()
        ),
        pairedDeviceStore: PairedDeviceStoring = UserDefaultsPairedDeviceStore(),
        preferenceStore: AgentPreferenceStoring = UserDefaultsAgentPreferenceStore(),
        integrationManager: AgentIntegrationManaging = AgentIntegrationManager(),
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.monitor = monitor
        self.pairedDeviceStore = pairedDeviceStore
        self.preferenceStore = preferenceStore
        self.integrationManager = integrationManager
        self.currentDate = currentDate
        selectedAgentSource = preferenceStore.selectedSource
        defaultAgentTool = preferenceStore.defaultTool
        displaySleepTimeoutOnBattery = preferenceStore.displaySleepTimeoutOnBattery
        displaySleepTimeoutOnExternalPower = preferenceStore.displaySleepTimeoutOnExternalPower
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
            self.sendCurrentSnapshot(force: true)
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

    private func sendCurrentSnapshot(force: Bool = false) {
        let now = currentDate()
        guard isConnected,
              let packet = try? AgentStatusMessageEncoder.encode(
                  agentSnapshot,
                  screenTimeoutOnBattery: displaySleepTimeoutOnBattery,
                  screenTimeoutOnExternalPower: displaySleepTimeoutOnExternalPower,
                  activityAt: agentSnapshots.compactMap(\.updatedAt).max(),
                  now: now
              ) else {
            return
        }
        let heartbeatDue = lastSentAt.map {
            now.timeIntervalSince($0) >= Self.statusHeartbeatInterval
        } ?? true
        let fingerprint = statusFingerprint(for: packet)
        guard force || fingerprint != lastSentFingerprint || heartbeatDue else { return }
        guard transport.send(packet) else { return }
        lastSentFingerprint = fingerprint
        lastSentAt = now
    }

    private func statusFingerprint(for packet: Data) -> Data {
        var fingerprint = packet
        // The four-byte activity token sits before the two reset countdowns.
        // It can advance every poll without changing anything visible on CoreS3.
        guard fingerprint.count >= 8 else { return fingerprint }
        fingerprint.replaceSubrange((fingerprint.count - 8)..<(fingerprint.count - 4), with: repeatElement(0, count: 4))
        return fingerprint
    }

    private func receive(_ snapshots: [AgentSnapshot]) {
        let snapshots = snapshots.isEmpty ? [.idle] : snapshots
        let currentID = agentSnapshot.sessionID
        agentSnapshots = snapshots
        let attentionIndexes = snapshots.indices.filter {
            snapshots[$0].state.requiresUserAttention
        }
        if agentSnapshot.state.requiresUserAttention,
           let index = attentionIndexes.first(where: {
               snapshots[$0].sessionID == currentID
           }) {
            rotationIndex = index
        } else if let index = attentionIndexes.first {
            rotationIndex = index
        } else if let index = snapshots.firstIndex(where: { $0.sessionID == currentID }) {
            rotationIndex = index
        } else {
            rotationIndex = 0
        }
        agentSnapshot = snapshots[rotationIndex]
        sendCurrentSnapshot()
    }

    func rotateSession() {
        guard agentSnapshots.count > 1,
              !agentSnapshot.state.requiresUserAttention else { return }
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

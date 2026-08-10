import CoreBluetooth
import Foundation

protocol BLETransporting: AnyObject {
    var onStateChange: ((BLEConnectionState) -> Void)? { get set }
    var onDevicesChange: (([DiscoveredDevice]) -> Void)? { get set }
    var onReady: ((UUID, String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func start(savedDeviceID: UUID?)
    func scan()
    func pair(deviceID: UUID)
    func retry(deviceID: UUID)
    func unpair()
    @discardableResult func send(_ data: Data) -> Bool
}

final class BLETransport: NSObject, BLETransporting {
    var onStateChange: ((BLEConnectionState) -> Void)?
    var onDevicesChange: (([DiscoveredDevice]) -> Void)?
    var onReady: ((UUID, String) -> Void)?
    var onError: ((String) -> Void)?

    private let serviceUUID = CBUUID(string: CompanionProtocol.serviceUUID)
    private let writeCharacteristicUUID = CBUUID(
        string: CompanionProtocol.writeCharacteristicUUID
    )

    private var centralManager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var discoveredDevices: [UUID: DiscoveredDevice] = [:]
    private var targetDeviceID: UUID?
    private var currentPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var reconnectEnabled = false
    private var writeInFlight = false
    private var connectionAttemptToken = UUID()
    private var reconnectWorkItem: DispatchWorkItem?
    private var state: BLEConnectionState = .idle {
        didSet { onStateChange?(state) }
    }

    func start(savedDeviceID: UUID?) {
        targetDeviceID = savedDeviceID
        reconnectEnabled = savedDeviceID != nil
        ensureCentralManager()

        if centralManager?.state == .poweredOn {
            savedDeviceID == nil ? beginScan(clearResults: true) : connectToTarget()
        }
    }

    func scan() {
        reconnectWorkItem?.cancel()
        reconnectEnabled = false
        targetDeviceID = nil
        cancelCurrentConnection()
        beginScan(clearResults: true)
    }

    func pair(deviceID: UUID) {
        guard let peripheral = peripherals[deviceID] else {
            state = .failed("设备已离开搜索范围，请重新搜索。")
            return
        }

        if currentPeripheral?.identifier != deviceID {
            cancelCurrentConnection()
        }
        targetDeviceID = deviceID
        reconnectEnabled = false
        connect(peripheral)
    }

    func retry(deviceID: UUID) {
        targetDeviceID = deviceID
        reconnectEnabled = true
        connectToTarget()
    }

    func unpair() {
        reconnectWorkItem?.cancel()
        reconnectEnabled = false
        targetDeviceID = nil
        cancelCurrentConnection()
        beginScan(clearResults: true)
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard !writeInFlight,
              let peripheral = currentPeripheral,
              peripheral.state == .connected,
              let characteristic = writeCharacteristic,
              characteristic.properties.contains(.write),
              data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            return false
        }

        writeInFlight = true
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        return true
    }

    private func ensureCentralManager() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    private func beginScan(clearResults: Bool) {
        guard let centralManager, centralManager.state == .poweredOn else { return }
        if clearResults {
            discoveredDevices.removeAll()
            peripherals.removeAll()
            publishDevices()
        }
        state = .scanning
        centralManager.stopScan()
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func connectToTarget() {
        guard let targetDeviceID, let centralManager,
              centralManager.state == .poweredOn else {
            return
        }

        if let knownPeripheral = peripherals[targetDeviceID] {
            connect(knownPeripheral)
            return
        }

        if let restored = centralManager
            .retrievePeripherals(withIdentifiers: [targetDeviceID])
            .first {
            peripherals[targetDeviceID] = restored
            connect(restored)
            return
        }

        beginScan(clearResults: false)
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard let centralManager, centralManager.state == .poweredOn else { return }
        guard currentPeripheral?.identifier != peripheral.identifier ||
                peripheral.state == .disconnected else {
            return
        }

        reconnectWorkItem?.cancel()
        centralManager.stopScan()
        currentPeripheral = peripheral
        writeCharacteristic = nil
        writeInFlight = false
        peripheral.delegate = self
        state = .connecting(peripheral.identifier)
        centralManager.connect(peripheral)
        scheduleConnectionTimeout(for: peripheral.identifier)
    }

    private func scheduleConnectionTimeout(for deviceID: UUID) {
        let token = UUID()
        connectionAttemptToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self,
                  self.connectionAttemptToken == token,
                  self.currentPeripheral?.identifier == deviceID,
                  self.writeCharacteristic == nil else {
                return
            }
            self.centralManager?.cancelPeripheralConnection(self.currentPeripheral!)
            self.handleConnectionFailure("连接超时，请确认 CoreS3 已开机并在附近。")
        }
    }

    private func handleConnectionFailure(_ message: String) {
        connectionAttemptToken = UUID()
        writeCharacteristic = nil
        writeInFlight = false
        currentPeripheral = nil
        state = .failed(message)
        if reconnectEnabled, targetDeviceID != nil {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.reconnectEnabled, self.targetDeviceID != nil else {
                return
            }
            self.beginScan(clearResults: false)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func cancelCurrentConnection() {
        connectionAttemptToken = UUID()
        writeCharacteristic = nil
        writeInFlight = false
        if let currentPeripheral {
            centralManager?.cancelPeripheralConnection(currentPeripheral)
        }
        currentPeripheral = nil
    }

    private func publishDevices() {
        let devices = discoveredDevices.values.sorted {
            if $0.name == $1.name {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        onDevicesChange?(devices)
    }

    private func deviceName(for peripheral: CBPeripheral) -> String {
        discoveredDevices[peripheral.identifier]?.name ??
            peripheral.name ??
            "CoreS3 Companion"
    }
}

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            targetDeviceID == nil ? beginScan(clearResults: true) : connectToTarget()
        case .poweredOff:
            state = .bluetoothUnavailable("蓝牙已关闭，请在系统设置中开启蓝牙。")
        case .unauthorized:
            state = .bluetoothUnavailable("蓝牙权限被拒绝，请在隐私与安全性设置中允许访问。")
        case .unsupported:
            state = .bluetoothUnavailable("这台 Mac 不支持 Bluetooth Low Energy。")
        case .resetting:
            state = .bluetoothUnavailable("蓝牙正在重置，请稍候。")
        case .unknown:
            state = .idle
        @unknown default:
            state = .bluetoothUnavailable("蓝牙处于未知状态。")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ??
            peripheral.name ??
            "CoreS3 Companion"
        peripherals[peripheral.identifier] = peripheral
        discoveredDevices[peripheral.identifier] = DiscoveredDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue
        )
        publishDevices()

        if BLESelectionPolicy.shouldAutoConnect(
            discoveredID: peripheral.identifier,
            targetID: targetDeviceID
        ) {
            connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == targetDeviceID else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectionAttemptToken = UUID()
        state = .discovering(peripheral.identifier)
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == targetDeviceID else { return }
        handleConnectionFailure(error?.localizedDescription ?? "无法连接设备。")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == targetDeviceID else { return }
        writeCharacteristic = nil
        writeInFlight = false
        currentPeripheral = nil
        state = .failed(error?.localizedDescription ?? "设备连接已断开。")
        if reconnectEnabled {
            scheduleReconnect()
        }
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            centralManager?.cancelPeripheralConnection(peripheral)
            handleConnectionFailure("设备缺少 Companion BLE 服务。")
            return
        }
        peripheral.discoverCharacteristics([writeCharacteristicUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral.identifier == targetDeviceID else { return }
        let characteristics = service.characteristics ?? []
        let characteristicIDs = characteristics.map(\.uuid.uuidString)
        guard error == nil,
              BLESelectionPolicy.hasRequiredCharacteristic(characteristicIDs),
              let characteristic = characteristics.first(where: {
                  $0.uuid == writeCharacteristicUUID && $0.properties.contains(.write)
              }) else {
            centralManager?.cancelPeripheralConnection(peripheral)
            handleConnectionFailure("设备缺少可写的 Companion 状态特征。")
            return
        }

        connectionAttemptToken = UUID()
        writeCharacteristic = characteristic
        reconnectEnabled = true
        state = .connected(peripheral.identifier)
        onReady?(peripheral.identifier, deviceName(for: peripheral))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        writeInFlight = false
        if let error {
            onError?("状态数据发送失败：\(error.localizedDescription)")
        }
    }
}

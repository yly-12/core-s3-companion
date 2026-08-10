#include "BlePeripheral.h"

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEUtils.h>

#include <string>

#include "protocol/AgentStatusMessage.h"

namespace companion {
namespace communication {

const char* const BlePeripheral::kDeviceName = "CoreS3 Companion";
const char* const BlePeripheral::kServiceUuid =
    "7B3E0001-6F2B-4B7C-9B4E-3A8C1D5F2A10";
const char* const BlePeripheral::kWriteCharacteristicUuid =
    "7B3E0002-6F2B-4B7C-9B4E-3A8C1D5F2A10";

class BlePeripheral::ServerCallbacks final : public BLEServerCallbacks {
 public:
  explicit ServerCallbacks(BlePeripheral& owner) : owner_(owner) {}

  void onConnect(BLEServer*) override { owner_.handleConnectionChanged(true); }

  void onDisconnect(BLEServer*) override {
    owner_.handleConnectionChanged(false);
  }

 private:
  BlePeripheral& owner_;
};

class BlePeripheral::WriteCallbacks final : public BLECharacteristicCallbacks {
 public:
  explicit WriteCallbacks(BlePeripheral& owner) : owner_(owner) {}

  void onWrite(BLECharacteristic* characteristic) override {
    owner_.handleWrite(characteristic);
  }

 private:
  BlePeripheral& owner_;
};

BlePeripheral::BlePeripheral() = default;

BlePeripheral::~BlePeripheral() {
  if (statusQueue_ != nullptr) {
    vQueueDelete(statusQueue_);
  }
  delete serverCallbacks_;
  delete writeCallbacks_;
}

bool BlePeripheral::begin() {
  statusQueue_ = xQueueCreate(1, sizeof(protocol::AgentStatusMessage));
  if (statusQueue_ == nullptr) {
    Serial.println("[BLE] Failed to create agent status queue");
    return false;
  }

  BLEDevice::init(kDeviceName);
  BLEDevice::setMTU(185);
  server_ = BLEDevice::createServer();
  serverCallbacks_ = new ServerCallbacks(*this);
  writeCallbacks_ = new WriteCallbacks(*this);
  server_->setCallbacks(serverCallbacks_);

  BLEService* service = server_->createService(kServiceUuid);
  BLECharacteristic* writeCharacteristic = service->createCharacteristic(
      kWriteCharacteristicUuid, BLECharacteristic::PROPERTY_WRITE);
  writeCharacteristic->setCallbacks(writeCallbacks_);
  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->setScanResponse(true);
  advertising->start();

  Serial.printf("[BLE] Advertising as %s\n", kDeviceName);
  return true;
}

bool BlePeripheral::isConnected() const { return connected_.load(); }

bool BlePeripheral::receiveAgentStatus(protocol::AgentStatusMessage& status) {
  return statusQueue_ != nullptr &&
         xQueueReceive(statusQueue_, &status, 0) == pdTRUE;
}

void BlePeripheral::handleConnectionChanged(const bool connected) {
  connected_.store(connected);
  if (connected) {
    Serial.println("[BLE] Mac connected");
    return;
  }

  Serial.println("[BLE] Mac disconnected; restarting advertising");
  if (statusQueue_ != nullptr) {
    xQueueReset(statusQueue_);
  }
  if (server_ != nullptr) {
    server_->startAdvertising();
  }
}

void BlePeripheral::handleWrite(BLECharacteristic* characteristic) {
  const std::string value = characteristic->getValue();
  protocol::AgentStatusMessage status;
  const auto result = protocol::parseAgentStatus(
      reinterpret_cast<const std::uint8_t*>(value.data()), value.size(),
      status);

  if (result != protocol::AgentParseResult::kOk) {
    Serial.printf("[BLE] Rejected agent frame: %s\n",
                  protocol::agentParseResultName(result));
    return;
  }

  if (statusQueue_ != nullptr) {
    xQueueOverwrite(statusQueue_, &status);
  }
  Serial.printf("[BLE] Agent state=%u title=%s\n",
                static_cast<unsigned>(status.state), status.title);
}

}  // namespace communication
}  // namespace companion

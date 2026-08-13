#pragma once

#include <BLEServer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

#include <atomic>
#include <cstdint>

#include "protocol/AgentStatusMessage.h"

namespace companion {
namespace communication {

class BlePeripheral {
 public:
  static const char* const kDeviceName;
  static const char* const kServiceUuid;
  static const char* const kWriteCharacteristicUuid;

  BlePeripheral();
  ~BlePeripheral();

  bool begin();
  void setEventTask(TaskHandle_t task);
  bool waitForEvent(std::uint32_t timeoutMs);
  bool isConnected() const;
  bool receiveAgentStatus(protocol::AgentStatusMessage& status);

 private:
  class ServerCallbacks;
  class WriteCallbacks;

  void handleConnectionChanged(bool connected);
  void handleWrite(BLECharacteristic* characteristic);
  void notifyEventTask();

  QueueHandle_t statusQueue_ = nullptr;
  BLEServer* server_ = nullptr;
  std::atomic_bool connected_{false};
  std::atomic<TaskHandle_t> eventTask_{nullptr};
  ServerCallbacks* serverCallbacks_ = nullptr;
  WriteCallbacks* writeCallbacks_ = nullptr;
};

}  // namespace communication
}  // namespace companion

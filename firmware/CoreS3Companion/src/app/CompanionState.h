#pragma once

#include <cstdint>

#include "protocol/AgentStatusMessage.h"

namespace companion {
namespace app {

class CompanionState {
 public:
  static constexpr std::uint32_t kSampleTimeoutMs = 20000;

  void setConnected(bool connected);
  void setAgentStatus(const protocol::AgentStatusMessage& status,
                      std::uint32_t nowMs);
  void recordLocalActivity(std::uint32_t nowMs);
  void setBatteryLevel(std::uint8_t batteryLevel);
  void setPowerState(bool externalPowerConnected, bool batteryCharging,
                     std::uint32_t nowMs);
  void update(std::uint32_t nowMs);

  bool isConnected() const;
  bool hasFreshStatus() const;
  bool hasActiveSession() const;
  bool isDisplayAwake() const;
  const protocol::AgentStatusMessage& status() const;
  std::uint8_t batteryLevel() const;
  bool isExternalPowerConnected() const;
  bool isBatteryCharging() const;

 private:
  bool connected_ = false;
  bool hasStatus_ = false;
  protocol::AgentStatusMessage status_;
  std::uint8_t batteryLevel_ = protocol::kUnknownMetricValue;
  bool externalPowerConnected_ = false;
  bool batteryCharging_ = false;
  std::uint32_t lastSampleMs_ = 0;
  std::uint32_t lastActivityMs_ = 0;
  bool displayAwake_ = true;
};

}  // namespace app
}  // namespace companion

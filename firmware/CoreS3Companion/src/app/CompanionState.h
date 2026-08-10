#pragma once

#include <cstdint>

#include "protocol/AgentStatusMessage.h"

namespace companion {
namespace app {

class CompanionState {
 public:
  static constexpr std::uint32_t kSampleTimeoutMs = 3000;

  void setConnected(bool connected);
  void setAgentStatus(const protocol::AgentStatusMessage& status,
                      std::uint32_t nowMs);
  void setBatteryLevel(std::uint8_t batteryLevel);
  void update(std::uint32_t nowMs);

  bool isConnected() const;
  bool hasFreshStatus() const;
  const protocol::AgentStatusMessage& status() const;
  std::uint8_t batteryLevel() const;

 private:
  bool connected_ = false;
  bool hasStatus_ = false;
  protocol::AgentStatusMessage status_;
  std::uint8_t batteryLevel_ = protocol::kUnknownMetricValue;
  std::uint32_t lastSampleMs_ = 0;
};

}  // namespace app
}  // namespace companion


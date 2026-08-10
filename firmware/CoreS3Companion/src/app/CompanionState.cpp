#include "CompanionState.h"

namespace companion {
namespace app {

void CompanionState::setConnected(const bool connected) {
  connected_ = connected;
  if (!connected_) {
    hasStatus_ = false;
  }
}

void CompanionState::setAgentStatus(const protocol::AgentStatusMessage& status,
                                    const std::uint32_t nowMs) {
  if (!connected_) {
    return;
  }
  status_ = status;
  lastSampleMs_ = nowMs;
  hasStatus_ = true;
}

void CompanionState::setBatteryLevel(const std::uint8_t batteryLevel) {
  batteryLevel_ = batteryLevel <= 100 ? batteryLevel
                                     : protocol::kUnknownMetricValue;
}

void CompanionState::update(const std::uint32_t nowMs) {
  if (hasStatus_ && nowMs - lastSampleMs_ >= kSampleTimeoutMs) {
    hasStatus_ = false;
  }
}

bool CompanionState::isConnected() const { return connected_; }

bool CompanionState::hasFreshStatus() const {
  return connected_ && hasStatus_;
}

const protocol::AgentStatusMessage& CompanionState::status() const {
  return status_;
}

std::uint8_t CompanionState::batteryLevel() const { return batteryLevel_; }

}  // namespace app
}  // namespace companion

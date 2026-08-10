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
  if (!hasStatus_ || status.activityToken != status_.activityToken ||
      status.displayTimeoutMinutes != status_.displayTimeoutMinutes) {
    recordLocalActivity(nowMs);
  }
  status_ = status;
  lastSampleMs_ = nowMs;
  hasStatus_ = true;
}

void CompanionState::recordLocalActivity(const std::uint32_t nowMs) {
  lastActivityMs_ = nowMs;
  displayAwake_ = true;
}

void CompanionState::setBatteryLevel(const std::uint8_t batteryLevel) {
  batteryLevel_ = batteryLevel <= 100 ? batteryLevel
                                     : protocol::kUnknownMetricValue;
}

void CompanionState::update(const std::uint32_t nowMs) {
  if (hasStatus_ && nowMs - lastSampleMs_ >= kSampleTimeoutMs) {
    hasStatus_ = false;
  }

  const std::uint8_t timeoutMinutes = status_.displayTimeoutMinutes;
  if (timeoutMinutes == 0) {
    displayAwake_ = true;
    return;
  }

  const std::uint32_t timeoutMs =
      static_cast<std::uint32_t>(timeoutMinutes) * 60U * 1000U;
  if (displayAwake_ && nowMs - lastActivityMs_ >= timeoutMs) {
    displayAwake_ = false;
  }
}

bool CompanionState::isConnected() const { return connected_; }

bool CompanionState::hasFreshStatus() const {
  return connected_ && hasStatus_;
}

bool CompanionState::isDisplayAwake() const { return displayAwake_; }

const protocol::AgentStatusMessage& CompanionState::status() const {
  return status_;
}

std::uint8_t CompanionState::batteryLevel() const { return batteryLevel_; }

}  // namespace app
}  // namespace companion

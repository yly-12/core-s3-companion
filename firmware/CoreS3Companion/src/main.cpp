#include <Arduino.h>
#include <M5Unified.h>

#include <algorithm>
#include <cstdint>

#include "app/CompanionState.h"
#include "communication/BlePeripheral.h"
#include "protocol/AgentStatusMessage.h"
#include "renderer/DisplayRenderer.h"

namespace {

constexpr std::uint32_t kPowerRefreshMs = 5000;

companion::app::CompanionState appState;
companion::communication::BlePeripheral blePeripheral;
companion::renderer::DisplayRenderer displayRenderer;
bool lastConnectionState = false;
std::uint32_t lastPowerRefreshMs = 0;

void refreshPower(const std::uint32_t nowMs) {
  const auto level = M5.Power.getBatteryLevel();
  if (level >= 0) {
    appState.setBatteryLevel(
        static_cast<std::uint8_t>(std::min<std::int32_t>(100, level)));
  }
  const bool externalPowerConnected = M5.Power.getVBUSVoltage() > 1000;
  const bool batteryCharging =
      M5.Power.isCharging() == m5::Power_Class::is_charging;
  appState.setPowerState(externalPowerConnected, batteryCharging, nowMs);
  lastPowerRefreshMs = nowMs;
}

}  // namespace

void setup() {
  Serial.begin(115200);
  displayRenderer.begin();
  refreshPower(millis());
  displayRenderer.render(appState);

  if (!blePeripheral.begin()) {
    Serial.println("[App] BLE initialization failed");
  }
}

void loop() {
  M5.update();
  const std::uint32_t nowMs = millis();

  if (M5.Touch.getDetail().wasPressed()) {
    appState.recordLocalActivity(nowMs);
  }

  const bool connected = blePeripheral.isConnected();
  if (connected != lastConnectionState) {
    lastConnectionState = connected;
    appState.setConnected(connected);
  }

  companion::protocol::AgentStatusMessage status;
  if (blePeripheral.receiveAgentStatus(status)) {
    appState.setAgentStatus(status, nowMs);
  }

  if (nowMs - lastPowerRefreshMs >= kPowerRefreshMs) {
    refreshPower(nowMs);
  }

  appState.update(nowMs);
  displayRenderer.render(appState);
  delay(10);
}

#include <Arduino.h>
#include <M5Unified.h>

#include <algorithm>
#include <cstdint>

#include "app/CompanionState.h"
#include "communication/BlePeripheral.h"
#include "protocol/AgentStatusMessage.h"
#include "renderer/DisplayRenderer.h"

namespace {

constexpr std::uint32_t kBatteryRefreshMs = 30000;

companion::app::CompanionState appState;
companion::communication::BlePeripheral blePeripheral;
companion::renderer::DisplayRenderer displayRenderer;
bool lastConnectionState = false;
std::uint32_t lastBatteryRefreshMs = 0;

void refreshBattery() {
  const auto level = M5.Power.getBatteryLevel();
  if (level >= 0) {
    appState.setBatteryLevel(
        static_cast<std::uint8_t>(std::min<std::int32_t>(100, level)));
  }
  lastBatteryRefreshMs = millis();
}

}  // namespace

void setup() {
  Serial.begin(115200);
  displayRenderer.begin();
  refreshBattery();
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

  if (millis() - lastBatteryRefreshMs >= kBatteryRefreshMs) {
    refreshBattery();
  }

  appState.update(nowMs);
  displayRenderer.render(appState);
  delay(10);
}

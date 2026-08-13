#include <Arduino.h>
#include <M5Unified.h>
#include <esp_timer.h>

#include <algorithm>
#include <cstdint>

#include "app/CompanionState.h"
#include "communication/BlePeripheral.h"
#include "protocol/AgentStatusMessage.h"
#include "renderer/DisplayRenderer.h"

namespace {

constexpr std::uint32_t kPowerRefreshMs = 5000;
constexpr std::uint32_t kTelemetryRefreshMs = 60000;
constexpr std::uint32_t kAwakePollMs = 20;
constexpr std::uint32_t kSleepingPollMs = 100;

companion::app::CompanionState appState;
companion::communication::BlePeripheral blePeripheral;
companion::renderer::DisplayRenderer displayRenderer;
bool lastConnectionState = false;
std::uint32_t lastPowerRefreshMs = 0;
std::uint32_t lastTelemetryRefreshMs = 0;
std::uint64_t activeMicros = 0;
std::uint32_t loopWakeups = 0;

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

void printRuntimeTelemetry(const std::uint32_t nowMs) {
  const std::uint32_t elapsedMs = nowMs - lastTelemetryRefreshMs;
  if (elapsedMs < kTelemetryRefreshMs) {
    return;
  }

  const double loopBusyPercent =
      elapsedMs == 0 ? 0.0 : activeMicros * 100.0 / (elapsedMs * 1000.0);
  const double wakeupsPerSecond =
      elapsedMs == 0 ? 0.0 : loopWakeups * 1000.0 / elapsedMs;
  Serial.printf(
      "[Runtime] cpu=%uMHz loop_busy=%.2f%% wakeups=%.1f/s "
      "heap=%u min_heap=%u psram=%u/%u bat=%dmV current=%ldmA\n",
      getCpuFrequencyMhz(), loopBusyPercent, wakeupsPerSecond,
      ESP.getFreeHeap(), ESP.getMinFreeHeap(), ESP.getFreePsram(),
      ESP.getPsramSize(), M5.Power.getBatteryVoltage(),
      static_cast<long>(M5.Power.getBatteryCurrent()));

  activeMicros = 0;
  loopWakeups = 0;
  lastTelemetryRefreshMs = nowMs;
}

}  // namespace

void setup() {
  Serial.begin(115200);
  blePeripheral.setEventTask(xTaskGetCurrentTaskHandle());
  displayRenderer.begin();
  const std::uint32_t nowMs = millis();
  refreshPower(nowMs);
  lastTelemetryRefreshMs = nowMs;
  displayRenderer.render(appState);

  if (!blePeripheral.begin()) {
    Serial.println("[App] BLE initialization failed");
  }
}

void loop() {
  const std::int64_t activeStartMicros = esp_timer_get_time();
  ++loopWakeups;
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
  printRuntimeTelemetry(nowMs);

  activeMicros += static_cast<std::uint64_t>(esp_timer_get_time() - activeStartMicros);
  blePeripheral.waitForEvent(appState.isDisplayAwake() ? kAwakePollMs
                                                       : kSleepingPollMs);
}

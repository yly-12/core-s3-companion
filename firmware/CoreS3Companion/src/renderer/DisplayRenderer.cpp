#include "DisplayRenderer.h"

#include <M5Unified.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "protocol/AgentStatusMessage.h"

namespace companion {
namespace renderer {

namespace {

std::uint16_t color(const std::uint8_t red, const std::uint8_t green,
                    const std::uint8_t blue) {
  return M5.Display.color565(red, green, blue);
}

const char* sourceLabel(const protocol::AgentSource source) {
  switch (source) {
    case protocol::AgentSource::kClaude:
      return "CLAUDE";
    case protocol::AgentSource::kCodex:
      return "CODEX";
    case protocol::AgentSource::kAutomatic:
      return "AGENT";
  }
  return "AGENT";
}

std::uint16_t sourceColor(const protocol::AgentSource source) {
  switch (source) {
    case protocol::AgentSource::kClaude:
      return color(217, 119, 87);  // Claude terracotta
    case protocol::AgentSource::kCodex:
      return color(16, 163, 127);  // OpenAI green
    case protocol::AgentSource::kAutomatic:
      return color(124, 135, 130);
  }
  return color(124, 135, 130);
}

const char* stateLabel(const protocol::AgentRunState state) {
  switch (state) {
    case protocol::AgentRunState::kIdle:
      return "IDLE";
    case protocol::AgentRunState::kRunning:
      return "RUNNING";
    case protocol::AgentRunState::kWaitingAuthorization:
      return "AUTH";
    case protocol::AgentRunState::kWaitingReply:
      return "REPLY";
    case protocol::AgentRunState::kCompleted:
      return "DONE";
  }
  return "IDLE";
}

std::uint16_t stateColor(const protocol::AgentRunState state) {
  switch (state) {
    case protocol::AgentRunState::kIdle:
      return color(124, 135, 130);
    case protocol::AgentRunState::kRunning:
      return color(70, 245, 154);
    case protocol::AgentRunState::kWaitingAuthorization:
      return color(255, 200, 87);
    case protocol::AgentRunState::kWaitingReply:
      return color(88, 166, 255);
    case protocol::AgentRunState::kCompleted:
      return color(167, 243, 208);
  }
  return TFT_WHITE;
}

void drawText(const char* text, const std::int32_t x, const std::int32_t y,
              const std::uint8_t size, const std::uint16_t foreground,
              const textdatum_t datum = top_left) {
  M5.Display.setTextDatum(datum);
  M5.Display.setTextSize(size);
  M5.Display.setTextColor(foreground, TFT_BLACK);
  M5.Display.drawString(text, x, y);
}

void drawTitle(const char* text) {
  M5.Display.setFont(&fonts::efontCN_16_b);
  M5.Display.setTextDatum(top_left);
  M5.Display.setTextSize(1);
  M5.Display.setTextColor(color(242, 245, 243), TFT_BLACK);
  M5.Display.drawString(text, 16, 43);
  M5.Display.setFont(&fonts::Font0);
}

void formatResetCountdown(char* text, const std::size_t textSize,
                          const std::uint16_t minutes,
                          const bool weekly) {
  if (minutes == protocol::kUnknownResetMinutes) {
    std::snprintf(text, textSize, "--");
    return;
  }
  if (weekly && minutes >= 24U * 60U) {
    const auto days = minutes / (24U * 60U);
    const auto hours = (minutes % (24U * 60U)) / 60U;
    std::snprintf(text, textSize, "%uD%uH", days, hours);
    return;
  }
  if (minutes < 60U) {
    std::snprintf(text, textSize, "%um", minutes);
    return;
  }
  const auto hours = minutes / 60U;
  const auto remainingMinutes = minutes % 60U;
  std::snprintf(text, textSize, "%uH%um", hours, remainingMinutes);
}

void drawMetric(const char* label, const std::uint8_t value,
                const std::uint16_t resetMinutes, const bool weekly,
                const std::int32_t x, const std::int32_t width,
                const std::uint16_t barColor) {
  char text[12];
  if (value == protocol::kUnknownMetricValue) {
    std::snprintf(text, sizeof(text), "%s --", label);
  } else {
    std::snprintf(text, sizeof(text), "%s %u%%", label, value);
  }
  drawText(text, x, 158, 2, color(242, 245, 243));
  M5.Display.fillRect(x, 178, width, 6, color(23, 49, 40));
  if (value != protocol::kUnknownMetricValue) {
    M5.Display.fillRect(x, 178, static_cast<std::int32_t>(value) * width / 100,
                        6, barColor);
  }
  if (resetMinutes == protocol::kUnknownResetMinutes &&
      std::strcmp(label, "CTX") == 0) {
    std::snprintf(text, sizeof(text), "SESSION");
  } else {
    formatResetCountdown(text, sizeof(text), resetMinutes, weekly);
  }
  drawText(text, x, 190, 2, color(124, 135, 130));
}

}  // namespace

void DisplayRenderer::begin() {
  auto config = M5.config();
  config.output_power = false;
  config.internal_imu = false;
  config.internal_mic = false;
  config.internal_spk = false;
  M5.begin(config);
  M5.Display.setRotation(1);
  M5.Display.setBrightness(96);
  M5.Display.fillScreen(TFT_BLACK);
}

void DisplayRenderer::render(const app::CompanionState& state) {
  if (!state.isDisplayAwake()) {
    if (displayAwake_) {
      M5.Display.sleep();
      displayAwake_ = false;
      lastSignature_.clear();
    }
    return;
  }

  if (!displayAwake_) {
    M5.Display.wakeup();
    displayAwake_ = true;
    lastSignature_.clear();
  }

  const auto& status = state.status();
  const bool alertState =
      state.hasFreshStatus() &&
      (status.state == protocol::AgentRunState::kWaitingAuthorization ||
       status.state == protocol::AgentRunState::kWaitingReply);
  const bool alertTextVisible = !alertState || (millis() / 500) % 2 == 0;
  char signature[256];
  std::snprintf(
      signature, sizeof(signature),
      "%u|%u|%u|%u|%u|%u|%u|%u|%u|%u|%u|%u|%u|%u|%u|%s|%s|%s",
      state.isConnected(), state.hasFreshStatus(),
      static_cast<unsigned>(status.source),
      static_cast<unsigned>(status.state), status.fiveHourRemaining,
      status.weeklyRemaining, status.contextUsed, state.batteryLevel(),
      state.isExternalPowerConnected(), state.isBatteryCharging(),
      status.displayTimeoutOnBatteryMinutes,
      status.displayTimeoutOnExternalPowerMinutes, status.fiveHourResetMinutes,
      status.weeklyResetMinutes, alertTextVisible, status.title,
      status.modelName, status.effort);
  if (lastSignature_ == signature) {
    return;
  }
  lastSignature_ = signature;

  M5.Display.fillScreen(TFT_BLACK);
  const std::uint16_t primary = color(242, 245, 243);
  const std::uint16_t muted = color(124, 135, 130);
  const std::uint16_t grid = color(23, 49, 40);

  const char* agent = state.hasFreshStatus() ? sourceLabel(status.source)
                                             : "AGENT";
  const std::uint16_t agentColor =
      state.hasFreshStatus() ? sourceColor(status.source) : muted;
  drawText(agent, 16, 11, 2, agentColor);
  char battery[12];
  if (state.batteryLevel() == protocol::kUnknownMetricValue) {
    std::snprintf(battery, sizeof(battery), "BAT --");
  } else {
    std::snprintf(battery, sizeof(battery), "BAT %u%%", state.batteryLevel());
  }
  drawText(battery, 304, 11, 2,
           state.isBatteryCharging() ? color(70, 245, 154) : primary,
           top_right);
  M5.Display.drawFastHLine(16, 34, 288, grid);

  const char* title = state.hasFreshStatus() && status.title[0] != '\0'
                          ? status.title
                          : "NO ACTIVE SESSION";
  drawTitle(title);

  protocol::AgentRunState displayedState = protocol::AgentRunState::kIdle;
  if (state.hasFreshStatus()) {
    displayedState = status.state;
  }
  const std::uint16_t accent = state.hasFreshStatus()
                                   ? stateColor(displayedState)
                                   : muted;
  M5.Display.fillRect(16, 76, 8, 50, accent);
  if (alertTextVisible) {
    drawText(stateLabel(displayedState), 40, 80, 5, accent);
  }

  M5.Display.drawFastHLine(16, 144, 288, grid);
  const bool hideFiveHour =
      state.hasFreshStatus() && status.source == protocol::AgentSource::kCodex &&
      status.fiveHourRemaining == protocol::kUnknownMetricValue;
  if (hideFiveHour) {
    drawMetric("WK", status.weeklyRemaining, status.weeklyResetMinutes, true,
               16, 136, color(70, 245, 154));
    drawMetric("CTX", status.contextUsed, protocol::kUnknownResetMinutes,
               false, 168, 136, color(255, 200, 87));
  } else {
    drawMetric("5H", state.hasFreshStatus() ? status.fiveHourRemaining
                                             : protocol::kUnknownMetricValue,
               state.hasFreshStatus() ? status.fiveHourResetMinutes
                                      : protocol::kUnknownResetMinutes,
               false, 16, 86, color(70, 245, 154));
    drawMetric("WK", state.hasFreshStatus() ? status.weeklyRemaining
                                             : protocol::kUnknownMetricValue,
               state.hasFreshStatus() ? status.weeklyResetMinutes
                                      : protocol::kUnknownResetMinutes,
               true, 117, 86, color(70, 245, 154));
    drawMetric("CTX", state.hasFreshStatus() ? status.contextUsed
                                              : protocol::kUnknownMetricValue,
               protocol::kUnknownResetMinutes, false, 218, 86,
               color(255, 200, 87));
  }

  const char* modelName = state.hasFreshStatus() && status.modelName[0] != '\0'
                              ? status.modelName
                              : "MODEL --";
  char effort[16];
  if (state.hasFreshStatus() && status.effort[0] != '\0') {
    std::snprintf(effort, sizeof(effort), "EFF %s", status.effort);
  } else {
    std::snprintf(effort, sizeof(effort), "EFF --");
  }
  drawText(modelName, 16, 218, 2, primary);
  drawText(effort, 304, 218, 2, muted, top_right);
}

}  // namespace renderer
}  // namespace companion

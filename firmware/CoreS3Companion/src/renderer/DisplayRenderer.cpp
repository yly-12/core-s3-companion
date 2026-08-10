#include "DisplayRenderer.h"

#include <M5Unified.h>

#include <cstdio>
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

const char* stateLabel(const protocol::AgentRunState state) {
  switch (state) {
    case protocol::AgentRunState::kIdle:
      return "IDLE";
    case protocol::AgentRunState::kRunning:
      return "RUN";
    case protocol::AgentRunState::kWaitingAuthorization:
      return "AUTH";
    case protocol::AgentRunState::kWaitingReply:
      return "REPLY";
    case protocol::AgentRunState::kCompleted:
      return "DONE";
  }
  return "IDLE";
}

const char* stateDetail(const protocol::AgentRunState state) {
  switch (state) {
    case protocol::AgentRunState::kIdle:
      return "READY";
    case protocol::AgentRunState::kRunning:
      return "WORKING";
    case protocol::AgentRunState::kWaitingAuthorization:
      return "ALLOW?";
    case protocol::AgentRunState::kWaitingReply:
      return "USER";
    case protocol::AgentRunState::kCompleted:
      return "100%";
  }
  return "READY";
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

void drawMetric(const char* label, const std::uint8_t value,
                const std::int32_t x, const std::int32_t width,
                const std::uint16_t barColor) {
  char text[12];
  if (value == protocol::kUnknownMetricValue) {
    std::snprintf(text, sizeof(text), "%s --", label);
  } else {
    std::snprintf(text, sizeof(text), "%s %u", label, value);
  }
  drawText(text, x, 158, 2, color(242, 245, 243));
  M5.Display.fillRect(x, 181, width, 6, color(23, 49, 40));
  if (value != protocol::kUnknownMetricValue) {
    M5.Display.fillRect(x, 181, static_cast<std::int32_t>(value) * width / 100,
                        6, barColor);
  }
}

}  // namespace

void DisplayRenderer::begin() {
  const auto config = M5.config();
  M5.begin(config);
  M5.Display.setRotation(1);
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
      signature, sizeof(signature), "%u|%u|%u|%u|%u|%u|%u|%u|%u|%s|%s|%s",
      state.isConnected(), state.hasFreshStatus(),
      static_cast<unsigned>(status.source),
      static_cast<unsigned>(status.state), status.fiveHourRemaining,
      status.weeklyRemaining, status.contextUsed, state.batteryLevel(),
      alertTextVisible, status.title, status.modelName, status.effort);
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
  drawText(agent, 16, 11, 2, muted);
  char battery[12];
  if (state.batteryLevel() == protocol::kUnknownMetricValue) {
    std::snprintf(battery, sizeof(battery), "BAT --");
  } else {
    std::snprintf(battery, sizeof(battery), "BAT %u", state.batteryLevel());
  }
  drawText(battery, 304, 11, 2, primary, top_right);
  M5.Display.drawFastHLine(16, 34, 288, grid);

  const char* title = state.hasFreshStatus() && status.title[0] != '\0'
                          ? status.title
                          : "NO ACTIVE SESSION";
  drawTitle(title);

  protocol::AgentRunState displayedState = protocol::AgentRunState::kIdle;
  const char* detail = state.isConnected() ? "WAIT DATA" : "OFFLINE";
  if (state.hasFreshStatus()) {
    displayedState = status.state;
    detail = stateDetail(displayedState);
  }
  const std::uint16_t accent = state.hasFreshStatus()
                                   ? stateColor(displayedState)
                                   : muted;
  M5.Display.fillRect(16, 76, 8, 50, accent);
  if (alertTextVisible) {
    drawText(stateLabel(displayedState), 40, 80, 5, accent);
    drawText(detail, 300, 103, 2, accent, top_right);
  }

  M5.Display.drawFastHLine(16, 144, 288, grid);
  const bool hideFiveHour =
      state.hasFreshStatus() && status.source == protocol::AgentSource::kCodex &&
      status.fiveHourRemaining == protocol::kUnknownMetricValue;
  if (hideFiveHour) {
    drawMetric("WK", status.weeklyRemaining, 16, 136, color(70, 245, 154));
    drawMetric("CTX", status.contextUsed, 168, 136, color(255, 200, 87));
  } else {
    drawMetric("5H", state.hasFreshStatus() ? status.fiveHourRemaining
                                             : protocol::kUnknownMetricValue,
               16, 86, color(70, 245, 154));
    drawMetric("WK", state.hasFreshStatus() ? status.weeklyRemaining
                                             : protocol::kUnknownMetricValue,
               117, 86, color(70, 245, 154));
    drawMetric("CTX", state.hasFreshStatus() ? status.contextUsed
                                              : protocol::kUnknownMetricValue,
               218, 86, color(255, 200, 87));
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
  drawText(modelName, 16, 207, 2, primary);
  drawText(effort, 304, 207, 2, muted, top_right);
}

}  // namespace renderer
}  // namespace companion

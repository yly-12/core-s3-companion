#include "DisplayRenderer.h"

#include <M5Unified.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "protocol/AgentStatusMessage.h"

namespace companion {
namespace renderer {

namespace {

constexpr std::int32_t kScreenWidth = 320;

bool updateSignature(std::string& previous, const char* current) {
  if (previous == current) {
    return false;
  }
  previous = current;
  return true;
}

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
      clearSignatures();
    }
    return;
  }

  if (!displayAwake_) {
    M5.Display.wakeup();
    displayAwake_ = true;
    clearSignatures();
  }

  const auto& status = state.status();
  const bool hasFreshStatus = state.hasFreshStatus();
  const protocol::AgentSource displayedSource =
      hasFreshStatus ? status.source : protocol::AgentSource::kAutomatic;
  const protocol::AgentRunState displayedState =
      hasFreshStatus ? status.state : protocol::AgentRunState::kIdle;
  const std::uint8_t fiveHourRemaining =
      hasFreshStatus ? status.fiveHourRemaining
                     : protocol::kUnknownMetricValue;
  const std::uint8_t weeklyRemaining =
      hasFreshStatus ? status.weeklyRemaining
                     : protocol::kUnknownMetricValue;
  const std::uint8_t contextUsed =
      hasFreshStatus ? status.contextUsed : protocol::kUnknownMetricValue;
  const std::uint16_t fiveHourResetMinutes =
      hasFreshStatus ? status.fiveHourResetMinutes
                     : protocol::kUnknownResetMinutes;
  const std::uint16_t weeklyResetMinutes =
      hasFreshStatus ? status.weeklyResetMinutes
                     : protocol::kUnknownResetMinutes;
  const char* title = hasFreshStatus && status.title[0] != '\0'
                          ? status.title
                          : "NO ACTIVE SESSION";
  const char* modelName = hasFreshStatus && status.modelName[0] != '\0'
                              ? status.modelName
                              : "MODEL --";
  const char* effortValue =
      hasFreshStatus && status.effort[0] != '\0' ? status.effort : "--";

  char signature[256];
  std::snprintf(
      signature, sizeof(signature), "%u|%u|%u|%u",
      static_cast<unsigned>(displayedSource), state.batteryLevel(),
      state.isBatteryCharging(), hasFreshStatus);
  const bool headerDirty = updateSignature(headerSignature_, signature);

  std::snprintf(signature, sizeof(signature), "%u|%s", hasFreshStatus, title);
  const bool titleDirty = updateSignature(titleSignature_, signature);

  std::snprintf(signature, sizeof(signature), "%u|%u", hasFreshStatus,
                static_cast<unsigned>(displayedState));
  const bool stateDirty = updateSignature(stateSignature_, signature);

  std::snprintf(
      signature, sizeof(signature), "%u|%u|%u|%u|%u|%u|%u",
      hasFreshStatus, static_cast<unsigned>(displayedSource),
      fiveHourRemaining, weeklyRemaining, contextUsed,
      fiveHourResetMinutes, weeklyResetMinutes);
  const bool metricsDirty = updateSignature(metricsSignature_, signature);

  std::snprintf(signature, sizeof(signature), "%u|%s|%s", hasFreshStatus,
                modelName, effortValue);
  const bool footerDirty = updateSignature(footerSignature_, signature);

  if (!headerDirty && !titleDirty && !stateDirty && !metricsDirty &&
      !footerDirty) {
    return;
  }

  const std::uint16_t primary = color(242, 245, 243);
  const std::uint16_t muted = color(124, 135, 130);
  const std::uint16_t grid = color(23, 49, 40);
  M5.Display.startWrite();

  if (headerDirty) {
    M5.Display.fillRect(0, 0, kScreenWidth, 35, TFT_BLACK);
    const char* agent =
        hasFreshStatus ? sourceLabel(displayedSource) : "AGENT";
    const std::uint16_t agentColor =
        hasFreshStatus ? sourceColor(displayedSource) : muted;
    drawText(agent, 16, 11, 2, agentColor);
    char battery[12];
    if (state.batteryLevel() == protocol::kUnknownMetricValue) {
      std::snprintf(battery, sizeof(battery), "BAT --");
    } else {
      std::snprintf(battery, sizeof(battery), "BAT %u%%",
                    state.batteryLevel());
    }
    drawText(battery, 304, 11, 2,
             state.isBatteryCharging() ? color(70, 245, 154) : primary,
             top_right);
    M5.Display.drawFastHLine(16, 34, 288, grid);
  }

  if (titleDirty) {
    M5.Display.fillRect(0, 35, kScreenWidth, 41, TFT_BLACK);
    drawTitle(title);
  }

  if (stateDirty) {
    M5.Display.fillRect(0, 76, kScreenWidth, 68, TFT_BLACK);
    const std::uint16_t accent =
        hasFreshStatus ? stateColor(displayedState) : muted;
    M5.Display.fillRect(16, 76, 8, 50, accent);
    drawText(stateLabel(displayedState), 40, 80, 5, accent);
  }

  if (metricsDirty) {
    M5.Display.fillRect(0, 144, kScreenWidth, 71, TFT_BLACK);
    M5.Display.drawFastHLine(16, 144, 288, grid);
    const bool hideFiveHour =
        hasFreshStatus && displayedSource == protocol::AgentSource::kCodex &&
        fiveHourRemaining == protocol::kUnknownMetricValue;
    if (hideFiveHour) {
      drawMetric("WK", weeklyRemaining, weeklyResetMinutes, true, 16, 136,
                 color(70, 245, 154));
      drawMetric("CTX", contextUsed, protocol::kUnknownResetMinutes, false, 168,
                 136, color(255, 200, 87));
    } else {
      drawMetric("5H", fiveHourRemaining, fiveHourResetMinutes, false, 16, 86,
                 color(70, 245, 154));
      drawMetric("WK", weeklyRemaining, weeklyResetMinutes, true, 117, 86,
                 color(70, 245, 154));
      drawMetric("CTX", contextUsed, protocol::kUnknownResetMinutes, false, 218,
                 86, color(255, 200, 87));
    }
  }

  if (footerDirty) {
    M5.Display.fillRect(0, 215, kScreenWidth, 25, TFT_BLACK);
    char effort[16];
    std::snprintf(effort, sizeof(effort), "EFF %s", effortValue);
    drawText(modelName, 16, 218, 2, primary);
    drawText(effort, 304, 218, 2, muted, top_right);
  }

  M5.Display.endWrite();
}

void DisplayRenderer::clearSignatures() {
  headerSignature_.clear();
  titleSignature_.clear();
  stateSignature_.clear();
  metricsSignature_.clear();
  footerSignature_.clear();
}

}  // namespace renderer
}  // namespace companion

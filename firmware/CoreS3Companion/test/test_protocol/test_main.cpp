#include <unity.h>

#include <cstdint>
#include <cstring>
#include <vector>

#include "app/CompanionState.h"
#include "protocol/AgentStatusMessage.h"
#include "protocol/CpuMessage.h"

using companion::protocol::AgentParseResult;
using companion::protocol::ParseResult;

void testParsesLegacyCpuUsage() {
  const std::uint8_t frame[] = {0x01, 0x01, 42};
  std::uint8_t cpuUsage = 0;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(ParseResult::kOk),
      static_cast<int>(companion::protocol::parseCpuUsage(frame, 3, cpuUsage)));
  TEST_ASSERT_EQUAL_UINT8(42, cpuUsage);
}

void testParsesAgentStatus() {
  const std::uint8_t frame[] = {
      0x01, 0x02, 0x02, 0x01, 68, 42, 61, 11,
      'F',  'I',  'R',  'M',  'W', 'A', 'R', 'E', ' ', 'C', 'I'};
  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kOk),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame, sizeof(frame), message)));
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(companion::protocol::AgentRunState::kWaitingAuthorization),
      static_cast<int>(message.state));
  TEST_ASSERT_EQUAL_UINT8(68, message.fiveHourRemaining);
  TEST_ASSERT_EQUAL_UINT8(42, message.weeklyRemaining);
  TEST_ASSERT_EQUAL_UINT8(61, message.contextUsed);
  TEST_ASSERT_EQUAL_STRING("FIRMWARE CI", message.title);
  TEST_ASSERT_EQUAL_STRING("", message.modelName);
  TEST_ASSERT_EQUAL_STRING("", message.effort);
}

void testParsesExtendedAgentStatus() {
  const char* title = "STATUS UI";
  const char* model = "GPT-5.6-SOL";
  const char* effort = "HIGH";
  std::vector<std::uint8_t> frame = {
      0x01, 0x02, 0x01, 0x02, 0xFF, 70, 45,
      static_cast<std::uint8_t>(std::strlen(title))};
  frame.insert(frame.end(), title, title + std::strlen(title));
  frame.push_back(static_cast<std::uint8_t>(std::strlen(model)));
  frame.push_back(static_cast<std::uint8_t>(std::strlen(effort)));
  frame.insert(frame.end(), model, model + std::strlen(model));
  frame.insert(frame.end(), effort, effort + std::strlen(effort));
  frame.push_back(5);
  frame.push_back(0x12);
  frame.push_back(0x34);
  frame.push_back(0x56);
  frame.push_back(0x78);

  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kOk),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame.data(), frame.size(), message)));
  TEST_ASSERT_EQUAL_STRING(title, message.title);
  TEST_ASSERT_EQUAL_STRING(model, message.modelName);
  TEST_ASSERT_EQUAL_STRING(effort, message.effort);
  TEST_ASSERT_EQUAL_UINT8(5, message.displayTimeoutOnBatteryMinutes);
  TEST_ASSERT_EQUAL_UINT8(5, message.displayTimeoutOnExternalPowerMinutes);
  TEST_ASSERT_EQUAL_UINT32(0x12345678, message.activityToken);
}

void testParsesPowerAwareDisplaySettingsAndResetCountdowns() {
  const std::uint8_t frame[] = {
      0x01, 0x02, 0x01, 0x01, 68,   42,   61,   0x00, 0x00,
      0x00, 5,    0,    0x12, 0x34, 0x56, 0x78, 0x00, 0x86,
      0x12, 0xC0};
  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kOk),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame, sizeof(frame), message)));
  TEST_ASSERT_EQUAL_UINT8(5, message.displayTimeoutOnBatteryMinutes);
  TEST_ASSERT_EQUAL_UINT8(0, message.displayTimeoutOnExternalPowerMinutes);
  TEST_ASSERT_EQUAL_UINT32(0x12345678, message.activityToken);
  TEST_ASSERT_EQUAL_UINT16(134, message.fiveHourResetMinutes);
  TEST_ASSERT_EQUAL_UINT16(4800, message.weeklyResetMinutes);
}

void testAgentStatusRejectsInvalidDisplayTimeout() {
  const std::uint8_t frame[] = {0x01, 0x02, 0x00, 0x01, 0xFF,
                                0xFF, 0xFF, 0x00, 0x00, 0x00,
                                31,   0x00, 0x00, 0x00, 0x01};
  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kInvalidDisplayTimeout),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame, sizeof(frame), message)));
}

void testAgentStatusAcceptsUnknownMetrics() {
  const std::uint8_t frame[] = {0x01, 0x02, 0x00, 0x02, 0xFF,
                                0xFF, 0xFF, 0x00};
  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kOk),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame, sizeof(frame), message)));
}

void testAgentStatusAcceptsChineseUtf8Title() {
  const char* title = u8"修复蓝牙";
  const std::size_t titleLength = std::strlen(title);
  std::vector<std::uint8_t> frame = {0x01, 0x02, 0x01, 0x01,
                                     80,   70,   25,
                                     static_cast<std::uint8_t>(titleLength)};
  frame.insert(frame.end(), title, title + titleLength);
  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kOk),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame.data(), frame.size(), message)));
  TEST_ASSERT_EQUAL_STRING(title, message.title);
}

void testAgentStatusRejectsInvalidUtf8Title() {
  const std::uint8_t frame[] = {0x01, 0x02, 0x01, 0x01, 50,
                                50,   50,   0x02, 0xE4, 0xB8};
  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kInvalidTitle),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame, sizeof(frame), message)));
}

void testAgentStatusRejectsInvalidLength() {
  const std::uint8_t frame[] = {0x01, 0x02, 0x01, 0x01, 50,
                                50,   50,   0x02, 'A'};
  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kInvalidLength),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame, sizeof(frame), message)));
}

void testAgentStatusRejectsInvalidState() {
  const std::uint8_t frame[] = {0x01, 0x02, 0x05, 0x01,
                                50,   50,   50,   0x00};
  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kInvalidState),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame, sizeof(frame), message)));
}

void testAgentStatusRejectsInvalidMetric() {
  const std::uint8_t frame[] = {0x01, 0x02, 0x01, 0x01,
                                101,  50,   50,   0x00};
  companion::protocol::AgentStatusMessage message;
  TEST_ASSERT_EQUAL_INT(
      static_cast<int>(AgentParseResult::kMetricOutOfRange),
      static_cast<int>(companion::protocol::parseAgentStatus(
          frame, sizeof(frame), message)));
}

void testAgentStatusBecomesStaleAfterTwentySeconds() {
  companion::app::CompanionState state;
  companion::protocol::AgentStatusMessage message;
  message.state = companion::protocol::AgentRunState::kRunning;
  std::strcpy(message.title, "STATUS UI");
  state.setConnected(true);
  state.setAgentStatus(message, 1000);

  state.update(20999);
  TEST_ASSERT_TRUE(state.hasFreshStatus());
  TEST_ASSERT_EQUAL_STRING("STATUS UI", state.status().title);

  state.update(21000);
  TEST_ASSERT_FALSE(state.hasFreshStatus());
}

void testDisconnectImmediatelyHidesAgentStatus() {
  companion::app::CompanionState state;
  companion::protocol::AgentStatusMessage message;
  state.setConnected(true);
  state.setAgentStatus(message, 1000);
  state.setConnected(false);
  TEST_ASSERT_FALSE(state.hasFreshStatus());
}

void testDisplaySleepsAfterConfiguredInactivity() {
  companion::app::CompanionState state;
  companion::protocol::AgentStatusMessage message;
  message.displayTimeoutOnBatteryMinutes = 1;
  message.activityToken = 100;
  state.setConnected(true);
  state.setAgentStatus(message, 1000);

  state.update(60999);
  TEST_ASSERT_TRUE(state.isDisplayAwake());
  state.update(61000);
  TEST_ASSERT_FALSE(state.isDisplayAwake());
}

void testRepeatedStatusDoesNotPostponeDisplaySleep() {
  companion::app::CompanionState state;
  companion::protocol::AgentStatusMessage message;
  message.displayTimeoutOnBatteryMinutes = 1;
  message.activityToken = 100;
  state.setConnected(true);
  state.setAgentStatus(message, 1000);
  state.setAgentStatus(message, 50000);

  state.update(61000);
  TEST_ASSERT_FALSE(state.isDisplayAwake());
}

void testNewMessageAndTouchWakeDisplay() {
  companion::app::CompanionState state;
  companion::protocol::AgentStatusMessage message;
  message.displayTimeoutOnBatteryMinutes = 1;
  message.activityToken = 100;
  state.setConnected(true);
  state.setAgentStatus(message, 1000);
  state.update(61000);
  TEST_ASSERT_FALSE(state.isDisplayAwake());

  message.activityToken = 101;
  state.setAgentStatus(message, 62000);
  TEST_ASSERT_TRUE(state.isDisplayAwake());
  state.update(122000);
  TEST_ASSERT_FALSE(state.isDisplayAwake());

  state.recordLocalActivity(123000);
  TEST_ASSERT_TRUE(state.isDisplayAwake());
  state.update(183000);
  TEST_ASSERT_FALSE(state.isDisplayAwake());
}

void testNeverSleepKeepsDisplayAwake() {
  companion::app::CompanionState state;
  companion::protocol::AgentStatusMessage message;
  message.displayTimeoutOnBatteryMinutes = 0;
  state.setConnected(true);
  state.setAgentStatus(message, 1000);

  state.update(0xFFFFFFFF);
  TEST_ASSERT_TRUE(state.isDisplayAwake());
}

void testPowerSourceSelectsDisplayTimeout() {
  companion::app::CompanionState state;
  companion::protocol::AgentStatusMessage message;
  message.displayTimeoutOnBatteryMinutes = 1;
  message.displayTimeoutOnExternalPowerMinutes = 0;
  state.setConnected(true);
  state.setAgentStatus(message, 1000);
  state.setPowerState(true, true, 1000);

  state.update(61000);
  TEST_ASSERT_TRUE(state.isExternalPowerConnected());
  TEST_ASSERT_TRUE(state.isBatteryCharging());
  TEST_ASSERT_TRUE(state.isDisplayAwake());

  state.setPowerState(false, false, 62000);
  state.update(121999);
  TEST_ASSERT_TRUE(state.isDisplayAwake());
  state.update(122000);
  TEST_ASSERT_FALSE(state.isExternalPowerConnected());
  TEST_ASSERT_FALSE(state.isBatteryCharging());
  TEST_ASSERT_FALSE(state.isDisplayAwake());
}

void testActiveSessionsKeepDisplayAwake() {
  const companion::protocol::AgentRunState activeStates[] = {
      companion::protocol::AgentRunState::kRunning,
      companion::protocol::AgentRunState::kWaitingAuthorization,
      companion::protocol::AgentRunState::kWaitingReply,
  };

  for (const auto activeState : activeStates) {
    companion::app::CompanionState state;
    companion::protocol::AgentStatusMessage message;
    message.displayTimeoutOnBatteryMinutes = 1;
    message.activityToken = 100;
    message.state = activeState;
    state.setConnected(true);
    state.setAgentStatus(message, 1000);
    state.setAgentStatus(message, 60999);
    state.update(61000);

    TEST_ASSERT_TRUE(state.hasActiveSession());
    TEST_ASSERT_TRUE(state.isDisplayAwake());
  }
}

void testIdleSessionSleepsAfterTimerExpires() {
  companion::app::CompanionState state;
  companion::protocol::AgentStatusMessage message;
  message.displayTimeoutOnBatteryMinutes = 1;
  message.activityToken = 100;
  message.state = companion::protocol::AgentRunState::kRunning;
  state.setConnected(true);
  state.setAgentStatus(message, 1000);
  state.setAgentStatus(message, 61000);
  state.update(61000);
  TEST_ASSERT_TRUE(state.isDisplayAwake());

  message.state = companion::protocol::AgentRunState::kIdle;
  message.activityToken = 101;
  state.setAgentStatus(message, 62000);
  state.update(121999);
  TEST_ASSERT_TRUE(state.isDisplayAwake());
  state.update(122000);
  TEST_ASSERT_FALSE(state.hasActiveSession());
  TEST_ASSERT_FALSE(state.isDisplayAwake());
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(testParsesLegacyCpuUsage);
  RUN_TEST(testParsesAgentStatus);
  RUN_TEST(testParsesExtendedAgentStatus);
  RUN_TEST(testParsesPowerAwareDisplaySettingsAndResetCountdowns);
  RUN_TEST(testAgentStatusRejectsInvalidDisplayTimeout);
  RUN_TEST(testAgentStatusAcceptsUnknownMetrics);
  RUN_TEST(testAgentStatusAcceptsChineseUtf8Title);
  RUN_TEST(testAgentStatusRejectsInvalidUtf8Title);
  RUN_TEST(testAgentStatusRejectsInvalidLength);
  RUN_TEST(testAgentStatusRejectsInvalidState);
  RUN_TEST(testAgentStatusRejectsInvalidMetric);
  RUN_TEST(testAgentStatusBecomesStaleAfterTwentySeconds);
  RUN_TEST(testDisconnectImmediatelyHidesAgentStatus);
  RUN_TEST(testDisplaySleepsAfterConfiguredInactivity);
  RUN_TEST(testRepeatedStatusDoesNotPostponeDisplaySleep);
  RUN_TEST(testNewMessageAndTouchWakeDisplay);
  RUN_TEST(testNeverSleepKeepsDisplayAwake);
  RUN_TEST(testPowerSourceSelectsDisplayTimeout);
  RUN_TEST(testActiveSessionsKeepDisplayAwake);
  RUN_TEST(testIdleSessionSleepsAfterTimerExpires);
  return UNITY_END();
}

#pragma once

#include <cstddef>
#include <cstdint>

namespace companion {
namespace protocol {

constexpr std::uint8_t kAgentStatusMessageType = 0x02;
constexpr std::size_t kAgentStatusHeaderSize = 8;
constexpr std::size_t kMaximumTitleLength = 60;
constexpr std::uint8_t kUnknownMetricValue = 0xFF;

enum class AgentRunState : std::uint8_t {
  kIdle = 0,
  kRunning = 1,
  kWaitingAuthorization = 2,
  kWaitingReply = 3,
  kCompleted = 4,
};

enum class AgentSource : std::uint8_t {
  kAutomatic = 0,
  kClaude = 1,
  kCodex = 2,
};

struct AgentStatusMessage {
  AgentRunState state = AgentRunState::kIdle;
  AgentSource source = AgentSource::kAutomatic;
  std::uint8_t fiveHourRemaining = kUnknownMetricValue;
  std::uint8_t weeklyRemaining = kUnknownMetricValue;
  std::uint8_t contextUsed = kUnknownMetricValue;
  char title[kMaximumTitleLength + 1] = {};
};

enum class AgentParseResult {
  kOk,
  kInvalidLength,
  kUnsupportedVersion,
  kUnsupportedType,
  kInvalidState,
  kInvalidSource,
  kMetricOutOfRange,
  kInvalidTitle,
};

AgentParseResult parseAgentStatus(const std::uint8_t* data, std::size_t length,
                                  AgentStatusMessage& message);

const char* agentParseResultName(AgentParseResult result);

}  // namespace protocol
}  // namespace companion

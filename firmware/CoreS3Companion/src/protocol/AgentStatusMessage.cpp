#include "AgentStatusMessage.h"

#include <cstring>

#include "CpuMessage.h"

namespace companion {
namespace protocol {

namespace {

bool validMetric(const std::uint8_t value) {
  return value <= 100 || value == kUnknownMetricValue;
}

bool validUtf8Title(const std::uint8_t* data, const std::size_t length) {
  std::size_t index = 0;
  while (index < length) {
    const std::uint8_t first = data[index];
    if (first < 0x80) {
      if (first < 0x20 || first == 0x7F) {
        return false;
      }
      ++index;
      continue;
    }

    std::size_t continuationCount = 0;
    std::uint32_t codePoint = 0;
    if (first >= 0xC2 && first <= 0xDF) {
      continuationCount = 1;
      codePoint = first & 0x1F;
    } else if (first >= 0xE0 && first <= 0xEF) {
      continuationCount = 2;
      codePoint = first & 0x0F;
    } else if (first >= 0xF0 && first <= 0xF4) {
      continuationCount = 3;
      codePoint = first & 0x07;
    } else {
      return false;
    }
    if (index + continuationCount >= length) {
      return false;
    }
    for (std::size_t offset = 1; offset <= continuationCount; ++offset) {
      const std::uint8_t byte = data[index + offset];
      if ((byte & 0xC0) != 0x80) {
        return false;
      }
      codePoint = (codePoint << 6) | (byte & 0x3F);
    }
    if ((continuationCount == 2 && codePoint < 0x800) ||
        (continuationCount == 3 && codePoint < 0x10000) ||
        (codePoint >= 0xD800 && codePoint <= 0xDFFF) ||
        codePoint > 0x10FFFF) {
      return false;
    }
    index += continuationCount + 1;
  }
  return true;
}

}  // namespace

AgentParseResult parseAgentStatus(const std::uint8_t* data,
                                  const std::size_t length,
                                  AgentStatusMessage& message) {
  if (data == nullptr || length < kAgentStatusHeaderSize) {
    return AgentParseResult::kInvalidLength;
  }
  if (data[0] != kProtocolVersion) {
    return AgentParseResult::kUnsupportedVersion;
  }
  if (data[1] != kAgentStatusMessageType) {
    return AgentParseResult::kUnsupportedType;
  }
  if (data[2] > static_cast<std::uint8_t>(AgentRunState::kCompleted)) {
    return AgentParseResult::kInvalidState;
  }
  if (data[3] > static_cast<std::uint8_t>(AgentSource::kCodex)) {
    return AgentParseResult::kInvalidSource;
  }
  if (!validMetric(data[4]) || !validMetric(data[5]) ||
      !validMetric(data[6])) {
    return AgentParseResult::kMetricOutOfRange;
  }

  const std::size_t titleLength = data[7];
  if (titleLength > kMaximumTitleLength ||
      length != kAgentStatusHeaderSize + titleLength) {
    return AgentParseResult::kInvalidLength;
  }
  if (!validUtf8Title(data + kAgentStatusHeaderSize, titleLength)) {
    return AgentParseResult::kInvalidTitle;
  }

  message.state = static_cast<AgentRunState>(data[2]);
  message.source = static_cast<AgentSource>(data[3]);
  message.fiveHourRemaining = data[4];
  message.weeklyRemaining = data[5];
  message.contextUsed = data[6];
  std::memset(message.title, 0, sizeof(message.title));
  if (titleLength > 0) {
    std::memcpy(message.title, data + kAgentStatusHeaderSize, titleLength);
  }
  return AgentParseResult::kOk;
}

const char* agentParseResultName(const AgentParseResult result) {
  switch (result) {
    case AgentParseResult::kOk:
      return "ok";
    case AgentParseResult::kInvalidLength:
      return "invalid length";
    case AgentParseResult::kUnsupportedVersion:
      return "unsupported version";
    case AgentParseResult::kUnsupportedType:
      return "unsupported type";
    case AgentParseResult::kInvalidState:
      return "invalid state";
    case AgentParseResult::kInvalidSource:
      return "invalid source";
    case AgentParseResult::kMetricOutOfRange:
      return "metric out of range";
    case AgentParseResult::kInvalidTitle:
      return "invalid title";
  }
  return "unknown error";
}

}  // namespace protocol
}  // namespace companion

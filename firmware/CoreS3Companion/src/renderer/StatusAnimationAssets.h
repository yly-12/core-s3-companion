#pragma once

#include <cstddef>
#include <cstdint>

#include "protocol/AgentStatusMessage.h"

namespace companion {
namespace renderer {

constexpr std::size_t kStatusAnimationFrameCount = 4;

struct StatusAnimationFrame {
  const std::uint8_t* data;
  std::size_t size;
};

struct StatusAnimation {
  StatusAnimationFrame frames[kStatusAnimationFrameCount];
  std::uint16_t frameDelayMs;
};

const StatusAnimation& statusAnimationFor(protocol::AgentRunState state);

}  // namespace renderer
}  // namespace companion

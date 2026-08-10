#pragma once

#include <cstddef>
#include <cstdint>

namespace companion {
namespace protocol {

constexpr std::uint8_t kProtocolVersion = 0x01;
constexpr std::uint8_t kCpuUsageMessageType = 0x01;
constexpr std::size_t kCpuMessageSize = 3;

enum class ParseResult {
  kOk,
  kInvalidLength,
  kUnsupportedVersion,
  kUnsupportedType,
  kValueOutOfRange,
};

ParseResult parseCpuUsage(const std::uint8_t* data, std::size_t length,
                          std::uint8_t& cpuUsage);

const char* parseResultName(ParseResult result);

}  // namespace protocol
}  // namespace companion

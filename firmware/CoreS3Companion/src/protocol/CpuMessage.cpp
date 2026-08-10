#include "CpuMessage.h"

namespace companion {
namespace protocol {

ParseResult parseCpuUsage(const std::uint8_t* data, const std::size_t length,
                          std::uint8_t& cpuUsage) {
  if (data == nullptr || length != kCpuMessageSize) {
    return ParseResult::kInvalidLength;
  }
  if (data[0] != kProtocolVersion) {
    return ParseResult::kUnsupportedVersion;
  }
  if (data[1] != kCpuUsageMessageType) {
    return ParseResult::kUnsupportedType;
  }
  if (data[2] > 100) {
    return ParseResult::kValueOutOfRange;
  }

  cpuUsage = data[2];
  return ParseResult::kOk;
}

const char* parseResultName(const ParseResult result) {
  switch (result) {
    case ParseResult::kOk:
      return "ok";
    case ParseResult::kInvalidLength:
      return "invalid length";
    case ParseResult::kUnsupportedVersion:
      return "unsupported version";
    case ParseResult::kUnsupportedType:
      return "unsupported type";
    case ParseResult::kValueOutOfRange:
      return "value out of range";
  }
  return "unknown error";
}

}  // namespace protocol
}  // namespace companion

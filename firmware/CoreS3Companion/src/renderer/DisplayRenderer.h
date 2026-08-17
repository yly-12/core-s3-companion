#pragma once

#include <cstdint>
#include <string>

#include "app/CompanionState.h"

namespace companion {
namespace renderer {

class DisplayRenderer {
 public:
  void begin();
  void render(const app::CompanionState& state);

 private:
  void clearSignatures();

  std::string headerSignature_;
  std::string titleSignature_;
  std::string stateSignature_;
  std::string metricsSignature_;
  std::string footerSignature_;
  bool displayAwake_ = true;
  std::uint8_t displayBrightness_ = 0;
};

}  // namespace renderer
}  // namespace companion

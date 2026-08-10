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
  std::string lastSignature_;
};

}  // namespace renderer
}  // namespace companion

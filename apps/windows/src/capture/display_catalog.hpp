#pragma once

#include "core/types.hpp"

#include <windows.h>
#include <optional>
#include <vector>

namespace doppelscreen {

class DisplayCatalog {
 public:
  struct Entry { DisplayInfo info; HMONITOR monitor{}; };

  static std::vector<Entry> enumerate();
  static std::optional<Entry> find(DisplayId id);
};

}  // namespace doppelscreen

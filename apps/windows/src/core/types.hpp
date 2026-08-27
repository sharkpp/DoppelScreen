#pragma once

#include <cstdint>
#include <string>

namespace doppelscreen {

using DisplayId = std::uint64_t;

struct DisplayInfo {
  DisplayId id{};
  std::string name;
  int width{};
  int height{};
  double scale{1.0};
  bool primary{};

  friend bool operator==(const DisplayInfo&, const DisplayInfo&) = default;
};

enum class QualityPreset { sharp, balanced, smooth };

struct QualitySettings {
  int max_framerate{};
  int max_bitrate_bps{};
  bool maintain_resolution{};

  friend bool operator==(const QualitySettings&, const QualitySettings&) = default;
};

}  // namespace doppelscreen

#include "core/video_encoding.hpp"

#include <algorithm>
#include <array>
#include <cmath>

namespace doppelscreen::video_encoding {
namespace {
constexpr int maximum_macroblocks = 36'864;
constexpr std::array resolution_steps{720, 1080, 1440, 2160};

int even(double value) {
  return std::max(2, static_cast<int>(value * 0.5) * 2);
}
}  // namespace

QualitySettings settings(QualityPreset preset) {
  switch (preset) {
    case QualityPreset::sharp:
      return {30, 20'000'000, true};
    case QualityPreset::balanced:
      return {60, 30'000'000, true};
    case QualityPreset::smooth:
      return {60, 40'000'000, false};
  }
  return {30, 20'000'000, true};
}

std::pair<int, int> encodable_size(int width, int height) {
  const auto macroblocks = ((width + 15) / 16) * ((height + 15) / 16);
  if (macroblocks <= maximum_macroblocks) return {width, height};
  const auto scale = std::sqrt(static_cast<double>(maximum_macroblocks) / macroblocks);
  return {even(width * scale), even(height * scale)};
}

std::pair<int, int> following_size(int display_width, int display_height,
                                   int viewport_width, int viewport_height) {
  const auto native = encodable_size(display_width, display_height);
  if (viewport_width <= 0 || viewport_height <= 0 || native.first <= 0 || native.second <= 0) {
    return native;
  }
  const auto scale = std::min(static_cast<double>(viewport_width) / native.first,
                              static_cast<double>(viewport_height) / native.second);
  const auto wanted_height = native.second * scale;
  for (const auto step : resolution_steps) {
    if (step >= wanted_height && step < native.second) {
      return {even(static_cast<double>(native.first) * step / native.second), step};
    }
  }
  return native;
}

}  // namespace doppelscreen::video_encoding

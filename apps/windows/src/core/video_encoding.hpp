#pragma once

#include "core/types.hpp"

#include <utility>

namespace doppelscreen::video_encoding {

inline constexpr int min_bitrate_bps = 5'000'000;

QualitySettings settings(QualityPreset preset);
std::pair<int, int> encodable_size(int width, int height);
std::pair<int, int> following_size(int display_width, int display_height,
                                   int viewport_width, int viewport_height);

}  // namespace doppelscreen::video_encoding

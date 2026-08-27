#include "core/video_encoding.hpp"

#include <catch2/catch_test_macros.hpp>

using namespace doppelscreen;

TEST_CASE("quality presets match the wire contract") {
  REQUIRE(video_encoding::settings(QualityPreset::sharp) == QualitySettings{30, 20'000'000, true});
  REQUIRE(video_encoding::settings(QualityPreset::balanced) == QualitySettings{60, 30'000'000, true});
  REQUIRE(video_encoding::settings(QualityPreset::smooth) == QualitySettings{60, 40'000'000, false});
}

TEST_CASE("viewport following uses stable resolution steps") {
  REQUIRE(video_encoding::following_size(2880, 1800, 1280, 720) == std::pair{1152, 720});
  REQUIRE(video_encoding::following_size(1920, 1080, 3840, 2160) == std::pair{1920, 1080});
}

TEST_CASE("H264 level limit is enforced") {
  const auto [width, height] = video_encoding::encodable_size(5120, 2880);
  REQUIRE(width < 5120);
  REQUIRE(height < 2880);
  REQUIRE(width % 2 == 0);
  REQUIRE(height % 2 == 0);
}

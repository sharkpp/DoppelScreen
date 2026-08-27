#include "core/protocol.hpp"

#include <catch2/catch_test_macros.hpp>

using namespace doppelscreen;

TEST_CASE("viewer hello is decoded") {
  const auto signal = protocol::decode_viewer_signal(R"({"t":"hello","token":"abc","display":7,"resume":"tick"})");
  REQUIRE(signal);
  const auto& hello = std::get<protocol::ViewerHello>(*signal);
  REQUIRE(hello.token == "abc");
  REQUIRE(hello.display == 7);
  REQUIRE(hello.resume == "tick");
}

TEST_CASE("unknown signaling is ignored") {
  REQUIRE_FALSE(protocol::decode_viewer_signal(R"({"t":"unknown"})"));
  REQUIRE_FALSE(protocol::decode_viewer_signal("{"));
  REQUIRE_FALSE(protocol::decode_viewer_signal(R"({"t":"hello"})"));
}

TEST_CASE("viewport and quality are decoded") {
  const auto viewport = protocol::decode_viewer_control(R"({"t":"viewport","w":2048,"h":1536,"dpr":2})");
  REQUIRE(viewport);
  REQUIRE(std::get<protocol::Viewport>(*viewport).width == 2048);
  const auto quality = protocol::decode_viewer_control(R"({"t":"quality","preset":"smooth"})");
  REQUIRE(quality);
  REQUIRE(std::get<protocol::Quality>(*quality).preset == QualityPreset::smooth);
  REQUIRE_FALSE(protocol::decode_viewer_control(R"({"t":"quality","preset":"crisp"})"));
}

TEST_CASE("errors use stable codes") {
  const auto text = protocol::encode_error("capture_stopped", "detail");
  REQUIRE(text.find("capture_stopped") != std::string::npos);
  REQUIRE(text.find("message") == std::string::npos);
}

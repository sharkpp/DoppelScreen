#include "core/protocol.hpp"

namespace doppelscreen::protocol {
namespace {
using json = nlohmann::json;

std::optional<json> parse(std::string_view text) {
  auto value = json::parse(text, nullptr, false);
  if (value.is_discarded() || !value.is_object()) return std::nullopt;
  return value;
}

std::optional<IceCandidate> candidate(const json& value) {
  if (!value.contains("candidate") || !value["candidate"].is_string()) return std::nullopt;
  IceCandidate result{value["candidate"].get<std::string>()};
  if (value.contains("sdpMid") && value["sdpMid"].is_string()) result.sdp_mid = value["sdpMid"].get<std::string>();
  if (value.contains("sdpMLineIndex") && value["sdpMLineIndex"].is_number_integer()) result.sdp_mline_index = value["sdpMLineIndex"].get<int>();
  return result;
}

json display_json(const DisplayInfo& display) {
  return {{"id", display.id}, {"name", display.name},
          {"w", display.width}, {"h", display.height}, {"scale", display.scale}};
}
}  // namespace

std::optional<ViewerSignal> decode_viewer_signal(std::string_view text) {
  const auto value = parse(text);
  if (!value || !value->contains("t") || !(*value)["t"].is_string()) return std::nullopt;
  const auto type = (*value)["t"].get<std::string>();
  if (type == "hello") {
    if (!value->contains("token") || !(*value)["token"].is_string()) return std::nullopt;
    ViewerHello hello{(*value)["token"].get<std::string>()};
    if (value->contains("display") && (*value)["display"].is_number_unsigned()) hello.display = (*value)["display"].get<DisplayId>();
    if (value->contains("resume") && (*value)["resume"].is_string()) hello.resume = (*value)["resume"].get<std::string>();
    return ViewerSignal{std::move(hello)};
  }
  if (type == "answer" && value->contains("sdp") && (*value)["sdp"].is_string()) return ViewerSignal{ViewerAnswer{(*value)["sdp"].get<std::string>()}};
  if (type == "candidate") if (auto decoded = candidate(*value)) return ViewerSignal{std::move(*decoded)};
  return std::nullopt;
}

std::optional<ViewerControl> decode_viewer_control(std::string_view text) {
  const auto value = parse(text);
  if (!value || !value->contains("t") || !(*value)["t"].is_string()) return std::nullopt;
  const auto type = (*value)["t"].get<std::string>();
  if (type == "viewport" && value->contains("w") && value->contains("h") &&
      (*value)["w"].is_number_integer() && (*value)["h"].is_number_integer()) {
    const auto width = (*value)["w"].get<int>();
    const auto height = (*value)["h"].get<int>();
    if (width <= 0 || height <= 0) return std::nullopt;
    const auto dpr = value->contains("dpr") && (*value)["dpr"].is_number() ? (*value)["dpr"].get<double>() : 1.0;
    return ViewerControl{Viewport{width, height, dpr}};
  }
  if (type == "quality" && value->contains("preset") && (*value)["preset"].is_string()) {
    const auto name = (*value)["preset"].get<std::string>();
    if (name == "sharp") return ViewerControl{Quality{QualityPreset::sharp}};
    if (name == "balanced") return ViewerControl{Quality{QualityPreset::balanced}};
    if (name == "smooth") return ViewerControl{Quality{QualityPreset::smooth}};
  }
  return std::nullopt;
}

std::string encode_offer(std::string_view sdp) { return json{{"t", "offer"}, {"sdp", sdp}}.dump(); }
std::string encode_candidate(const IceCandidate& value) {
  json result{{"t", "candidate"}, {"candidate", value.candidate}};
  result["sdpMid"] = value.sdp_mid ? json(*value.sdp_mid) : json(nullptr);
  result["sdpMLineIndex"] = value.sdp_mline_index ? json(*value.sdp_mline_index) : json(nullptr);
  return result.dump();
}
std::string encode_error(std::string_view code, std::optional<std::string_view> detail) {
  return json{{"t", "error"}, {"code", code}, {"detail", detail ? json(*detail) : json(nullptr)}}.dump();
}
std::string encode_hello(const DisplayInfo& display) { return json{{"t", "hello"}, {"platform", "windows"}, {"display", display_json(display)}}.dump(); }
std::string encode_display(const DisplayInfo& display) { auto result = display_json(display); result["t"] = "display"; return result.dump(); }
std::string encode_resume(std::string_view ticket, int ttl_ms) { return json{{"t", "resume"}, {"ticket", ticket}, {"ttlMs", ttl_ms}}.dump(); }
std::string encode_stats(double fps, double bitrate, double encode_ms) { return json{{"t", "stats"}, {"fps", fps}, {"bitrate", bitrate}, {"encodeMs", encode_ms}}.dump(); }

}  // namespace doppelscreen::protocol

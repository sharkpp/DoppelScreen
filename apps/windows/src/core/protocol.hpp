#pragma once

#include "core/types.hpp"

#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <variant>

namespace doppelscreen::protocol {

struct IceCandidate { std::string candidate; std::optional<std::string> sdp_mid; std::optional<int> sdp_mline_index; };
struct ViewerHello { std::string token; std::optional<DisplayId> display; std::optional<std::string> resume; };
struct ViewerAnswer { std::string sdp; };
using ViewerSignal = std::variant<ViewerHello, ViewerAnswer, IceCandidate>;

struct Viewport { int width; int height; double dpr; };
struct Quality { QualityPreset preset; };
using ViewerControl = std::variant<Viewport, Quality>;

std::optional<ViewerSignal> decode_viewer_signal(std::string_view text);
std::optional<ViewerControl> decode_viewer_control(std::string_view text);

std::string encode_offer(std::string_view sdp);
std::string encode_candidate(const IceCandidate& candidate);
std::string encode_error(std::string_view code, std::optional<std::string_view> detail = std::nullopt);
std::string encode_hello(const DisplayInfo& display);
std::string encode_display(const DisplayInfo& display);
std::string encode_resume(std::string_view ticket, int ttl_ms);
std::string encode_stats(double fps, double bitrate, double encode_ms);

}  // namespace doppelscreen::protocol

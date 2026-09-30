#include "app/host_bridge.hpp"

#include "generated/strings.hpp"

#include <windows.h>
#include <algorithm>

namespace doppelscreen {
namespace {

std::string narrow(std::wstring_view value) {
  if (value.empty()) return {};
  const auto size = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                                        nullptr, 0, nullptr, nullptr);
  std::string output(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), output.data(), size,
                      nullptr, nullptr);
  return output;
}

// Pigeon の任意項目はポインタで渡す。空文字列は「なし」
const std::string* optional(const std::string& value) { return value.empty() ? nullptr : &value; }

ui::ServerStatus convert(SessionController::ServerState state) {
  switch (state) {
    case SessionController::ServerState::idle: return ui::ServerStatus::kIdle;
    case SessionController::ServerState::starting: return ui::ServerStatus::kStarting;
    case SessionController::ServerState::running: return ui::ServerStatus::kRunning;
    case SessionController::ServerState::failed: return ui::ServerStatus::kFailed;
  }
  return ui::ServerStatus::kFailed;
}

ui::StreamStatus convert(SessionController::StreamState state) {
  switch (state) {
    case SessionController::StreamState::idle: return ui::StreamStatus::kIdle;
    case SessionController::StreamState::awaiting_approval: return ui::StreamStatus::kAwaitingApproval;
    case SessionController::StreamState::connecting: return ui::StreamStatus::kStarting;
    case SessionController::StreamState::streaming: return ui::StreamStatus::kStreaming;
    case SessionController::StreamState::failed: return ui::StreamStatus::kFailed;
  }
  return ui::StreamStatus::kFailed;
}

ui::StreamQuality convert(QualityPreset preset) {
  switch (preset) {
    case QualityPreset::sharp: return ui::StreamQuality::kSharp;
    case QualityPreset::balanced: return ui::StreamQuality::kBalanced;
    case QualityPreset::smooth: return ui::StreamQuality::kSmooth;
  }
  return ui::StreamQuality::kSharp;
}

// コアは失敗をコードで持つ（ビューアへもコードで送る。SPEC.md §7）。UI には表示言語の文言で渡す
std::string failure(std::string_view code, int language) {
  const auto text = [language](const std::array<std::wstring_view, 2>& value) {
    return narrow(value[std::clamp(language, 0, 1)]);
  };
  if (code == "capture_failed") return text(l10n::host_failure_captureFailed);
  if (code == "peer_failed") return text(l10n::host_failure_peerFailed);
  return std::string(code);
}

DisplayId display(int64_t id) { return static_cast<DisplayId>(id); }

}  // namespace

HostBridge::HostBridge(flutter::BinaryMessenger* messenger, SessionController& controller, int language)
    : messenger_(messenger), controller_(controller), events_(messenger), language_(language) {
  ui::HostUIControl::SetUp(messenger_, this);
}

HostBridge::~HostBridge() { ui::HostUIControl::SetUp(messenger_, nullptr); }

void HostBridge::publish() {
  // Dart がまだ購読していなければ届かない。起動直後の Dart は CurrentState で取りに来る
  events_.StateChanged(state(), [] {}, [](const ui::FlutterError&) {});
}

ui::HostState HostBridge::state() {
  const auto snapshot = controller_.snapshot();
  flutter::EncodableList streams;
  for (const auto& stream : snapshot.streams) {
    flutter::EncodableList endpoints;
    for (const auto& endpoint : snapshot.endpoints) {
      if (endpoint.display_id != stream.display.id) continue;
      endpoints.emplace_back(flutter::CustomEncodableValue(
          ui::EndpointState(narrow(endpoint.interface_name), endpoint.url, optional(endpoint.secure_url))));
    }
    const auto status = convert(stream.state);
    const auto peer = status == ui::StreamStatus::kIdle || status == ui::StreamStatus::kFailed
                          ? std::string() : stream.remote_address;
    const auto reason = status == ui::StreamStatus::kFailed ? failure(stream.error, language_) : std::string();
    // 実効解像度は配信中だけ出す
    const auto streaming = status == ui::StreamStatus::kStreaming;
    const int64_t width = stream.width;
    const int64_t height = stream.height;
    streams.emplace_back(flutter::CustomEncodableValue(ui::DisplayStreamState(
        static_cast<int64_t>(stream.display.id), stream.display.name, stream.display.width,
        stream.display.height, status, optional(peer), optional(reason),
        streaming ? &width : nullptr, streaming ? &height : nullptr, convert(stream.quality), endpoints)));
  }
  const auto server = convert(snapshot.server_state);
  const auto server_failure = server == ui::ServerStatus::kFailed ? snapshot.server_error : std::string();
  const auto certificate_error = server == ui::ServerStatus::kRunning ? snapshot.certificate_error : std::string();
  return ui::HostState(ui::ScreenPermission::kGranted, server, optional(server_failure), snapshot.pairing.token,
                       snapshot.pairing.remaining.count() / 1000, snapshot.pairing.regenerated_after_failures,
                       optional(certificate_error), streams);
}

ui::ErrorOr<ui::HostState> HostBridge::CurrentState() { return state(); }

std::optional<ui::FlutterError> HostBridge::StartServing() {
  controller_.start_serving();
  return std::nullopt;
}

std::optional<ui::FlutterError> HostBridge::StopServing() {
  controller_.stop_serving();
  return std::nullopt;
}

std::optional<ui::FlutterError> HostBridge::RegenerateToken() {
  controller_.regenerate_token();
  return std::nullopt;
}

std::optional<ui::FlutterError> HostBridge::Approve(int64_t display_id) {
  controller_.approve(display(display_id));
  return std::nullopt;
}

std::optional<ui::FlutterError> HostBridge::Reject(int64_t display_id) {
  controller_.reject(display(display_id));
  return std::nullopt;
}

std::optional<ui::FlutterError> HostBridge::Disconnect(int64_t display_id) {
  controller_.disconnect(display(display_id));
  return std::nullopt;
}

std::optional<ui::FlutterError> HostBridge::RequestPermission() { return std::nullopt; }
std::optional<ui::FlutterError> HostBridge::OpenPermissionSettings() { return std::nullopt; }
std::optional<ui::FlutterError> HostBridge::Relaunch() { return std::nullopt; }

}  // namespace doppelscreen

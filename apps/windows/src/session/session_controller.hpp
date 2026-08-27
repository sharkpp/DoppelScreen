#pragma once

#include "capture/d3d_device.hpp"
#include "capture/display_catalog.hpp"
#include "core/pairing_service.hpp"
#include "server/local_server.hpp"
#include "server/network_interfaces.hpp"

#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <string_view>
#include <vector>

namespace doppelscreen {

class PeerTransport;
class ScreenCapturer;

class SessionController {
 public:
  enum class ServerState { idle, starting, running, failed };
  enum class StreamState { idle, awaiting_approval, connecting, streaming, failed };

  struct Endpoint {
    DisplayId display_id{};
    std::wstring interface_name;
    std::string url;
    std::string secure_url;
  };
  struct StreamSnapshot {
    DisplayInfo display;
    StreamState state{StreamState::idle};
    std::string remote_address;
    std::string error;
  };
  struct Snapshot {
    ServerState server_state{ServerState::idle};
    std::string server_error;
    PairingService::Snapshot pairing;
    std::vector<StreamSnapshot> streams;
    std::vector<Endpoint> endpoints;
  };

  explicit SessionController(std::filesystem::path viewer_html);
  ~SessionController();
  void set_change_handler(std::function<void()> handler);
  void refresh_displays();
  void start_serving();
  void stop_serving();
  void regenerate_token();
  void approve(DisplayId display);
  void reject(DisplayId display);
  void disconnect(DisplayId display);
  Snapshot snapshot();

 private:
  class Stream;
  void accept(SignalingConnectionPtr connection);
  void rebuild_endpoints(std::string_view token);
  void changed();
  std::shared_ptr<Stream> find_stream(DisplayId display);

  std::filesystem::path viewer_html_;
  D3DDevice d3d_;
  PairingService pairing_;
  LocalServer server_;
  mutable std::mutex mutex_;
  ServerState server_state_{ServerState::idle};
  std::string server_error_;
  std::vector<std::shared_ptr<Stream>> streams_;
  std::vector<NetworkInterface> addresses_;
  std::vector<Endpoint> endpoints_;
  std::string endpoint_token_;
  unsigned short port_{};
  unsigned short secure_port_{};
  std::function<void()> change_handler_;
};

}  // namespace doppelscreen

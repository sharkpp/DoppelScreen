#include "session/session_controller.hpp"

#include "core/protocol.hpp"
#include "core/video_encoding.hpp"
#include "video/peer_transport.hpp"
#include "capture/screen_capturer.hpp"

#include <algorithm>

namespace doppelscreen {

class SessionController::Stream : public std::enable_shared_from_this<Stream> {
 public:
  Stream(SessionController& owner, DisplayCatalog::Entry display)
      : owner_(owner), id_(display.info.id), display_(std::move(display)),
        target_width_(display_.info.width), target_height_(display_.info.height) {}

  DisplayId id() const noexcept { return id_; }

  StreamSnapshot snapshot() const {
    std::scoped_lock lock(mutex_);
    return {display_.info, state_, connection_ ? connection_->remote_address() : "", error_,
            quality_, target_width_, target_height_};
  }

  void update(DisplayCatalog::Entry display) {
    std::scoped_lock lock(mutex_);
    display_ = std::move(display);
  }

  void request(SignalingConnectionPtr connection, bool resumed) {
    std::unique_lock lock(mutex_);
    if (connection_) {
      connection->send(protocol::encode_error("rejected"));
      return connection->close();
    }
    connection_ = std::move(connection);
    state_ = resumed ? StreamState::connecting : StreamState::awaiting_approval;
    auto weak = weak_from_this();
    connection_->set_handlers(
        [weak](std::string text) { if (auto self = weak.lock()) self->on_signal(std::move(text)); },
        [weak] { if (auto self = weak.lock()) self->on_closed(); });
    if (resumed) start_safely_locked();
    lock.unlock();
    owner_.changed();
  }

  void approve() {
    std::unique_lock lock(mutex_);
    if (state_ != StreamState::awaiting_approval) return;
    start_safely_locked();
    lock.unlock();
    owner_.changed();
  }

  void reject() {
    std::unique_lock lock(mutex_);
    if (state_ != StreamState::awaiting_approval) return;
    connection_->send(protocol::encode_error("rejected"));
    connection_->close();
    reset_locked();
    lock.unlock();
    owner_.changed();
  }

  void stop(bool revoke = true) {
    std::unique_ptr<ScreenCapturer> capturer;
    std::unique_ptr<PeerTransport> peer;
    SignalingConnectionPtr connection;
    DisplayId display{};
    {
      std::scoped_lock lock(mutex_);
      display = display_.info.id;
      capturer = std::move(capturer_);
      peer = std::move(peer_);
      connection = std::move(connection_);
      state_ = StreamState::idle;
      error_.clear();
    }
    if (revoke) owner_.pairing_.revoke_resume_tickets(display);
    if (capturer) capturer->stop();
    if (peer) peer->stop();
    if (connection) connection->close();
    owner_.changed();
  }

 private:
  void start_safely_locked() noexcept {
    try {
      start_locked();
    } catch (...) {
      error_ = "capture_failed";
      state_ = StreamState::failed;
      if (connection_) connection_->send(protocol::encode_error(error_));
    }
  }

  void start_locked() {
    state_ = StreamState::connecting;
    error_.clear();
    capturer_ = std::make_unique<ScreenCapturer>(owner_.d3d_, display_);
    const auto weak = weak_from_this();
    peer_ = std::make_unique<PeerTransport>(
        owner_.d3d_, connection_, display_.info,
        [weak](protocol::ViewerControl control) { if (auto self = weak.lock()) self->on_control(std::move(control)); },
        [weak] { if (auto self = weak.lock()) self->connected(); },
        [weak](std::string error) { if (auto self = weak.lock()) self->failed(std::move(error)); });
    if (!peer_->start()) {
      error_ = "peer_failed";
      state_ = StreamState::failed;
      connection_->send(protocol::encode_error(error_));
      return;
    }
    capturer_->start([weak](auto texture, int width, int height, std::int64_t timestamp) {
      if (auto self = weak.lock()) {
        std::scoped_lock lock(self->mutex_);
        if (self->peer_) self->peer_->submit_frame(std::move(texture), width, height, timestamp);
      }
    });
    const auto ticket = owner_.pairing_.issue_resume_ticket(display_.info.id);
    peer_->send_control(protocol::encode_resume(ticket, 600'000));
  }

  void connected() {
    {
      std::scoped_lock lock(mutex_);
      if (state_ != StreamState::connecting) return;
      state_ = StreamState::streaming;
    }
    owner_.changed();
  }

  void on_signal(std::string text) {
    auto message = protocol::decode_viewer_signal(text);
    if (!message || std::holds_alternative<protocol::ViewerHello>(*message)) return;
    std::scoped_lock lock(mutex_);
    if (peer_) peer_->handle_signal(*message);
  }

  void on_control(protocol::ViewerControl message) {
    std::scoped_lock lock(mutex_);
    if (const auto* viewport = std::get_if<protocol::Viewport>(&message)) {
      const auto size = video_encoding::following_size(display_.info.width, display_.info.height,
                                                       viewport->width, viewport->height);
      target_width_ = size.first;
      target_height_ = size.second;
      const auto settings = video_encoding::settings(quality_);
      if (capturer_) capturer_->resize(size.first, size.second, settings.max_framerate);
    } else if (const auto* quality = std::get_if<protocol::Quality>(&message)) {
      quality_ = quality->preset;
      const auto settings = video_encoding::settings(quality_);
      if (capturer_) capturer_->resize(target_width_, target_height_, settings.max_framerate);
      if (peer_) peer_->apply_quality(quality_);
    }
  }

  void on_closed() {
    std::unique_ptr<ScreenCapturer> capturer;
    std::unique_ptr<PeerTransport> peer;
    {
      std::scoped_lock lock(mutex_);
      capturer = std::move(capturer_);
      peer = std::move(peer_);
      connection_.reset();
      state_ = StreamState::idle;
      error_.clear();
    }
    if (capturer) capturer->stop();
    if (peer) peer->stop();
    owner_.changed();
  }

  void failed(std::string error) {
    std::unique_ptr<ScreenCapturer> capturer;
    {
      std::scoped_lock lock(mutex_);
      error_ = std::move(error);
      state_ = StreamState::failed;
      capturer = std::move(capturer_);
    }
    if (capturer) capturer->stop();
    owner_.changed();
  }

  void reset_locked() {
    capturer_.reset();
    peer_.reset();
    connection_.reset();
    state_ = StreamState::idle;
    error_.clear();
  }

  SessionController& owner_;
  const DisplayId id_;
  mutable std::recursive_mutex mutex_;
  DisplayCatalog::Entry display_;
  StreamState state_{StreamState::idle};
  QualityPreset quality_{QualityPreset::sharp};
  int target_width_{};
  int target_height_{};
  SignalingConnectionPtr connection_;
  std::unique_ptr<ScreenCapturer> capturer_;
  std::unique_ptr<PeerTransport> peer_;
  std::string error_;
};

SessionController::SessionController(std::filesystem::path viewer_html)
    : viewer_html_(std::move(viewer_html)) { refresh_displays(); }

SessionController::~SessionController() { stop_serving(); }

void SessionController::set_change_handler(std::function<void()> handler) {
  std::scoped_lock lock(mutex_);
  change_handler_ = std::move(handler);
}

void SessionController::refresh_displays() {
  const auto displays = DisplayCatalog::enumerate();
  const auto token = pairing_.snapshot().token;
  std::vector<std::shared_ptr<Stream>> removed;
  {
    std::scoped_lock lock(mutex_);
    for (const auto& display : displays) {
      auto found = std::find_if(streams_.begin(), streams_.end(), [&](const auto& stream) {
        return stream->id() == display.info.id;
      });
      if (found == streams_.end()) streams_.push_back(std::make_shared<Stream>(*this, display));
      else (*found)->update(display);
    }
    std::erase_if(streams_, [&](const auto& stream) {
      const auto id = stream->id();
      const auto missing = std::none_of(displays.begin(), displays.end(), [id](const auto& value) { return value.info.id == id; });
      if (missing) removed.push_back(stream);
      return missing;
    });
    rebuild_endpoints(token);
  }
  for (const auto& stream : removed) stream->stop();
  changed();
}

void SessionController::start_serving() {
  {
    std::scoped_lock lock(mutex_);
    if (server_state_ != ServerState::idle && server_state_ != ServerState::failed) return;
    server_state_ = ServerState::starting;
    server_error_.clear();
  }
  changed();
  try {
    const auto addresses = lan_addresses();
    std::vector<std::string> address_values;
    for (const auto& address : addresses) address_values.push_back(address.address);
    const auto listening = server_.start(viewer_html_, address_values,
        [this](SignalingConnectionPtr connection) { accept(std::move(connection)); });
    const auto token = pairing_.snapshot().token;
    {
      std::scoped_lock lock(mutex_);
      addresses_ = addresses;
      port_ = listening.port;
      secure_port_ = listening.secure_port;
      certificate_error_ = listening.certificate_error;
      server_state_ = ServerState::running;
      rebuild_endpoints(token);
    }
  } catch (const std::exception& error) {
    std::scoped_lock lock(mutex_);
    server_state_ = ServerState::failed;
    server_error_ = error.what();
  }
  changed();
}

void SessionController::stop_serving() {
  std::vector<std::shared_ptr<Stream>> streams;
  {
    std::scoped_lock lock(mutex_);
    streams = streams_;
  }
  for (const auto& stream : streams) stream->stop();
  server_.stop();
  {
    std::scoped_lock lock(mutex_);
    server_state_ = ServerState::idle;
    addresses_.clear();
    endpoints_.clear();
    endpoint_token_.clear();
    port_ = secure_port_ = 0;
    certificate_error_.clear();
  }
  changed();
}

void SessionController::regenerate_token() {
  pairing_.regenerate();
  const auto token = pairing_.snapshot().token;
  {
    std::scoped_lock lock(mutex_);
    rebuild_endpoints(token);
  }
  changed();
}
void SessionController::approve(DisplayId display) { if (auto stream = find_stream(display)) stream->approve(); }
void SessionController::reject(DisplayId display) { if (auto stream = find_stream(display)) stream->reject(); }
void SessionController::disconnect(DisplayId display) { if (auto stream = find_stream(display)) stream->stop(); }

SessionController::Snapshot SessionController::snapshot() {
  std::vector<std::shared_ptr<Stream>> streams;
  Snapshot result;
  const auto pairing = pairing_.snapshot();
  {
    std::scoped_lock lock(mutex_);
    if (endpoint_token_ != pairing.token) rebuild_endpoints(pairing.token);
    result = {server_state_, server_error_, certificate_error_, pairing};
    result.endpoints = endpoints_;
    streams = streams_;
  }
  for (const auto& stream : streams) result.streams.push_back(stream->snapshot());
  return result;
}

void SessionController::accept(SignalingConnectionPtr connection) {
  const auto remote = connection->remote_address();
  connection->set_handlers([this, connection, remote](std::string text) {
    const auto signal = protocol::decode_viewer_signal(text);
    const auto* hello = signal ? std::get_if<protocol::ViewerHello>(&*signal) : nullptr;
    if (!hello) return;
    bool resumed = hello->resume && pairing_.redeem_resume_ticket(*hello->resume, hello->display);
    if (!resumed) {
      const auto verdict = pairing_.verify(hello->token, remote);
      if (verdict != PairingService::Verdict::accepted) {
        connection->send(protocol::encode_error(*PairingService::error_code(verdict)));
        changed();
        return connection->close();
      }
    }
    std::shared_ptr<Stream> stream;
    if (hello->display) stream = find_stream(*hello->display);
    else {
      std::scoped_lock lock(mutex_);
      const auto primary = std::find_if(streams_.begin(), streams_.end(), [](const auto& value) {
        return value->snapshot().display.primary;
      });
      stream = primary != streams_.end() ? *primary : (streams_.empty() ? nullptr : streams_.front());
    }
    if (!stream) {
      connection->send(protocol::encode_error("display_not_found"));
      return connection->close();
    }
    stream->request(connection, resumed);
  }, [] {});
}

void SessionController::rebuild_endpoints(std::string_view token) {
  endpoints_.clear();
  endpoint_token_ = token;
  if (!port_) return;
  for (const auto& stream : streams_) {
    const auto display = stream->snapshot().display;
    for (const auto& address : addresses_) {
      const auto suffix = "/?d=" + std::to_string(display.id) + "#" + std::string(token);
      endpoints_.push_back({display.id, address.name,
                            "http://" + address.address + ":" + std::to_string(port_) + suffix,
                            secure_port_ ? "https://" + address.address + ":" +
                                               std::to_string(secure_port_) + suffix
                                         : ""});
    }
  }
}

void SessionController::changed() {
  std::function<void()> handler;
  {
    std::scoped_lock lock(mutex_);
    handler = change_handler_;
  }
  if (handler) handler();
}

std::shared_ptr<SessionController::Stream> SessionController::find_stream(DisplayId display) {
  std::scoped_lock lock(mutex_);
  const auto found = std::find_if(streams_.begin(), streams_.end(), [display](const auto& value) {
    return value->id() == display;
  });
  return found == streams_.end() ? nullptr : *found;
}

}  // namespace doppelscreen

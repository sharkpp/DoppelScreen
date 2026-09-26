#include "server/local_server.hpp"

#include "server/tls_identity.hpp"

#include <boost/asio/post.hpp>
#include <boost/asio/ssl/stream.hpp>
#include <boost/asio/strand.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/beast/websocket.hpp>
#include <algorithm>
#include <fstream>
#include <mutex>
#include <queue>
#include <stdexcept>
#include <type_traits>

namespace doppelscreen {
namespace net = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
namespace websocket = beast::websocket;
namespace ssl = net::ssl;
using tcp = net::ip::tcp;

namespace {
std::string read_file(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("viewer.html is missing");
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

template <typename Stream>
beast::tcp_stream& lowest(Stream& stream) { return beast::get_lowest_layer(stream); }

template <typename Stream>
class Connection final : public SignalingConnection,
                         public std::enable_shared_from_this<Connection<Stream>> {
 public:
  Connection(Stream stream, std::string viewer, unsigned short secure_port,
             LocalServer::ConnectionHandler accepted)
      : ws_(std::move(stream)), viewer_(std::move(viewer)), secure_port_(secure_port),
        accepted_(std::move(accepted)), remote_(lowest(ws_).socket().remote_endpoint().address().to_string()) {
    ws_.read_message_max(1024 * 1024);
  }

  template <typename Completion>
  void handshake_transport(Completion completion) {
    if constexpr (std::is_same_v<Stream, beast::ssl_stream<beast::tcp_stream>>) {
      ws_.next_layer().async_handshake(ssl::stream_base::server, std::move(completion));
    } else {
      completion(beast::error_code{});
    }
  }

  void run() { read_request(); }

  void send(std::string message) override {
    net::post(ws_.get_executor(), [self = this->shared_from_this(), message = std::move(message)]() mutable {
      if (self->closing_ || self->closed_) return;
      const auto idle = self->writes_.empty();
      self->writes_.push(std::move(message));
      if (idle) self->write_next();
    });
  }

  void close() override {
    net::post(ws_.get_executor(), [self = this->shared_from_this()] {
      self->closing_ = true;
      if (self->writes_.empty()) self->begin_close();
    });
  }

  void abort() override {
    beast::error_code ignored;
    lowest(ws_).socket().close(ignored);
    notify_closed();
  }

  std::string remote_address() const override { return remote_; }

  void set_handlers(MessageHandler message, CloseHandler close) override {
    message_ = std::move(message);
    close_ = std::move(close);
  }

 private:
  void read_request() {
    request_ = {};
    http::async_read(ws_.next_layer(), buffer_, request_,
      [self = this->shared_from_this()](beast::error_code error, std::size_t) {
        if (error) return self->notify_closed();
        self->route_request();
      });
  }

  void route_request() {
    if (websocket::is_upgrade(request_) && request_.target() == "/signal") {
      ws_.set_option(websocket::stream_base::timeout::suggested(beast::role_type::server));
      ws_.async_accept(request_, [self = this->shared_from_this()](beast::error_code error) {
        if (error) return self->notify_closed();
        self->accepted_(self);
        self->read_message();
      });
      return;
    }

    http::response<http::string_body> response;
    response.version(request_.version());
    response.keep_alive(false);
    if (request_.method() != http::verb::get) {
      response.result(http::status::method_not_allowed);
    } else if (request_.target() == "/config") {
      response.result(http::status::ok);
      response.set(http::field::content_type, "application/json");
      response.body() = "{\"securePort\":" + std::to_string(secure_port_) + "}";
    } else {
      response.result(http::status::ok);
      response.set(http::field::content_type, "text/html; charset=utf-8");
      response.set(http::field::cache_control, "no-store");
      response.body() = viewer_;
    }
    response.prepare_payload();
    auto shared_response = std::make_shared<http::response<http::string_body>>(std::move(response));
    http::async_write(ws_.next_layer(), *shared_response,
      [self = this->shared_from_this(), shared_response](beast::error_code, std::size_t) {
        beast::error_code ignored;
        lowest(self->ws_).socket().shutdown(tcp::socket::shutdown_both, ignored);
      });
  }

  void read_message() {
    ws_.async_read(buffer_, [self = this->shared_from_this()](beast::error_code error, std::size_t) {
      if (error) return self->notify_closed();
      auto text = beast::buffers_to_string(self->buffer_.data());
      self->buffer_.consume(self->buffer_.size());
      if (self->message_) self->message_(std::move(text));
      self->read_message();
    });
  }

  void write_next() {
    ws_.text(true);
    ws_.async_write(net::buffer(writes_.front()),
      [self = this->shared_from_this()](beast::error_code error, std::size_t) {
        if (error) return self->notify_closed();
        self->writes_.pop();
        if (!self->writes_.empty()) self->write_next();
        else if (self->closing_) self->begin_close();
      });
  }

  void begin_close() {
    if (close_started_) return;
    close_started_ = true;
    ws_.async_close(websocket::close_code::normal,
      [self = this->shared_from_this()](beast::error_code) { self->notify_closed(); });
  }

  void notify_closed() {
    if (closed_) return;
    closed_ = true;
    if (close_) close_();
  }

  websocket::stream<Stream> ws_;
  beast::flat_buffer buffer_;
  http::request<http::string_body> request_;
  std::queue<std::string> writes_;
  std::string viewer_;
  unsigned short secure_port_{};
  LocalServer::ConnectionHandler accepted_;
  MessageHandler message_;
  CloseHandler close_;
  std::string remote_;
  bool closed_{};
  bool closing_{};
  bool close_started_{};
};

}  // namespace

LocalServer::LocalServer() {
  tls_.set_options(ssl::context::default_workarounds | ssl::context::no_sslv2 |
                   ssl::context::no_sslv3 | ssl::context::single_dh_use);
}

LocalServer::~LocalServer() { stop(); }

LocalServer::Listening LocalServer::start(const std::filesystem::path& viewer_html,
                                          const std::vector<std::string>& certificate_addresses,
                                          ConnectionHandler handler) {
  stop();
  io_.restart();
  viewer_ = read_file(viewer_html);
  handler_ = std::move(handler);
  const auto port = bind(plain_, 8422);
  try {
    configure_persistent_identity(tls_, certificate_addresses);
    secure_port_ = bind(secure_, 8423);
  } catch (...) {
    secure_port_ = 0;
  }
  accept_plain();
  if (secure_port_) accept_secure();
  thread_ = std::jthread([this] { io_.run(); });
  return {port, secure_port_};
}

void LocalServer::stop() {
  beast::error_code ignored;
  plain_.close(ignored);
  secure_.close(ignored);
  io_.stop();
  if (thread_.joinable()) thread_.join();
  {
    std::scoped_lock lock(connections_mutex_);
    for (auto& weak : connections_) {
      if (auto connection = weak.lock()) connection->abort();
    }
    connections_.clear();
  }
  io_.restart();
  io_.poll();
  handler_ = {};
  viewer_.clear();
}

unsigned short LocalServer::bind(tcp::acceptor& acceptor, unsigned short preferred) {
  for (unsigned short port = preferred; port < preferred + 100; ++port) {
    beast::error_code error;
    acceptor.open(tcp::v4(), error);
    if (error) continue;
    const BOOL exclusive = TRUE;
    if (setsockopt(acceptor.native_handle(), SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
                   reinterpret_cast<const char*>(&exclusive), sizeof(exclusive)) == SOCKET_ERROR) {
      acceptor.close(error);
      continue;
    }
    acceptor.bind({tcp::v4(), port}, error);
    if (!error) {
      acceptor.listen(net::socket_base::max_listen_connections, error);
      if (!error) return acceptor.local_endpoint().port();
    }
    acceptor.close(error);
  }
  throw std::runtime_error("no listening port available");
}

void LocalServer::accept_plain() {
  plain_.async_accept(net::make_strand(io_), [this](beast::error_code error, tcp::socket socket) {
    if (!error) {
      auto connection = std::make_shared<Connection<beast::tcp_stream>>(
          beast::tcp_stream(std::move(socket)), viewer_, secure_port_, handler_);
      remember(connection);
      connection->run();
    }
    if (plain_.is_open()) accept_plain();
  });
}

void LocalServer::accept_secure() {
  secure_.async_accept(net::make_strand(io_), [this](beast::error_code error, tcp::socket socket) {
    if (!error) {
      using SecureStream = beast::ssl_stream<beast::tcp_stream>;
      auto connection = std::make_shared<Connection<SecureStream>>(
          SecureStream(beast::tcp_stream(std::move(socket)), tls_), viewer_, secure_port_, handler_);
      remember(connection);
      connection->handshake_transport([connection](beast::error_code handshake_error) {
        if (!handshake_error) connection->run();
      });
    }
    if (secure_.is_open()) accept_secure();
  });
}

void LocalServer::remember(const SignalingConnectionPtr& connection) {
  std::scoped_lock lock(connections_mutex_);
  std::erase_if(connections_, [](const auto& weak) { return weak.expired(); });
  connections_.push_back(connection);
}

}  // namespace doppelscreen

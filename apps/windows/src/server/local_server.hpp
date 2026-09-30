#pragma once

#include "server/signaling_connection.hpp"

#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl/context.hpp>
#include <filesystem>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace doppelscreen {

class LocalServer {
 public:
  struct Listening {
    unsigned short port{};
    // 証明書を用意できなかったときは 0 で、理由を certificate_error に入れる。HTTP だけで動く
    unsigned short secure_port{};
    std::string certificate_error;
  };
  using ConnectionHandler = std::function<void(SignalingConnectionPtr)>;

  LocalServer();
  ~LocalServer();
  Listening start(const std::filesystem::path& viewer_html,
                  const std::vector<std::string>& certificate_addresses,
                  ConnectionHandler handler);
  void stop();

 private:
  unsigned short bind(boost::asio::ip::tcp::acceptor& acceptor, unsigned short preferred);
  void accept_plain();
  void accept_secure();
  void remember(const SignalingConnectionPtr& connection);

  boost::asio::io_context io_;
  boost::asio::ssl::context tls_{boost::asio::ssl::context::tls_server};
  boost::asio::ip::tcp::acceptor plain_{io_};
  boost::asio::ip::tcp::acceptor secure_{io_};
  std::jthread thread_;
  std::string viewer_;
  ConnectionHandler handler_;
  std::mutex connections_mutex_;
  std::vector<std::weak_ptr<SignalingConnection>> connections_;
  unsigned short secure_port_{};
};

}  // namespace doppelscreen

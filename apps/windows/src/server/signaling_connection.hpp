#pragma once

#include <functional>
#include <memory>
#include <string>

namespace doppelscreen {

class SignalingConnection {
 public:
  using MessageHandler = std::function<void(std::string)>;
  using CloseHandler = std::function<void()>;
  virtual ~SignalingConnection() = default;
  virtual void send(std::string message) = 0;
  virtual void close() = 0;
  virtual void abort() = 0;
  virtual std::string remote_address() const = 0;
  virtual void set_handlers(MessageHandler message, CloseHandler close) = 0;
};

using SignalingConnectionPtr = std::shared_ptr<SignalingConnection>;

}  // namespace doppelscreen

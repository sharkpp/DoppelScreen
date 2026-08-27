#pragma once

#include "core/types.hpp"

#include <chrono>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace doppelscreen {

class PairingService {
 public:
  using Clock = std::chrono::steady_clock;
  static constexpr std::size_t failure_limit = 5;

  enum class Verdict { accepted, invalid, expired, too_many_attempts };

  struct Snapshot {
    std::string token;
    std::chrono::milliseconds remaining{};
    bool regenerated_after_failures{};
  };

  explicit PairingService(
      std::chrono::milliseconds lifetime = std::chrono::minutes(5),
      std::chrono::milliseconds cooldown = std::chrono::seconds(30),
      std::chrono::milliseconds resume_lifetime = std::chrono::minutes(10));

  Snapshot snapshot();
  void regenerate();
  Verdict verify(std::string_view presented, std::string_view address);

  std::string issue_resume_ticket(DisplayId display);
  bool redeem_resume_ticket(std::string_view ticket, std::optional<DisplayId> display);
  void revoke_resume_tickets(DisplayId display);

  static std::optional<std::string_view> error_code(Verdict verdict);

 private:
  struct ResumeTicket { DisplayId display; Clock::time_point issued_at; };

  static std::string random_token(std::size_t length);
  static bool constant_time_equal(std::string_view lhs, std::string_view rhs);
  bool expired(Clock::time_point now) const;
  void expire_if_needed(Clock::time_point now);
  void reissue(bool after_failures, Clock::time_point now);
  void prune_failures(Clock::time_point now);
  void prune_resume_tickets(Clock::time_point now);

  const std::chrono::milliseconds lifetime_;
  const std::chrono::milliseconds cooldown_;
  const std::chrono::milliseconds resume_lifetime_;
  std::mutex mutex_;
  std::string token_;
  Clock::time_point issued_at_;
  std::size_t failures_{};
  bool regenerated_after_failures_{};
  std::unordered_map<std::string, std::vector<Clock::time_point>> failure_times_;
  std::unordered_map<std::string, ResumeTicket> resume_tickets_;
};

}  // namespace doppelscreen

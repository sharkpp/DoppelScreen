#include "core/pairing_service.hpp"

#include <algorithm>
#include <random>
#include <stdexcept>
#ifdef _WIN32
#include <bcrypt.h>
#endif

namespace doppelscreen {

PairingService::PairingService(std::chrono::milliseconds lifetime,
                               std::chrono::milliseconds cooldown,
                               std::chrono::milliseconds resume_lifetime)
    : lifetime_(lifetime), cooldown_(cooldown), resume_lifetime_(resume_lifetime),
      token_(random_token(8)), issued_at_(Clock::now()) {}

PairingService::Snapshot PairingService::snapshot() {
  std::scoped_lock lock(mutex_);
  const auto now = Clock::now();
  expire_if_needed(now);
  return {token_, std::max(std::chrono::milliseconds::zero(),
                           std::chrono::duration_cast<std::chrono::milliseconds>(lifetime_ - (now - issued_at_))),
          regenerated_after_failures_};
}

void PairingService::regenerate() {
  std::scoped_lock lock(mutex_);
  reissue(false, Clock::now());
}

PairingService::Verdict PairingService::verify(std::string_view presented, std::string_view address) {
  std::scoped_lock lock(mutex_);
  const auto now = Clock::now();
  prune_failures(now);
  const auto address_key = std::string(address);
  if (failure_times_[address_key].size() >= failure_limit) return Verdict::too_many_attempts;

  const auto was_expired = expired(now);
  expire_if_needed(now);
  if (was_expired) return Verdict::expired;

  if (!constant_time_equal(presented, token_)) {
    ++failures_;
    failure_times_[address_key].push_back(now);
    if (failures_ >= failure_limit) reissue(true, now);
    return Verdict::invalid;
  }

  failures_ = 0;
  regenerated_after_failures_ = false;
  return Verdict::accepted;
}

std::string PairingService::issue_resume_ticket(DisplayId display) {
  std::scoped_lock lock(mutex_);
  const auto now = Clock::now();
  prune_resume_tickets(now);
  auto ticket = random_token(24);
  resume_tickets_.insert_or_assign(ticket, ResumeTicket{display, now});
  return ticket;
}

bool PairingService::redeem_resume_ticket(std::string_view ticket,
                                          std::optional<DisplayId> display) {
  std::scoped_lock lock(mutex_);
  prune_resume_tickets(Clock::now());
  const auto found = resume_tickets_.find(std::string(ticket));
  if (found == resume_tickets_.end()) return false;
  if (display && *display != found->second.display) return false;
  resume_tickets_.erase(found);
  return true;
}

void PairingService::revoke_resume_tickets(DisplayId display) {
  std::scoped_lock lock(mutex_);
  std::erase_if(resume_tickets_, [display](const auto& entry) {
    return entry.second.display == display;
  });
}

std::optional<std::string_view> PairingService::error_code(Verdict verdict) {
  switch (verdict) {
    case Verdict::accepted: return std::nullopt;
    case Verdict::invalid: return "invalid_token";
    case Verdict::expired: return "token_expired";
    case Verdict::too_many_attempts: return "too_many_attempts";
  }
  return std::nullopt;
}

std::string PairingService::random_token(std::size_t length) {
  static constexpr std::string_view alphabet = "0123456789abcdefghjkmnpqrstvwxyz";
  std::string value;
  value.reserve(length);
#ifdef _WIN32
  std::vector<unsigned char> bytes(length);
  if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    throw std::runtime_error("BCryptGenRandom");
  }
  for (const auto byte : bytes) value.push_back(alphabet[byte & 31]);
#else
  thread_local std::mt19937_64 engine(std::random_device{}());
  std::uniform_int_distribution<std::size_t> distribution(0, alphabet.size() - 1);
  while (value.size() < length) value.push_back(alphabet[distribution(engine)]);
#endif
  return value;
}

bool PairingService::constant_time_equal(std::string_view lhs, std::string_view rhs) {
  std::uint8_t difference = lhs.size() == rhs.size() ? 0 : 1;
  const auto size = std::max(lhs.size(), rhs.size());
  for (std::size_t index = 0; index < size; ++index) {
    const auto a = index < lhs.size() ? static_cast<std::uint8_t>(lhs[index]) : 0;
    const auto b = index < rhs.size() ? static_cast<std::uint8_t>(rhs[index]) : 0;
    difference |= a ^ b;
  }
  return difference == 0;
}

bool PairingService::expired(Clock::time_point now) const { return now - issued_at_ >= lifetime_; }

void PairingService::expire_if_needed(Clock::time_point now) {
  if (expired(now)) reissue(false, now);
}

void PairingService::reissue(bool after_failures, Clock::time_point now) {
  token_ = random_token(8);
  issued_at_ = now;
  failures_ = 0;
  regenerated_after_failures_ = after_failures;
}

void PairingService::prune_failures(Clock::time_point now) {
  std::erase_if(failure_times_, [this, now](auto& entry) {
    std::erase_if(entry.second, [this, now](auto instant) { return now - instant >= cooldown_; });
    return entry.second.empty();
  });
}

void PairingService::prune_resume_tickets(Clock::time_point now) {
  std::erase_if(resume_tickets_, [this, now](const auto& entry) {
    return now - entry.second.issued_at >= resume_lifetime_;
  });
}

}  // namespace doppelscreen

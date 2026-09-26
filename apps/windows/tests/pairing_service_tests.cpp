#include "core/pairing_service.hpp"

#include <catch2/catch_test_macros.hpp>
#include <thread>

using doppelscreen::PairingService;

TEST_CASE("current token is reusable") {
  PairingService pairing;
  const auto token = pairing.snapshot().token;
  REQUIRE(pairing.verify(token, "192.168.1.2") == PairingService::Verdict::accepted);
  REQUIRE(pairing.verify(token, "192.168.1.3") == PairingService::Verdict::accepted);
  REQUIRE(pairing.snapshot().token == token);
}

TEST_CASE("expired tokens rotate") {
  PairingService pairing(std::chrono::milliseconds(10));
  const auto old = pairing.snapshot().token;
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  REQUIRE(pairing.verify(old, "192.168.1.2") == PairingService::Verdict::expired);
  REQUIRE(pairing.snapshot().token != old);
}

TEST_CASE("repeated failures are rate limited") {
  PairingService pairing(std::chrono::minutes(5), std::chrono::milliseconds(30));
  for (std::size_t i = 0; i < PairingService::failure_limit; ++i) {
    REQUIRE(pairing.verify("wrong", "10.0.0.9") == PairingService::Verdict::invalid);
  }
  REQUIRE(pairing.verify(pairing.snapshot().token, "10.0.0.9") == PairingService::Verdict::too_many_attempts);
  REQUIRE(pairing.verify(pairing.snapshot().token, "10.0.0.8") == PairingService::Verdict::accepted);
  std::this_thread::sleep_for(std::chrono::milliseconds(40));
  REQUIRE(pairing.verify(pairing.snapshot().token, "10.0.0.9") == PairingService::Verdict::accepted);
}

TEST_CASE("resume tickets are display-bound and single-use") {
  PairingService pairing;
  const auto ticket = pairing.issue_resume_ticket(7);
  REQUIRE_FALSE(pairing.redeem_resume_ticket(ticket, 8));
  REQUIRE(pairing.redeem_resume_ticket(ticket, 7));
  REQUIRE_FALSE(pairing.redeem_resume_ticket(ticket, 7));
}

TEST_CASE("tokens have the documented shape") {
  const auto token = PairingService().snapshot().token;
  REQUIRE(token.size() == 8);
  for (const auto value : token) {
    REQUIRE(std::string_view("0123456789abcdefghjkmnpqrstvwxyz").find(value) != std::string_view::npos);
  }
}

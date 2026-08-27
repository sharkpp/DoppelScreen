#pragma once

#include <string>
#include <vector>

namespace doppelscreen {

struct NetworkInterface { std::wstring name; std::string address; };
std::vector<NetworkInterface> lan_addresses();

}  // namespace doppelscreen

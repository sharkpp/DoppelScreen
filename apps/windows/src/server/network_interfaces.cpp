#include "server/network_interfaces.hpp"

#include <iphlpapi.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <cstddef>
#include <vector>

namespace doppelscreen {

std::vector<NetworkInterface> lan_addresses() {
  ULONG size = 16 * 1024;
  std::vector<std::byte> storage(size);
  auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
  auto result = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                                                  GAA_FLAG_SKIP_DNS_SERVER,
                                     nullptr, adapters, &size);
  if (result == ERROR_BUFFER_OVERFLOW) {
    storage.resize(size);
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
    result = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                                               GAA_FLAG_SKIP_DNS_SERVER,
                                  nullptr, adapters, &size);
  }
  if (result != NO_ERROR) return {};

  std::vector<NetworkInterface> output;
  for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp || adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
    for (auto* address = adapter->FirstUnicastAddress; address; address = address->Next) {
      if (address->Address.lpSockaddr->sa_family != AF_INET) continue;
      char text[INET_ADDRSTRLEN]{};
      const auto* ipv4 = reinterpret_cast<sockaddr_in*>(address->Address.lpSockaddr);
      if (!InetNtopA(AF_INET, &ipv4->sin_addr, text, std::size(text))) continue;
      output.push_back({adapter->FriendlyName ? adapter->FriendlyName : L"LAN", text});
    }
  }
  return output;
}

}  // namespace doppelscreen

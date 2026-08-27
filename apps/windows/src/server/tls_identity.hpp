#pragma once

#include <boost/asio/ssl/context.hpp>
#include <string>
#include <vector>

namespace doppelscreen {

void configure_persistent_identity(boost::asio::ssl::context& context,
                                   const std::vector<std::string>& addresses);

}  // namespace doppelscreen

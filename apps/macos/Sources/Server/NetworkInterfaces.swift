import Foundation

/// ビューアに渡す URL を組み立てるための LAN アドレス列挙（docs/STACK.md §2.5）。
///
/// インタフェースが複数ある場合はホスト UI で選ばせる（SPEC.md §5.2）ため、
/// ここでは順位付けだけして全件返す。
struct NetworkInterface: Sendable, Identifiable, Equatable {
    var name: String
    var address: String

    var id: String { "\(name)/\(address)" }
}

enum NetworkInterfaces {

    /// 待受中のアドレスのうち、ビューアから到達しうる IPv4 を返す。
    ///
    /// IPv6 は返さない。URL に入れると角括弧が要り、QR も手入力も長くなる。
    /// LAN 内の到達性は IPv4 で足りる。
    static func lanAddresses() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [NetworkInterface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sockaddr = pointer.pointee.ifa_addr,
                  sockaddr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sockaddr, socklen_t(sockaddr.pointee.sa_len),
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            let name = String(cString: pointer.pointee.ifa_name)
            let address = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            // 169.254/16 はリンクローカル。DHCP に失敗した残骸で到達しないことが多い
            guard !address.hasPrefix("169.254.") else { continue }
            found.append(NetworkInterface(name: name, address: address))
        }

        return found.sorted { rank($0.name) < rank($1.name) }
    }

    /// `en0` が Wi-Fi、`en1` 以降が有線や Thunderbolt になることが多い。
    /// 迷ったときに上に出る順にするだけで、選択はユーザに委ねる。
    private static func rank(_ interfaceName: String) -> Int {
        if interfaceName.hasPrefix("en") { return 0 }
        if interfaceName.hasPrefix("bridge") { return 2 }
        return 1
    }
}

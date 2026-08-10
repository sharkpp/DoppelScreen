import Foundation

/// 接続トークン（SPEC.md §5.2）。
///
/// M0 では起動ごとに 1 つ作って固定する。TTL・失効・再生成は M2 の `PairingService` で扱う。
enum PairingToken {
    /// 紛らわしい文字（i / l / o / u）を外した 32 文字。手入力を前提にする
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    /// 8 文字 = 40bit
    static func generate(length: Int = 8) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

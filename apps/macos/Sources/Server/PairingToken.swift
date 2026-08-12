import Foundation

/// 接続トークンの文字列そのもの（SPEC.md §5.2）。
///
/// 発行・期限・検証は `PairingService` が持つ。ここは値の作り方だけを受け持つ。
enum PairingToken {
    /// 紛らわしい文字（i / l / o / u）を外した 32 文字。手入力を前提にする
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    /// 8 文字 = 40bit
    static func generate(length: Int = 8) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

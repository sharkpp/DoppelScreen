import Foundation
import Testing

/// HTTPS 待受の自己署名証明書（SPEC.md §5.3）。
///
/// キーチェーンを使わずファイルに置くので、一時ディレクトリへ向ければ実機の状態を汚さずに確かめられる。
struct TLSIdentityTests {

    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "doppelscreen-tls-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test("初回に作ったものを使い回す")
    func reuses() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try TLSIdentity.current(addresses: ["192.168.1.10"], in: directory)
        let second = try TLSIdentity.current(addresses: ["192.168.1.10"], in: directory)

        #expect(first.certificate == second.certificate)
        #expect(first.privateKey.rawRepresentation == second.privateKey.rawRepresentation)
    }

    /// 証明書例外を無駄に無効化しない
    @Test("アドレスが減っただけなら作り直さない")
    func keepsWhenAddressesShrink() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try TLSIdentity.current(addresses: ["192.168.1.10", "10.0.0.5"], in: directory)
        let second = try TLSIdentity.current(addresses: ["10.0.0.5"], in: directory)

        #expect(first.certificate == second.certificate)
    }

    @Test("アドレスが増えたら作り直し、ループバックも常に含める")
    func regeneratesForNewAddress() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try TLSIdentity.current(addresses: ["192.168.1.10"], in: directory)
        let second = try TLSIdentity.current(addresses: ["192.168.1.20"], in: directory)

        #expect(first.certificate != second.certificate)
        #expect(second.covers(["127.0.0.1", "192.168.1.20"]))
        #expect(!second.covers(["192.168.1.10"]))
    }

    @Test("鍵は本人だけが読める")
    func restrictsPermissions() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try TLSIdentity.current(addresses: [], in: directory)

        let files = FileManager.default
        let directoryMode = try files.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let keyMode = try files.attributesOfItem(
            atPath: directory.appending(path: "private-key.pem").path
        )[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        #expect(keyMode == 0o600)
    }

    @Test("壊れていれば作り直す")
    func regeneratesWhenCorrupted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try TLSIdentity.current(addresses: [], in: directory)
        try Data("broken".utf8).write(to: directory.appending(path: "private-key.pem"))
        let second = try TLSIdentity.current(addresses: [], in: directory)

        #expect(first.certificate != second.certificate)
    }

    @Test("NIOSSL の待受設定にできる")
    func makesServerContext() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try TLSIdentity.current(addresses: [], in: directory).serverContext()
    }
}

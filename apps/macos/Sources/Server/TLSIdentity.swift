import Crypto
import Foundation
import NIOSSL
import OSLog
import SwiftASN1
import X509

private let log = Logger(subsystem: "net.sharkpp.doppelscreen", category: "tls")

/// HTTPS 待受のための自己署名証明書（SPEC.md §5.3 / docs/STACK.md §2.4）。
///
/// **初回に作って以後は使い回す。** 毎回作り直すと、ビューア端末が受け入れた証明書例外が
/// そのたびに無効になり、警告を何度も踏むことになる。
/// URL は IP ベースなので **SAN に IP アドレスを入れる。** CN だけでは Safari / Chrome とも受け付けない。
///
/// **キーチェーンは使わない。** 秘密鍵と証明書は Application Support に本人だけが読めるファイルで置く。
/// キーチェーンの鍵は署名した実行ファイルのパーティション（自己署名なら cdhash）に結び付き、
/// リビルドのたびに確認ダイアログが出て、その間 TLS ハンドシェイクが返らなくなる（§落とし穴）。
struct TLSIdentity {

    var certificate: Certificate
    var privateKey: P256.Signing.PrivateKey

    /// `~/Library/Application Support/net.sharkpp.doppelscreen/tls`
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "net.sharkpp.doppelscreen", directoryHint: .isDirectory)
            .appending(path: "tls", directoryHint: .isDirectory)
    }

    private static let certificateFile = "certificate.pem"
    private static let privateKeyFile = "private-key.pem"

    /// 現在の LAN アドレスを覆う証明書を返す。無ければ作る。IP が増えていれば作り直す。
    static func current(addresses: [String], in directory: URL = defaultDirectory) throws -> TLSIdentity {
        // ループバックは常に入れる。E2E と手元確認がこれで通る
        let required = Set(["127.0.0.1"] + addresses)

        if let stored = load(from: directory) {
            if stored.covers(required) {
                log.info("reusing the stored TLS certificate")
                return stored
            }
            log.notice("the stored TLS certificate no longer matches; regenerating")
        }

        let identity = try generate(addresses: required)
        try identity.save(to: directory)
        log.info("generated a TLS certificate for \(required.sorted().joined(separator: ", "), privacy: .public)")
        return identity
    }

    /// 待受に渡す TLS の設定。検証はしない（相手はブラウザで、クライアント証明書を持たない）
    func serverContext() throws -> NIOSSLContext {
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(certificate.serializeAsPEM().pemString.utf8), format: .pem))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(privateKey.pemRepresentation.utf8), format: .pem))
        )
        return try NIOSSLContext(configuration: configuration)
    }

    // MARK: - 生成

    private static func generate(addresses: Set<String>) throws -> TLSIdentity {
        let key = P256.Signing.PrivateKey()
        let signingKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName("DoppelScreen")
            OrganizationName("sharkpp.net")
        }

        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: signingKey.publicKey,
            // 端末間の時計のずれで「まだ有効でない」と判定されないよう少し前から
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365 * 5),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true, keyEncipherment: true)
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(addresses.sorted().compactMap(generalName))
            },
            issuerPrivateKey: signingKey
        )
        return TLSIdentity(certificate: certificate, privateKey: key)
    }

    private static func generalName(for address: String) -> GeneralName? {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return .ipAddress(ASN1OctetString(contentBytes: ArraySlice(octets)))
    }

    // MARK: - 保存と読み出し

    /// 読めない・壊れている・鍵と証明書が対でない場合は `nil`。呼び出し側が作り直す
    private static func load(from directory: URL) -> TLSIdentity? {
        guard let certificatePEM = try? String(contentsOf: directory.appending(path: certificateFile), encoding: .utf8),
              let keyPEM = try? String(contentsOf: directory.appending(path: privateKeyFile), encoding: .utf8),
              let certificate = try? Certificate(pemEncoded: certificatePEM),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM),
              certificate.publicKey == Certificate.PublicKey(key.publicKey)
        else { return nil }
        return TLSIdentity(certificate: certificate, privateKey: key)
    }

    /// 本人だけが読めるようにする。ディレクトリを 0700 にしてから書くので、
    /// ファイルが既定の権限で作られる一瞬にも他のユーザからは見えない
    private func save(to directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // 鍵を先に書く。途中で落ちても、次回の読み出しで対にならず作り直される
        for (name, contents) in [
            (Self.privateKeyFile, privateKey.pemRepresentation),
            (Self.certificateFile, try certificate.serializeAsPEM().pemString),
        ] {
            let url = directory.appending(path: name)
            try Data(contents.utf8).write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// いま待ち受けているアドレスをすべて覆っているか。
    /// 古い IP が余分に入っているぶんには作り直さない（証明書例外を無駄に無効化しない）。
    func covers(_ addresses: Set<String>) -> Bool {
        guard let names = try? certificate.extensions.subjectAlternativeNames else { return false }

        var present: Set<String> = []
        for name in names {
            guard case .ipAddress(let octets) = name, octets.bytes.count == 4 else { continue }
            present.insert(octets.bytes.map(String.init).joined(separator: "."))
        }
        return addresses.isSubset(of: present)
    }
}

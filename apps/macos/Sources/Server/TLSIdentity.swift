import Crypto
import Foundation
import OSLog
import Security
import SwiftASN1
import X509

private let log = Logger(subsystem: "net.sharkpp.doppelscreen", category: "tls")

/// HTTPS 待受のための自己署名証明書（SPEC.md §5.3 / docs/STACK.md §2.4）。
///
/// **初回に作って以後は使い回す。** 毎回作り直すと、ビューア端末が受け入れた証明書例外が
/// そのたびに無効になり、警告を何度も踏むことになる。
/// URL は IP ベースなので **SAN に IP アドレスを入れる。** CN だけでは Safari / Chrome とも受け付けない。
///
/// **キーチェーンは「属性で引いて属性で消す」をしない。**
/// macOS の（レガシー）キーチェーンでは `kSecClassIdentity` に対する `kSecAttrLabel` での
/// 絞り込みが効かず、無関係な識別情報を掴んで消してしまう。証明書を 1 件ずつ読んで
/// 中身で判定し、**参照そのもの（`kSecMatchItemList`）を指して消す**（§落とし穴）。
enum TLSIdentity {

    /// 自分の証明書だと分かるための目印。証明書の OU に入れる。
    /// キーチェーンの属性に頼らず、証明書の中身で判定するために使う
    private static let marker = "net.sharkpp.doppelscreen.tls"

    enum IdentityError: LocalizedError {
        case keychain(OSStatus, String)
        case certificateCreationFailed
        case keyCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .keychain(let status, let operation):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "キーチェーン操作に失敗しました（\(operation): \(message)）"
            case .certificateCreationFailed:
                return "証明書を生成できませんでした"
            case .keyCreationFailed(let message):
                return "秘密鍵を生成できませんでした: \(message)"
            }
        }
    }

    /// 現在の LAN アドレスを覆う証明書を返す。無ければ作る。IP が増減していれば作り直す。
    static func current(addresses: [String]) throws -> SecIdentity {
        // ループバックは常に入れる。E2E と手元確認がこれで通る
        let required = Set(["127.0.0.1"] + addresses)

        if let stored = try findStored() {
            if covers(stored.certificate, addresses: required), let identity = identity(for: stored.reference) {
                log.info("reusing the stored TLS certificate")
                return identity
            }
            log.notice("the stored TLS certificate no longer matches; regenerating")
            try remove(stored.reference)
        }

        return try generate(addresses: required)
    }

    // MARK: - 生成

    private static func generate(addresses: Set<String>) throws -> SecIdentity {
        let key = P256.Signing.PrivateKey()
        let privateKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName("DoppelScreen")
            OrganizationName("sharkpp.net")
            OrganizationalUnitName(marker)
        }

        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: privateKey.publicKey,
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
            issuerPrivateKey: privateKey
        )

        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        guard let secCertificate = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else {
            throw IdentityError.certificateCreationFailed
        }

        var error: Unmanaged<CFError>?
        // EC の秘密鍵は ANSI X9.63 形式（04 || X || Y || K）で渡す
        guard let secKey = SecKeyCreateWithData(
            key.x963Representation as CFData,
            [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits: 256,
            ] as CFDictionary,
            &error
        ) else {
            throw IdentityError.keyCreationFailed(
                (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            )
        }

        // 秘密鍵と証明書を入れると、キーチェーンが公開鍵ハッシュで両者を結び付け、
        // `SecIdentity` として引けるようになる。PKCS#12 を組み立てる必要はない
        try add([
            kSecClass: kSecClassKey,
            kSecValueRef: secKey,
            kSecAttrLabel: marker,
            kSecAttrIsPermanent: true,
        ], operation: "秘密鍵の保存")

        try add([
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCertificate,
            kSecAttrLabel: marker,
        ], operation: "証明書の保存")

        guard let identity = identity(for: secCertificate) else {
            throw IdentityError.certificateCreationFailed
        }
        log.info("generated a TLS certificate for \(addresses.sorted().joined(separator: ", "), privacy: .public)")
        return identity
    }

    private static func generalName(for address: String) -> GeneralName? {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return .ipAddress(ASN1OctetString(contentBytes: ArraySlice(octets)))
    }

    // MARK: - 保存と読み出し

    private struct Stored {
        var reference: SecCertificate
        var certificate: Certificate
    }

    /// 証明書を全件読み、**中身の目印で** 自分のものを選ぶ。
    /// キーチェーンの属性による絞り込みは当てにしない。
    private static func findStored() throws -> Stored? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ] as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        default:
            throw IdentityError.keychain(status, "証明書の一覧取得")
        }

        guard let references = result as? [SecCertificate] else { return nil }
        for reference in references {
            let der = SecCertificateCopyData(reference) as Data
            guard let certificate = try? Certificate(derEncoded: [UInt8](der)),
                  isOurs(certificate)
            else { continue }
            return Stored(reference: reference, certificate: certificate)
        }
        return nil
    }

    private static func isOurs(_ certificate: Certificate) -> Bool {
        certificate.subject.contains { relativeName in
            relativeName.contains { attribute in
                attribute.type == ASN1ObjectIdentifier.RDNAttributeType.organizationalUnitName
                    && String(attribute.value) == marker
            }
        }
    }

    private static func identity(for certificate: SecCertificate) -> SecIdentity? {
        var identity: SecIdentity?
        // 秘密鍵が失われていれば `nil`。その場合は作り直す
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess else { return nil }
        return identity
    }

    /// 保存済みの証明書が、いま待ち受けているアドレスをすべて覆っているか。
    /// 古い IP が余分に入っているぶんには作り直さない（証明書例外を無駄に無効化しない）。
    private static func covers(_ certificate: Certificate, addresses: Set<String>) -> Bool {
        guard let names = try? certificate.extensions.subjectAlternativeNames else { return false }

        var present: Set<String> = []
        for name in names {
            guard case .ipAddress(let octets) = name, octets.bytes.count == 4 else { continue }
            present.insert(octets.bytes.map(String.init).joined(separator: "."))
        }
        return addresses.isSubset(of: present)
    }

    private static func add(_ attributes: [CFString: Any], operation: String) throws {
        let status = SecItemAdd(attributes as CFDictionary, nil)
        // 既にある場合は作り直しの途中。同一性は呼び出し側が判断済みなので通す
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw IdentityError.keychain(status, operation)
        }
    }

    /// **参照そのものを指して消す。** 属性で消すと、キーチェーンが属性を無視した場合に
    /// 無関係な項目まで巻き込む（実際に開発用の署名証明書を消してしまった）。
    private static func remove(_ certificate: SecCertificate) throws {
        if let identity = identity(for: certificate) {
            var key: SecKey?
            if SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key {
                try delete([kSecClass: kSecClassKey, kSecMatchItemList: [key]], operation: "古い秘密鍵の削除")
            }
        }
        try delete(
            [kSecClass: kSecClassCertificate, kSecMatchItemList: [certificate]],
            operation: "古い証明書の削除"
        )
    }

    private static func delete(_ query: [CFString: Any], operation: String) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychain(status, operation)
        }
    }
}

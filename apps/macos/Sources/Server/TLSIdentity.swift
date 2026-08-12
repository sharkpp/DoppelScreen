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

    /// **ファイルベース（レガシー）のキーチェーンを明示的に使う。**
    /// 指定しないとデータ保護キーチェーンへ回され、`keychain-access-groups` の
    /// エンタイトルメントを要求されて `errSecMissingEntitlement` で弾かれる。
    /// このエンタイトルメントは実 Team ID とプロビジョニングプロファイルが要り、
    /// 自己署名の開発ビルドでは付けられない。
    private static func query(_ attributes: [CFString: Any]) -> CFDictionary {
        var merged = attributes
        merged[kSecUseDataProtectionKeychain] = false
        return merged as CFDictionary
    }

    enum IdentityError: LocalizedError {
        case keychain(OSStatus, String)
        case certificateCreationFailed
        case keyCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .keychain(let status, let operation):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return L10n.Failure.keychain(operation: operation, message: message)
            case .certificateCreationFailed:
                return L10n.Failure.certificateCreationFailed
            case .keyCreationFailed(let message):
                return L10n.Failure.keyCreationFailed(message: message)
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
        let privateKey = Certificate.PrivateKey(try storeNewKey())
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

        // 証明書を入れると、キーチェーンが公開鍵ハッシュで秘密鍵と結び付け、
        // `SecIdentity` として引けるようになる。PKCS#12 を組み立てる必要はない
        try add([
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCertificate,
            kSecAttrLabel: marker,
        ], operation: "save-certificate")

        guard let identity = identity(for: secCertificate) else {
            throw IdentityError.certificateCreationFailed
        }
        log.info("generated a TLS certificate for \(addresses.sorted().joined(separator: ", "), privacy: .public)")
        return identity
    }

    /// **鍵はキーチェーンの中で作る。**
    /// `SecKeyCreateWithData` で作った「浮いた」鍵を `kSecValueRef` で `SecItemAdd` に渡すと、
    /// ファイルベースのキーチェーンは項目参照として受け付けず `errSecInvalidItemRef` を返す。
    /// 作ってから取り出して swift-certificates に署名させる。
    private static func storeNewKey() throws -> P256.Signing.PrivateKey {
        var error: Unmanaged<CFError>?
        var privateKeyAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrLabel: marker,
        ]
        // 取れなかった場合は既定（作成したアプリだけ）になる。HTTPS が使えなくなる可能性は
        // 残るが、鍵を作れないよりはよい
        if let access = try? unrestrictedAccess() {
            privateKeyAttributes[kSecAttrAccess] = access
        }

        guard let secKey = SecKeyCreateRandomKey(query([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: privateKeyAttributes as CFDictionary,
        ]), &error) else {
            throw IdentityError.keyCreationFailed(
                (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            )
        }

        // EC の秘密鍵は ANSI X9.63 形式（04 || X || Y || K）で出てくる
        guard let external = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            try? delete([kSecClass: kSecClassKey, kSecMatchItemList: [secKey]], operation: "rollback-key")
            throw IdentityError.keyCreationFailed(
                (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unavailable"
            )
        }
        return try P256.Signing.PrivateKey(x963Representation: external)
    }

    /// 秘密鍵に付ける利用許可。**どのプロセスからも確認なしで使える**ようにする。
    ///
    /// 既定（`SecAccessCreate` に `nil` を渡したときと同じ＝作成したアプリだけ）にすると、
    /// **アプリを更新した瞬間に HTTPS が黙って死ぬ。** 署名が変わった実行ファイルから鍵を
    /// 使おうとするとキーチェーンが確認ダイアログを出そうとし、検証モード（§2.7）のように
    /// UI を持たないプロセスでは**そのまま返ってこない**。TCP は繋がるのに TLS ハンドシェイクが
    /// 完了しない、という一番分かりにくい壊れ方をする（実際に踏んだ）。
    ///
    /// 守るものと釣り合っているかを考えたうえでの判断:
    /// この鍵が守るのは LAN 内の中間者だけで、**同じ Mac 上のプロセスに対しては何も守っていない**
    /// （画面を撮れる立場のプロセスは、そもそも配信内容そのものを直接読める）。
    /// 秘密は接続トークンとホスト承認の側にあり（SPEC.md §5.2）、ここではない。
    private static func unrestrictedAccess() throws -> SecAccess {
        var access: SecAccess?
        let status = SecAccessCreate(marker as CFString, nil, &access)
        guard status == errSecSuccess, let access else {
            throw IdentityError.keychain(status, "create-access")
        }

        var acls: CFArray?
        let listStatus = SecAccessCopyACLList(access, &acls)
        guard listStatus == errSecSuccess, let entries = acls as? [SecACL] else {
            throw IdentityError.keychain(listStatus, "read-acl")
        }

        // `applicationList` に nil を渡すと「どのアプリでも可」になる。
        // 空配列だと「どのアプリも不可」で、意味が正反対になる
        for acl in entries {
            let contentsStatus = SecACLSetContents(acl, nil, "" as CFString, [])
            guard contentsStatus == errSecSuccess else {
                throw IdentityError.keychain(contentsStatus, "set-acl")
            }
        }
        return access
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
        let status = SecItemCopyMatching(query([
            kSecClass: kSecClassCertificate,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ]), &result)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        default:
            throw IdentityError.keychain(status, "list-certificates")
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
        let status = SecItemAdd(query(attributes), nil)
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
                try delete([kSecClass: kSecClassKey, kSecMatchItemList: [key]], operation: "delete-old-key")
            }
        }
        try delete(
            [kSecClass: kSecClassCertificate, kSecMatchItemList: [certificate]],
            operation: "delete-old-certificate"
        )
    }

    private static func delete(_ attributes: [CFString: Any], operation: String) throws {
        let status = SecItemDelete(query(attributes))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychain(status, operation)
        }
    }
}

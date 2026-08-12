import CoreGraphics
import Foundation
import OSLog

/// 接続トークンの発行と検証（SPEC.md §5.2）。
///
/// トークンは無人アクセスを防ぐ仕組み**ではない**（それはホスト承認の役目）。ここが担うのは
/// 「画面に出ている QR を読んだ人だけが繋げる」ところまでで、次の 3 つを守る。
///
/// - **TTL 5 分。** 期限が切れたら次に読まれたときに作り直す。古い QR の写真では繋がらない。
/// - **1 本の接続が確立しても失効させない。** 失効させると 2 画面目を繋げなくなる。
/// - **失敗 5 回で作り直す。** 総当たりの試行を、1 つのトークンあたり 5 回で打ち切る。
///   40bit に対して 5 回なので、当てるより先にトークンが変わる。
///
/// 検証はネットワーク側のスレッドから呼ばれ、発行は UI から読まれる。
/// どちらも短時間で終わるためロック 1 本で足りる。
final class PairingService: @unchecked Sendable {

    /// このトークンで許す失敗回数。超えたら作り直す
    static let failureLimit = 5

    /// 期限（SPEC.md §5.2）。既定は 5 分
    let lifetime: Duration
    /// 同じ相手からの失敗を抑える窓。総当たりのために張り直されるのを止める
    let cooldown: Duration
    /// 承認済みのビューアが繋ぎ直せる期間（`issueResumeTicket`）
    let resumeLifetime: Duration

    /// 時間はすべて注入できるようにする。**この 3 つが本体の安全性そのもの**なので、
    /// 5 分待たないと確かめられない作りにしない（SPEC.md §11-6）
    init(
        lifetime: Duration = .seconds(300),
        cooldown: Duration = .seconds(30),
        resumeLifetime: Duration = .seconds(600)
    ) {
        self.lifetime = lifetime
        self.cooldown = cooldown
        self.resumeLifetime = resumeLifetime
    }

    enum Verdict: Sendable, Equatable {
        case accepted
        case invalid
        case expired
        case tooManyAttempts

        /// ビューアへ返すコード。文言はビューア側が自分の言語で出す（SPEC.md §7）
        var errorCode: String? {
            switch self {
            case .accepted: nil
            case .invalid: "invalid_token"
            case .expired: "token_expired"
            case .tooManyAttempts: "too_many_attempts"
            }
        }
    }

    /// UI に出す現在の状態。読んだ時点で期限が切れていれば作り直したあとの値を返す
    struct Snapshot: Sendable, Equatable {
        var token: String
        /// 期限までの残り
        var remaining: Duration
        /// 直近の作り直しが「失敗が続いたから」だったか。UI で理由を出す
        var regeneratedAfterFailures: Bool
    }

    private let log = Logger(subsystem: "net.sharkpp.doppelscreen", category: "pairing")
    private let lock = NSLock()

    private var token = PairingToken.generate()
    private var issuedAt = ContinuousClock.now
    private var failures = 0
    private var regeneratedAfterFailures = false
    /// 相手ごとの直近の**失敗**時刻。窓の中で `failureLimit` 回を超えたら比較すらしない。
    /// 成功は数えない — ビューアは自動再接続するので、正しい端末が枠を食い潰してはいけない
    private var failureTimes: [String: [ContinuousClock.Instant]] = [:]

    /// 期限が切れていれば作り直してから返す。QR と URL はこの値から組み立てる
    func snapshot() -> Snapshot {
        lock.withLock {
            expireIfNeeded()
            return Snapshot(
                token: token,
                remaining: lifetime - (ContinuousClock.now - issuedAt),
                regeneratedAfterFailures: regeneratedAfterFailures
            )
        }
    }

    /// 人が明示的に作り直す。QR を配り直したいときに使う
    func regenerate() {
        lock.withLock { reissue(afterFailures: false) }
    }

    // MARK: - 再接続チケット（SPEC.md §11-4）
    //
    // 一度承認されたビューアが、承認をやり直さずに繋ぎ直せるようにする。`resumeLifetime` は
    // ネットワーク断・スリープ復帰・ディスプレイ構成変更を跨ぐには足りて、「席を外している
    // 間に勝手に繋がれる」には足りない長さにする。長く取ると無人アクセスを禁じた前提
    // （SPEC.md §1.2）が崩れる。

    /// 発行済みのチケット。画面に紐づける — A の承認で B が映せてはいけない
    private var resumeTickets: [String: (display: CGDirectDisplayID, issuedAt: ContinuousClock.Instant)] = [:]

    /// 承認済みのビューアへ渡す。**使い切り** — 繋ぎ直したら新しいものを発行する
    func issueResumeTicket(for display: CGDirectDisplayID) -> String {
        lock.withLock {
            pruneResumeTickets()
            let ticket = PairingToken.generate(length: 24)
            resumeTickets[ticket] = (display, ContinuousClock.now)
            return ticket
        }
    }

    /// チケットを使う。通れば承認をやり直さずに配信を再開してよい
    func redeemResumeTicket(_ ticket: String, for display: CGDirectDisplayID?) -> Bool {
        lock.withLock {
            pruneResumeTickets()
            guard let issued = resumeTickets[ticket] else { return false }
            // 画面が違えば別の承認が要る
            guard display == nil || display == issued.display else { return false }
            resumeTickets[ticket] = nil
            return true
        }
    }

    /// その画面のチケットを無効にする。人が「切断」を押したときに呼ぶ —
    /// 切ったつもりのビューアが黙って戻ってきてはいけない
    func revokeResumeTickets(for display: CGDirectDisplayID) {
        lock.withLock {
            resumeTickets = resumeTickets.filter { $0.value.display != display }
        }
    }

    private func pruneResumeTickets() {
        let now = ContinuousClock.now
        resumeTickets = resumeTickets.filter { now - $0.value.issuedAt < resumeLifetime }
    }

    /// ビューアが名乗ったトークンを検証する。ネットワーク側のスレッドから呼ばれる
    func verify(_ presented: String, from address: String) -> Verdict {
        lock.withLock {
            guard !isBlocked(address) else {
                log.notice("pairing: too many attempts from \(address, privacy: .public)")
                return .tooManyAttempts
            }

            let wasExpired = isExpired
            expireIfNeeded()

            // 期限切れは「間違い」ではないので失敗回数に数えない。
            // 数えると、古い QR を持った端末が繋ぎに来るだけでトークンが回り続ける
            if wasExpired { return .expired }

            guard constantTimeEquals(presented, token) else {
                failures += 1
                recordFailure(address)
                log.notice("pairing: rejected token from \(address, privacy: .public) (\(self.failures)/\(Self.failureLimit))")
                if failures >= Self.failureLimit { reissue(afterFailures: true) }
                return .invalid
            }

            // 繋がっても失効させない。2 画面目を別の端末から繋げるようにするため（SPEC.md §5.2）
            failures = 0
            regeneratedAfterFailures = false
            return .accepted
        }
    }

    // MARK: - ロックの内側

    private var isExpired: Bool {
        ContinuousClock.now - issuedAt >= lifetime
    }

    private func expireIfNeeded() {
        guard isExpired else { return }
        reissue(afterFailures: false)
    }

    private func reissue(afterFailures: Bool) {
        token = PairingToken.generate()
        issuedAt = ContinuousClock.now
        failures = 0
        regeneratedAfterFailures = afterFailures
        log.info("pairing: token reissued (afterFailures: \(afterFailures))")
    }

    /// 同じ相手からの失敗を窓で絞る。総当たりは「トークンを作り直す」だけでは止まらない
    /// （作り直しても試行し続けられる）ため、頻度そのものを抑える
    private func isBlocked(_ address: String) -> Bool {
        let now = ContinuousClock.now
        // 溜め込まないよう、窓を抜けた相手ごと落とす
        failureTimes = failureTimes.compactMapValues { times in
            let kept = times.filter { now - $0 < cooldown }
            return kept.isEmpty ? nil : kept
        }
        return (failureTimes[address]?.count ?? 0) >= Self.failureLimit
    }

    private func recordFailure(_ address: String) {
        failureTimes[address, default: []].append(ContinuousClock.now)
    }

    /// トークンの照合は長さも内容も漏らさない。LAN 内とはいえ比較時間で当てられる余地を残さない
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}

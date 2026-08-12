import Testing

/// 接続トークンの発行・検証（SPEC.md §5.2）と再接続チケット（§11-4）。
///
/// 実機も画面収録の許可も要らない純粋なロジックなので、ここで確かめる（SPEC.md §11-6）。
/// 期限は注入できるようにしてあるため、5 分待たずに確認できる。
struct PairingServiceTests {

    @Test("正しいトークンだけ通す")
    func acceptsCurrentToken() {
        let pairing = PairingService()
        let token = pairing.snapshot().token

        #expect(pairing.verify(token, from: "192.168.1.2") == .accepted)
        #expect(pairing.verify("wrong123", from: "192.168.1.2") == .invalid)
    }

    /// 失効させると 2 画面目を繋げなくなる（SPEC.md §5.2）
    @Test("1 本繋がってもトークンは失効しない")
    func staysValidAfterUse() {
        let pairing = PairingService()
        let token = pairing.snapshot().token

        #expect(pairing.verify(token, from: "192.168.1.2") == .accepted)
        #expect(pairing.verify(token, from: "192.168.1.3") == .accepted)
        #expect(pairing.snapshot().token == token)
    }

    @Test("期限が切れたら作り直し、古いトークンは通さない")
    func expires() async throws {
        let pairing = PairingService(lifetime: .milliseconds(50))
        let old = pairing.snapshot().token

        try await Task.sleep(for: .milliseconds(80))

        #expect(pairing.verify(old, from: "192.168.1.2") == .expired)
        #expect(pairing.snapshot().token != old)
    }

    @Test("失敗が 5 回続いたらトークンを作り直す")
    func regeneratesAfterFailures() {
        let pairing = PairingService()
        let old = pairing.snapshot().token

        // 相手を散らす。1 か所からの連打はレート制限で先に止まる
        for index in 0..<PairingService.failureLimit {
            #expect(pairing.verify("wrong\(index)", from: "10.0.0.\(index)") == .invalid)
        }

        let snapshot = pairing.snapshot()
        #expect(snapshot.token != old)
        #expect(snapshot.regeneratedAfterFailures)
    }

    @Test("同じ相手の失敗が続いたら照合すらしない")
    func ratelimitsRepeatedFailures() {
        let pairing = PairingService()

        for _ in 0..<PairingService.failureLimit {
            _ = pairing.verify("wrong", from: "10.0.0.9")
        }
        // 正しいトークンを出しても窓が明けるまで受け付けない
        #expect(pairing.verify(pairing.snapshot().token, from: "10.0.0.9") == .tooManyAttempts)
        // 別の相手は巻き込まない
        #expect(pairing.verify(pairing.snapshot().token, from: "10.0.0.8") == .accepted)
    }

    /// ビューアは自動で繋ぎ直す（SPEC.md §11-4）。正しい端末が枠を食い潰してはいけない
    @Test("成功はレート制限の枠を使わない")
    func successDoesNotConsumeBudget() {
        let pairing = PairingService()
        let token = pairing.snapshot().token

        for _ in 0..<20 {
            #expect(pairing.verify(token, from: "10.0.0.7") == .accepted)
        }
    }

    @Test("窓が明ければまた試せる")
    func lockoutExpires() async throws {
        let pairing = PairingService(cooldown: .milliseconds(50))

        for _ in 0..<PairingService.failureLimit {
            _ = pairing.verify("wrong", from: "10.0.0.9")
        }
        #expect(pairing.verify(pairing.snapshot().token, from: "10.0.0.9") == .tooManyAttempts)

        try await Task.sleep(for: .milliseconds(80))
        #expect(pairing.verify(pairing.snapshot().token, from: "10.0.0.9") == .accepted)
    }

    @Test("トークンは 8 文字で、紛らわしい文字を含まない")
    func tokenShape() {
        let token = PairingService().snapshot().token
        #expect(token.count == 8)
        #expect(token.allSatisfy { "0123456789abcdefghjkmnpqrstvwxyz".contains($0) })
    }
}

/// 再接続チケット（SPEC.md §11-4）
struct ResumeTicketTests {

    @Test("使い切り。2 回目は通らない")
    func singleUse() {
        let pairing = PairingService()
        let ticket = pairing.issueResumeTicket(for: 1)

        #expect(pairing.redeemResumeTicket(ticket, for: 1))
        #expect(!pairing.redeemResumeTicket(ticket, for: 1))
    }

    /// 画面 A の承認で画面 B が映せてはいけない
    @Test("発行された画面にしか使えない")
    func boundToDisplay() {
        let pairing = PairingService()
        let ticket = pairing.issueResumeTicket(for: 1)

        #expect(!pairing.redeemResumeTicket(ticket, for: 2))
        // 弾かれただけで、本来の画面には使えるまま
        #expect(pairing.redeemResumeTicket(ticket, for: 1))
    }

    @Test("期限が切れたら通らない")
    func expires() async throws {
        let pairing = PairingService(resumeLifetime: .milliseconds(50))
        let ticket = pairing.issueResumeTicket(for: 1)

        try await Task.sleep(for: .milliseconds(80))
        #expect(!pairing.redeemResumeTicket(ticket, for: 1))
    }

    /// 切ったつもりのビューアが黙って戻ってきてはいけない
    @Test("切断すると無効になる")
    func revoked() {
        let pairing = PairingService()
        let ticket = pairing.issueResumeTicket(for: 1)
        let other = pairing.issueResumeTicket(for: 2)

        pairing.revokeResumeTickets(for: 1)

        #expect(!pairing.redeemResumeTicket(ticket, for: 1))
        #expect(pairing.redeemResumeTicket(other, for: 2))
    }

    @Test("接続トークンとは別物。トークンが回っても効く")
    func independentOfPairingToken() {
        let pairing = PairingService()
        let ticket = pairing.issueResumeTicket(for: 1)

        pairing.regenerate()

        #expect(pairing.redeemResumeTicket(ticket, for: 1))
    }
}

// 自動生成 — 直接編集しない。i18n/*.yaml を直して `make i18n` を実行する。
//
// 実際の文言は <言語>.lproj/Localizable.strings にあり、選択は OS が行う。
// ここが持つのはキーの綴りと引数の型だけ。

import Foundation

enum L10n {
    enum Connection {
        /// 承認
        static var approve: String {
            NSLocalizedString("host.connection.approve", comment: "")
        }

        /// HTTPS は使えません: {reason}
        static func certificateUnavailable(reason: String) -> String {
            String(format: NSLocalizedString("host.connection.certificateUnavailable", comment: ""), reason)
        }

        /// {address} と接続中
        static func connecting(address: String) -> String {
            String(format: NSLocalizedString("host.connection.connecting", comment: ""), address)
        }

        /// URL をコピー
        static var copyUrl: String {
            NSLocalizedString("host.connection.copyUrl", comment: "")
        }

        /// 切断
        static var disconnect: String {
            NSLocalizedString("host.connection.disconnect", comment: "")
        }

        /// QR を隠す
        static var hideQR: String {
            NSLocalizedString("host.connection.hideQR", comment: "")
        }

        /// ビューア未接続
        static var idle: String {
            NSLocalizedString("host.connection.idle", comment: "")
        }

        /// LAN のアドレスが見つかりません
        static var noAddress: String {
            NSLocalizedString("host.connection.noAddress", comment: "")
        }

        /// 画質: {preset}
        static func quality(preset: String) -> String {
            String(format: NSLocalizedString("host.connection.quality", comment: ""), preset)
        }

        /// 拒否
        static var reject: String {
            NSLocalizedString("host.connection.reject", comment: "")
        }

        /// {address} から接続要求
        static func request(address: String) -> String {
            String(format: NSLocalizedString("host.connection.request", comment: ""), address)
        }

        /// この QR をビューアにする端末のカメラで読んでください
        static var scanHint: String {
            NSLocalizedString("host.connection.scanHint", comment: "")
        }

        /// QR を表示
        static var showQR: String {
            NSLocalizedString("host.connection.showQR", comment: "")
        }

        /// {address} へ配信中
        static func streaming(address: String) -> String {
            String(format: NSLocalizedString("host.connection.streaming", comment: ""), address)
        }
    }

    enum Control {
        /// プレビュー
        static var preview: String {
            NSLocalizedString("host.control.preview", comment: "")
        }

        /// 配信を開始
        static var start: String {
            NSLocalizedString("host.control.start", comment: "")
        }

        /// 停止
        static var stop: String {
            NSLocalizedString("host.control.stop", comment: "")
        }
    }

    enum Failure {
        /// ビューアの応答を受け付けられませんでした
        static var answerRejected: String {
            NSLocalizedString("host.failure.answerRejected", comment: "")
        }

        /// 証明書を生成できませんでした
        static var certificateCreationFailed: String {
            NSLocalizedString("host.failure.certificateCreationFailed", comment: "")
        }

        /// 制御チャネルを生成できません
        static var controlUnavailable: String {
            NSLocalizedString("host.failure.controlUnavailable", comment: "")
        }

        /// ディスプレイ {id} が見つかりません
        static func displayNotFound(id: String) -> String {
            String(format: NSLocalizedString("host.failure.displayNotFound", comment: ""), id)
        }

        /// 秘密鍵を生成できませんでした: {message}
        static func keyCreationFailed(message: String) -> String {
            String(format: NSLocalizedString("host.failure.keyCreationFailed", comment: ""), message)
        }

        /// キーチェーン操作に失敗しました（{operation}: {message}）
        static func keychain(operation: String, message: String) -> String {
            String(format: NSLocalizedString("host.failure.keychain", comment: ""), operation, message)
        }

        /// 接続に失敗しました
        static var peerFailed: String {
            NSLocalizedString("host.failure.peerFailed", comment: "")
        }

        /// PeerConnection を生成できません
        static var peerUnavailable: String {
            NSLocalizedString("host.failure.peerUnavailable", comment: "")
        }

        /// ビューアとの接続が切れました
        static var viewerDisconnected: String {
            NSLocalizedString("host.failure.viewerDisconnected", comment: "")
        }

        /// ビューアが切断しました
        static var viewerLeft: String {
            NSLocalizedString("host.failure.viewerLeft", comment: "")
        }

        /// ビューアページがバンドルに含まれていません（apps/web のビルドを確認してください）
        static var viewerPageMissing: String {
            NSLocalizedString("host.failure.viewerPageMissing", comment: "")
        }
    }

    enum Menu {
        /// エラー
        static var failed: String {
            NSLocalizedString("host.menu.failed", comment: "")
        }

        /// DoppelScreen を終了
        static var quit: String {
            NSLocalizedString("host.menu.quit", comment: "")
        }

        /// {count} 件の接続要求
        static func requests(count: String) -> String {
            String(format: NSLocalizedString("host.menu.requests", comment: ""), count)
        }

        /// 待受中（{count} 画面を配信）
        static func serving(count: String) -> String {
            String(format: NSLocalizedString("host.menu.serving", comment: ""), count)
        }

        /// ウィンドウを表示
        static var showWindow: String {
            NSLocalizedString("host.menu.showWindow", comment: "")
        }

        /// 開始中…
        static var starting: String {
            NSLocalizedString("host.menu.starting", comment: "")
        }

        /// 停止中
        static var stopped: String {
            NSLocalizedString("host.menu.stopped", comment: "")
        }
    }

    enum Onboarding {
        /// 現在の状態: 未許可（1 秒ごとに再確認しています）
        static var checking: String {
            NSLocalizedString("host.onboarding.checking", comment: "")
        }

        /// システム設定の「プライバシーとセキュリティ  ›  画面収録」で DoppelScreen を許可してください。
        static var guidanceAgain: String {
            NSLocalizedString("host.onboarding.guidanceAgain", comment: "")
        }

        /// DoppelScreen はこの Mac の画面を配信します。
        static var guidanceFirst: String {
            NSLocalizedString("host.onboarding.guidanceFirst", comment: "")
        }

        /// システム設定を開く
        static var openSettings: String {
            NSLocalizedString("host.onboarding.openSettings", comment: "")
        }

        /// 再起動して反映
        static var relaunch: String {
            NSLocalizedString("host.onboarding.relaunch", comment: "")
        }

        /// 許可を求める
        static var request: String {
            NSLocalizedString("host.onboarding.request", comment: "")
        }

        /// 画面収録の許可が必要です
        static var title: String {
            NSLocalizedString("host.onboarding.title", comment: "")
        }
    }

    enum Pairing {
        /// 期限切れ。作り直してください
        static var expired: String {
            NSLocalizedString("host.pairing.expired", comment: "")
        }

        /// あと {seconds} 秒で新しくなります
        static func expires(seconds: String) -> String {
            String(format: NSLocalizedString("host.pairing.expires", comment: ""), seconds)
        }

        /// 作り直す
        static var regenerate: String {
            NSLocalizedString("host.pairing.regenerate", comment: "")
        }

        /// トークンの誤りが続いたため作り直しました
        static var rejected: String {
            NSLocalizedString("host.pairing.rejected", comment: "")
        }

        /// 接続トークン: {token}
        static func token(token: String) -> String {
            String(format: NSLocalizedString("host.pairing.token", comment: ""), token)
        }
    }

    enum Preview {
        /// 接続要求を承認するとここに映ります
        static var awaitingApproval: String {
            NSLocalizedString("host.preview.awaitingApproval", comment: "")
        }

        /// 接続しています…
        static var connecting: String {
            NSLocalizedString("host.preview.connecting", comment: "")
        }

        /// ディスプレイが見つかりません
        static var noDisplay: String {
            NSLocalizedString("host.preview.noDisplay", comment: "")
        }

        /// 「配信を開始」で待受を始めます
        static var notServing: String {
            NSLocalizedString("host.preview.notServing", comment: "")
        }

        /// URL を開いたビューアからの接続を待っています
        static var waitingViewer: String {
            NSLocalizedString("host.preview.waitingViewer", comment: "")
        }
    }

    enum Quality {
        /// バランス
        static var balanced: String {
            NSLocalizedString("host.quality.balanced", comment: "")
        }

        /// 文字くっきり
        static var sharp: String {
            NSLocalizedString("host.quality.sharp", comment: "")
        }

        /// なめらか
        static var smooth: String {
            NSLocalizedString("host.quality.smooth", comment: "")
        }
    }

    enum Status {
        /// {count} 件の接続要求
        static func requests(count: String) -> String {
            String(format: NSLocalizedString("host.status.requests", comment: ""), count)
        }

        /// {active} / {total} 画面を配信中
        static func streaming(active: String, total: String) -> String {
            String(format: NSLocalizedString("host.status.streaming", comment: ""), active, total)
        }
    }
}

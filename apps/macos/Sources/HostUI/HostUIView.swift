import FlutterMacOS
import SwiftUI

/// メインウィンドウの中身。描いているのは Flutter（apps/host_ui）。
///
/// ウィンドウを閉じると SwiftUI はこのビューを捨てるが、エンジンは `HostUIBridge` が持ち続ける。
/// 開き直したときに新しい `FlutterViewController` を同じエンジンへ付け直す。
struct HostUIView: NSViewControllerRepresentable {
    let bridge: HostUIBridge

    func makeNSViewController(context: Context) -> FlutterViewController {
        FlutterViewController(engine: bridge.engine, nibName: nil, bundle: nil)
    }

    func updateNSViewController(_ controller: FlutterViewController, context: Context) {}

    /// エンジンに付けられるビューは 1 つだけ。外しておかないと開き直せない。
    /// SwiftUI は新しいビューを作ってから古い方を捨てることがあるので、自分が付いているときだけ外す
    static func dismantleNSViewController(_ controller: FlutterViewController, coordinator: ()) {
        if controller.engine.viewController === controller {
            controller.engine.viewController = nil
        }
    }
}

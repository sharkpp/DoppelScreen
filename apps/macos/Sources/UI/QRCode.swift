import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 接続 URL の QR（SPEC.md §5.2）。
///
/// 「QR を読むだけで繋がる」ところがペアリングの本体で、手入力は QR が読めない環境の
/// 代替でしかない。URL にはトークンと画面が丸ごと入る。
///
/// CoreImage の内蔵フィルタで作る。外部ライブラリを足す理由がない。
///
/// 描画のためだけに使うので `MainActor` に閉じる。`CIContext` と `NSCache` を
/// スレッド間で共有しないことが、そのまま並行性の保証になる。
@MainActor
enum QRCode {

    private static let context = CIContext()
    /// 生成は数 ms かかる。URL はトークンの期限（5 分）まで変わらないので使い回す
    private static let cache = NSCache<NSString, NSImage>()

    /// 指定した一辺の長さ（ポイント）で描いた QR。作れなければ `nil`
    static func image(for text: String, size: CGFloat) -> NSImage? {
        let key = "\(Int(size)):\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // URL は短く、誤り訂正を厚くしても密度が上がりすぎない。画面越しに読ませるので余裕を取る
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // ベクタではないので、必要な大きさまで整数倍に拡大してからラスタライズする。
        // 補間で拡大するとモジュールの境界がぼけて読み取り率が落ちる
        let scale = max(1, (size / output.extent.width).rounded(.up))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        cache.setObject(image, forKey: key)
        return image
    }
}

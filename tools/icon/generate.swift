#!/usr/bin/env swift
// アイコンの原本（assets/icon/doppelscreen.svg）を各 OS の形式へ書き出す。
//
//   swift tools/icon/generate.swift        生成する（make icon）
//
// 生成物はリポジトリに入れる。ビルドにこの道具を要求しないため。
//
// **各サイズは原本から直接ラスタライズする。** 大きい PNG を縮小して回すと、
// 16px 側で輪郭が濁る。ベクタのまま各サイズへ描くほうが小さい側が保つ。
//
// SVG の解釈は AppKit（NSImage）に任せている。外部の変換ツールを要求しない。
// Windows の .ico も同じ原本から生成する。

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appending(path: "assets/icon/doppelscreen.svg")
let iconset = root.appending(path: "apps/macos/build/AppIcon.iconset")
let output = root.appending(path: "apps/macos/Sources/Resources/AppIcon.icns")
let windowsOutput = root.appending(path: "apps/windows/resources/AppIcon.ico")

guard let master = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(Data("原本を読めません: \(source.path)\n".utf8))
    exit(1)
}

/// 原本を 1 辺 `size` の PNG へ描く。縮小ではなくその解像度で描き直す
func rasterize(_ size: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw Failure("\(size)px のビットマップを作れません") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero, operation: .copy, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw Failure("\(size)px を PNG にできません")
    }
    return data
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8(value >> 24))
    }
}

do {
    // .icns が要求する組み合わせ。@2x は 1x の 2 倍のピクセル数で同じ名前を持つ
    let points = [16, 32, 128, 256, 512]

    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    for point in points {
        try rasterize(point).write(to: iconset.appending(path: "icon_\(point)x\(point).png"))
        try rasterize(point * 2).write(to: iconset.appending(path: "icon_\(point)x\(point)@2x.png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", iconset.path, "--output", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw Failure("iconutil が失敗しました") }

    try FileManager.default.removeItem(at: iconset)
    let windowsSizes = [16, 24, 32, 48, 64, 128, 256]
    let windowsImages = try windowsSizes.map(rasterize)
    var ico = Data()
    ico.appendUInt16LE(0)
    ico.appendUInt16LE(1)
    ico.appendUInt16LE(UInt16(windowsImages.count))
    var offset = 6 + 16 * windowsImages.count
    for (index, image) in windowsImages.enumerated() {
        let size = windowsSizes[index]
        ico.append(size == 256 ? 0 : UInt8(size))
        ico.append(size == 256 ? 0 : UInt8(size))
        ico.append(0)
        ico.append(0)
        ico.appendUInt16LE(1)
        ico.appendUInt16LE(32)
        ico.appendUInt32LE(UInt32(image.count))
        ico.appendUInt32LE(UInt32(offset))
        offset += image.count
    }
    for image in windowsImages { ico.append(image) }
    try FileManager.default.createDirectory(at: windowsOutput.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try ico.write(to: windowsOutput)
    print("書き出し: \(output.relativePath(from: root))")
    print("書き出し: \(windowsOutput.relativePath(from: root))")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

extension URL {
    func relativePath(from base: URL) -> String {
        path.hasPrefix(base.path + "/") ? String(path.dropFirst(base.path.count + 1)) : path
    }
}

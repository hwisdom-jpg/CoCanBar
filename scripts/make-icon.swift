// 把一张 1024×1024 的满版原画做成 macOS app 图标（Support/AppIcon.icns）。
// 按 macOS 图标网格：画布 1024，主体 824×824 居中，连续曲率圆角 185.4，带一层柔和投影。
//
//   xcrun swift scripts/make-icon.swift Support/AppIcon-source.png Support/AppIcon.icns
//
// 原画由 ChatGPT（Codex 图像生成）按项目配色生成，三个方案在 Support/图标方案/。
import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3, let source = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("用法：make-icon.swift <原画.png> <输出.icns>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2])

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let cg = context.cgContext
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: body).cgPath
    // 投影：先用不透明的形状画一次阴影，再把原画裁进形状里
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    cg.addPath(shape)
    cg.setFillColor(NSColor(srgbRed: 1, green: 0.28, blue: 0.1, alpha: 1).cgColor)
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    source.draw(in: body, from: .zero, operation: .copy, fraction: 1)
    cg.restoreGState()
    // 细描边，深色背景下边缘更清楚
    cg.addPath(shape)
    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor)
    cg.setLineWidth(2)
    cg.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("已生成：\(output.path)")

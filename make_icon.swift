// 生成 AppIcon.icns 所需的 iconset PNG：深蓝雷达底 + 绿色状态灯，呼应菜单栏的状态圆点。
// 用法：swift make_icon.swift <输出 iconset 目录>

import Cocoa

private func drawIcon(in rect: NSRect, size: CGFloat) {
    let scale = size / 1024.0
    let inset = 100 * scale // macOS 图标网格：1024 画布内 824 内容区
    let content = rect.insetBy(dx: inset, dy: inset)
    let cornerRadius = content.width * 0.2237
    let iconPath = NSBezierPath(roundedRect: content, xRadius: cornerRadius, yRadius: cornerRadius)

    guard let context = NSGraphicsContext.current else { return }
    context.saveGraphicsState()
    iconPath.addClip()

    // 背景：深藏青渐变，顶部略亮（此处 y 轴向上）
    let topColor = NSColor(calibratedRed: 0.14, green: 0.21, blue: 0.35, alpha: 1)
    let bottomColor = NSColor(calibratedRed: 0.03, green: 0.06, blue: 0.13, alpha: 1)
    NSGradient(colors: [bottomColor, topColor], atLocations: [0, 1], colorSpace: .deviceRGB)!
        .draw(in: iconPath, angle: 90)

    let center = NSPoint(x: content.midX, y: content.midY)
    let half = content.width / 2

    // 雷达环，由内向外逐渐变淡
    if size >= 64 {
        let rings: [(fraction: CGFloat, alpha: CGFloat)] = [(0.62, 0.20), (0.78, 0.12), (0.94, 0.06)]
        for ring in rings {
            let r = half * ring.fraction
            let ringPath = NSBezierPath(
                ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            )
            ringPath.lineWidth = max(1.5, 3 * scale)
            NSColor.white.withAlphaComponent(ring.alpha).setStroke()
            ringPath.stroke()
        }
    }

    // 状态灯外层辉光
    let coreRadius = half * (size >= 64 ? 0.36 : 0.42)
    let glowRadius = coreRadius * 2.3
    let glowRect = NSRect(
        x: center.x - glowRadius, y: center.y - glowRadius,
        width: glowRadius * 2, height: glowRadius * 2
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.55, alpha: 0.5),
        NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.55, alpha: 0)
    ])!.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

    // 灯体：径向渐变，光源在左上方
    let coreRect = NSRect(
        x: center.x - coreRadius, y: center.y - coreRadius,
        width: coreRadius * 2, height: coreRadius * 2
    )
    NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.85, green: 1.0, blue: 0.9, alpha: 1), 0.0),
        (NSColor(calibratedRed: 0.25, green: 0.9, blue: 0.45, alpha: 1), 0.45),
        (NSColor(calibratedRed: 0.04, green: 0.55, blue: 0.22, alpha: 1), 1.0)
    )!.draw(in: NSBezierPath(ovalIn: coreRect), relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))

    // 高光
    if size >= 128 {
        let highlightRect = NSRect(
            x: center.x - coreRadius * 0.55,
            y: center.y + coreRadius * 0.05,
            width: coreRadius * 0.8,
            height: coreRadius * 0.5
        )
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: highlightRect).fill()
    }

    // 图标顶部柔和反光
    if size >= 64 {
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.10),
            NSColor.white.withAlphaComponent(0.0)
        ])!.draw(
            from: NSPoint(x: content.midX, y: content.maxY),
            to: NSPoint(x: content.midX, y: content.midY),
            options: []
        )
    }

    context.restoreGraphicsState()
}

private func writePNG(size: Int, to path: String) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "无法创建位图 (\(size)px)"
        ])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(in: NSRect(x: 0, y: 0, width: size, height: size), size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "无法编码 PNG (\(size)px)"
        ])
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let iconset = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : ".build/AppIcon.iconset"

let files: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

do {
    try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    for file in files {
        try writePNG(size: file.pixels, to: (iconset as NSString).appendingPathComponent(file.name))
    }
    print("已生成 \(files.count) 个 PNG 到 \(iconset)")
} catch {
    FileHandle.standardError.write("!! \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

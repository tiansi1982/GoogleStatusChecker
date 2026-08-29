// 生成 AppIcon.icns 所需的 iconset PNG：macOS 圆角底板 + 三段服务状态柱，
// 与菜单栏中 Google / ChatGPT / Claude 的三段状态图标保持同一视觉语言。
// 用法：swift make_icon.swift <输出 iconset 目录>

import Cocoa

private func drawIcon(in rect: NSRect, size: CGFloat) {
    let scale = size / 1024.0
    let inset = 100 * scale // macOS 图标网格：1024 画布内 824 内容区
    let content = rect.insetBy(dx: inset, dy: inset)
    let cornerRadius = content.width * 0.2237
    let iconPath = NSBezierPath(roundedRect: content, xRadius: cornerRadius, yRadius: cornerRadius)

    guard let context = NSGraphicsContext.current else { return }

    // 与系统图标一致的悬浮阴影；保留透明画布边缘，Finder 中不会显得像满幅方块。
    context.saveGraphicsState()
    let iconShadow = NSShadow()
    iconShadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
    iconShadow.shadowBlurRadius = 34 * scale
    iconShadow.shadowOffset = NSSize(width: 0, height: -18 * scale)
    iconShadow.set()
    NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.16, alpha: 1).setFill()
    iconPath.fill()
    context.restoreGraphicsState()

    context.saveGraphicsState()
    iconPath.addClip()

    // 深海军蓝底板：顶部更通透，底部更稳重，避免纯黑造成廉价的高对比感。
    let topColor = NSColor(calibratedRed: 0.20, green: 0.34, blue: 0.56, alpha: 1)
    let bottomColor = NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.17, alpha: 1)
    NSGradient(colors: [bottomColor, topColor], atLocations: [0, 1], colorSpace: .deviceRGB)!
        .draw(in: iconPath, angle: 90)

    // 中心柔光只负责提亮符号，不加入额外图案，确保缩小后仍然干净。
    let glowSize = 690 * scale
    let glowRect = NSRect(
        x: content.midX - glowSize / 2,
        y: content.midY - glowSize / 2,
        width: glowSize,
        height: glowSize
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.82, blue: 0.66, alpha: 0.24),
        NSColor(calibratedRed: 0.10, green: 0.60, blue: 0.72, alpha: 0)
    ])!.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

    // 三根等高圆角竖条共同构成正方形轮廓，固定对应 Google / ChatGPT / Claude。
    let barWidth = 126 * scale
    let gap = 46 * scale
    let groupWidth = barWidth * 3 + gap * 2
    let barHeight = groupWidth
    let originX = content.midX - groupWidth / 2
    let originY = content.midY - barHeight / 2

    // 一层克制的绿色环境光，让符号像系统材质而不是平面贴纸。
    let auraRect = NSRect(
        x: originX - 54 * scale,
        y: originY - 54 * scale,
        width: groupWidth + 108 * scale,
        height: barHeight + 108 * scale
    )
    let auraPath = NSBezierPath(
        roundedRect: auraRect,
        xRadius: 106 * scale,
        yRadius: 106 * scale
    )
    context.saveGraphicsState()
    let auraShadow = NSShadow()
    auraShadow.shadowColor = NSColor(calibratedRed: 0.14, green: 0.95, blue: 0.65, alpha: 0.20)
    auraShadow.shadowBlurRadius = 60 * scale
    auraShadow.shadowOffset = .zero
    auraShadow.set()
    NSColor(calibratedWhite: 1, alpha: 0.018).setFill()
    auraPath.fill()
    context.restoreGraphicsState()

    let palettes: [(bottom: NSColor, top: NSColor)] = [
        (
            NSColor(calibratedRed: 0.06, green: 0.61, blue: 0.47, alpha: 1),
            NSColor(calibratedRed: 0.38, green: 0.94, blue: 0.74, alpha: 1)
        ),
        (
            NSColor(calibratedRed: 0.06, green: 0.68, blue: 0.39, alpha: 1),
            NSColor(calibratedRed: 0.56, green: 0.98, blue: 0.68, alpha: 1)
        ),
        (
            NSColor(calibratedRed: 0.04, green: 0.58, blue: 0.52, alpha: 1),
            NSColor(calibratedRed: 0.32, green: 0.91, blue: 0.80, alpha: 1)
        )
    ]

    for index in 0..<3 {
        let barRect = NSRect(
            x: originX + CGFloat(index) * (barWidth + gap),
            y: originY,
            width: barWidth,
            height: barHeight
        )
        let radius = barWidth / 2
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)

        context.saveGraphicsState()
        let barShadow = NSShadow()
        barShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        barShadow.shadowBlurRadius = 25 * scale
        barShadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
        barShadow.set()
        NSGradient(colors: [palettes[index].bottom, palettes[index].top])!
            .draw(in: barPath, angle: 90)
        context.restoreGraphicsState()

        // 顶部柔光和左侧窄高光提供厚度，同时不使用夸张的玻璃反射。
        context.saveGraphicsState()
        barPath.addClip()
        let upperRect = NSRect(
            x: barRect.minX,
            y: barRect.midY,
            width: barRect.width,
            height: barRect.height / 2
        )
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0),
            NSColor.white.withAlphaComponent(0.16)
        ])!.draw(in: upperRect, angle: 90)

        if size >= 32 {
            let sideHighlight = NSRect(
                x: barRect.minX + 18 * scale,
                y: barRect.minY + 74 * scale,
                width: max(1, 8 * scale),
                height: barRect.height - 148 * scale
            )
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSBezierPath(
                roundedRect: sideHighlight,
                xRadius: sideHighlight.width / 2,
                yRadius: sideHighlight.width / 2
            ).fill()
        }
        context.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.23).setStroke()
        barPath.lineWidth = max(0.45, 2.4 * scale)
        barPath.stroke()
    }

    // 底板顶部的整体反光与内描边，模拟 macOS 图标常见的层叠材质。
    if size >= 64 {
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.13),
            NSColor.white.withAlphaComponent(0.0)
        ])!.draw(
            from: NSPoint(x: content.midX, y: content.maxY),
            to: NSPoint(x: content.midX, y: content.midY + content.height * 0.04),
            options: []
        )
    }

    context.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.16).setStroke()
    iconPath.lineWidth = max(0.5, 2.2 * scale)
    iconPath.stroke()
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

private extension Data {
    mutating func appendFourCC(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendBigEndian(_ value: UInt32) {
        var bigEndianValue = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}

/// Writes the PNG-based ICNS chunks supported by macOS 11 and later.
/// This keeps icon generation reproducible even when the installed `iconutil`
/// cannot repack an otherwise valid iconset.
private func writeICNS(iconset: String, to outputPath: String) throws {
    let chunks: [(type: String, filename: String)] = [
        ("icp4", "icon_16x16.png"),
        ("ic11", "icon_16x16@2x.png"),
        ("icp5", "icon_32x32.png"),
        ("ic12", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic08", "icon_256x256.png"),
        ("ic14", "icon_256x256@2x.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png")
    ]

    var body = Data()
    for chunk in chunks {
        let pngPath = (iconset as NSString).appendingPathComponent(chunk.filename)
        let pngData = try Data(contentsOf: URL(fileURLWithPath: pngPath))
        let chunkLength = pngData.count + 8
        guard chunkLength <= Int(UInt32.max) else {
            throw NSError(domain: "make_icon", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "ICNS 数据块过大：\(chunk.filename)"
            ])
        }
        body.appendFourCC(chunk.type)
        body.appendBigEndian(UInt32(chunkLength))
        body.append(pngData)
    }

    let totalLength = body.count + 8
    guard totalLength <= Int(UInt32.max) else {
        throw NSError(domain: "make_icon", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "ICNS 文件过大"
        ])
    }

    var icns = Data()
    icns.appendFourCC("icns")
    icns.appendBigEndian(UInt32(totalLength))
    icns.append(body)
    try icns.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
}

let iconset = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : ".build/AppIcon.iconset"
let outputICNS = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "AppIcon.icns"

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
    try writeICNS(iconset: iconset, to: outputICNS)
    print("已打包 ICNS：\(outputICNS)")
} catch {
    FileHandle.standardError.write("!! \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

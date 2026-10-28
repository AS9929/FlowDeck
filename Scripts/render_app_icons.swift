import AppKit

// 用同一套 U 字形几何生成替换图标，原有极光图标保持不变。
// 从代码目录执行：swift Scripts/render_app_icons.swift
let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("FlowDeck/Resources/Assets.xcassets")

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func renderIcon(name: String, light: Bool) throws {
    let size = 1024
    // 使用 32 位无透明度上下文；AppKit 不支持为 24 位 RGB 位图创建绘制上下文。
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let background =
        light
        ? [color(0.82, 0.87, 0.93), color(0.99, 0.99, 1)]
        : [color(0.055, 0.07, 0.105), color(0.20, 0.23, 0.28)]
    NSGradient(colors: background)!.draw(in: bounds, angle: 110)

    let monogram = NSBezierPath()
    monogram.move(to: NSPoint(x: 310, y: 650))
    monogram.line(to: NSPoint(x: 310, y: 434))
    monogram.curve(
        to: NSPoint(x: 714, y: 434),
        controlPoint1: NSPoint(x: 310, y: 192),
        controlPoint2: NSPoint(x: 714, y: 192)
    )
    monogram.line(to: NSPoint(x: 714, y: 650))
    monogram.lineWidth = 110
    monogram.lineCapStyle = .round
    monogram.lineJoinStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(light ? 0.15 : 0.45)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    (light ? color(0.12, 0.39, 0.51) : color(0.83, 0.88, 0.93)).setStroke()
    monogram.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 较细的内高光保持石墨与白瓷在小尺寸下清晰，避免叠加细碎光效。
    let highlight = monogram.copy() as! NSBezierPath
    highlight.lineWidth = 76
    (light ? color(0.20, 0.52, 0.65) : color(0.94, 0.96, 0.99)).setStroke()
    highlight.stroke()

    let signal = NSBezierPath(roundedRect: NSRect(x: 656, y: 766, width: 116, height: 34), xRadius: 17, yRadius: 17)
    (light ? color(0.20, 0.52, 0.65) : color(0.94, 0.96, 0.99)).setFill()
    signal.fill()
    NSGraphicsContext.restoreGraphicsState()

    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    let data = bitmap.representation(using: .png, properties: [:])!
    for (suffix, preview) in [("appiconset", false), ("imageset", true)] {
        let resourceName = preview ? name + "Preview" : name
        let directory = assets.appendingPathComponent(resourceName + "." + suffix)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("icon.png"))
        var image: [String: String] = ["filename": "icon.png", "idiom": "universal"]
        if !preview {
            image["platform"] = "ios"
            image["size"] = "1024x1024"
        }
        let metadata: [String: Any] = ["images": [image], "info": ["author": "xcode", "version": 1]]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("Contents.json"))
    }
}

try renderIcon(name: "GraphiteIcon", light: false)
try renderIcon(name: "PorcelainIcon", light: true)

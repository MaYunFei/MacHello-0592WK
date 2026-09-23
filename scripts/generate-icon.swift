import AppKit

func generateIcon() {
    let size = CGSize(width: 1024, height: 1024)
    let image = NSImage(size: size)

    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // 1. Background rounded rectangle (Squircle)
    let rect = CGRect(origin: .zero, size: size)
    let cornerRadius: CGFloat = 224.0
    let bgPath = CGPath(roundedRect: rect.insetBy(dx: 32, dy: 32), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Gradient background: Deep Obsidian to Tech Teal/Midnight Blue
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1.0).cgColor,
        NSColor(red: 0.02, green: 0.04, blue: 0.07, alpha: 1.0).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
        ctx.restoreGState()
    }

    // Outer subtle border
    ctx.addPath(bgPath)
    ctx.setStrokeColor(NSColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 0.3).cgColor)
    ctx.setLineWidth(8.0)
    ctx.strokePath()

    // 2. Face ID 4-Corner Viewfinder
    let cornerColor = NSColor(red: 0.15, green: 0.75, blue: 0.95, alpha: 0.95).cgColor
    let cornerLen: CGFloat = 110.0
    let cornerR: CGFloat = 40.0
    let margin: CGFloat = 240.0
    let box = rect.insetBy(dx: margin, dy: margin)

    ctx.setStrokeColor(cornerColor)
    ctx.setLineWidth(24.0)
    ctx.setLineCap(.round)

    // Top-Left
    ctx.move(to: CGPoint(x: box.minX, y: box.maxY - cornerLen))
    ctx.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX + cornerLen, y: box.maxY), radius: cornerR)
    ctx.addLine(to: CGPoint(x: box.minX + cornerLen, y: box.maxY))
    ctx.strokePath()

    // Top-Right
    ctx.move(to: CGPoint(x: box.maxX - cornerLen, y: box.maxY))
    ctx.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX, y: box.maxY - cornerLen), radius: cornerR)
    ctx.addLine(to: CGPoint(x: box.maxX, y: box.maxY - cornerLen))
    ctx.strokePath()

    // Bottom-Left
    ctx.move(to: CGPoint(x: box.minX, y: box.minY + cornerLen))
    ctx.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX + cornerLen, y: box.minY), radius: cornerR)
    ctx.addLine(to: CGPoint(x: box.minX + cornerLen, y: box.minY))
    ctx.strokePath()

    // Bottom-Right
    ctx.move(to: CGPoint(x: box.maxX - cornerLen, y: box.minY))
    ctx.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY + cornerLen), radius: cornerR)
    ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY + cornerLen))
    ctx.strokePath()

    // 3. Central Face Silhouette (Eyes and Smile)
    ctx.setFillColor(cornerColor)

    // Eyes (Two pill-shaped capsules)
    let leftEye = CGRect(x: 410, y: 550, width: 28, height: 70)
    let rightEye = CGRect(x: 586, y: 550, width: 28, height: 70)
    ctx.addPath(CGPath(roundedRect: leftEye, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.addPath(CGPath(roundedRect: rightEye, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()

    // Nose (Vertical small pill)
    let nose = CGRect(x: 498, y: 460, width: 28, height: 50)
    ctx.addPath(CGPath(roundedRect: nose, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()

    // Smile (Arc)
    ctx.setStrokeColor(cornerColor)
    ctx.setLineWidth(24.0)
    ctx.move(to: CGPoint(x: 420, y: 390))
    ctx.addQuadCurve(to: CGPoint(x: 604, y: 390), control: CGPoint(x: 512, y: 320))
    ctx.strokePath()

    image.unlockFocus()

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return
    }

    let iconsetURL = URL(fileURLWithPath: "AppIcon.iconset")
    try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
    for s in sizes {
        let destURL = iconsetURL.appendingPathComponent("icon_\(s)x\(s).png")
        if s == 1024 {
            try? pngData.write(to: destURL)
        } else {
            let resized = NSImage(size: CGSize(width: s, height: s))
            resized.lockFocus()
            image.draw(in: CGRect(x: 0, y: 0, width: s, height: s))
            resized.unlockFocus()
            if let rTiff = resized.tiffRepresentation,
               let rBitmap = NSBitmapImageRep(data: rTiff),
               let rPng = rBitmap.representation(using: .png, properties: [:]) {
                try? rPng.write(to: destURL)
            }
        }
        if s <= 512 {
            let dest2xURL = iconsetURL.appendingPathComponent("icon_\(s)x\(s)@2x.png")
            let doubleS = s * 2
            let resized2x = NSImage(size: CGSize(width: doubleS, height: doubleS))
            resized2x.lockFocus()
            image.draw(in: CGRect(x: 0, y: 0, width: doubleS, height: doubleS))
            resized2x.unlockFocus()
            if let rTiff = resized2x.tiffRepresentation,
               let rBitmap = NSBitmapImageRep(data: rTiff),
               let rPng = rBitmap.representation(using: .png, properties: [:]) {
                try? rPng.write(to: dest2xURL)
            }
        }
    }
}

generateIcon()

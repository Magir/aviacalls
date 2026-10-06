// Рисует иконку приложения: красный кружок записи на тёмной плашке. Запуск: swift scripts/make-icon.swift
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let plate = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: size - 120, height: size - 120), xRadius: 230, yRadius: 230)
NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.16, alpha: 1).setFill()
plate.fill()
NSColor(calibratedRed: 0.93, green: 0.23, blue: 0.21, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 292, y: 292, width: 440, height: 440)).fill()
NSColor(calibratedWhite: 1, alpha: 0.9).setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: 212, y: 212, width: 600, height: 600))
ring.lineWidth = 44
ring.stroke()
image.unlockFocus()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    for (name, scale) in [("icon_\(px)x\(px).png", 1), ("icon_\(px / 2)x\(px / 2)@2x.png", 2)] where px / scale >= 16 && px / scale <= 512 {
        try! png.write(to: out.appendingPathComponent(name))
    }
}
print(out.path)

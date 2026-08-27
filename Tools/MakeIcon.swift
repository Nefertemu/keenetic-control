import AppKit
import Foundation

// Рисуем иконку кодом: никаких бинарных ассетов в репозитории.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

// --- Фон: squircle с диагональным градиентом.
let inset: CGFloat = size * 0.055
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = CGPath(roundedRect: rect, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil)

context.saveGState()
context.addPath(shape)
context.clip()

let colors = [
    NSColor(srgbRed: 0.22, green: 0.47, blue: 1.00, alpha: 1).cgColor,
    NSColor(srgbRed: 0.09, green: 0.20, blue: 0.62, alpha: 1).cgColor,
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])

// Мягкий блик сверху.
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(white: 1, alpha: 0.22).cgColor,
                               NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                      locations: [0, 1])!
context.drawRadialGradient(glow,
                           startCenter: CGPoint(x: size * 0.34, y: size * 0.86), startRadius: 0,
                           endCenter: CGPoint(x: size * 0.34, y: size * 0.86), endRadius: size * 0.55,
                           options: [])
context.restoreGState()

let center = CGPoint(x: size / 2, y: size * 0.505)
let white = NSColor.white
let accent = NSColor(srgbRed: 1.00, green: 0.74, blue: 0.24, alpha: 1)

// --- Корпус роутера.
let bodyWidth = size * 0.46
let bodyHeight = size * 0.135
let body = CGRect(x: center.x - bodyWidth / 2, y: center.y - bodyHeight * 1.55,
                  width: bodyWidth, height: bodyHeight)
context.setFillColor(white.cgColor)
context.addPath(CGPath(roundedRect: body, cornerWidth: bodyHeight * 0.42,
                       cornerHeight: bodyHeight * 0.42, transform: nil))
context.fillPath()

// Индикаторы на корпусе.
for index in 0..<3 {
    let dot = CGRect(x: body.minX + bodyWidth * 0.13 + CGFloat(index) * bodyWidth * 0.115,
                     y: body.midY - size * 0.011,
                     width: size * 0.022, height: size * 0.022)
    context.setFillColor(index == 2 ? accent.cgColor : NSColor(srgbRed: 0.16, green: 0.32, blue: 0.78, alpha: 1).cgColor)
    context.fillEllipse(in: dot)
}

// --- Волны сигнала над корпусом.
let waveBase = CGPoint(x: center.x, y: body.maxY + size * 0.012)
let lineWidth = size * 0.052
context.setLineCap(.round)
context.setLineWidth(lineWidth)

for index in 0..<3 {
    let radius = size * (0.105 + CGFloat(index) * 0.082)
    let alpha = 1.0 - Double(index) * 0.24
    context.setStrokeColor(white.withAlphaComponent(alpha).cgColor)
    context.addArc(center: waveBase, radius: radius,
                   startAngle: .pi * 0.19, endAngle: .pi * 0.81, clockwise: false)
    context.strokePath()
}

// --- Точка-источник.
context.setFillColor(accent.cgColor)
context.fillEllipse(in: CGRect(x: waveBase.x - size * 0.033, y: waveBase.y - size * 0.012,
                               width: size * 0.066, height: size * 0.066))

// --- Ветвление маршрута под корпусом.
context.setLineWidth(size * 0.036)
context.setStrokeColor(white.withAlphaComponent(0.92).cgColor)
let stemTop = body.minY
let junction = stemTop - size * 0.065
context.move(to: CGPoint(x: center.x, y: stemTop))
context.addLine(to: CGPoint(x: center.x, y: junction))
context.strokePath()

let arm = size * 0.135
let drop = size * 0.062
for direction in [-1.0, 1.0] {
    context.move(to: CGPoint(x: center.x, y: junction))
    context.addLine(to: CGPoint(x: center.x + arm * direction, y: junction))
    context.addLine(to: CGPoint(x: center.x + arm * direction, y: junction - drop))
    context.strokePath()

    context.setFillColor(direction < 0 ? white.cgColor : accent.cgColor)
    context.fillEllipse(in: CGRect(x: center.x + arm * direction - size * 0.032,
                                   y: junction - drop - size * 0.055,
                                   width: size * 0.064, height: size * 0.064))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try png.write(to: URL(fileURLWithPath: output))
print("icon written: \(output)")

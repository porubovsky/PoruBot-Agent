import AppKit
import CoreGraphics

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                    bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}
func gradient(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.drawLinearGradient(CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!,
                           start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func stroke(_ points: [CGPoint], width: CGFloat, tint: CGColor) {
    ctx.setStrokeColor(tint)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.addLines(between: points)
    ctx.strokePath()
}
let tile = rounded(65, 72, 894, 894, 202)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0x000000, 0.5))
ctx.setFillColor(color(0x151515))
ctx.addPath(tile)
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
gradient([color(0x424242), color(0x202020), color(0x080808)],
         from: CGPoint(x: 175, y: 990), to: CGPoint(x: 832, y: 60))
let glow = CGGradient(colorsSpace: colorSpace,
                      colors: [color(0xF0F0F0, 0.15), color(0xF0F0F0, 0)] as CFArray,
                      locations: nil)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 780, y: 821), startRadius: 0,
                       endCenter: CGPoint(x: 780, y: 821), endRadius: 522, options: [])
ctx.restoreGState()
ctx.setStrokeColor(color(0xE3E3E3, 0.33))
ctx.setLineWidth(5)
ctx.addPath(rounded(68, 75, 888, 888, 200))
ctx.strokePath()

func fill(_ tint: UInt32, _ draw: (CGMutablePath) -> Void) {
    let path = CGMutablePath()
    draw(path)
    path.closeSubpath()
    ctx.setFillColor(color(tint))
    ctx.addPath(path)
    ctx.fillPath()
}
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func dot(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ tint: UInt32) {
    ctx.setFillColor(color(tint))
    ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
}

// Tailored jacket and shirt
fill(0x050505) { p in
    p.move(to: point(358, 488))
    p.addQuadCurve(to: point(199, 237), control: point(218, 433))
    p.addQuadCurve(to: point(825, 237), control: point(512, 123))
    p.addQuadCurve(to: point(666, 488), control: point(804, 433))
}
fill(0x333333) { p in
    p.move(to: point(358, 452)); p.addLine(to: point(300, 366))
    p.addLine(to: point(356, 342)); p.addLine(to: point(331, 298))
    p.addLine(to: point(512, 207)); p.addLine(to: point(378, 457))
}
fill(0x454545) { p in
    p.move(to: point(666, 452)); p.addLine(to: point(724, 366))
    p.addLine(to: point(668, 342)); p.addLine(to: point(693, 298))
    p.addLine(to: point(512, 207)); p.addLine(to: point(646, 457))
}
fill(0xF1F1F1) { p in
    p.move(to: point(409, 414)); p.addLine(to: point(512, 217))
    p.addLine(to: point(615, 414)); p.addLine(to: point(512, 446))
}
fill(0x131313) { p in
    p.move(to: point(455, 375)); p.addLine(to: point(512, 352))
    p.addLine(to: point(569, 375)); p.addLine(to: point(569, 317))
    p.addLine(to: point(512, 335)); p.addLine(to: point(455, 317))
}
dot(501, 334, 22, 24, 0x353535)

// Helmet, visor and angular beard
let helmet = rounded(278, 424, 468, 391, 153)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: color(0x000000, 0.7))
ctx.setFillColor(color(0xEDEDED))
ctx.addPath(helmet); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(helmet); ctx.clip()
gradient([color(0xFFFFFF), color(0xEAEAEA), color(0xA0A0A0)],
         from: point(400, 810), to: point(650, 421))
ctx.restoreGState()
ctx.setFillColor(color(0x858585))
ctx.addPath(rounded(248, 541, 43, 124, 17)); ctx.fillPath()
ctx.addPath(rounded(733, 541, 43, 124, 17)); ctx.fillPath()
ctx.setFillColor(color(0x161616))
ctx.addPath(rounded(306, 561, 412, 174, 61)); ctx.fillPath()
stroke([point(358, 661), point(448, 642)], width: 18, tint: color(0xFFFFFF))
stroke([point(576, 642), point(666, 661)], width: 18, tint: color(0xFFFFFF))
fill(0x1B1B1B) { p in
    p.move(to: point(321, 600)); p.addLine(to: point(379, 525))
    p.addLine(to: point(447, 518)); p.addLine(to: point(480, 543))
    p.addLine(to: point(512, 533)); p.addLine(to: point(545, 543))
    p.addLine(to: point(578, 518)); p.addLine(to: point(645, 525))
    p.addLine(to: point(703, 600)); p.addLine(to: point(697, 493))
    p.addQuadCurve(to: point(512, 371), control: point(669, 412))
    p.addQuadCurve(to: point(327, 493), control: point(355, 412))
}
stroke([point(475, 484), point(550, 484)], width: 11, tint: color(0xF2F2F2))
stroke([point(392, 488), point(449, 435)], width: 9, tint: color(0x626262))
stroke([point(631, 488), point(574, 435)], width: 9, tint: color(0x626262))

let image = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

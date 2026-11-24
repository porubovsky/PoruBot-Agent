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
gradient([color(0xFFF8FC), color(0xE4DDF7), color(0xABAADD)],
         from: CGPoint(x: 175, y: 990), to: CGPoint(x: 832, y: 60))
let glow = CGGradient(colorsSpace: colorSpace,
                      colors: [color(0xF0F0F0, 0.15), color(0xF0F0F0, 0)] as CFArray,
                      locations: nil)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 780, y: 821), startRadius: 0,
                       endCenter: CGPoint(x: 780, y: 821), endRadius: 522, options: [])
ctx.restoreGState()
ctx.setStrokeColor(color(0xFFFFFF, 0.70))
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
// Curved tail and the profile of a cat reaching diagonally upward.
let black: UInt32 = 0x171421
let tail = CGMutablePath()
tail.move(to: point(411, 310))
tail.addCurve(to: point(202, 374), control1: point(294, 275), control2: point(207, 297))
tail.addCurve(to: point(283, 475), control1: point(197, 429), control2: point(250, 478))
tail.addCurve(to: point(270, 429), control1: point(320, 470), control2: point(308, 427))
ctx.setLineWidth(48)
ctx.setLineCap(.round)
ctx.setStrokeColor(color(black))
ctx.addPath(tail)
ctx.strokePath()
fill(black) { p in
    p.move(to: point(356, 279))
    p.addQuadCurve(to: point(359, 404), control: point(322, 348))
    p.addQuadCurve(to: point(438, 495), control: point(389, 455))
    p.addQuadCurve(to: point(475, 553), control: point(461, 521))
    p.addQuadCurve(to: point(459, 620), control: point(452, 585))
    p.addLine(to: point(453, 761))
    p.addQuadCurve(to: point(548, 680), control: point(507, 721))
    p.addQuadCurve(to: point(587, 675), control: point(570, 689))
    p.addLine(to: point(620, 728))
    p.addQuadCurve(to: point(641, 645), control: point(643, 694))
    p.addQuadCurve(to: point(673, 602), control: point(651, 618))
    p.addQuadCurve(to: point(707, 586), control: point(686, 593))
    p.addQuadCurve(to: point(681, 550), control: point(715, 566))
    p.addQuadCurve(to: point(613, 537), control: point(654, 531))
    p.addQuadCurve(to: point(604, 493), control: point(605, 512))
    p.addLine(to: point(755, 591))
    p.addQuadCurve(to: point(806, 581), control: point(790, 617))
    p.addQuadCurve(to: point(781, 541), control: point(816, 558))
    p.addLine(to: point(634, 428))
    p.addQuadCurve(to: point(580, 394), control: point(609, 400))
    p.addQuadCurve(to: point(548, 310), control: point(570, 344))
    p.addLine(to: point(592, 308))
    p.addQuadCurve(to: point(609, 268), control: point(632, 305))
    p.addLine(to: point(378, 266))
    p.addQuadCurve(to: point(356, 279), control: point(362, 263))
}
stroke([point(603, 627), point(623, 633)], width: 12, tint: color(0xF2E9FD))

func star(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ tint: UInt32) {
    fill(tint) { p in
        p.move(to: point(x, y + radius))
        p.addQuadCurve(to: point(x + radius, y), control: point(x + radius * 0.19, y + radius * 0.19))
        p.addQuadCurve(to: point(x, y - radius), control: point(x + radius * 0.19, y - radius * 0.19))
        p.addQuadCurve(to: point(x - radius, y), control: point(x - radius * 0.19, y - radius * 0.19))
        p.addQuadCurve(to: point(x, y + radius), control: point(x - radius * 0.19, y + radius * 0.19))
    }
}
star(785, 730, 61, 0x6553A6)
star(851, 796, 21, 0x8D7FC1)

let image = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

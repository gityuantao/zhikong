import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Renders the 直控 (ZhiKong) app icon — the "直" wordmark on an indigo→violet
// rounded-tile — at a given pixel size. Pure CoreGraphics/CoreText, no assets.
//
// Usage:  swift scripts/make-appicon.swift <size> <out.png>
// Driven by scripts/build-icon.sh to produce AppIcon.icns + assets/logo.png.

guard CommandLine.arguments.count == 3, let S = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: make-appicon.swift <size> <out.png>\n".utf8))
    exit(2)
}
let outPath = CommandLine.arguments[2]
let Sf = CGFloat(S)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex>>16)&0xff)/255, green: CGFloat((hex>>8)&0xff)/255,
            blue: CGFloat(hex&0xff)/255, alpha: a)
}
func rounded(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let c = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c.interpolationQuality = .high
c.setAllowsAntialiasing(true)

let m = Sf * 0.085
let tile = CGRect(x: m, y: m, width: Sf - 2*m, height: Sf - 2*m)
let radius = tile.width * 0.2235

// soft drop shadow under the tile
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: -Sf*0.012), blur: Sf*0.03, color: rgb(0x000000, 0.25))
c.addPath(rounded(tile, radius)); c.setFillColor(rgb(0x6D5BF2)); c.fillPath()
c.restoreGState()

// indigo → violet gradient
let g = CGGradient(colorsSpace: cs, colors: [rgb(0x6D5BF2), rgb(0x9333EA)] as CFArray, locations: [0, 1])!
c.saveGState()
c.addPath(rounded(tile, radius)); c.clip()
c.drawLinearGradient(g, start: CGPoint(x: tile.minX, y: tile.maxY),
                     end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
c.restoreGState()

// "直" wordmark, white, centered on the tile
let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, tile.height * 0.64, nil)
let astr = NSAttributedString(string: "直", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0xFFFFFF),
])
let line = CTLineCreateWithAttributedString(astr)
c.textPosition = .zero
let ib = CTLineGetImageBounds(line, c)
c.textPosition = CGPoint(x: tile.midX - ib.midX, y: tile.midY - ib.midY)
CTLineDraw(line, c)

guard let img = c.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("failed to create image\n".utf8)); exit(1)
}
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("failed to write \(outPath)\n".utf8)); exit(1)
}

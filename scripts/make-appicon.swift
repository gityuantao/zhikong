import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the 直控 (ZhiKong) app icon from the source artwork
// (assets/logo-source.png): center-cropped to square, with native macOS
// rounded corners (full-bleed). Pure ImageIO/CoreGraphics, no extra deps.
//
// Usage:  swift scripts/make-appicon.swift <size> <out.png>   (run from repo root)
// Driven by scripts/build-icon.sh to produce AppIcon.icns + assets/logo.png.

guard CommandLine.arguments.count == 3, let S = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: make-appicon.swift <size> <out.png>\n".utf8))
    exit(2)
}
let outPath = CommandLine.arguments[2]
let Sf = CGFloat(S)
let sourcePath = "assets/logo-source.png"

guard let srcRef = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let src = CGImageSourceCreateImageAtIndex(srcRef, 0, nil) else {
    FileHandle.standardError.write(Data("cannot load \(sourcePath)\n".utf8)); exit(1)
}

// center-crop to a square
let w = src.width, h = src.height
let side = min(w, h)
let cropped = src.cropping(to: CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)) ?? src

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let c = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("context failed\n".utf8)); exit(1)
}
c.interpolationQuality = .high

// native macOS rounded-corner mask (full-bleed)
let rect = CGRect(x: 0, y: 0, width: Sf, height: Sf)
let radius = Sf * 0.2237
c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
c.clip()
c.draw(cropped, in: rect)

guard let out = c.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("write setup failed\n".utf8)); exit(1)
}
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("write \(outPath) failed\n".utf8)); exit(1)
}

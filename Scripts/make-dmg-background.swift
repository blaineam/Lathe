#!/usr/bin/env swift
// Draws the disk image's background.
//
//     swift Scripts/make-dmg-background.swift <output.png>
//
// Generated rather than stored, for the same reason the app icon is: a public
// repository should not carry a binary it can produce in a second.
//
// ## Why light
//
// The previous background was near-black, and that was a defect rather than a
// style. Finder draws the labels under the icons in DARK text whatever the
// background image is — it does not look at the picture — so on a dark ground
// "Lathe" and "Applications" were close to invisible. A light ground is the
// only choice that keeps Finder's own text legible, and it matches the
// documentation site, which is a light steel spec sheet.
//
// ## Why Swift
//
// The old generator was a hand-rolled rasteriser in pure Python, which could
// draw dots and a triangle and nothing that needed a font. Everything this
// wants to say is text. CoreGraphics and CoreText are on every Mac, including
// the release runner, so there is no dependency to add.
//
// ## Geometry
//
// Tied to `build-dmg.sh`: a 660x400 window, 100pt icons, the app centred at
// (145, 185) and the Applications alias at (515, 185), Finder's labels
// underneath them. If either script moves those, both move together.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

let width: CGFloat = 660
let height: CGFloat = 400
let scale: CGFloat = 2                       // not soft on a Retina display
let appCentre = CGPoint(x: 145, y: 185)      // Finder coordinates, origin top-left
let applicationsCentre = CGPoint(x: 515, y: 185)
let iconHalf: CGFloat = 50

// The site's palette, so the download and the page that offered it look like
// the same product.
func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}
let paper = colour(0xF6F7F8)
let paperLow = colour(0xE9ECEF)
let ink = colour(0x15191E)
let inkSoft = colour(0x5A6570)
let inkFaint = colour(0x8A939C)
let rule = colour(0xC3CAD1)
let edge = colour(0xD9481F)

guard let context = CGContext(
    data: nil,
    width: Int(width * scale), height: Int(height * scale),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no drawing context") }

context.scaleBy(x: scale, y: scale)

/// Finder's coordinates run down from the top; CoreGraphics' run up.
func y(_ finderY: CGFloat) -> CGFloat { height - finderY }

// MARK: - Ground

let ground = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [paper, paperLow] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(
    ground, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

// MARK: - Where to drop

/// A soft well behind each icon. It gives the drop target a place, and it is
/// the only thing on the page that is not flat — a card being lifted
/// rather than a decoration.
func well(at centre: CGPoint) {
    let rect = CGRect(
        x: centre.x - 72, y: y(centre.y) - 72, width: 144, height: 144)
    let path = CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: colour(0x15191E, 0.12))
    context.setFillColor(colour(0xFFFFFF))
    context.addPath(path)
    context.fillPath()
    context.restoreGState()
    context.setStrokeColor(colour(0xDDE1E5))
    context.setLineWidth(1)
    context.addPath(path)
    context.strokePath()
}
well(at: appCentre)
well(at: applicationsCentre)

// MARK: - The dimension line

// The site's one ornament, used for the same job: marking a span. Ticked at
// the start, an arrowhead at the end, drawn between the two wells.
let lineY = y(appCentre.y)
let start = appCentre.x + 82
let end = applicationsCentre.x - 82

context.setStrokeColor(rule)
context.setLineWidth(1.5)
context.move(to: CGPoint(x: start, y: lineY))
context.addLine(to: CGPoint(x: end - 10, y: lineY))
context.strokePath()

context.setLineWidth(1.5)
context.move(to: CGPoint(x: start, y: lineY - 7))
context.addLine(to: CGPoint(x: start, y: lineY + 7))
context.strokePath()

context.setFillColor(edge)
context.move(to: CGPoint(x: end, y: lineY))
context.addLine(to: CGPoint(x: end - 14, y: lineY + 8))
context.addLine(to: CGPoint(x: end - 14, y: lineY - 8))
context.closePath()
context.fillPath()

// MARK: - Type

func font(_ name: String, _ size: CGFloat, fallbackWeight: CGFloat = 0) -> CTFont {
    let candidate = CTFontCreateWithName(name as CFString, size, nil)
    // CTFontCreateWithName quietly substitutes when a face is missing, so the
    // check is on what came back rather than on whether a font was returned.
    if (CTFontCopyPostScriptName(candidate) as String) == name { return candidate }
    let system = CTFontCreateUIFontForLanguage(.system, size, nil)!
    guard fallbackWeight != 0 else { return system }
    let traits = [kCTFontWeightTrait: fallbackWeight] as CFDictionary
    let descriptor = CTFontDescriptorCreateCopyWithAttributes(
        CTFontCopyFontDescriptor(system),
        [kCTFontTraitsAttribute: traits] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

enum Alignment { case left, centre }

func draw(
    _ text: String, font: CTFont, colour: CGColor, at point: CGPoint,
    tracking: CGFloat = 0, align: Alignment = .left
) {
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: colour,
        kCTKernAttributeName: tracking,
    ]
    let line = CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!)
    let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
    let x = align == .centre ? point.x - CGFloat(lineWidth) / 2 : point.x
    context.textPosition = CGPoint(x: x, y: y(point.y))
    CTLineDraw(line, context)
}

let mono = font("Menlo-Regular", 9.5)
let monoBold = font("Menlo-Bold", 9.5)
let heading = font("SFPro-Bold", 22, fallbackWeight: 0.4)
let body = font("SFPro-Regular", 12, fallbackWeight: 0)

draw("LATHE", font: monoBold, colour: edge, at: CGPoint(x: 36, y: 44), tracking: 1.8)
draw("Drag onto Applications to install",
     font: heading, colour: ink, at: CGPoint(x: 36, y: 72))

// Over the line, naming what it measures.
draw("DRAG", font: mono, colour: inkFaint,
     at: CGPoint(x: (start + end) / 2, y: appCentre.y - 12), tracking: 2, align: .centre)

// Foot. Where the icons' own labels are not.
draw("Free  ·  Apache-2.0  ·  Runs on your Mac, uploads nothing",
     font: body, colour: inkSoft, at: CGPoint(x: width / 2, y: 330), align: .centre)
draw("lathe  ·  on-device media",
     font: mono, colour: inkFaint, at: CGPoint(x: width / 2, y: 352), tracking: 1.4, align: .centre)

// MARK: - Write

guard let image = context.makeImage() else { fatalError("no image") }
guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot write \(output.path)") }

// 144 dpi, so Finder treats the 1320x800 file as a 660x400 image at 2x rather
// than a 1320x800 one at 1x, which would be drawn twice the size and cropped.
CGImageDestinationAddImage(destination, image, [
    kCGImagePropertyDPIWidth: 144,
    kCGImagePropertyDPIHeight: 144,
] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("write failed") }
print("    background: \(output.path) (\(Int(width * scale))x\(Int(height * scale)))")

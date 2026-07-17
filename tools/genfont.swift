#!/usr/bin/env xcrun swift
// tools/genfont.swift — macOS-only generator for Userland/FontData.swift.
//
// Renders ASCII 32...126 with Menlo via CoreText into 8x16 grayscale cells,
// thresholds to 1 bit/pixel, packs MSB-left into 16 bytes/glyph, and prints a
// complete replacement Userland/FontData.swift on stdout. Sanity ASCII art of
// a few glyphs goes to stderr (so it never pollutes the generated file).
//
// Run:  xcrun swift tools/genfont.swift > Userland/FontData.swift
// (or `make font`, which does exactly that)
//
// NOTE: this script is the ONLY place Foundation/CoreText are allowed; the
// generated FontData.swift itself is plain Embedded Swift with zero imports.

import CoreText
import CoreGraphics
import Foundation

// MARK: - Layout constants (must match the FontData API exactly)

let cellWidth = 8
let cellHeight = 16
let firstScalar: UInt32 = 32
let lastScalar: UInt32 = 126
let bytesPerGlyph = 16 // == cellHeight: one 8-pixel row per byte
let glyphCount = Int(lastScalar - firstScalar + 1)

/// Coverage (0...255) at or above which a pixel counts as set. Tuned by
/// eyeballing the stderr ASCII art: stems should be solid, thin curves and
/// serifs should not drop out.
let threshold: UInt8 = 96

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// MARK: - Font metrics

func glyphFor(_ font: CTFont, _ scalar: UInt32) -> CGGlyph? {
    var ch = UniChar(scalar)
    var glyph = CGGlyph(0)
    guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1), glyph != 0 else { return nil }
    return glyph
}

/// Picks the largest Menlo size whose advance fits 8 px and whose ink box
/// fits inside the 16 px cell, then centers the ink within the cell.
/// Returns (font, size, baselineY, penX) where baselineY is the Quartz
/// y of the baseline measured from the cell bottom.
func pickFont() -> (CTFont, CGFloat, CGFloat, CGFloat) {
    var size: CGFloat = 13.5
    while size >= 8 {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        var maxAdvance: CGFloat = 0
        var inkTop = -CGFloat.greatestFiniteMagnitude
        var inkBottom = CGFloat.greatestFiniteMagnitude
        var inkLeft = CGFloat.greatestFiniteMagnitude
        var inkRight = -CGFloat.greatestFiniteMagnitude
        for scalar in firstScalar...lastScalar {
            guard var glyph = glyphFor(font, scalar) else { continue }
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &adv, 1)
            maxAdvance = max(maxAdvance, adv.width)
            var rect = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &rect, 1)
            guard !rect.isNull, !rect.isEmpty else { continue } // e.g. space
            inkTop = max(inkTop, rect.maxY)
            inkBottom = min(inkBottom, rect.minY)
            inkLeft = min(inkLeft, rect.minX)
            inkRight = max(inkRight, rect.maxX)
        }
        // Monospace: every glyph is drawn at the same pen x so ink aligns.
        let penX = (CGFloat(cellWidth) - maxAdvance) / 2
        // Center the ink block vertically; snap the baseline to a whole pixel
        // so horizontal stems land crisply on pixel rows.
        var baselineY = ((CGFloat(cellHeight) - inkTop - inkBottom) / 2).rounded()
        if baselineY + inkTop > CGFloat(cellHeight) { baselineY = floor(CGFloat(cellHeight) - inkTop) }
        if baselineY + inkBottom < 0 { baselineY = ceil(-inkBottom) }
        let fits = maxAdvance <= CGFloat(cellWidth)
            && baselineY + inkTop <= CGFloat(cellHeight)
            && baselineY + inkBottom >= 0
            && penX + inkLeft >= 0
            && penX + inkRight <= CGFloat(cellWidth)
        eprint(String(format: "Menlo %4.1fpt: advance=%.2f inkX=[%.2f..%.2f] inkY=[%.2f..%.2f] baselineY=%.1f penX=%.2f -> %@",
                      size, maxAdvance, inkLeft, inkRight, inkBottom, inkTop, baselineY, penX,
                      fits ? "OK" : "too big"))
        if fits { return (font, size, baselineY, penX) }
        size -= 0.5
    }
    fatalError("no Menlo size fits the 8x16 cell")
}

// MARK: - Rasterization

/// Renders one glyph into 16 packed bytes (MSB of each byte = leftmost pixel,
/// row 0 = visual top row of the cell).
func rasterize(_ font: CTFont, glyph: CGGlyph, baselineY: CGFloat, penX: CGFloat) -> [UInt8] {
    let ctx = CGContext(data: nil, width: cellWidth, height: cellHeight,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(false)
    ctx.setShouldSmoothFonts(false)
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))
    ctx.setFillColor(gray: 1, alpha: 1)
    var g = glyph
    var pos = CGPoint(x: penX, y: baselineY)
    CTFontDrawGlyphs(font, &g, &pos, 1, ctx)

    // CGBitmapContext memory is laid out top-down: row 0 of the buffer is the
    // visual top row (Quartz y = cellHeight-1), so no flip is needed. The
    // stderr art below verifies this — if glyphs print upside down there,
    // swap `row` for `cellHeight - 1 - row` in the data index.
    let bytesPerRow = ctx.bytesPerRow
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var packed = [UInt8](repeating: 0, count: bytesPerGlyph)
    for row in 0..<cellHeight {
        var byte: UInt8 = 0
        for col in 0..<cellWidth where data[row * bytesPerRow + col] >= threshold {
            byte |= 0x80 >> col
        }
        packed[row] = byte
    }
    return packed
}

// MARK: - Generate all glyphs

let (font, chosenSize, baselineY, penX) = pickFont()
eprint("using Menlo \(chosenSize)pt, baselineY=\(baselineY), penX=\(penX), threshold=\(threshold)")

var allBytes = [[UInt8]]()
allBytes.reserveCapacity(glyphCount)
for scalar in firstScalar...lastScalar {
    if let glyph = glyphFor(font, scalar) {
        allBytes.append(rasterize(font, glyph: glyph, baselineY: baselineY, penX: penX))
    } else {
        allBytes.append([UInt8](repeating: 0, count: bytesPerGlyph))
        eprint("warning: no glyph for scalar \(scalar), emitting blank cell")
    }
}

// Self-check: every printable glyph except space must contain some ink.
for scalar in (firstScalar + 1)...lastScalar {
    if allBytes[Int(scalar - firstScalar)].allSatisfy({ $0 == 0 }) {
        eprint("warning: glyph \(scalar) packed to all zeros — threshold too high?")
    }
}

// MARK: - Sanity ASCII art (stderr)

func dumpArt(_ scalar: UInt32) {
    let bytes = allBytes[Int(scalar - firstScalar)]
    eprint("--- '\(UnicodeScalar(scalar)!)' (\(String(format: "0x%02X", scalar))) ---")
    for row in 0..<cellHeight {
        var line = ""
        for col in 0..<cellWidth {
            line += (bytes[row] & (0x80 >> col)) != 0 ? "#" : "."
        }
        eprint(line)
    }
}
for s: UInt32 in [65, 103, 48, 95, 124] { dumpArt(s) } // 'A' 'g' '0' '_' '|'

// MARK: - Emit FontData.swift (stdout)

var out = """
// Bitmap font data for the software renderer.
// GENERATED by tools/genfont.swift on macOS (CoreText renders Menlo into 8x16
// cells). Do not edit by hand — regenerate with `make font`.
//
// Encoding: cellWidth x cellHeight pixels per glyph, 1 bit per pixel,
// cellHeight bytes per glyph, MSB of each byte = leftmost pixel.
// Glyphs cover ASCII firstScalar...lastScalar inclusive.

public enum FontData {
    public static let cellWidth = 8
    public static let cellHeight = 16
    public static let firstScalar: UInt32 = 32
    public static let lastScalar: UInt32 = 126
    public static let bytesPerGlyph = 16

    /// (lastScalar - firstScalar + 1) * bytesPerGlyph bytes = 1520 bytes.
    public static let bitmap: [UInt8] = [

"""
for (i, bytes) in allBytes.enumerated() {
    let scalar = firstScalar + UInt32(i)
    let hex = bytes.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
    out += "    \(hex), // \(String(format: "0x%02X", scalar)) '\(UnicodeScalar(scalar)!)'\n"
}
out += """
    ]

    /// Byte offset of `scalar`'s glyph inside `bitmap`, or nil when the glyph
    /// is not covered (renderer draws a replacement box then).
    public static func glyphOffset(forScalar scalar: UInt32) -> Int? {
        guard scalar >= firstScalar, scalar <= lastScalar, !bitmap.isEmpty else { return nil }
        return Int(scalar - firstScalar) * bytesPerGlyph
    }
}

"""
print(out)
eprint("wrote \(glyphCount) glyphs, \(glyphCount * bytesPerGlyph) bitmap bytes")

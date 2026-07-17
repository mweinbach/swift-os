// Bitmap font data for the software renderer.
// STUB — the real glyph bitmaps are generated on macOS by tools/genfont.swift
// (CoreText renders Menlo into 8x16 cells) and committed as this file's `bitmap`.
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

    /// (lastScalar - firstScalar + 1) * bytesPerGlyph bytes when generated.
    public static let bitmap: [UInt8] = []

    /// Byte offset of `scalar`'s glyph inside `bitmap`, or nil when the glyph
    /// is not covered (renderer draws a replacement box then).
    public static func glyphOffset(forScalar scalar: UInt32) -> Int? {
        guard scalar >= firstScalar, scalar <= lastScalar, !bitmap.isEmpty else { return nil }
        return Int(scalar - firstScalar) * bytesPerGlyph
    }
}

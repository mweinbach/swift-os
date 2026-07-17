// Software rasterizer for SwiftOS userland.
// SoftwareSurface draws into a 32bpp XRGB8888 pixel buffer (little-endian byte
// order B, G, R, X; UInt32 value 0xXXRRGGBB). All drawing is clipped to the
// current clip-rect stack and done with plain pointer arithmetic — no
// Foundation, no CoreGraphics. Presentation is Display's job; this only draws.

public final class SoftwareSurface: Surface {
    private let pixels: UnsafeMutableRawPointer
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let strideBytes: Int

    /// Pixel-space clip rect, half-open: [x0, x1) x [y0, y1).
    private struct ClipRect {
        var x0: Int, y0: Int, x1: Int, y1: Int
    }

    /// Color precomputed once per drawing call so the inner loops stay tight.
    private struct Brush {
        var packed: UInt32                     // 0xFF_RR_GG_BB
        var sr: UInt32, sg: UInt32, sb: UInt32 // channels 0...255
        var sa: UInt32                         // alpha 0...255
        var opaque: Bool                       // sa == 255 -> raw-store path

        init(_ c: Color) {
            let a = clamp(c.a, 0, 1)
            sa = UInt32(a * 255 + 0.5)
            sr = UInt32(clamp(c.r, 0, 1) * 255 + 0.5)
            sg = UInt32(clamp(c.g, 0, 1) * 255 + 0.5)
            sb = UInt32(clamp(c.b, 0, 1) * 255 + 0.5)
            packed = 0xFF00_0000 | (sr << 16) | (sg << 8) | sb
            opaque = sa == 255
        }
    }

    private static let clipCapacity = 32
    private var clipStack: [ClipRect] = []
    /// pushClip calls beyond clipCapacity are counted so popClip stays balanced.
    private var clipOverflow = 0

    public init(pixels: UnsafeMutableRawPointer, width: Int, height: Int, strideBytes: Int) {
        self.pixels = pixels
        self.pixelWidth = max(0, width)
        self.pixelHeight = max(0, height)
        self.strideBytes = max(strideBytes, max(0, width) * 4)
        super.init()
        clipStack.reserveCapacity(SoftwareSurface.clipCapacity)
        clipStack.append(ClipRect(x0: 0, y0: 0, x1: pixelWidth, y1: pixelHeight))
    }

    public override var size: Size {
        Size(width: Double(pixelWidth), height: Double(pixelHeight))
    }

    // MARK: - Low-level helpers

    @inline(__always) private func rowPtr(_ y: Int) -> UnsafeMutablePointer<UInt32> {
        pixels.advanced(by: y * strideBytes).assumingMemoryBound(to: UInt32.self)
    }

    @inline(__always) private func put(_ p: UnsafeMutablePointer<UInt32>, _ v: UInt32) {
        p.pointee = v
    }

    /// src-over blend of brush color over *p: out = src*a + dst*(1-a).
    /// (t + (t >> 8)) >> 8 is the exact round(t / 255) for t in 0...65790.
    @inline(__always) private func blendAt(_ p: UnsafeMutablePointer<UInt32>, _ b: Brush) {
        let d = p.pointee
        let ia = 255 - b.sa
        var t = b.sb * b.sa + (d & 0xFF) * ia + 127
        let ob = (t + (t >> 8)) >> 8
        t = b.sg * b.sa + ((d >> 8) & 0xFF) * ia + 127
        let og = (t + (t >> 8)) >> 8
        t = b.sr * b.sa + ((d >> 16) & 0xFF) * ia + 127
        let orr = (t + (t >> 8)) >> 8
        p.pointee = 0xFF00_0000 | (orr << 16) | (og << 8) | ob
    }

    /// Rejects NaN, infinities and values too large to convert to Int safely.
    @inline(__always) private func usable(_ v: Double) -> Bool {
        v > -4.0e15 && v < 4.0e15
    }

    /// Convert a point-space rect to half-open pixel bounds; nil when the rect
    /// is degenerate or has non-finite corners.
    private func pixelBounds(of r: Rect) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        guard !r.isEmpty, usable(r.minX), usable(r.minY), usable(r.maxX), usable(r.maxY) else {
            return nil
        }
        let x0 = Int(r.minX.rounded(.down))
        let y0 = Int(r.minY.rounded(.down))
        let x1 = Int(r.maxX.rounded(.up))
        let y1 = Int(r.maxY.rounded(.up))
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1, y1)
    }

    /// Workhorse: fill the half-open pixel rect [x0,x1)x[y0,y1), intersected
    /// with the current clip. Opaque colors take a row-wise raw-store path.
    private func spanFill(x0: Int, y0: Int, x1: Int, y1: Int, brush: Brush) {
        let c = clipStack[clipStack.count - 1]
        let ax0 = x0 > c.x0 ? x0 : c.x0
        let ay0 = y0 > c.y0 ? y0 : c.y0
        let ax1 = x1 < c.x1 ? x1 : c.x1
        let ay1 = y1 < c.y1 ? y1 : c.y1
        guard ax1 > ax0, ay1 > ay0 else { return }
        let w = ax1 - ax0
        if brush.opaque {
            let v = brush.packed
            var y = ay0
            while y < ay1 {
                var p = rowPtr(y) + ax0
                var n = w
                while n > 0 {
                    put(p, v)
                    p += 1
                    n -= 1
                }
                y += 1
            }
        } else {
            var y = ay0
            while y < ay1 {
                var p = rowPtr(y) + ax0
                var n = w
                while n > 0 {
                    blendAt(p, brush)
                    p += 1
                    n -= 1
                }
                y += 1
            }
        }
    }

    @inline(__always) private func plotPixel(_ x: Int, _ y: Int, brush: Brush) {
        let c = clipStack[clipStack.count - 1]
        guard x >= c.x0, x < c.x1, y >= c.y0, y < c.y1 else { return }
        let p = rowPtr(y) + x
        if brush.opaque {
            put(p, brush.packed)
        } else {
            blendAt(p, brush)
        }
    }

    // MARK: - Surface primitives

    public override func clear(_ color: Color) {
        let v = Brush(color).packed
        var y = 0
        while y < pixelHeight {
            var p = rowPtr(y)
            var n = pixelWidth
            while n > 0 {
                put(p, v)
                p += 1
                n -= 1
            }
            y += 1
        }
    }

    public override func fill(_ rect: Rect, color: Color) {
        guard color.a > 0, let b = pixelBounds(of: rect) else { return }
        spanFill(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1, brush: Brush(color))
    }

    public override func stroke(_ rect: Rect, color: Color, width: CGFloat) {
        guard width > 0, !rect.isEmpty, color.a > 0 else { return }
        let w = min(width, min(rect.width, rect.height) / 2)
        guard w > 0 else { return }
        // Four thin fills: top, bottom, then left/right between the two.
        fill(Rect(x: rect.minX, y: rect.minY, width: rect.width, height: w), color: color)
        fill(Rect(x: rect.minX, y: rect.maxY - w, width: rect.width, height: w), color: color)
        fill(Rect(x: rect.minX, y: rect.minY + w, width: w, height: rect.height - 2 * w), color: color)
        fill(Rect(x: rect.maxX - w, y: rect.minY + w, width: w, height: rect.height - 2 * w), color: color)
    }

    public override func line(from p1: Point, to p2: Point, color: Color, width: CGFloat) {
        guard width > 0, color.a > 0 else { return }
        // Endpoints beyond ±32768 px would make the walk below unreasonably
        // long; such lines are degenerate for a 1280x800 screen — skip them.
        guard usable(p1.x), usable(p1.y), usable(p2.x), usable(p2.y),
              abs(p1.x) < 32768, abs(p1.y) < 32768,
              abs(p2.x) < 32768, abs(p2.y) < 32768 else { return }
        let brush = Brush(color)
        let thin = width <= 1
        let half = width / 2
        // Bresenham walk over pixel centers; every pixel is visited once, so
        // translucent thin lines never blend twice over the same pixel.
        var x = Int(p1.x.rounded())
        var y = Int(p1.y.rounded())
        let x1 = Int(p2.x.rounded())
        let y1 = Int(p2.y.rounded())
        let dx = abs(x1 - x)
        let dy = -abs(y1 - y)
        let sx = x < x1 ? 1 : -1
        let sy = y < y1 ? 1 : -1
        var err = dx + dy
        while true {
            if thin {
                plotPixel(x, y, brush: brush)
            } else if let b = pixelBounds(of: Rect(x: Double(x) - half, y: Double(y) - half,
                                                   width: width, height: width)) {
                spanFill(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1, brush: brush)
            }
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    public override func fillCircle(center: Point, radius: CGFloat, color: Color) {
        guard radius > 0, usable(radius), color.a > 0,
              usable(center.x), usable(center.y) else { return }
        let brush = Brush(color)
        let clip = clipStack[clipStack.count - 1]
        let r2 = radius * radius
        // Scanline fill: per row derive the half-width from r^2 - dy^2 and
        // emit one span. Rows are clamped to the clip before conversion, so
        // the loop runs at most clip-height iterations. Pixel centers are
        // sampled (py + 0.5, px + 0.5) for a symmetric circle.
        let row0 = max(center.y - radius, Double(clip.y0))
        let row1 = min(center.y + radius, Double(clip.y1))
        guard row1 > row0 else { return }
        var py = Int(row0.rounded(.down))
        let pyEnd = Int(row1.rounded(.up))
        while py < pyEnd {
            let dy = Double(py) + 0.5 - center.y
            let rem = r2 - dy * dy
            if rem >= 0 {
                let hw = rem.squareRoot()
                let x0 = Int((center.x - hw - 0.5).rounded(.up))
                let x1 = Int((center.x + hw - 0.5).rounded(.down)) + 1
                if x1 > x0 {
                    spanFill(x0: x0, y0: py, x1: x1, y1: py + 1, brush: brush)
                }
            }
            py += 1
        }
    }

    // MARK: - Text

    /// Integer pixel scale for text: Int(scale.rounded()), minimum 1, and a
    /// sanity cap so absurd scales cannot trap the pen-advance arithmetic.
    /// text() and textSize() share this so they always agree.
    @inline(__always) private func intScale(_ scale: CGFloat) -> Int {
        guard scale.isFinite, scale > 1 else { return 1 }
        if scale >= 256 { return 256 }
        let r = Int(scale.rounded())
        return r < 1 ? 1 : r
    }

    public override func text(_ string: String, at point: Point, color: Color, scale: CGFloat) {
        guard !string.isEmpty, color.a > 0, usable(point.x), usable(point.y) else { return }
        let s = intScale(scale)
        let brush = Brush(color)
        var penX = Int(point.x.rounded())
        let penY = Int(point.y.rounded())
        let advance = FontData.cellWidth * s
        for ch in string {
            drawChar(ch, x: penX, y: penY, s: s, brush: brush)
            penX += advance
        }
    }

    public override func textSize(_ string: String, scale: CGFloat) -> Size {
        let s = intScale(scale)
        return Size(width: Double(FontData.cellWidth * s * string.count),
                    height: Double(FontData.cellHeight * s))
    }

    /// Single cell: glyph bitmap when the character is one scalar covered by
    /// FontData, otherwise (multi-scalar grapheme, control char such as \n,
    /// out-of-range scalar, or empty font stub) a hollow replacement box.
    private func drawChar(_ ch: Character, x: Int, y: Int, s: Int, brush: Brush) {
        var scalar: UInt32 = 0
        var single = false
        var it = ch.unicodeScalars.makeIterator()
        if let first = it.next() {
            single = it.next() == nil
            scalar = first.value
        }
        if single, let offset = FontData.glyphOffset(forScalar: scalar) {
            blitGlyph(offset: offset, x: x, y: y, s: s, brush: brush)
        } else {
            drawReplacementBox(x: x, y: y, s: s, brush: brush)
        }
    }

    /// Blit one glyph: cellWidth x cellHeight, 1 bit/pixel, MSB = leftmost.
    /// Each set bit becomes an s x s block of the text color.
    private func blitGlyph(offset: Int, x: Int, y: Int, s: Int, brush: Brush) {
        var row = 0
        while row < FontData.cellHeight {
            let bits = FontData.bitmap[offset + row]
            if bits != 0 {
                var mask: UInt8 = 0x80
                var col = 0
                while col < FontData.cellWidth {
                    if bits & mask != 0 {
                        spanFill(x0: x + col * s, y0: y + row * s,
                                 x1: x + (col + 1) * s, y1: y + (row + 1) * s,
                                 brush: brush)
                    }
                    mask >>= 1
                    col += 1
                }
            }
            row += 1
        }
    }

    /// 6x10 hollow box (scaled by s), centered in the 8x16 cell.
    private func drawReplacementBox(x: Int, y: Int, s: Int, brush: Brush) {
        let bx = x + s
        let by = y + 3 * s
        let bw = 6 * s
        let bh = 10 * s
        spanFill(x0: bx, y0: by, x1: bx + bw, y1: by + s, brush: brush)
        spanFill(x0: bx, y0: by + bh - s, x1: bx + bw, y1: by + bh, brush: brush)
        spanFill(x0: bx, y0: by + s, x1: bx + s, y1: by + bh - s, brush: brush)
        spanFill(x0: bx + bw - s, y0: by + s, x1: bx + bw, y1: by + bh - s, brush: brush)
    }

    // MARK: - Clip stack

    public override func pushClip(_ rect: Rect) {
        guard clipStack.count < SoftwareSurface.clipCapacity else {
            clipOverflow += 1
            return
        }
        let parent = clipStack[clipStack.count - 1]
        if let b = pixelBounds(of: rect) {
            clipStack.append(ClipRect(x0: max(b.x0, parent.x0),
                                      y0: max(b.y0, parent.y0),
                                      x1: min(b.x1, parent.x1),
                                      y1: min(b.y1, parent.y1)))
        } else {
            // Degenerate or non-finite rect: push an empty clip (draws
            // nothing) so the matching popClip stays balanced.
            clipStack.append(ClipRect(x0: parent.x0, y0: parent.y0,
                                      x1: parent.x0, y1: parent.y0))
        }
    }

    public override func popClip() {
        if clipOverflow > 0 {
            clipOverflow -= 1
            return
        }
        // Index 0 is the full-screen base clip and is never popped.
        if clipStack.count > 1 {
            clipStack.removeLast()
        }
    }
}

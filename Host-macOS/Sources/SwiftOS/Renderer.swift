import Foundation
import CoreGraphics
import CoreText
import Metal
import MetalKit

// MARK: - Embedded Metal Shading Language source
//
// SwiftPM cannot compile .metal files, so the shader library is built at
// runtime from this string. Vertex layout matches `Vertex` below exactly:
// 8 consecutive Floats, 32 bytes, no padding.

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position;
    float2 texCoord;
    float2 colorRG;
    float2 colorBA;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 texCoord;
};

struct Uniforms {
    float2 viewportSize; // in points
};

vertex VertexOut os_vertex(const device Vertex *vertices [[buffer(0)]],
                           constant Uniforms &uniforms [[buffer(1)]],
                           uint vid [[vertex_id]]) {
    Vertex v = vertices[vid];
    VertexOut out;
    // Screen points (origin top-left, y down) -> NDC (y up).
    float2 ndc;
    ndc.x = v.position.x / uniforms.viewportSize.x * 2.0 - 1.0;
    ndc.y = 1.0 - v.position.y / uniforms.viewportSize.y * 2.0;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = float4(v.colorRG, v.colorBA);
    out.texCoord = v.texCoord;
    return out;
}

fragment float4 os_fragment_solid(VertexOut in [[stage_in]]) {
    return in.color;
}

fragment float4 os_fragment_text(VertexOut in [[stage_in]],
                                 texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float a = atlas.sample(s, in.texCoord).r;
    return float4(in.color.rgb, in.color.a * a);
}
"""

/// CPU-side vertex; must match the `Vertex` struct in the shader source
/// (8 Floats, 32 bytes, sequential).
private struct Vertex {
    var x: Float, y: Float
    var u: Float, v: Float
    var r: Float, g: Float, b: Float, a: Float
}

// MARK: - MetalRenderer

final class MetalRenderer: NSObject, MTKViewDelegate {
    /// Called every frame between begin-frame and end-frame. The WindowManager
    /// installs its tick+draw closure here.
    var onFrame: ((Surface) -> Void)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let solidPipeline: MTLRenderPipelineState
    private let textPipeline: MTLRenderPipelineState
    private let surface = MetalSurface()

    init(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            preconditionFailure("SwiftOS: Metal is not available on this machine.")
        }
        self.device = device
        view.device = device

        guard let queue = device.makeCommandQueue() else {
            preconditionFailure("SwiftOS: failed to create MTLCommandQueue.")
        }
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            print("SwiftOS: Metal shader compilation failed: \(error)")
            preconditionFailure("SwiftOS: could not build shader library.")
        }
        guard let vertexFn = library.makeFunction(name: "os_vertex"),
              let solidFn = library.makeFunction(name: "os_fragment_solid"),
              let textFn = library.makeFunction(name: "os_fragment_text") else {
            preconditionFailure("SwiftOS: shader functions missing from library.")
        }
        self.solidPipeline = MetalRenderer.makePipeline(device: device,
                                                        vertex: vertexFn,
                                                        fragment: solidFn,
                                                        pixelFormat: view.colorPixelFormat)
        self.textPipeline = MetalRenderer.makePipeline(device: device,
                                                       vertex: vertexFn,
                                                       fragment: textFn,
                                                       pixelFormat: view.colorPixelFormat)

        super.init()

        surface.configure(device: device,
                          commandQueue: queue,
                          solidPipeline: solidPipeline,
                          textPipeline: textPipeline)
        surface.viewSize = view.bounds.size
        surface.drawableSize = view.drawableSize
        view.delegate = self
    }

    private static func makePipeline(device: MTLDevice,
                                     vertex: MTLFunction,
                                     fragment: MTLFunction,
                                     pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "SwiftOS.\(fragment.name)"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("SwiftOS: pipeline creation failed: \(error)")
            preconditionFailure("SwiftOS: could not create render pipeline state.")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        surface.drawableSize = size
    }

    func draw(in view: MTKView) {
        autoreleasepool {
            surface.viewSize = view.bounds.size
            surface.drawableSize = view.drawableSize
            surface.beginFrame()
            onFrame?(surface)
            // Fetch the descriptor/drawable fresh every frame; they are nil when
            // the window is occluded or minimized, in which case we skip the frame.
            guard let passDescriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }
            surface.renderFrame(renderPassDescriptor: passDescriptor, drawable: drawable)
        }
    }
}

// MARK: - Glyph atlas (CoreText rasterization + shelf packing)

private struct GlyphKey: Hashable {
    let char: Character
    let scale: CGFloat
}

private struct GlyphEntry {
    var advance: CGFloat          // points, exact CTFont advance at `scale`
    var hasBitmap: Bool           // false for whitespace: advance only, nothing drawn
    var offsetX: CGFloat = 0      // points from pen (baseline) to quad top-left
    var offsetY: CGFloat = 0
    var width: CGFloat = 0        // quad size in points
    var height: CGFloat = 0
    var u0: Float = 0, v0: Float = 0, u1: Float = 0, v1: Float = 0
}

private struct LineMetrics {
    var ascent: CGFloat
    var descent: CGFloat
    var leading: CGFloat
    var lineHeight: CGFloat { ascent + descent + leading }
}

/// Lazily rasterizes glyphs into a shared 2048x2048 .r8Unorm atlas texture
/// using simple shelf packing. All layout metrics come from a "layout" CTFont
/// sized at 13pt * scale (points); bitmaps are rasterized with a font sized
/// 13pt * scale * backingScale so Retina rendering stays crisp while quad
/// geometry stays in points.
private final class GlyphAtlas {
    static let atlasSize = 2048
    static let baseFontSize: CGFloat = 13
    static let padding = 1

    private var device: MTLDevice?
    private var texture: MTLTexture?
    private var backingScale: CGFloat = 1

    private var layoutFonts: [CGFloat: CTFont] = [:] // key: scale (UI multiplier)
    private var rasterFonts: [CGFloat: CTFont] = [:]
    private var metricsCache: [CGFloat: LineMetrics] = [:]
    private var missingAdvance: [CGFloat: CGFloat] = [:]
    private var advanceCache: [GlyphKey: CGFloat] = [:] // backing-independent advances
    private var entries: [GlyphKey: GlyphEntry] = [:]

    // Shelf packing state (atlas pixels).
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private var warnedFull = false

    func configure(device: MTLDevice) {
        if self.device == nil {
            self.device = device
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: GlyphAtlas.atlasSize,
                height: GlyphAtlas.atlasSize,
                mipmapped: false)
            desc.usage = .shaderRead
            desc.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: desc) else {
                preconditionFailure("SwiftOS: could not create glyph atlas texture.")
            }
            texture.label = "SwiftOS.GlyphAtlas"
            // Start fully transparent so unsampled regions read alpha 0.
            let zeros = [UInt8](repeating: 0, count: GlyphAtlas.atlasSize * GlyphAtlas.atlasSize)
            texture.replace(region: MTLRegionMake2D(0, 0, GlyphAtlas.atlasSize, GlyphAtlas.atlasSize),
                            mipmapLevel: 0, withBytes: zeros, bytesPerRow: GlyphAtlas.atlasSize)
            self.texture = texture
        }
    }

    var atlasTexture: MTLTexture? { texture }

    /// Called once per frame with the drawable-to-bounds ratio. A change means
    /// the window moved to a display with a different backing scale: re-rasterize.
    func updateBackingScale(_ scale: CGFloat) {
        let clamped = scale.isFinite && scale > 0 ? scale : 1
        guard clamped != backingScale else { return }
        backingScale = clamped
        entries.removeAll(keepingCapacity: true)
        rasterFonts.removeAll()
        shelfX = 0; shelfY = 0; shelfHeight = 0
        if let texture {
            let zeros = [UInt8](repeating: 0, count: GlyphAtlas.atlasSize * GlyphAtlas.atlasSize)
            texture.replace(region: MTLRegionMake2D(0, 0, GlyphAtlas.atlasSize, GlyphAtlas.atlasSize),
                            mipmapLevel: 0, withBytes: zeros, bytesPerRow: GlyphAtlas.atlasSize)
        }
    }

    private func makeFont(size: CGFloat) -> CTFont {
        // Menlo is present on every macOS system; CoreText substitutes a
        // fallback automatically if a name ever fails to resolve.
        CTFontCreateWithName("Menlo" as CFString, size, nil)
    }

    private func layoutFont(scale: CGFloat) -> CTFont {
        if let f = layoutFonts[scale] { return f }
        let f = makeFont(size: GlyphAtlas.baseFontSize * scale)
        layoutFonts[scale] = f
        return f
    }

    private func rasterFont(scale: CGFloat) -> CTFont {
        if let f = rasterFonts[scale] { return f }
        let f = makeFont(size: GlyphAtlas.baseFontSize * scale * backingScale)
        rasterFonts[scale] = f
        return f
    }

    func lineMetrics(scale: CGFloat) -> LineMetrics {
        if let m = metricsCache[scale] { return m }
        let font = layoutFont(scale: scale)
        let m = LineMetrics(ascent: CTFontGetAscent(font),
                            descent: CTFontGetDescent(font),
                            leading: CTFontGetLeading(font))
        metricsCache[scale] = m
        return m
    }

    /// Maps a Character to a single glyph + exact advance using the layout font.
    /// Returns nil when the font has no glyph (caller draws the missing box).
    private func glyphAndAdvance(for char: Character, scale: CGFloat) -> (CGGlyph, CGSize)? {
        var utf16 = Array(char.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let found = CTFontGetGlyphsForCharacters(layoutFont(scale: scale), &utf16, &glyphs, utf16.count)
        guard found, glyphs.count == 1, glyphs[0] != 0 else { return nil }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(layoutFont(scale: scale), .horizontal, glyphs, &advance, 1)
        return (glyphs[0], advance)
    }

    /// Advance for the missing-glyph box (.notdef advance), cached per scale.
    func missingGlyphAdvance(scale: CGFloat) -> CGFloat {
        if let a = missingAdvance[scale] { return a }
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(layoutFont(scale: scale), .horizontal, &glyph, &advance, 1)
        // .notdef may report a zero advance in some fonts; fall back to the
        // space advance so the box is always visible and layouts move.
        let a = advance.width > 0 ? advance.width : spaceAdvance(scale: scale)
        missingAdvance[scale] = a
        return a
    }

    private func spaceAdvance(scale: CGFloat) -> CGFloat {
        let space: [UniChar] = [0x20]
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        guard CTFontGetGlyphsForCharacters(layoutFont(scale: scale), space, &glyphs, 1) else {
            return GlyphAtlas.baseFontSize * scale * 0.6
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(layoutFont(scale: scale), .horizontal, glyphs, &advance, 1)
        return advance.width > 0 ? advance.width : GlyphAtlas.baseFontSize * scale * 0.6
    }

    /// Metrics-only path used by textSize: exact advance without rasterizing.
    func advance(for char: Character, scale: CGFloat) -> CGFloat {
        let key = GlyphKey(char: char, scale: scale)
        if let cached = advanceCache[key] { return cached }
        let value: CGFloat
        if let cached = entries[key] {
            value = cached.advance
        } else if let (_, advance) = glyphAndAdvance(for: char, scale: scale) {
            value = advance.width
        } else {
            value = missingGlyphAdvance(scale: scale)
        }
        advanceCache[key] = value
        return value
    }

    /// Full entry used by text(): rasterizes the glyph into the atlas on first use.
    func entry(for char: Character, scale: CGFloat) -> GlyphEntry {
        let key = GlyphKey(char: char, scale: scale)
        if let cached = entries[key] { return cached }
        let entry: GlyphEntry
        if let (glyph, advance) = glyphAndAdvance(for: char, scale: scale) {
            entry = rasterize(glyph: glyph, advance: advance.width, scale: scale)
        } else {
            // Missing glyph: no bitmap; MetalSurface draws the hollow box and
            // advances by the .notdef advance.
            entry = GlyphEntry(advance: missingGlyphAdvance(scale: scale), hasBitmap: false)
        }
        entries[key] = entry
        return entry
    }

    private func rasterize(glyph: CGGlyph, advance: CGFloat, scale: CGFloat) -> GlyphEntry {
        let font = rasterFont(scale: scale)
        var g = glyph
        var bbox = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &bbox, 1)

        guard bbox.width > 0, bbox.height > 0 else {
            return GlyphEntry(advance: advance, hasBitmap: false)
        }

        let pad = CGFloat(GlyphAtlas.padding)
        let fx = bbox.minX.rounded(.down)
        let fy = bbox.minY.rounded(.down)
        let bw = Int((bbox.maxX).rounded(.up) - fx) + GlyphAtlas.padding * 2
        let bh = Int((bbox.maxY).rounded(.up) - fy) + GlyphAtlas.padding * 2

        guard let pixels = drawGlyphBitmap(font: font, glyph: g, width: bw, height: bh,
                                           originX: pad - fx, originY: pad - fy) else {
            return GlyphEntry(advance: advance, hasBitmap: false)
        }
        guard let (ax, ay) = allocate(width: bw, height: bh) else {
            if !warnedFull {
                warnedFull = true
                print("SwiftOS: glyph atlas full; some glyphs will not render.")
            }
            return GlyphEntry(advance: advance, hasBitmap: false)
        }
        texture?.replace(region: MTLRegionMake2D(ax, ay, bw, bh),
                         mipmapLevel: 0, withBytes: pixels, bytesPerRow: bw)

        // Bitmap pixels correspond to points divided by backingScale.
        let atlas = CGFloat(GlyphAtlas.atlasSize)
        return GlyphEntry(
            advance: advance,
            hasBitmap: true,
            offsetX: (fx - pad) / backingScale,
            offsetY: -(CGFloat(bh) - pad + fy) / backingScale,
            width: CGFloat(bw) / backingScale,
            height: CGFloat(bh) / backingScale,
            u0: Float(CGFloat(ax) / atlas), v0: Float(CGFloat(ay) / atlas),
            u1: Float(CGFloat(ax + bw) / atlas), v1: Float(CGFloat(ay + bh) / atlas))
    }

    /// Renders one glyph into a small gray bitmap whose row 0 is the visual
    /// TOP of the glyph (the CTM is flipped so CTFontDraw lands right-side-up
    /// in memory). `originX/originY` place the text-space pen in bitmap pixels.
    private func drawGlyphBitmap(font: CTFont, glyph: CGGlyph,
                                 width: Int, height: Int,
                                 originX: CGFloat, originY: CGFloat) -> [UInt8]? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        // NOTE: CTFontDrawGlyphs already renders upright with memory row 0
        // as the visual top — a CTM flip here double-flips every glyph.
        ctx.setFillColor(gray: 1, alpha: 1)
        var g = glyph
        var position = CGPoint(x: originX, y: originY)
        CTFontDrawGlyphs(font, &g, &position, 1, ctx)
        guard let data = ctx.data else { return nil }
        let count = ctx.bytesPerRow * height
        let ptr = data.bindMemory(to: UInt8.self, capacity: count)
        if ctx.bytesPerRow == width {
            return Array(UnsafeBufferPointer(start: ptr, count: width * height))
        }
        // Defensive: repack rows if the context padded the row stride.
        var packed = [UInt8](repeating: 0, count: width * height)
        packed.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress else { return }
            for row in 0..<height {
                memcpy(base + row * width, ptr.advanced(by: row * ctx.bytesPerRow), width)
            }
        }
        return packed
    }

    /// Shelf packing: rows of glyphs left-to-right; a new shelf starts below the
    /// tallest glyph of the previous one.
    private func allocate(width: Int, height: Int) -> (Int, Int)? {
        let limit = GlyphAtlas.atlasSize
        if width > limit || height > limit { return nil }
        if shelfX + width > limit {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        if shelfY + height > limit { return nil }
        let origin = (shelfX, shelfY)
        shelfX += width
        shelfHeight = max(shelfHeight, height)
        return origin
    }
}

// MARK: - MetalSurface

final class MetalSurface: Surface {
    var viewSize: CGSize = .zero
    var size: CGSize { viewSize }

    fileprivate var drawableSize: CGSize = .zero

    private enum PipelineKind { case solid, text }

    /// A contiguous run of vertices sharing one pipeline and one clip rect.
    private struct DrawBatch {
        var kind: PipelineKind
        var clip: CGRect // points; scissored at encode time
        var start: Int
        var count: Int
    }

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var solidPipeline: MTLRenderPipelineState?
    private var textPipeline: MTLRenderPipelineState?

    private let atlas = GlyphAtlas()

    // Per-frame batching state.
    private var vertices: [Vertex] = []
    private var batches: [DrawBatch] = []
    private var openKind: PipelineKind?
    private var openClip: CGRect = .zero
    private var clipStack: [CGRect] = []
    private var warnedPopUnderflow = false

    // Growable upload buffer (shared memory: CPU writes, GPU reads).
    private var vertexBuffer: MTLBuffer?
    private var vertexBufferCapacity = 0 // in vertices

    fileprivate func configure(device: MTLDevice,
                               commandQueue: MTLCommandQueue,
                               solidPipeline: MTLRenderPipelineState,
                               textPipeline: MTLRenderPipelineState) {
        self.device = device
        self.commandQueue = commandQueue
        self.solidPipeline = solidPipeline
        self.textPipeline = textPipeline
        atlas.configure(device: device)
    }

    // MARK: Frame lifecycle (called by MetalRenderer)

    fileprivate func beginFrame() {
        vertices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        clipStack.removeAll(keepingCapacity: true)
        openKind = nil
        atlas.updateBackingScale(currentBackingScale())
    }

    fileprivate func renderFrame(renderPassDescriptor: MTLRenderPassDescriptor,
                                 drawable: MTLDrawable) {
        guard let device, let commandQueue,
              let solidPipeline, let textPipeline,
              viewSize.width > 0, viewSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else { return }

        closeOpenBatch()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "SwiftOS.Frame"

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        encoder.label = "SwiftOS.UI"

        if !vertices.isEmpty {
            uploadVertices(device: device)
            if let vertexBuffer {
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            }
        }
        var viewport = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        for batch in batches where batch.count > 0 {
            encoder.setRenderPipelineState(batch.kind == .solid ? solidPipeline : textPipeline)
            if batch.kind == .text, let texture = atlas.atlasTexture {
                encoder.setFragmentTexture(texture, index: 0)
            }
            encoder.setScissorRect(scissorRect(for: batch.clip))
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: batch.start,
                                   vertexCount: batch.count)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func uploadVertices(device: MTLDevice) {
        let needed = vertices.count
        if needed > vertexBufferCapacity {
            var capacity = max(16_384, vertexBufferCapacity * 2)
            while capacity < needed { capacity *= 2 }
            guard let buffer = device.makeBuffer(length: capacity * MemoryLayout<Vertex>.stride,
                                                 options: .storageModeShared) else {
                preconditionFailure("SwiftOS: could not allocate vertex buffer.")
            }
            buffer.label = "SwiftOS.Vertices"
            vertexBuffer = buffer
            vertexBufferCapacity = capacity
        }
        guard let vertexBuffer else { return }
        vertices.withUnsafeBytes { src in
            if let base = src.baseAddress, !src.isEmpty {
                memcpy(vertexBuffer.contents(), base, src.count)
            }
        }
    }

    // MARK: Batching

    private func currentClip() -> CGRect {
        clipStack.last ?? CGRect(origin: .zero, size: viewSize)
    }

    private func closeOpenBatch() {
        guard let kind = openKind else { return }
        let start = batches.isEmpty ? 0 : batches.last!.start + batches.last!.count
        let count = vertices.count - start
        if count > 0 {
            batches.append(DrawBatch(kind: kind, clip: openClip, start: start, count: count))
        }
        openKind = nil
    }

    private func beginVertices(kind: PipelineKind) {
        let clip = currentClip()
        if let kind0 = openKind, kind0 == kind, clip == openClip { return }
        closeOpenBatch()
        openKind = kind
        openClip = clip
    }

    /// Append the 6 vertices of an axis-aligned quad (two triangles).
    /// Skipped entirely when the current clip is empty or the color is invisible.
    private func emitQuad(_ rect: CGRect, color: Color, kind: PipelineKind,
                          u0: Float = 0, v0: Float = 0, u1: Float = 0, v1: Float = 0) {
        guard rect.width > 0, rect.height > 0, color.a > 0 else { return }
        let clip = currentClip()
        guard clip.width > 0, clip.height > 0 else { return }
        beginVertices(kind: kind)

        let x0 = Float(rect.minX), y0 = Float(rect.minY)
        let x1 = Float(rect.maxX), y1 = Float(rect.maxY)
        let r = Float(color.r), g = Float(color.g), b = Float(color.b), a = Float(color.a)

        vertices.append(Vertex(x: x0, y: y0, u: u0, v: v0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x0, y: y1, u: u0, v: v1, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y0, u: u1, v: v0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y0, u: u1, v: v0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x0, y: y1, u: u0, v: v1, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y1, u: u1, v: v1, r: r, g: g, b: b, a: a))
    }

    // MARK: Scissor (points -> pixels, top-left origin on both sides)

    private func currentBackingScale() -> CGFloat {
        guard viewSize.width > 0, drawableSize.width > 0 else { return 1 }
        return drawableSize.width / viewSize.width
    }

    private func scissorRect(for clip: CGRect) -> MTLScissorRect {
        let dw = Int(drawableSize.width)
        let dh = Int(drawableSize.height)
        guard viewSize.width > 0, viewSize.height > 0, dw > 0, dh > 0 else {
            return MTLScissorRect(x: 0, y: 0, width: max(dw, 0), height: max(dh, 0))
        }
        let sx = drawableSize.width / viewSize.width
        let sy = drawableSize.height / viewSize.height
        var x0 = Int((clip.minX * sx).rounded(.down))
        var y0 = Int((clip.minY * sy).rounded(.down))
        var x1 = Int((clip.maxX * sx).rounded(.up))
        var y1 = Int((clip.maxY * sy).rounded(.up))
        x0 = min(max(x0, 0), dw)
        y0 = min(max(y0, 0), dh)
        x1 = min(max(x1, x0), dw)
        y1 = min(max(y1, y0), dh)
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: Surface

    func clear(_ color: Color) {
        fill(CGRect(origin: .zero, size: viewSize), color: color)
    }

    func fill(_ rect: CGRect, color: Color) {
        emitQuad(rect.standardized, color: color, kind: .solid)
    }

    func stroke(_ rect: CGRect, color: Color, width: CGFloat) {
        let rect = rect.standardized
        guard width > 0, rect.width > 0, rect.height > 0 else { return }
        let w = min(width, min(rect.width, rect.height) / 2)
        guard w > 0 else { return }
        // Four thin fills: top, bottom, left, right (left/right between the two).
        fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: w), color: color)
        fill(CGRect(x: rect.minX, y: rect.maxY - w, width: rect.width, height: w), color: color)
        fill(CGRect(x: rect.minX, y: rect.minY + w, width: w, height: rect.height - 2 * w), color: color)
        fill(CGRect(x: rect.maxX - w, y: rect.minY + w, width: w, height: rect.height - 2 * w), color: color)
    }

    func line(from p1: CGPoint, to p2: CGPoint, color: Color, width: CGFloat) {
        guard width > 0, color.a > 0 else { return }
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let length = (dx * dx + dy * dy).squareRoot()
        let half = width / 2
        if length < 1e-6 {
            // Zero-length segment: draw a square dot of `width` centered on p1.
            fill(CGRect(x: p1.x - half, y: p1.y - half, width: width, height: width), color: color)
            return
        }
        // Extrude a quad around the segment along its normal.
        let nx = -dy / length * half
        let ny = dx / length * half
        let clip = currentClip()
        guard clip.width > 0, clip.height > 0 else { return }
        beginVertices(kind: .solid)
        let r = Float(color.r), g = Float(color.g), b = Float(color.b), a = Float(color.a)
        let ax = Float(p1.x + nx), ay = Float(p1.y + ny)
        let bx = Float(p1.x - nx), by = Float(p1.y - ny)
        let cx = Float(p2.x + nx), cy = Float(p2.y + ny)
        let dxq = Float(p2.x - nx), dyq = Float(p2.y - ny)
        vertices.append(Vertex(x: ax, y: ay, u: 0, v: 0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: bx, y: by, u: 0, v: 0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: cx, y: cy, u: 0, v: 0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: cx, y: cy, u: 0, v: 0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: bx, y: by, u: 0, v: 0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: dxq, y: dyq, u: 0, v: 0, r: r, g: g, b: b, a: a))
    }

    func fillCircle(center: CGPoint, radius: CGFloat, color: Color) {
        guard radius > 0, color.a > 0 else { return }
        let clip = currentClip()
        guard clip.width > 0, clip.height > 0 else { return }
        beginVertices(kind: .solid)
        let r = Float(color.r), g = Float(color.g), b = Float(color.b), a = Float(color.a)
        let cx = Float(center.x), cy = Float(center.y), rad = Float(radius)
        let segments = 24
        var prevX = cx + rad
        var prevY = cy
        for i in 1...segments {
            let angle = Float(i) * (2 * .pi) / Float(segments)
            let px = cx + rad * cos(angle)
            let py = cy + rad * sin(angle)
            vertices.append(Vertex(x: cx, y: cy, u: 0, v: 0, r: r, g: g, b: b, a: a))
            vertices.append(Vertex(x: prevX, y: prevY, u: 0, v: 0, r: r, g: g, b: b, a: a))
            vertices.append(Vertex(x: px, y: py, u: 0, v: 0, r: r, g: g, b: b, a: a))
            prevX = px
            prevY = py
        }
    }

    func text(_ string: String, at point: CGPoint, color: Color, scale: CGFloat) {
        guard !string.isEmpty, scale > 0, color.a > 0 else { return }
        let metrics = atlas.lineMetrics(scale: scale)
        var penX = point.x
        var baseline = point.y + metrics.ascent

        for char in string {
            if char == "\n" {
                penX = point.x
                baseline += metrics.lineHeight
                continue
            }
            let entry = atlas.entry(for: char, scale: scale)
            if entry.hasBitmap {
                emitQuad(CGRect(x: penX + entry.offsetX,
                                y: baseline + entry.offsetY,
                                width: entry.width,
                                height: entry.height),
                         color: color, kind: .text,
                         u0: entry.u0, v0: entry.v0, u1: entry.u1, v1: entry.v1)
            } else if !char.isWhitespace {
                drawMissingGlyphBox(penX: penX, baseline: baseline,
                                    advance: entry.advance, metrics: metrics,
                                    color: color, scale: scale)
            }
            penX += entry.advance
        }
    }

    /// Hollow replacement box for characters the font cannot render.
    private func drawMissingGlyphBox(penX: CGFloat, baseline: CGFloat,
                                     advance: CGFloat, metrics: LineMetrics,
                                     color: Color, scale: CGFloat) {
        let thickness = max(1, scale)
        let box = CGRect(x: penX + 0.5,
                         y: baseline - metrics.ascent,
                         width: max(advance - 1, thickness),
                         height: metrics.ascent + metrics.descent)
        stroke(box, color: color, width: thickness)
    }

    func textSize(_ string: String, scale: CGFloat) -> CGSize {
        guard !string.isEmpty, scale > 0 else { return .zero }
        let metrics = atlas.lineMetrics(scale: scale)
        var maxWidth: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lines = 1
        for char in string {
            if char == "\n" {
                maxWidth = max(maxWidth, lineWidth)
                lineWidth = 0
                lines += 1
            } else {
                lineWidth += atlas.advance(for: char, scale: scale)
            }
        }
        maxWidth = max(maxWidth, lineWidth)
        return CGSize(width: maxWidth, height: metrics.lineHeight * CGFloat(lines))
    }

    func pushClip(_ rect: CGRect) {
        closeOpenBatch()
        clipStack.append(currentClip().intersection(rect.standardized))
    }

    func popClip() {
        closeOpenBatch()
        if clipStack.isEmpty {
            if !warnedPopUnderflow {
                warnedPopUnderflow = true
                print("SwiftOS: popClip() with empty clip stack; ignoring.")
            }
            return
        }
        clipStack.removeLast()
    }
}

import Foundation
import CoreGraphics
import Metal
import MetalKit

/// STUB — the renderer subsystem replaces this whole file with a real Metal backend.
/// Keep the class names and the `Surface` conformance API EXACTLY as declared here;
/// main.swift and every UI subsystem compile against them.
final class MetalRenderer: NSObject, MTKViewDelegate {
    /// Called every frame between begin-frame and end-frame. The WindowManager
    /// installs its tick+draw closure here.
    var onFrame: ((Surface) -> Void)?

    private let surface = MetalSurface()

    init(view: MTKView) {
        super.init()
        surface.viewSize = view.bounds.size
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        surface.viewSize = view.bounds.size
        onFrame?(surface)
    }
}

/// STUB implementation of the drawing surface. Replaced by the real Metal one.
final class MetalSurface: Surface {
    var viewSize: CGSize = .zero
    var size: CGSize { viewSize }

    func clear(_ color: Color) {}
    func fill(_ rect: CGRect, color: Color) {}
    func stroke(_ rect: CGRect, color: Color, width: CGFloat) {}
    func line(from p1: CGPoint, to p2: CGPoint, color: Color, width: CGFloat) {}
    func fillCircle(center: CGPoint, radius: CGFloat, color: Color) {}
    func text(_ string: String, at point: CGPoint, color: Color, scale: CGFloat) {}
    func textSize(_ string: String, scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(string.count) * 8 * scale, height: 17 * scale)
    }
    func pushClip(_ rect: CGRect) {}
    func popClip() {}
}

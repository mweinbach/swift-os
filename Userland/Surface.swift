// The immediate-mode 2D drawing surface.
// BASE CLASS (not a protocol): Embedded Swift has no protocol existentials.
// SoftwareSurface (kernel framebuffer) and the macOS Metal surface subclass it.
//
// All drawing happens in SCREEN coordinates, in POINTS, origin at the
// TOP-LEFT, y growing downward.

public class Surface {
    /// Size of the whole screen in points.
    public var size: Size { .zero }

    public func clear(_ color: Color) {}
    public func fill(_ rect: Rect, color: Color) {}
    public func stroke(_ rect: Rect, color: Color, width: CGFloat) {}
    public func line(from p1: Point, to p2: Point, color: Color, width: CGFloat) {}
    public func fillCircle(center: Point, radius: CGFloat, color: Color) {}
    /// Monospace text. `point` is the TOP-LEFT of the text's bounding box.
    /// `scale` 1 is the base terminal size, 2 is double size, etc.
    public func text(_ string: String, at point: Point, color: Color, scale: CGFloat) {}
    /// Advance width and line height of `string` at `scale`.
    /// MUST agree with `text(_:at:color:scale:)` or layouts break.
    public func textSize(_ string: String, scale: CGFloat) -> Size { .zero }
    /// Clip stack: drawing is restricted to `rect` (intersected with the
    /// current clip) until the matching `popClip()`.
    public func pushClip(_ rect: Rect) {}
    public func popClip() {}

    // MARK: Convenience (final — built on the primitives above)

    public final func text(_ string: String, at point: Point, color: Color) {
        text(string, at: point, color: color, scale: 1)
    }
    public final func textSize(_ string: String) -> Size {
        textSize(string, scale: 1)
    }
    public final func stroke(_ rect: Rect, color: Color) {
        stroke(rect, color: color, width: 1)
    }
}

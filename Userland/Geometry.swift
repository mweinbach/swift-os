// Geometry + color primitives for SwiftOS userland.
// Stand-in for CoreGraphics: keeps ported app code compiling with the same
// call shapes (CGPoint/CGSize/CGRect/CGFloat are typealiases of our types).

public typealias CGFloat = Double
public typealias TimeInterval = Double

// MARK: - Point

public struct Point: Equatable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
    public static let zero = Point(x: 0, y: 0)
    public func offsetBy(x dx: CGFloat = 0, y dy: CGFloat = 0) -> Point {
        Point(x: x + dx, y: y + dy)
    }
}

public typealias CGPoint = Point

// MARK: - Size

public struct Size: Equatable {
    public var width: CGFloat
    public var height: CGFloat
    public init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }
    public static let zero = Size(width: 0, height: 0)
}

public typealias CGSize = Size

// MARK: - Rect

public struct Rect: Equatable {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) { self.origin = origin; self.size = size }
    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = Point(x: x, y: y)
        self.size = Size(width: width, height: height)
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }
    public var midX: CGFloat { origin.x + size.width / 2 }
    public var midY: CGFloat { origin.y + size.height / 2 }
    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }

    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    public func insetBy(dx: CGFloat, dy: CGFloat) -> Rect {
        Rect(x: minX + dx, y: minY + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> Rect {
        Rect(x: minX + dx, y: minY + dy, width: width, height: height)
    }

    public func intersection(_ other: Rect) -> Rect {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        if x1 <= x0 || y1 <= y0 { return .zero }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func union(_ other: Rect) -> Rect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX), y1 = max(maxY, other.maxY)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

public typealias CGRect = Rect

// MARK: - Color

public struct Color: Equatable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static func hex(_ value: UInt32, alpha: Double = 1) -> Color {
        Color(Double((value >> 16) & 0xFF) / 255,
              Double((value >> 8) & 0xFF) / 255,
              Double(value & 0xFF) / 255, alpha)
    }
    public func withAlpha(_ alpha: Double) -> Color { Color(r, g, b, alpha) }

    /// Pack into a 32-bit XRGB8888 pixel.
    public var xrgb: UInt32 {
        let ri = UInt32(max(0, min(1, r)) * 255 + 0.5)
        let gi = UInt32(max(0, min(1, g)) * 255 + 0.5)
        let bi = UInt32(max(0, min(1, b)) * 255 + 0.5)
        return 0xFF00_0000 | (ri << 16) | (gi << 8) | bi
    }

    public static let clear = Color(0, 0, 0, 0)
    public static let black = Color(0, 0, 0)
    public static let white = Color(1, 1, 1)

    public static let desktopTop         = Color.hex(0x2E3440)
    public static let desktopBottom      = Color.hex(0x1B1E25)
    public static let panel              = Color.hex(0x191C21)
    public static let panelText          = Color.hex(0xD8DEE9)
    public static let taskbar            = Color.hex(0x14161B)
    public static let windowBackground   = Color.hex(0x23262D)
    public static let windowBorder       = Color.hex(0x0E1013)
    public static let titleBar           = Color.hex(0x2C3037)
    public static let titleBarFocused    = Color.hex(0x3A3F47)
    public static let titleText          = Color.hex(0xE5E9F0)
    public static let titleTextDim       = Color.hex(0x9DA3AE)
    public static let accent             = Color.hex(0x3584E4)
    public static let selection          = Color.hex(0x2B4C6E)
    public static let green              = Color.hex(0x33D17A)
    public static let red                = Color.hex(0xE01B24)
    public static let yellow             = Color.hex(0xE5A50A)
    public static let orange             = Color.hex(0xFF7800)
    public static let purple             = Color.hex(0x9141AC)
    public static let cyan               = Color.hex(0x35C4B5)
    public static let blue               = Color.hex(0x62A0EA)
    public static let gray               = Color.hex(0x9A9996)
    public static let darkGray           = Color.hex(0x5E5C64)
    public static let lightGray          = Color.hex(0xC0BFBC)
    public static let terminalBackground = Color.hex(0x0D0F13)
    public static let terminalText       = Color.hex(0xD8DEE9)
}

/// min/max/clamp helpers that Foundation would normally provide in some paths.
@inline(__always) public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}

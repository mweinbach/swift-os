// Input event model shared by the kernel input drivers and userland.

public struct KeyModifiers: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let shift   = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

public struct KeyEvent {
    /// macOS-style key codes are kept for compatibility with ported app code:
    /// arrows 123/124/125/126 (L/R/U/D), Return 36, Backspace 51, Escape 53,
    /// Tab 48, Space 49, PageUp 116, PageDown 121, Home 115, End 119,
    /// Forward-Delete 117, keypad Enter 76. The input driver maps evdev codes
    /// onto these.
    public let keyCode: UInt16
    public let characters: String
    public let modifiers: KeyModifiers
    public let isRepeat: Bool

    public init(keyCode: UInt16, characters: String, modifiers: KeyModifiers, isRepeat: Bool) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

public enum OSEvent {
    case keyDown(KeyEvent)
    case keyUp(KeyEvent)
    case mouseDown(Point)
    case rightMouseDown(Point)
    case mouseUp(Point)
    case mouseMoved(Point)
    case mouseDragged(Point)
    case scrollWheel(at: Point, deltaX: CGFloat, deltaY: CGFloat)
}

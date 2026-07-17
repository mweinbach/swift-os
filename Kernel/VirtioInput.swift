// Virtio input driver (legacy virtio-mmio v1) for QEMU's virtio-keyboard and
// virtio-tablet, plus serial-console keyboard input via the PL011 UART.
//
// QEMU virt exposes up to 32 virtio-mmio slots at 0x0A00_0000 + slot*0x200
// (IRQ 16+slot — unused; we poll the used rings from the main loop). The
// Makefile boots with -global virtio-mmio.force-legacy=on, so only the
// legacy (v1) register interface is implemented.
//
// Devices deliver evdev events through vring queue 0 (eventq) as
//   struct virtio_input_event { u16 type; u16 code; u32 value; }
// Keyboard EV_KEY codes are translated to the macOS-style key codes the rest
// of the OS speaks (see Userland/Events.swift) plus ASCII characters with
// shift applied. Tablet EV_ABS coordinates (0..32767) are scaled onto the
// framebuffer; BTN_LEFT/BTN_RIGHT produce mouse events.

import _Volatile

// File-local volatile accessors for sub-word MMIO and ring memory
// (MMIO.swift only has 32/64-bit variants).

@inline(__always)
private func vload8(_ a: UInt) -> UInt8 {
    VolatileMappedRegister<UInt8>(unsafeBitPattern: a).load()
}

@inline(__always)
private func vstore8(_ a: UInt, _ v: UInt8) {
    VolatileMappedRegister<UInt8>(unsafeBitPattern: a).store(v)
}

@inline(__always)
private func vload16(_ a: UInt) -> UInt16 {
    VolatileMappedRegister<UInt16>(unsafeBitPattern: a).load()
}

@inline(__always)
private func vstore16(_ a: UInt, _ v: UInt16) {
    VolatileMappedRegister<UInt16>(unsafeBitPattern: a).store(v)
}

@inline(__always)
private func vstore64(_ a: UInt, _ v: UInt64) {
    VolatileMappedRegister<UInt64>(unsafeBitPattern: a).store(v)
}

// Legacy virtio-mmio register offsets from the slot base.
private enum VReg {
    static let magicValue: UInt = 0x00     // reads 'virt' = 0x74726976
    static let version: UInt = 0x04        // 1 = legacy interface
    static let deviceID: UInt = 0x08       // 18 = input device
    static let hostFeatures: UInt = 0x10
    static let guestFeatures: UInt = 0x20
    static let guestPageSize: UInt = 0x28
    static let queueSel: UInt = 0x30
    static let queueNumMax: UInt = 0x34
    static let queueNum: UInt = 0x38
    static let queueAlign: UInt = 0x3C
    static let queuePFN: UInt = 0x40
    static let queueNotify: UInt = 0x50
    static let interruptStatus: UInt = 0x60
    static let interruptACK: UInt = 0x64
    static let status: UInt = 0x70
    static let config: UInt = 0x100        // device config space starts here
}

// Virtio status register bits.
private let stAcknowledge: UInt32 = 1
private let stDriver: UInt32 = 2
private let stDriverOK: UInt32 = 4
private let stFeaturesOK: UInt32 = 8

/// One initialized virtio input device with its event queue.
///
/// NOTE: the reserved fields pad the struct to 48 bytes (a multiple of 16).
/// Trivial-type copies are inlined by the compiler as 16-byte vector ops;
/// with the MMU off all memory is Device-like and an UNALIGNED vector access
/// faults (observed: ESR 0x96000021 during devices.append). Size 48 keeps
/// every chunk of the copy naturally aligned.
private struct VirtioInputDevice {
    enum Kind { case keyboard, tablet }

    let base: UInt
    let kind: Kind
    let qsize: UInt16
    let availBase: UInt   // vring avail ring (u16 flags, u16 idx, u16 ring[qsize])
    let usedBase: UInt    // vring used ring, 4096-aligned
    let bufBase: UInt     // qsize event buffers of bufLen bytes each
    var availIdx: UInt16  // next avail-ring index to publish
    var lastUsed: UInt16  // next used-ring index to consume
    let reserved: UInt32 = 0
}

enum Input {
    /// Current pointer position in framebuffer pixels.
    static private(set) var mouseX: Int = Config.screenWidth / 2
    static private(set) var mouseY: Int = Config.screenHeight / 2

    private static let mmioBase: UInt = 0x0A00_0000
    private static let slotStride: UInt = 0x200
    private static let slotCount = 32
    private static let bufLen: UInt = 64
    private static let absMax = 32767     // virtio tablet ABS_X/ABS_Y maximum

    private static var devices: [VirtioInputDevice] = []
    private static var mods: KeyModifiers = []
    private static var leftButtonDown = false
    private static var rightButtonDown = false

    // MARK: - Initialization

    /// Scan all virtio-mmio slots and initialize every legacy input device
    /// found. Returns false when none exist (serial input still works).
    static func initInput() -> Bool {
        devices.removeAll()
        var fallbackCount = 0
        for slot in 0..<slotCount {
            let base = mmioBase + UInt(slot) * slotStride
            guard mmioRead32(base + VReg.magicValue) == 0x7472_6976 else { continue }
            guard mmioRead32(base + VReg.deviceID) == 18 else { continue }
            guard mmioRead32(base + VReg.version) == 1 else {
                klog("[input] slot \(slot): modern-only virtio input device skipped")
                continue
            }
            let name = readDeviceName(base)
            let kind: VirtioInputDevice.Kind
            if containsASCII(name, "Keyboard") {
                kind = .keyboard
            } else if containsASCII(name, "Tablet") {
                kind = .tablet
            } else {
                // Unnamed device: assume QEMU's keyboard/tablet pair order.
                kind = fallbackCount == 0 ? .keyboard : .tablet
                fallbackCount += 1
            }
            guard let dev = setupDevice(base: base, kind: kind) else {
                klog("[input] slot \(slot): \(name) setup FAILED")
                continue
            }
            devices.append(dev)
            switch kind {
            case .keyboard: klog("[input] virtio keyboard (slot \(slot))")
            case .tablet:   klog("[input] virtio tablet (slot \(slot))")
            }
        }
        if devices.isEmpty {
            klog("[input] no virtio input devices found — serial keyboard only")
        }
        return !devices.isEmpty
    }

    /// VIRTIO_INPUT_CFG_ID_NAME (select 0x01, subsel 0) from the config space.
    private static func readDeviceName(_ base: UInt) -> String {
        let cfg = base + VReg.config
        vstore8(cfg + 0x00, 0x01)     // select = ID_NAME
        vstore8(cfg + 0x01, 0x00)     // subsel = 0
        let size = vload8(cfg + 0x02)
        var bytes: [UInt8] = []
        for i in 0..<min(Int(size), 64) {
            bytes.append(vload8(cfg + 0x08 + UInt(i)))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Foundation-free substring test over UTF-8 bytes (init-time only).
    private static func containsASCII(_ s: String, _ sub: String) -> Bool {
        let a = Array(s.utf8), b = Array(sub.utf8)
        if b.count > a.count { return false }
        if b.isEmpty { return true }
        for i in 0...(a.count - b.count) {
            var match = true
            for j in 0..<b.count where a[i + j] != b[j] { match = false; break }
            if match { return true }
        }
        return false
    }

    /// Legacy virtio bring-up: status handshake, then vring + buffer posting.
    private static func setupDevice(base: UInt, kind: VirtioInputDevice.Kind) -> VirtioInputDevice? {
        mmioWrite32(base + VReg.status, 0)                            // reset
        mmioWrite32(base + VReg.status, stAcknowledge)
        mmioWrite32(base + VReg.status, stAcknowledge | stDriver)
        _ = mmioRead32(base + VReg.hostFeatures)                      // we require nothing
        mmioWrite32(base + VReg.guestFeatures, 0)
        // FEATURES_OK is optional on the legacy interface; continue either way.
        mmioWrite32(base + VReg.status, stAcknowledge | stDriver | stFeaturesOK)
        _ = mmioRead32(base + VReg.status)

        mmioWrite32(base + VReg.guestPageSize, 4096)
        mmioWrite32(base + VReg.queueSel, 0)                          // queue 0 = eventq
        let qmax = mmioRead32(base + VReg.queueNumMax)
        guard qmax > 0 else { return nil }
        let qsize = UInt16(min(qmax, 8))
        mmioWrite32(base + VReg.queueNum, UInt32(qsize))
        mmioWrite32(base + VReg.queueAlign, 4096)

        // Vring: descriptor table (qsize*16 B) + avail ring in page 0,
        // used ring at +4096 (QueueAlign). Buffers live on their own page.
        guard let vq = KernelHeap.allocPages(2) else { return nil }
        guard let bufs = KernelHeap.allocPages(1) else { return nil }
        zeroRegion(vq, 2 * 4096)
        zeroRegion(bufs, 4096)

        let availBase = vq + UInt(qsize) * 16
        let usedBase = vq + 4096
        mmioWrite32(base + VReg.queuePFN, UInt32(vq / 4096))

        vstore16(availBase, 1)  // VIRTQ_AVAIL_F_NO_INTERRUPT — we poll
        var i: UInt16 = 0
        while i < qsize {
            let desc = vq + UInt(i) * 16
            vstore64(desc, UInt64(bufs + UInt(i) * bufLen))
            mmioWrite32(desc + 8, UInt32(bufLen)) // length
            vstore16(desc + 12, 2)          // VIRTQ_DESC_F_WRITE (device-writable)
            vstore16(desc + 14, 0)          // next
            vstore16(availBase + 4 + UInt(i) * 2, i)
            i += 1
        }
        armDsbSy()
        vstore16(availBase + 2, qsize)      // avail.idx: all buffers posted
        armDsbSy()

        // Acknowledge any stale interrupt, go live, then kick the device.
        mmioWrite32(base + VReg.interruptACK, mmioRead32(base + VReg.interruptStatus))
        mmioWrite32(base + VReg.status, stAcknowledge | stDriver | stFeaturesOK | stDriverOK)
        mmioWrite32(base + VReg.queueNotify, 0)

        return VirtioInputDevice(base: base, kind: kind, qsize: qsize,
                                 availBase: availBase, usedBase: usedBase,
                                 bufBase: bufs, availIdx: qsize, lastUsed: 0)
    }

    private static func zeroRegion(_ base: UInt, _ bytes: Int) {
        var off = 0
        while off < bytes {
            vstore64(base + UInt(off), 0)
            off += 8
        }
    }

    // MARK: - Polling

    /// Drain every device's used ring and the UART RX FIFO. Called once per
    /// frame from the kernel main loop (not IRQ context — allocation is OK).
    static func pollEvents() -> [OSEvent] {
        var out: [OSEvent] = []
        // Reserve up front and cap the batch: array GROWTH reallocates via
        // moveInitialize, which the compiler lowers to 16-byte vector copies.
        // OSEvent's stride is 40, so every second element sits 8 mod 16 and
        // an unaligned vector copy faults while the MMU is off (Device-like
        // memory, ESR 0x96000021). With spare capacity, appends are plain
        // field-wise copies. The buffer itself is freed (real free) once the
        // memory subsystem replaces the bump allocator.
        out.reserveCapacity(maxEventsPerPoll)
        for i in devices.indices {
            drain(&devices[i], into: &out)
        }
        drainUART(into: &out)
        return out
    }

    /// Events delivered per poll; leftovers stay in the rings/UART FIFO for
    /// the next call.
    private static let maxEventsPerPoll = 64

    private static func drain(_ d: inout VirtioInputDevice, into out: inout [OSEvent]) {
        let usedIdx = vload16(d.usedBase + 2)
        while d.lastUsed != usedIdx && out.count < maxEventsPerPoll {
            let slot = d.lastUsed % d.qsize
            let id = UInt16(mmioRead32(d.usedBase + 4 + UInt(slot) * 8) & 0xFFFF)
            if id < d.qsize {
                let b = d.bufBase + UInt(id) * bufLen
                handleEvent(d.kind, type: vload16(b), code: vload16(b + 2),
                            value: mmioRead32(b + 4), into: &out)
                repost(&d, id: id)
            }
            d.lastUsed &+= 1
        }
    }

    /// Return a consumed buffer to the avail ring and notify the device.
    private static func repost(_ d: inout VirtioInputDevice, id: UInt16) {
        vstore16(d.availBase + 4 + UInt(d.availIdx % d.qsize) * 2, id)
        armDsbSy()
        d.availIdx &+= 1
        vstore16(d.availBase + 2, d.availIdx)
        armDsbSy()
        mmioWrite32(d.base + VReg.queueNotify, 0)
    }

    private static func handleEvent(_ kind: VirtioInputDevice.Kind, type: UInt16,
                                    code: UInt16, value: UInt32, into out: inout [OSEvent]) {
        switch kind {
        case .keyboard:
            if type == 0x01 { handleKey(code, value: value, into: &out) }   // EV_KEY
        case .tablet:
            switch type {
            case 0x01: handleTabletButton(code, value: value, into: &out)   // EV_KEY
            case 0x02:                                                      // EV_REL
                if code == 0x08 {                                           // REL_WHEEL
                    out.append(.scrollWheel(at: mousePoint(), deltaX: 0,
                                            deltaY: Double(Int32(bitPattern: value))))
                }
            case 0x03: handleAbs(code, value: value, into: &out)            // EV_ABS
            default: break
            }
        }
    }

    // MARK: - Keyboard (virtio keyboard)

    private static func handleKey(_ code: UInt16, value: UInt32, into out: inout [OSEvent]) {
        // Modifier keys update the tracked state and generate events too.
        if let mod = modifierKey(code) {
            if value == 1 { mods.insert(mod.flag) }
            else if value == 0 { mods.remove(mod.flag) }
            else { return }                                                 // ignore repeats
            let ev = KeyEvent(keyCode: mod.mac, characters: "", modifiers: mods, isRepeat: false)
            out.append(value == 1 ? .keyDown(ev) : .keyUp(ev))
            return
        }
        guard value <= 2 else { return }
        guard let (mac, chars) = translate(code) else { return }            // unmapped key
        let ev = KeyEvent(keyCode: mac, characters: chars, modifiers: mods, isRepeat: value == 2)
        out.append(value == 0 ? .keyUp(ev) : .keyDown(ev))
    }

    /// evdev KEY_* → (macOS key code, characters with shift/control applied).
    private static func translate(_ evdev: UInt16) -> (UInt16, String)? {
        for e in keyTable where e.evdev == evdev {
            if mods.contains(.control), e.lower >= 97, e.lower <= 122 {
                return (e.mac, asciiString(e.lower & 0x1F))                 // ctrl+a → 0x01 …
            }
            return (e.mac, asciiString(mods.contains(.shift) ? e.upper : e.lower))
        }
        switch evdev {
        case 1:   return (53, "")         // ESC
        case 14:  return (51, "\u{7F}")   // BACKSPACE
        case 15:  return (48, "\t")       // TAB
        case 28:  return (36, "\r")       // ENTER
        case 96:  return (76, "\r")       // keypad ENTER
        case 102: return (115, "")        // HOME
        case 103: return (126, "")        // UP
        case 104: return (116, "")        // PAGEUP
        case 105: return (123, "")        // LEFT
        case 106: return (124, "")        // RIGHT
        case 107: return (119, "")        // END
        case 108: return (125, "")        // DOWN
        case 109: return (121, "")        // PAGEDOWN
        case 111: return (117, "")        // forward DELETE
        default:  return nil
        }
    }

    private static func modifierKey(_ evdev: UInt16) -> (mac: UInt16, flag: KeyModifiers)? {
        switch evdev {
        case 42:  return (56, .shift)     // LEFTSHIFT
        case 54:  return (60, .shift)     // RIGHTSHIFT
        case 29:  return (59, .control)   // LEFTCTRL
        case 97:  return (62, .control)   // RIGHTCTRL
        case 56:  return (58, .option)    // LEFTALT
        case 100: return (61, .option)    // RIGHTALT
        case 125: return (55, .command)   // LEFTMETA
        case 126: return (54, .command)   // RIGHTMETA
        default:  return nil
        }
    }

    private struct KeyEntry {
        let evdev: UInt16
        let mac: UInt16
        let lower: UInt8
        let upper: UInt8
    }

    /// Printable keys: evdev KEY_* → macOS virtual key code + ASCII (plain/shifted).
    private static let keyTable: [KeyEntry] = [
        KeyEntry(evdev:  2, mac: 18, lower:  49, upper:  33), // 1 !
        KeyEntry(evdev:  3, mac: 19, lower:  50, upper:  64), // 2 @
        KeyEntry(evdev:  4, mac: 20, lower:  51, upper:  35), // 3 #
        KeyEntry(evdev:  5, mac: 21, lower:  52, upper:  36), // 4 $
        KeyEntry(evdev:  6, mac: 23, lower:  53, upper:  37), // 5 %
        KeyEntry(evdev:  7, mac: 22, lower:  54, upper:  94), // 6 ^
        KeyEntry(evdev:  8, mac: 26, lower:  55, upper:  38), // 7 &
        KeyEntry(evdev:  9, mac: 28, lower:  56, upper:  42), // 8 *
        KeyEntry(evdev: 10, mac: 25, lower:  57, upper:  40), // 9 (
        KeyEntry(evdev: 11, mac: 29, lower:  48, upper:  41), // 0 )
        KeyEntry(evdev: 12, mac: 27, lower:  45, upper:  95), // - _
        KeyEntry(evdev: 13, mac: 24, lower:  61, upper:  43), // = +
        KeyEntry(evdev: 16, mac: 12, lower: 113, upper:  81), // q Q
        KeyEntry(evdev: 17, mac: 13, lower: 119, upper:  87), // w W
        KeyEntry(evdev: 18, mac: 14, lower: 101, upper:  69), // e E
        KeyEntry(evdev: 19, mac: 15, lower: 114, upper:  82), // r R
        KeyEntry(evdev: 20, mac: 17, lower: 116, upper:  84), // t T
        KeyEntry(evdev: 21, mac: 16, lower: 121, upper:  89), // y Y
        KeyEntry(evdev: 22, mac: 32, lower: 117, upper:  85), // u U
        KeyEntry(evdev: 23, mac: 34, lower: 105, upper:  73), // i I
        KeyEntry(evdev: 24, mac: 31, lower: 111, upper:  79), // o O
        KeyEntry(evdev: 25, mac: 35, lower: 112, upper:  80), // p P
        KeyEntry(evdev: 26, mac: 33, lower:  91, upper: 123), // [ {
        KeyEntry(evdev: 27, mac: 30, lower:  93, upper: 125), // ] }
        KeyEntry(evdev: 30, mac:  0, lower:  97, upper:  65), // a A
        KeyEntry(evdev: 31, mac:  1, lower: 115, upper:  83), // s S
        KeyEntry(evdev: 32, mac:  2, lower: 100, upper:  68), // d D
        KeyEntry(evdev: 33, mac:  3, lower: 102, upper:  70), // f F
        KeyEntry(evdev: 34, mac:  5, lower: 103, upper:  71), // g G
        KeyEntry(evdev: 35, mac:  4, lower: 104, upper:  72), // h H
        KeyEntry(evdev: 36, mac: 38, lower: 106, upper:  74), // j J
        KeyEntry(evdev: 37, mac: 40, lower: 107, upper:  75), // k K
        KeyEntry(evdev: 38, mac: 37, lower: 108, upper:  76), // l L
        KeyEntry(evdev: 39, mac: 41, lower:  59, upper:  58), // ; :
        KeyEntry(evdev: 40, mac: 39, lower:  39, upper:  34), // ' "
        KeyEntry(evdev: 41, mac: 50, lower:  96, upper: 126), // ` ~
        KeyEntry(evdev: 43, mac: 42, lower:  92, upper: 124), // \ |
        KeyEntry(evdev: 44, mac:  6, lower: 122, upper:  90), // z Z
        KeyEntry(evdev: 45, mac:  7, lower: 120, upper:  88), // x X
        KeyEntry(evdev: 46, mac:  8, lower:  99, upper:  67), // c C
        KeyEntry(evdev: 47, mac:  9, lower: 118, upper:  86), // v V
        KeyEntry(evdev: 48, mac: 11, lower:  98, upper:  66), // b B
        KeyEntry(evdev: 49, mac: 45, lower: 110, upper:  78), // n N
        KeyEntry(evdev: 50, mac: 46, lower: 109, upper:  77), // m M
        KeyEntry(evdev: 51, mac: 43, lower:  44, upper:  60), // , <
        KeyEntry(evdev: 52, mac: 47, lower:  46, upper:  62), // . >
        KeyEntry(evdev: 53, mac: 44, lower:  47, upper:  63), // / ?
        KeyEntry(evdev: 57, mac: 49, lower:  32, upper:  32), // space
    ]

    // MARK: - Tablet (virtio tablet, absolute pointer)

    private static func handleAbs(_ code: UInt16, value: UInt32, into out: inout [OSEvent]) {
        var nx = mouseX, ny = mouseY
        if code == 0 {          // ABS_X
            nx = clamp(Int(value) * (Config.screenWidth - 1) / absMax, 0, Config.screenWidth - 1)
        } else if code == 1 {   // ABS_Y
            ny = clamp(Int(value) * (Config.screenHeight - 1) / absMax, 0, Config.screenHeight - 1)
        } else {
            return
        }
        guard nx != mouseX || ny != mouseY else { return }
        mouseX = nx
        mouseY = ny
        let p = mousePoint()
        out.append((leftButtonDown || rightButtonDown) ? .mouseDragged(p) : .mouseMoved(p))
    }

    private static func handleTabletButton(_ code: UInt16, value: UInt32, into out: inout [OSEvent]) {
        switch code {
        case 0x110, 0x14A:  // BTN_LEFT (BTN_TOUCH treated as left click)
            if value == 1 { leftButtonDown = true;  out.append(.mouseDown(mousePoint())) }
            else if value == 0 { leftButtonDown = false; out.append(.mouseUp(mousePoint())) }
        case 0x111:         // BTN_RIGHT
            if value == 1 { rightButtonDown = true; out.append(.rightMouseDown(mousePoint())) }
            else if value == 0 { rightButtonDown = false; out.append(.mouseUp(mousePoint())) }
        default: break
        }
    }

    private static func mousePoint() -> Point {
        Point(x: Double(mouseX), y: Double(mouseY))
    }

    private static func asciiString(_ a: UInt8) -> String {
        String(Character(Unicode.Scalar(a)))
    }

    // MARK: - Serial console input (UART)

    private enum UARTRxState { case normal, esc, csi }
    private static var uartState: UARTRxState = .normal
    private static var uartLastWasCR = false
    private static var csiParam = 0

    private static func drainUART(into out: inout [OSEvent]) {
        var budget = 0
        while budget < 256 && out.count < maxEventsPerPoll, let byte = UART.getc() {
            budget += 1
            uartByte(byte, into: &out)
        }
        // A trailing ESC with nothing after it is the Escape key itself.
        if uartState == .esc {
            uartState = .normal
            emitSerialKey(mac: 53, chars: "", modifiers: [], into: &out)
        }
    }

    private static func uartByte(_ b: UInt8, into out: inout [OSEvent]) {
        switch uartState {
        case .normal:
            switch b {
            case 27:      uartState = .esc
            case 13:      emitSerialKey(mac: 36, chars: "\r", modifiers: [], into: &out)     // CR → Return
                          uartLastWasCR = true
            case 10:      if !uartLastWasCR {                                                // bare LF → Return
                              emitSerialKey(mac: 36, chars: "\r", modifiers: [], into: &out)
                          }
                          uartLastWasCR = false
            case 9:       emitSerialKey(mac: 48, chars: "\t", modifiers: [], into: &out)     // TAB
                          uartLastWasCR = false
            case 0x7F:    emitSerialKey(mac: 51, chars: "\u{7F}", modifiers: [], into: &out) // DEL → Backspace
                          uartLastWasCR = false
            case 32...126:
                uartLastWasCR = false
                if let (mac, chars, m) = asciiKey(b) {
                    emitSerialKey(mac: mac, chars: chars, modifiers: m, into: &out)
                }
            default: break
            }
        case .esc:
            if b == 0x5B {  // '['
                uartState = .csi
                csiParam = 0
            } else {
                // ESC + other byte: ESC was the Escape key; reprocess this byte.
                uartState = .normal
                emitSerialKey(mac: 53, chars: "", modifiers: [], into: &out)
                uartByte(b, into: &out)
            }
        case .csi:
            if b >= 48 && b <= 57 {
                csiParam = csiParam * 10 + Int(b - 48)
            } else {
                uartState = .normal
                switch b {
                case 65:  emitSerialKey(mac: 126, chars: "", modifiers: [], into: &out)  // A → Up
                case 66:  emitSerialKey(mac: 125, chars: "", modifiers: [], into: &out)  // B → Down
                case 67:  emitSerialKey(mac: 124, chars: "", modifiers: [], into: &out)  // C → Right
                case 68:  emitSerialKey(mac: 123, chars: "", modifiers: [], into: &out)  // D → Left
                case 72:  emitSerialKey(mac: 115, chars: "", modifiers: [], into: &out)  // H → Home
                case 70:  emitSerialKey(mac: 119, chars: "", modifiers: [], into: &out)  // F → End
                case 126: // '~'
                    switch csiParam {
                    case 3:    emitSerialKey(mac: 117, chars: "", modifiers: [], into: &out) // Delete
                    case 5:    emitSerialKey(mac: 116, chars: "", modifiers: [], into: &out) // PageUp
                    case 6:    emitSerialKey(mac: 121, chars: "", modifiers: [], into: &out) // PageDown
                    case 1, 7: emitSerialKey(mac: 115, chars: "", modifiers: [], into: &out) // Home
                    case 4, 8: emitSerialKey(mac: 119, chars: "", modifiers: [], into: &out) // End
                    default: break
                    }
                default: break
                }
            }
        }
    }

    /// Reverse lookup for serial input: ASCII byte → key table entry.
    private static func asciiKey(_ b: UInt8) -> (mac: UInt16, chars: String, mods: KeyModifiers)? {
        for e in keyTable {
            if e.lower == b { return (e.mac, asciiString(b), []) }
            if e.upper == b { return (e.mac, asciiString(b), [.shift]) }
        }
        return nil
    }

    /// Serial bytes carry no press/release, so emit a complete keystroke.
    /// Kept out of line deliberately: when the enum store is inlined into the
    /// caller the compiler may emit a single 32-byte vector copy for the
    /// OSEvent payload, which faults on odd (8 mod 16) element addresses while
    /// the MMU is off. Out of line, the append is compiled as scalar copies.
    @inline(never)
    private static func emitSerialKey(mac: UInt16, chars: String,
                                      modifiers: KeyModifiers, into out: inout [OSEvent]) {
        let ev = KeyEvent(keyCode: mac, characters: chars, modifiers: modifiers, isRepeat: false)
        out.append(.keyDown(ev))
        out.append(.keyUp(ev))
    }
}

// ramfb display driver for QEMU virt. QEMU's fw_cfg device (0x0902_0000)
// exposes an "etc/ramfb" file; writing a config struct to it points QEMU's
// ramfb scanout at a plain RAM buffer we own. No real display hardware is
// involved: present() is a memcpy into the scanout buffer.
//
// Pixels are little-endian UInt32 0xFFRRGGBB (XR24 = DRM_FORMAT_XRGB8888).
// The MMU is off, so Swift pointers are guest-physical addresses and RAM
// buffers need no cache maintenance.

enum Display {
    static private(set) var width: Int = 0
    static private(set) var height: Int = 0
    static private(set) var strideBytes: Int = 0

    /// Front buffer: the memory QEMU scans out.
    static var framebuffer: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: fbAddr)!
    }
    /// Back buffer: compositor target. present() copies it to the front.
    static var backBuffer: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: backAddr)!
    }

    private static var fbAddr: UInt = 0
    private static var backAddr: UInt = 0

    // fw_cfg MMIO registers (QEMU virt).
    private enum FwCfg {
        static let data: UInt     = 0x0902_0000
        static let selector: UInt = 0x0902_0008
        static let dma: UInt      = 0x0902_0010   // 64-bit: address of FWCfgDmaAccess
        // DMA control bits; the selector rides in the upper 16 bits. A
        // transfer without ctlRead is a write (guest -> device).
        static let ctlRead: UInt32   = 0x02
        static let ctlSelect: UInt32 = 0x08
        static let fileDirKey: UInt32 = 0x19      // FW_CFG_FILE_DIR
    }

    /// Physical address of the 16-byte FWCfgDmaAccess descriptor, reused
    /// for every transfer.
    private static var dmaDescAddr: UInt = 0

    private static let hexDigits: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "a", "b", "c", "d", "e", "f",
    ]

    /// Bring up the framebuffer: allocate front/back buffers, paint the front
    /// dark blue-gray so early boot shows something, then hand the front to
    /// ramfb via fw_cfg DMA. Safe to call more than once.
    static func initDisplay() -> Bool {
        if width != 0 { return true }

        let w = Config.screenWidth
        let h = Config.screenHeight
        let stride = w * 4
        let bytes = stride * h
        let pages = (bytes + 4095) / 4096

        guard let front = KernelHeap.allocPages(pages),
              let back = KernelHeap.allocPages(pages) else {
            klog("[fb] ramfb: page allocation failed")
            return false
        }
        guard let dmaDesc = KernelHeap.alloc(size: 16, alignment: 8) else {
            klog("[fb] ramfb: descriptor allocation failed")
            return false
        }
        dmaDescAddr = UInt(bitPattern: dmaDesc)

        let frontPtr = UnsafeMutableRawPointer(bitPattern: front)!
        fillColor(frontPtr, color: 0xFF1B_1E25, bytes: bytes)
        memset_(UnsafeMutableRawPointer(bitPattern: back), 0, bytes)

        guard let selector = findRamfbSelector() else {
            klog("[fb] ramfb: etc/ramfb not present (boot with -device ramfb)")
            return false
        }

        // etc/ramfb config struct, all fields big-endian:
        //   u64 addr, u32 fourcc, u32 flags, u32 width, u32 height, u32 stride
        guard let cfg = KernelHeap.alloc(size: 28, alignment: 8) else {
            klog("[fb] ramfb: config allocation failed")
            return false
        }
        cfg.storeBytes(of: UInt64(front).bigEndian, toByteOffset: 0, as: UInt64.self)
        cfg.storeBytes(of: UInt32(0x3432_5258).bigEndian, toByteOffset: 8, as: UInt32.self) // 'XR24'
        cfg.storeBytes(of: UInt32(0).bigEndian, toByteOffset: 12, as: UInt32.self)
        cfg.storeBytes(of: UInt32(w).bigEndian, toByteOffset: 16, as: UInt32.self)
        cfg.storeBytes(of: UInt32(h).bigEndian, toByteOffset: 20, as: UInt32.self)
        cfg.storeBytes(of: UInt32(stride).bigEndian, toByteOffset: 24, as: UInt32.self)
        fwCfgDma(control: (selector << 16) | FwCfg.ctlSelect,
                 length: 28, address: UInt(bitPattern: cfg))

        fbAddr = front
        backAddr = back
        width = w
        height = h
        strideBytes = stride

        klog("[fb] ramfb \(w)x\(h) @ \(hex(front))")
        return true
    }

    /// Copy the composited frame (back -> front).
    static func present() {
        if strideBytes == 0 { return }
        memcpy_(framebuffer, backBuffer, strideBytes * height)
    }

    // MARK: - fw_cfg DMA

    /// One fw_cfg DMA transfer. control/length/address are stored big-endian
    /// into the FWCfgDmaAccess descriptor; writing the descriptor's physical
    /// address to the DMA register performs the transfer synchronously.
    private static func fwCfgDma(control: UInt32, length: UInt32, address: UInt) {
        let desc = UnsafeMutableRawPointer(bitPattern: dmaDescAddr)!
        desc.storeBytes(of: control.bigEndian, toByteOffset: 0, as: UInt32.self)
        desc.storeBytes(of: length.bigEndian, toByteOffset: 4, as: UInt32.self)
        desc.storeBytes(of: UInt64(address).bigEndian, toByteOffset: 8, as: UInt64.self)
        mmioWrite64(FwCfg.dma, UInt64(dmaDescAddr))
    }

    /// Read the fw_cfg file directory and return the selector for
    /// "etc/ramfb", or nil when ramfb is not attached.
    private static func findRamfbSelector() -> UInt32? {
        guard let countBuf = KernelHeap.alloc(size: 4, alignment: 4) else { return nil }
        fwCfgDma(control: (FwCfg.fileDirKey << 16) | FwCfg.ctlSelect | FwCfg.ctlRead,
                 length: 4, address: UInt(bitPattern: countBuf))
        let count = Int(countBuf.load(as: UInt32.self).bigEndian)
        if count <= 0 || count > 4096 { return nil }

        guard let dir = KernelHeap.alloc(size: count * 64, alignment: 4) else { return nil }
        fwCfgDma(control: FwCfg.ctlRead, length: UInt32(count * 64),
                 address: UInt(bitPattern: dir))

        // FWCfgFile: u32 size, u16 select, u16 reserved, char name[56].
        let target = "etc/ramfb"
        var off = 0
        for _ in 0..<count {
            var match = true
            var j = 0
            for c in target.utf8 {
                if dir.load(fromByteOffset: off + 8 + j, as: UInt8.self) != c {
                    match = false
                    break
                }
                j += 1
            }
            if match && dir.load(fromByteOffset: off + 8 + j, as: UInt8.self) == 0 {
                return UInt32(dir.load(fromByteOffset: off + 4, as: UInt16.self).bigEndian)
            }
            off += 64
        }
        return nil
    }

    // MARK: - helpers

    private static func fillColor(_ p: UnsafeMutableRawPointer, color: UInt32, bytes: Int) {
        let pair = UInt64(color) << 32 | UInt64(color)
        var i = 0
        while i + 8 <= bytes {
            p.storeBytes(of: pair, toByteOffset: i, as: UInt64.self)
            i += 8
        }
        while i < bytes {
            p.storeBytes(of: color, toByteOffset: i, as: UInt32.self)
            i += 4
        }
    }

    private static func hex(_ v: UInt) -> String {
        var s = "0x"
        var shift = 60
        while shift >= 0 {
            s.append(hexDigits[Int((v >> UInt(shift)) & 0xF)])
            shift -= 4
        }
        return s
    }
}

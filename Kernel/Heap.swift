// Kernel heap. v1: bump allocator over [heapStart, heapEnd). The memory
// subsystem replaces the internals with a page allocator + free lists while
// keeping this exact API.

enum KernelHeap {
    static let heapStart: UInt = 0x4080_0000
    static let heapEnd:   UInt = 0x5000_0000
    static private var next: UInt = heapStart

    static func initHeap() {
        next = heapStart
    }

    static func alloc(size: Int, alignment: Int) -> UnsafeMutableRawPointer? {
        let align = UInt(max(alignment, 16))
        next = (next + align - 1) & ~(align - 1)
        let p = next
        next += UInt(size)
        guard next <= heapEnd else { return nil }
        return UnsafeMutableRawPointer(bitPattern: p)
    }

    static func free(_ p: UnsafeMutableRawPointer?) {
        // Bump allocator: no-op. Replaced by the memory subsystem.
    }

    /// Physical page allocator (4 KiB pages). Returns the page address, or nil.
    static func allocPages(_ count: Int) -> UInt? {
        let bytes = UInt(count) * 4096
        next = (next + 4095) & ~UInt(4095)
        let p = next
        next += bytes
        guard next <= heapEnd else { return nil }
        return p
    }

    static func freePages(_ base: UInt, count: Int) {
        // Bump allocator: no-op.
    }

    static var totalBytes: Int { Int(heapEnd - heapStart) }
    static var usedBytes: Int { Int(next - heapStart) }
    static var freePageCount: Int { Int((heapEnd - next) / 4096) }
}

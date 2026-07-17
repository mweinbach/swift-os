// Kernel heap: 4 KiB physical page allocator + kernel malloc heap.
//
// Managed region [heapStart, heapEnd) = 248 MiB, laid out as:
//   [heapStart, heapStart + 8 KiB)   page bitmap, 1 bit per 4 KiB page
//                                    (63,488 pages = 992 words; 2 pages reserved)
//   [arenaStart, arenaEnd)           64 MiB kernel malloc arena (boundary-tag
//                                    allocator, coalescing on free); its pages
//                                    are marked reserved in the bitmap at init
//   remainder (~184 MiB)             allocPages pool (first-fit, contiguous)
//
// CRITICAL: this code runs underneath the Swift runtime (posix_memalign ->
// KernelHeap.alloc). It must never itself allocate: no Array/Dictionary/
// String interpolation inside alloc/free — fixed statics and raw pointers
// only. Detected corruption (double free, wild pointer, broken tags) panics
// with a literal message rather than silently poisoning the heap.
//
// Every public entry point (alloc/free/allocPages/freePages) is IRQ-atomic:
// wrapped in armIrqSave/armIrqRestore (nesting-safe, unlike raw
// enable/disable) so a timer IRQ can't context-switch into a second heap
// user mid-operation — the preemptive scheduler makes the heap shared
// between threads.
//
// Arena block format (16-byte aligned blocks, sizes are multiples of 16):
//   +0        header: blockSize | flags (bit 0 = allocated)
//   +8        allocated: back-pointer to block start (free() finds the block
//             even for over-aligned payloads); free: free-list prev
//   +16       payload (allocated) / free-list next (free)
//   size-8    footer: exact copy of the header word (boundary tag)
// A 16-byte allocated prologue at arenaStart and a zero-size allocated
// epilogue header at arenaEnd-16 bound coalescing at the arena edges.

enum KernelHeap {
    // Public region bounds (unchanged from the bump-allocator v1).
    static let heapStart: UInt = 0x4080_0000
    static let heapEnd:   UInt = 0x5000_0000

    // MARK: - Geometry

    static private let pageSize = 4096
    static private let pageCount = Int(heapEnd - heapStart) / pageSize         // 63,488
    static private let bitmapWords = pageCount / 64                            // 992
    static private let bitmapPages = (bitmapWords * 8 + pageSize - 1) / pageSize // 2
    static private let arenaPages = 16_384                                     // 64 MiB malloc arena
    static private let bitmapBase = heapStart
    static private let arenaStart = heapStart + UInt(bitmapPages * pageSize)
    static private let arenaEnd   = arenaStart + UInt(arenaPages * pageSize)
    static private let firstAllocPage = bitmapPages + arenaPages               // 16,386

    static private let flagAlloc: UInt64 = 1
    static private let sizeMask: UInt64 = ~UInt64(0xF)
    static private let minBlock = 32

    // MARK: - State (fixed storage; no runtime allocation anywhere below)

    static private var freeHead: UInt = 0   // malloc free-list head (0 = empty)
    static private var mallocLiveBytes = 0  // sum of live payload capacities
    static private var liveAllocPages = 0   // pages currently out via allocPages

    // MARK: - Raw memory helpers

    @inline(__always)
    static private func load64(_ addr: UInt) -> UInt64 {
        UnsafeMutablePointer<UInt64>(bitPattern: addr)!.pointee
    }

    @inline(__always)
    static private func store64(_ addr: UInt, _ value: UInt64) {
        UnsafeMutablePointer<UInt64>(bitPattern: addr)!.pointee = value
    }

    @inline(__always)
    static private func loadPtr(_ addr: UInt) -> UInt {
        UnsafeMutablePointer<UInt>(bitPattern: addr)!.pointee
    }

    @inline(__always)
    static private func storePtr(_ addr: UInt, _ value: UInt) {
        UnsafeMutablePointer<UInt>(bitPattern: addr)!.pointee = value
    }

    // MARK: - Bitmap helpers

    @inline(__always)
    static private func bitIsSet(_ page: Int) -> Bool {
        load64(bitmapBase + UInt((page >> 6) << 3)) & (UInt64(1) << UInt64(page & 63)) != 0
    }

    @inline(__always)
    static private func bitSet(_ page: Int) {
        let a = bitmapBase + UInt((page >> 6) << 3)
        store64(a, load64(a) | (UInt64(1) << UInt64(page & 63)))
    }

    @inline(__always)
    static private func bitClear(_ page: Int) {
        let a = bitmapBase + UInt((page >> 6) << 3)
        store64(a, load64(a) & ~(UInt64(1) << UInt64(page & 63)))
    }

    // MARK: - Init (runs before any allocation)

    static func initHeap() {
        // Bitmap: all pages free, then reserve bitmap + arena pages.
        var i = 0
        while i < bitmapWords {
            store64(bitmapBase + UInt(i << 3), 0)
            i += 1
        }
        i = 0
        while i < firstAllocPage {
            bitSet(i)
            i += 1
        }

        // Arena sentinels.
        store64(arenaStart, UInt64(16) | flagAlloc)      // prologue header
        store64(arenaStart + 8, UInt64(16) | flagAlloc)  // prologue footer
        store64(arenaEnd - 16, flagAlloc)                // epilogue header (size 0, allocated)
        store64(arenaEnd - 8, 0)

        // One free block spanning the whole arena.
        let fb = arenaStart + 16
        let fs = Int(arenaEnd - 16 - fb)
        writeFreeBlock(at: fb, size: fs)
        store64(fb + 8, 0)     // prev
        store64(fb + 16, 0)    // next
        freeHead = fb

        mallocLiveBytes = 0
        liveAllocPages = 0
    }

    // MARK: - malloc

    static func alloc(size: Int, alignment: Int) -> UnsafeMutableRawPointer? {
        let daif = armIrqSave()     // IRQ-atomic: see header comment
        defer { armIrqRestore(daif) }
        var align = alignment
        if align < 16 { align = 16 }
        if align > 1_048_576 { return nil }     // absurd alignment: refuse (overflow guard)
        if align & (align - 1) != 0 {           // round up to a power of two
            var p = 16
            while p < align { p <<= 1 }
            align = p
        }
        let sz = size > 0 ? size : 1
        let slack = align > 16 ? align : 0      // worst-case alignment padding
        guard sz <= Int.max - 24 - slack else { return nil }
        var need = (sz + 24 + slack + 15) & ~15
        if need < minBlock { need = minBlock }

        // First-fit over the free list.
        var cur = freeHead
        while cur != 0 {
            let h = load64(cur)
            let bsz = Int(h & sizeMask)
            if h & flagAlloc == 0, bsz >= need {
                return place(at: cur, blockSize: bsz, payloadSize: sz, alignment: align)
            }
            cur = loadPtr(cur + 16)
        }
        return nil
    }

    /// Carve an allocation out of free block `b` (size `bs`), honoring the
    /// payload alignment by splitting a front fragment when possible.
    static private func place(at b: UInt, blockSize bs: Int, payloadSize sz: Int, alignment align: Int) -> UnsafeMutableRawPointer {
        listRemove(b)
        let am = UInt(align) - 1
        let payloadTarget = (b + 16 + am) & ~am
        var allocStart = payloadTarget - 16
        var front = Int(allocStart - b)
        if front > 0, front < minBlock {
            allocStart = b                       // absorb sliver as internal padding
            front = 0
        }
        let remaining = bs - front
        let payloadOff = Int(payloadTarget - allocStart)
        var take = (payloadOff + sz + 8 + 15) & ~15
        if take < minBlock { take = minBlock }
        if remaining - take < minBlock { take = remaining }

        if front > 0 {
            writeFreeBlock(at: b, size: front)
        }
        let tail = remaining - take
        if tail > 0 {                            // tail >= minBlock here
            writeFreeBlock(at: allocStart + UInt(take), size: tail)
            listInsert(allocStart + UInt(take))
        }
        if front > 0 {
            listInsert(b)                        // head becomes the lower fragment
        }

        let hdr = UInt64(take) | flagAlloc
        store64(allocStart, hdr)
        store64(allocStart + UInt(take) - 8, hdr)
        storePtr(payloadTarget - 8, allocStart)  // back-pointer for free()
        mallocLiveBytes += take - payloadOff - 8 // payload capacity
        return UnsafeMutableRawPointer(bitPattern: payloadTarget)!
    }

    static func free(_ p: UnsafeMutableRawPointer?) {
        let daif = armIrqSave()     // IRQ-atomic: see header comment
        defer { armIrqRestore(daif) }
        guard let p else { return }
        let payload = UInt(bitPattern: p)
        let b = loadPtr(payload - 8)             // back-pointer to block start

        // Validate before trusting any tag.
        guard b >= arenaStart + 16, b < arenaEnd - 16, b & 0xF == 0 else {
            kpanic("heap: wild pointer in free")
        }
        let h = load64(b)
        let bsz = h & sizeMask
        guard bsz >= UInt64(minBlock), bsz <= UInt64(arenaEnd - 16 - b) else {
            kpanic("heap: corrupt block header")
        }
        guard load64(b + UInt(bsz) - 8) == h else {
            kpanic("heap: corrupt block footer")
        }
        guard h & flagAlloc != 0 else {
            kpanic("heap: double free")
        }

        mallocLiveBytes -= Int(b + UInt(bsz) - 8 - payload)

        var nb = b
        var ns = bsz
        // Coalesce with the next block (the epilogue reads as allocated).
        let na = b + UInt(bsz)
        let nh = load64(na)
        if nh & flagAlloc == 0 {
            listRemove(na)
            ns += nh & sizeMask
        }
        // Coalesce with the previous block (the prologue reads as allocated).
        let pf = load64(b - 8)
        if pf & flagAlloc == 0 {
            let psz = pf & sizeMask
            let pa = b - UInt(psz)
            listRemove(pa)
            nb = pa
            ns += psz
        }
        writeFreeBlock(at: nb, size: Int(ns))
        listInsert(nb)
    }

    // MARK: - Free-list plumbing (links live inside free blocks)

    static private func writeFreeBlock(at addr: UInt, size: Int) {
        let v = UInt64(size) & sizeMask
        store64(addr, v)
        store64(addr + UInt(size) - 8, v)
    }

    static private func listInsert(_ addr: UInt) {
        storePtr(addr + 8, 0)
        storePtr(addr + 16, freeHead)
        if freeHead != 0 { storePtr(freeHead + 8, addr) }
        freeHead = addr
    }

    static private func listRemove(_ addr: UInt) {
        let p = loadPtr(addr + 8)
        let n = loadPtr(addr + 16)
        if p != 0 { storePtr(p + 16, n) } else { freeHead = n }
        if n != 0 { storePtr(n + 8, p) }
    }

    // MARK: - Physical page allocator (4 KiB pages, first-fit contiguous)

    static func allocPages(_ count: Int) -> UInt? {
        let daif = armIrqSave()     // IRQ-atomic: see header comment
        defer { armIrqRestore(daif) }
        guard count > 0, count <= pageCount - firstAllocPage else { return nil }
        var i = firstAllocPage
        var run = 0
        var runStart = 0
        while i < pageCount {
            // Once the cursor passes the last feasible run start, give up.
            if i - run > pageCount - count { return nil }
            let word = load64(bitmapBase + UInt((i >> 6) << 3))
            if word == UInt64.max {              // whole word allocated: skip
                run = 0
                i = ((i >> 6) + 1) << 6
                continue
            }
            if word & (UInt64(1) << UInt64(i & 63)) == 0 {
                if run == 0 { runStart = i }
                run += 1
                if run == count {
                    var j = runStart
                    let end = runStart + count
                    while j < end {
                        bitSet(j)
                        j += 1
                    }
                    liveAllocPages += count
                    return heapStart + (UInt(runStart) << 12)
                }
            } else {
                run = 0
            }
            i += 1
        }
        return nil
    }

    static func freePages(_ base: UInt, count: Int) {
        let daif = armIrqSave()     // IRQ-atomic: see header comment
        defer { armIrqRestore(daif) }
        guard count > 0 else { return }
        guard base >= heapStart, base < heapEnd else {
            kpanic("heap: freePages out of region")
        }
        guard base & UInt(pageSize - 1) == 0 else {
            kpanic("heap: unaligned freePages")
        }
        let first = Int((base - heapStart) >> 12)
        guard first >= firstAllocPage, count <= pageCount - first else {
            kpanic("heap: freePages out of range")
        }
        var j = first
        let end = first + count
        while j < end {                          // validate first, then clear
            guard bitIsSet(j) else { kpanic("heap: page double free") }
            j += 1
        }
        j = first
        while j < end {
            bitClear(j)
            j += 1
        }
        liveAllocPages -= count
    }

    // MARK: - Stats

    static var totalBytes: Int { Int(heapEnd - heapStart) }

    /// Live malloc payload bytes + reserved page bytes (bitmap, arena,
    /// pages handed out via allocPages).
    static var usedBytes: Int {
        mallocLiveBytes + (bitmapPages + arenaPages + liveAllocPages) * pageSize
    }

    /// Pages allocPages can still hand out (arena/bitmap pages excluded).
    static var freePageCount: Int { pageCount - firstAllocPage - liveAllocPages }

    // MARK: - Self test

    /// Boot-time sanity check, callable from kmain after initHeap (log the
    /// result there; earliest is best, before subsystems consume the arena).
    /// Internally allocation-free and leaves the heap exactly as found.
    static func selfTest() -> Bool {
        let used0 = usedBytes
        let pages0 = freePageCount

        // Page allocator: alignment, non-overlap, accounting, restore.
        guard let pg1 = allocPages(1), let pg3 = allocPages(3) else { return false }
        if pg1 & 0xFFF != 0 || pg3 & 0xFFF != 0 { return false }
        if pg3 >= pg1, pg3 < pg1 + 4096 { return false }
        if freePageCount != pages0 - 4 { return false }
        store64(pg1, 0xDEAD_BEEF_0102_0304)
        store64(pg3 + 8192, 0x0F0E_0D0C_0B0A_0908)
        if load64(pg1) != 0xDEAD_BEEF_0102_0304 { return false }
        if load64(pg3 + 8192) != 0x0F0E_0D0C_0B0A_0908 { return false }
        freePages(pg1, count: 1)
        freePages(pg3, count: 3)
        if freePageCount != pages0 { return false }

        // Exhaustion: whole pool out, next request must fail, then restore.
        guard let everything = allocPages(pages0) else { return false }
        if allocPages(1) != nil { return false }
        if freePageCount != 0 { return false }
        freePages(everything, count: pages0)
        if freePageCount != pages0 { return false }

        // malloc: alignment guarantees, data integrity, accounting.
        guard let a = alloc(size: 24, alignment: 16),
              let b = alloc(size: 100, alignment: 16),
              let c = alloc(size: 1000, alignment: 64) else { return false }
        if UInt(bitPattern: a) & 0xF != 0 { return false }
        if UInt(bitPattern: b) & 0xF != 0 { return false }
        if UInt(bitPattern: c) & 0x3F != 0 { return false }
        var i = 0
        while i < 24 { a.storeBytes(of: 0xA5, toByteOffset: i, as: UInt8.self); i += 1 }
        i = 0
        while i < 100 { b.storeBytes(of: 0x5A, toByteOffset: i, as: UInt8.self); i += 1 }
        i = 0
        while i < 1000 { c.storeBytes(of: UInt8(i & 0xFF), toByteOffset: i, as: UInt8.self); i += 1 }
        i = 0
        while i < 24 { if a.load(fromByteOffset: i, as: UInt8.self) != 0xA5 { return false }; i += 1 }
        i = 0
        while i < 100 { if b.load(fromByteOffset: i, as: UInt8.self) != 0x5A { return false }; i += 1 }
        i = 0
        while i < 1000 { if c.load(fromByteOffset: i, as: UInt8.self) != UInt8(i & 0xFF) { return false }; i += 1 }
        if usedBytes <= used0 { return false }
        free(b)
        free(a)
        free(c)
        if usedBytes != used0 { return false }

        // Coalescing: two adjacent frees must merge into one free block
        // (verified through the boundary tags themselves).
        guard let x = alloc(size: 2000, alignment: 16),
              let y = alloc(size: 2000, alignment: 16) else { return false }
        let xb = loadPtr(UInt(bitPattern: x) - 8)
        let yb = loadPtr(UInt(bitPattern: y) - 8)
        let xbs = load64(xb) & sizeMask
        let ybs = load64(yb) & sizeMask
        let adjacent = xb + UInt(xbs) == yb
        free(x)
        free(y)
        if adjacent {
            let m = load64(xb)
            if m & flagAlloc != 0 { return false }        // merged block is free
            if m & sizeMask < xbs + ybs { return false }  // ... and spans both
        }
        guard let z = alloc(size: 3500, alignment: 16) else { return false }
        free(z)
        if usedBytes != used0 { return false }

        // Fragmentation: 64 small blocks, free every other, refill the holes,
        // free all. Live-byte accounting and free-list shape must be exact.
        guard let table = alloc(size: 64 * 8, alignment: 16) else { return false }
        var n = 0
        while n < 64 {
            guard let q = alloc(size: 48, alignment: 16) else { free(table); return false }
            table.storeBytes(of: UInt(bitPattern: q), toByteOffset: n * 8, as: UInt.self)
            n += 1
        }
        let usedAfterFill = usedBytes
        var nodesAfterFill = 0
        var cur = freeHead
        while cur != 0 {
            nodesAfterFill += 1
            cur = loadPtr(cur + 16)
        }
        n = 0
        while n < 64 {
            if n & 1 == 0 {
                free(UnsafeMutableRawPointer(bitPattern: table.load(fromByteOffset: n * 8, as: UInt.self)))
            }
            n += 1
        }
        n = 0
        while n < 64 {
            if n & 1 == 0 {
                guard let q = alloc(size: 48, alignment: 16) else { return false }
                table.storeBytes(of: UInt(bitPattern: q), toByteOffset: n * 8, as: UInt.self)
            }
            n += 1
        }
        // Refills must have landed in the freed holes exactly: same live
        // bytes, same number of free-list nodes as right after the fill.
        if usedBytes != usedAfterFill { return false }
        var nodes = 0
        cur = freeHead
        while cur != 0 {
            nodes += 1
            cur = loadPtr(cur + 16)
        }
        if nodes != nodesAfterFill { return false }
        n = 0
        while n < 64 {
            free(UnsafeMutableRawPointer(bitPattern: table.load(fromByteOffset: n * 8, as: UInt.self)))
            n += 1
        }
        free(table)
        if usedBytes != used0 { return false }
        if freePageCount != pages0 { return false }

        // The coalesced wilderness must still serve a multi-MiB allocation.
        guard let big = alloc(size: 4 * 1024 * 1024, alignment: 16) else { return false }
        free(big)
        if usedBytes != used0 { return false }
        return true
    }
}

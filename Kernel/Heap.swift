// Kernel heap: 4 KiB physical page allocator + kernel malloc heap.
//
// Managed region [heapStart, heapEnd) = 1 GiB, laid out as:
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
// only. Detected corruption (double free, wild pointer, broken tags) is
// reported on the serial console (one '[heap] ...' line) and the offending
// call is IGNORED: bad input must never corrupt the allocator. These
// diagnostics cannot use klog() — klog allocates via BootLog, which routes
// straight back into the heap being reported on — so they are literal-only
// UART writes plus the fixed counters below.
//
// Every public entry point (alloc/free/allocPages/freePages) is IRQ-atomic:
// wrapped in armIrqSave/armIrqRestore (nesting-safe, unlike raw
// enable/disable) so a timer IRQ can't context-switch into a second heap
// user mid-operation — the preemptive scheduler makes the heap shared
// between threads.
//
// Arena block format (16-byte aligned blocks, sizes are multiples of 16):
//   +0        header: (magic << 32) | blockSize | flags (bit 0 = allocated)
//   +8        allocated: back-pointer to block start (free() finds the block
//             even for over-aligned payloads); free: free-list prev
//   +16       payload (allocated) / free-list next (free)
//   size-8    footer: exact copy of the header word (boundary tag)
// magic is 0xA110CA7E for allocated blocks and 0xFEE1DEAD for free ones;
// since the footer mirrors it, free() and validate() can tell live, freed,
// and corrupt blocks apart before trusting any size or link. A 16-byte
// allocated prologue at arenaStart and a zero-size allocated epilogue header
// at arenaEnd-16 bound coalescing at the arena edges.

enum KernelHeap {
    // Public region bounds (unchanged from the bump-allocator v1).
    static let heapStart: UInt = 0x4080_0000
    static let heapEnd:   UInt = 0x8080_0000

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

    // Header/footer word: top 32 bits = integrity magic, low 32 = size|flags
    // (arena blocks are < 64 MiB, so the size never reaches the magic).
    static private let magicAlloc: UInt64 = 0xA110_CA7E
    static private let magicFreed: UInt64 = 0xFEE1_DEAD
    static private let flagAlloc: UInt64 = 1
    static private let sizeMask: UInt64 = 0xFFFF_FFF0
    static private let minBlock = 32

    // MARK: - State (fixed storage; no runtime allocation anywhere below)

    static private var freeHead: UInt = 0   // malloc free-list head (0 = empty)
    static private var mallocLiveBytes = 0  // sum of live payload capacities
    static private var liveAllocPages = 0   // pages currently out via allocPages
    static private var initialized = false
    static private var oomLogged = false       // one-shot OUT OF MEMORY report
    static private var highWaterLogged = false // one-shot 90% arena notice

    /// Allocations refused since boot (arena OOM, absurd requests, page OOM).
    static private(set) var allocFailCount = 0
    /// free()/freePages() calls rejected (wild, double, corrupt) plus
    /// corrupt neighbors skipped during coalescing.
    static private(set) var badFreeCount = 0

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

    // MARK: - Allocation-free diagnostics
    //
    // klog()/BootLog allocate, so heap trouble reports go straight to the
    // UART using string literals and these two formatters. Safe from OOM
    // paths, IRQ-off sections, and half-broken heap states.

    /// Hex, `0x` + 16 digits.
    static private func hhex(_ v: UInt64) {
        UART.write("0x")
        var shift = 60
        while shift >= 0 {
            let nib = Int((v >> UInt64(shift)) & 0xF)
            UART.putc(UInt8(nib < 10 ? 48 + nib : 87 + nib))  // 0-9, a-f
            shift -= 4
        }
    }

    /// Decimal.
    static private func hdec(_ v: Int) {
        if v < 0 { UART.putc(45); hdec(0 &- v); return }
        if v >= 10 { hdec(v / 10) }
        UART.putc(UInt8(48 + v % 10))
    }

    /// A free() argument failed validation: report it, never touch the heap.
    static private func badFree(_ payload: UInt) {
        badFreeCount += 1
        UART.write("[heap] bad free ")
        hhex(UInt64(payload))
        UART.write("\n")
    }

    /// A freePages() argument failed validation: report it, bitmap untouched.
    static private func badFreePages(_ base: UInt) {
        badFreeCount += 1
        UART.write("[heap] bad freePages ")
        hhex(UInt64(base))
        UART.write("\n")
    }

    /// A coalescing neighbor claimed to be free but its tags disagreed.
    static private func badNeighbor(_ addr: UInt) {
        badFreeCount += 1
        UART.write("[heap] bad neighbor ")
        hhex(UInt64(addr))
        UART.write("\n")
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
        guard !initialized else {
            // A second init would orphan every live allocation — refuse.
            UART.write("[heap] initHeap ignored (already initialized)\n")
            return
        }
        initialized = true

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

        // Arena sentinels (allocated, magic-tagged).
        let prologue = (magicAlloc << 32) | UInt64(16) | flagAlloc
        store64(arenaStart, prologue)                // prologue header
        store64(arenaStart + 8, prologue)            // prologue footer
        store64(arenaEnd - 16, (magicAlloc << 32) | flagAlloc)  // epilogue header
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
        if align > 1_048_576 { allocFailCount += 1; return nil } // absurd alignment: refuse (overflow guard)
        if align & (align - 1) != 0 {           // round up to a power of two
            var p = 16
            while p < align { p <<= 1 }
            align = p
        }
        let sz = size > 0 ? size : 1
        let slack = align > 16 ? align : 0      // worst-case alignment padding
        guard sz <= Int.max - 24 - slack else { allocFailCount += 1; return nil }
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
        allocFailCount += 1                       // arena exhausted (or too fragmented)
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

        let hdr = (magicAlloc << 32) | UInt64(take) | flagAlloc
        store64(allocStart, hdr)
        store64(allocStart + UInt(take) - 8, hdr)
        storePtr(payloadTarget - 8, allocStart)  // back-pointer for free()
        mallocLiveBytes += take - payloadOff - 8 // payload capacity

        // One-shot high-water notice: arena usage first crossing 90%.
        let capacity = Int(arenaEnd - arenaStart)
        if !highWaterLogged, mallocLiveBytes * 100 >= capacity * 90 {
            highWaterLogged = true
            UART.write("[heap] arena usage crossed 90% (used=")
            hdec(mallocLiveBytes)
            UART.write(" free=")
            hdec(capacity - mallocLiveBytes)
            UART.write(")\n")
        }
        return UnsafeMutableRawPointer(bitPattern: payloadTarget)!
    }

    static func free(_ p: UnsafeMutableRawPointer?) {
        let daif = armIrqSave()     // IRQ-atomic: see header comment
        defer { armIrqRestore(daif) }
        guard let p else { return }
        let payload = UInt(bitPattern: p)

        // Validate magic + arena bounds + alignment BEFORE trusting any tag
        // or link. Every failure mode — wild pointer, double free, corrupted
        // header — is reported once and ignored; the allocator's own
        // structures stay untouched.
        guard payload & 0xF == 0, payload >= arenaStart + 32, payload < arenaEnd - 16 else {
            badFree(payload); return
        }
        let b = loadPtr(payload - 8)             // back-pointer to block start
        guard b >= arenaStart + 16, b < arenaEnd - 16, b & 0xF == 0 else {
            badFree(payload); return
        }
        let h = load64(b)
        guard h >> 32 == magicAlloc, h & flagAlloc != 0 else {
            badFree(payload); return   // magicFreed = double free; else corrupt
        }
        let bsz = h & sizeMask
        guard bsz >= UInt64(minBlock), bsz <= UInt64(arenaEnd - 16 - b) else {
            badFree(payload); return
        }
        guard load64(b + UInt(bsz) - 8) == h else {
            badFree(payload); return
        }

        mallocLiveBytes -= Int(b + UInt(bsz) - 8 - payload)

        var nb = b
        var ns = bsz
        // Coalesce with the next block (the epilogue reads as allocated).
        // A neighbor claiming to be free must prove it with intact tags —
        // coalescing a corrupt "free" block would import its broken links
        // into the free list; skip it instead (validate() will flag it).
        let na = b + UInt(bsz)
        let nh = load64(na)
        if nh & flagAlloc == 0 {
            if neighborIsIntactFreeBlock(at: na, header: nh) {
                listRemove(na)
                ns += nh & sizeMask
            } else {
                badNeighbor(na)
            }
        }
        // Coalesce with the previous block (the prologue reads as allocated).
        let pf = load64(b - 8)
        if pf & flagAlloc == 0 {
            let psz = pf & sizeMask
            if psz >= UInt64(minBlock), psz <= UInt64(b - (arenaStart + 16)) {
                let pa = b - UInt(psz)
                if load64(pa) == pf, neighborIsIntactFreeBlock(at: pa, header: pf) {
                    listRemove(pa)
                    nb = pa
                    ns += psz
                } else {
                    badNeighbor(pa)
                }
            } else {
                badNeighbor(b - 8)
            }
        }
        writeFreeBlock(at: nb, size: Int(ns))
        listInsert(nb)
    }

    /// A block that claims to be free must carry the freed magic, a sane
    /// size, and a footer that exactly mirrors its header.
    static private func neighborIsIntactFreeBlock(at addr: UInt, header h: UInt64) -> Bool {
        guard h >> 32 == magicFreed, h & flagAlloc == 0 else { return false }
        let bsz = h & sizeMask
        guard bsz >= UInt64(minBlock), bsz <= UInt64(arenaEnd - 16 - addr) else { return false }
        return load64(addr + UInt(bsz) - 8) == h
    }

    // MARK: - Free-list plumbing (links live inside free blocks)

    static private func writeFreeBlock(at addr: UInt, size: Int) {
        let v = (magicFreed << 32) | (UInt64(size) & sizeMask)
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
        guard count > 0, count <= pageCount - firstAllocPage else {
            allocFailCount += 1
            return nil
        }
        var i = firstAllocPage
        var run = 0
        var runStart = 0
        while i < pageCount {
            // Once the cursor passes the last feasible run start, give up.
            if i - run > pageCount - count { allocFailCount += 1; return nil }
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
        allocFailCount += 1
        return nil
    }

    static func freePages(_ base: UInt, count: Int) {
        let daif = armIrqSave()     // IRQ-atomic: see header comment
        defer { armIrqRestore(daif) }
        guard count > 0 else { return }
        // Validate the whole range before touching a single bit: a bad
        // freePages (out of region, unaligned, into the reserved arena/bitmap
        // pages, or double) is reported and ignored, never half-applied.
        guard base >= heapStart, base < heapEnd, base & UInt(pageSize - 1) == 0 else {
            badFreePages(base); return
        }
        let first = Int((base - heapStart) >> 12)
        guard first >= firstAllocPage, count <= pageCount - first else {
            badFreePages(base); return
        }
        var j = first
        let end = first + count
        while j < end {
            guard bitIsSet(j) else {             // already free: double free
                badFreePages(base); return
            }
            j += 1
        }
        j = first
        while j < end {
            bitClear(j)
            j += 1
        }
        liveAllocPages -= count
    }

    // MARK: - OOM reporting (called from the posix_memalign shim)

    /// Reports malloc exhaustion once per boot; later failures stay silent
    /// (allocFailCount keeps counting). Allocation-free by design — this runs
    /// precisely when the arena cannot serve another byte.
    static func noteOutOfMemory() {
        let daif = armIrqSave()
        defer { armIrqRestore(daif) }
        guard !oomLogged else { return }
        oomLogged = true
        UART.write("[heap] OUT OF MEMORY (used=")
        hdec(mallocLiveBytes)
        UART.write(" free=")
        hdec(Int(arenaEnd - arenaStart) - mallocLiveBytes)
        UART.write(")\n")
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

    // MARK: - Deep validation

    /// Allocation-free audit of the whole heap, callable any time after
    /// initHeap (e.g. from kworker every ~10 s). Walks the page bitmap and
    /// every arena block, then the free list, cross-checking magics, sizes,
    /// boundary tags, links, and counters. Returns false and logs the first
    /// inconsistency found (serial only — the heap may be the thing that is
    /// broken, so this never allocates). O(pages + arena blocks).
    static func validate() -> Bool {
        let daif = armIrqSave()
        defer { armIrqRestore(daif) }
        guard initialized else {
            UART.write("[heap] validate: not initialized\n")
            return false
        }

        // 1. Page bitmap: the reserved pages (bitmap + arena) must all be
        //    marked, and marks in the allocatable pool must equal
        //    liveAllocPages exactly. The bitmap covers the region precisely
        //    (992 words * 64 = 63,488 pages), so there are no tail bits that
        //    could carry stray marks outside it.
        var page = 0
        while page < firstAllocPage {
            guard bitIsSet(page) else {
                vlogFail("reserved page clear", UInt(page)); return false
            }
            page += 1
        }
        var marked = 0
        while page < pageCount {
            if bitIsSet(page) { marked += 1 }
            page += 1
        }
        guard marked == liveAllocPages else {
            vlogFail("page accounting mismatch, marked =", UInt(marked)); return false
        }

        // 2. Arena walk from arenaStart: valid magic, flag/magic agreement,
        //    sane size, footer == header, forward landings exact (the walk
        //    must end precisely on the epilogue), no uncoalesced free pairs.
        var cur = arenaStart
        var freeBlocks = 0
        var prevFree = false
        var liveBlockBytes = 0
        while cur < arenaEnd - 16 {
            let h = load64(cur)
            let magic = h >> 32
            guard magic == magicAlloc || magic == magicFreed else {
                vlogFail("bad block magic at", cur); return false
            }
            let isAlloc = h & flagAlloc != 0
            guard isAlloc == (magic == magicAlloc) else {
                vlogFail("magic/flag disagree at", cur); return false
            }
            let bsz = Int(h & sizeMask)
            guard bsz >= 16, bsz & 0xF == 0, cur + UInt(bsz) <= arenaEnd - 16 else {
                vlogFail("bad block size at", cur); return false
            }
            guard load64(cur + UInt(bsz) - 8) == h else {
                vlogFail("footer mismatch at", cur); return false
            }
            if isAlloc {
                liveBlockBytes += bsz
                prevFree = false
            } else {
                guard !prevFree else {
                    vlogFail("uncoalesced free pair at", cur); return false
                }
                freeBlocks += 1
                prevFree = true
            }
            cur += UInt(bsz)
        }
        guard cur == arenaEnd - 16 else {
            vlogFail("arena walk landed at", cur); return false
        }
        guard load64(arenaEnd - 16) == (magicAlloc << 32) | flagAlloc else {
            vlogFail("bad epilogue at", arenaEnd - 16); return false
        }
        guard mallocLiveBytes >= 0, mallocLiveBytes <= liveBlockBytes else {
            vlogFail("live-byte accounting off, mallocLiveBytes =", UInt(bitPattern: mallocLiveBytes)); return false
        }

        // 3. Free list: nodes inside the arena, tagged free in their boundary
        //    tags, prev/next consistent, acyclic (bounded walk), and covering
        //    exactly the free blocks the arena walk counted.
        var node = freeHead
        var prevNode: UInt = 0
        var nodes = 0
        let maxNodes = Int(arenaEnd - arenaStart) / 16
        while node != 0 {
            guard nodes < maxNodes else {
                vlogFail("free-list cycle at", node); return false
            }
            guard node >= arenaStart + 16, node < arenaEnd - 16, node & 0xF == 0 else {
                vlogFail("free-list node outside arena:", node); return false
            }
            let h = load64(node)
            guard h >> 32 == magicFreed, h & flagAlloc == 0 else {
                vlogFail("free-list node not free at", node); return false
            }
            guard loadPtr(node + 8) == prevNode else {
                vlogFail("free-list prev link broken at", node); return false
            }
            let next = loadPtr(node + 16)
            if next != 0 {
                guard next >= arenaStart + 16, next < arenaEnd - 16, next & 0xF == 0 else {
                    vlogFail("free-list next points to", next); return false
                }
            }
            prevNode = node
            node = next
            nodes += 1
        }
        guard nodes == freeBlocks else {
            vlogFail("free-list count mismatch, nodes =", UInt(nodes)); return false
        }
        return true
    }

    /// One validate() finding: what, and the address/count involved.
    static private func vlogFail(_ what: String, _ at: UInt) {
        UART.write("[heap] validate: ")
        UART.write(what)
        UART.write(" ")
        hhex(UInt64(at))
        UART.write("\n")
    }

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

        // The deep audit must agree the heap is still pristine.
        if !validate() { return false }
        return true
    }
}

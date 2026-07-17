// SwiftFS — our own trivial persistent filesystem, on top of BlockDev.
//
// Disk layout (512-byte sectors, all integers little-endian):
//
//   sector 0          superblock:
//                       +0  magic[8] = "SWFS0001"
//                       +8  totalSectors u64
//                       +16 inodeCount u32       (256)
//                       +20 inodeTableStart u32  (sector 1)
//                       +24 inodeTableSectors u32 (32)
//                       +28 bitmapStart u32
//                       +32 bitmapSectors u32
//                       +36 dataStart u32        (first data sector)
//                       +40 blockSizeSectors u32 (8 = 4 KiB blocks)
//                       +44 reserved u32
//   1 ..< 33          inode table: 256 inodes x 64 bytes:
//                       +0  name[44]   UTF-8, zero-padded (truncated at a
//                                     scalar boundary when longer)
//                       +44 type u8    (0 free, 1 file, 2 dir)
//                       +45 parent u8  (parent inode; root's parent is 0)
//                       +46 flags u16  (bit 0: executable — restores -rwxr-xr-x)
//                       +48 size u32
//                       +52 firstBlock u32 (block index relative to dataStart)
//                       +56 blockCount u32 (allocated span length, >= size)
//                       +60 mtime u32  (SECONDS since 2024-01-01 00:00:00 UTC —
//                                     ~136 years of range. The VFS converts
//                                     to/from wall-clock ms at the boundary.
//                                     Images written before this change hold
//                                     truncated wall-clock ms here, so
//                                     pre-existing files show odd dates until
//                                     rewritten; magic deliberately unchanged.)
//   bitmapStart ..    free bitmap, 1 bit per data block (1 = used)
//   dataStart ..      data blocks, 8 sectors (4 KiB) each
//
// Design (per spec): directories have no data blocks — membership is encoded
// by the inode's parent link, so listing a directory is a scan of the inode
// table. Files are a single contiguous span; allocation is first-fit over the
// bitmap. Writes that fit the current span go in place; growth allocates a
// fresh contiguous span, writes it, then frees the old one (grow-only — a
// span never moves unless it has to). Every metadata mutation flushes its
// sector(s) immediately (write-through); there is no journal, so an unlucky
// power cut can lose the last write — acceptable for a demo OS.
//
// The whole inode table (16 KiB) and bitmap (<= a few KiB) are cached in RAM
// (plain Swift arrays — SwiftFS is a client of the heap, never underneath it).

/// Snapshot of one on-disk inode, as handed to the VFS for hydration.
struct SFInode {
    let index: Int
    let name: String
    let isDirectory: Bool
    let parent: Int
    let size: Int
    let mtimeSecs: UInt64   // seconds since 2024-01-01 UTC, zero-extended u32
    let executable: Bool
}

enum SwiftFS {
    static private(set) var isMounted = false

    // Geometry (filled in by mount()/format()).
    private static var totalSectors: UInt64 = 0
    private static var bitmapStart: UInt32 = 0
    private static var bitmapSectors: UInt32 = 0
    private static var dataStart: UInt32 = 0
    private static var dataBlocks: Int = 0

    // Constants of the format.
    private static let inodeCount = 256
    private static let inodeSize = 64
    private static let inodeTableStart: UInt32 = 1
    private static let inodeTableSectors: UInt32 = UInt32(inodeCount * inodeSize / 512) // 32
    private static let blockSectors = 8
    private static let blockBytes = blockSectors * 512   // 4096
    private static let nameMax = 44

    // Inode field offsets within an inode.
    private static let oName = 0, oType = 44, oParent = 45, oFlags = 46
    private static let oSize = 48, oFirst = 52, oCount = 56, oMtime = 60

    // Inode types.
    private static let tFree: UInt8 = 0, tFile: UInt8 = 1, tDir: UInt8 = 2

    // RAM caches, loaded by mount()/format() and kept write-through.
    private static var inodeTable = [UInt8]()
    private static var bitmap = [UInt8]()

    // MARK: - Mount / format

    /// Reads and validates the superblock, loading the inode table and free
    /// bitmap. Returns false on any inconsistency (blank or foreign disk).
    static func mount() -> Bool {
        isMounted = false
        guard let sb = readSectors(0, 1) else { return false }
        let magic: [UInt8] = [0x53, 0x57, 0x46, 0x53, 0x30, 0x30, 0x30, 0x31] // "SWFS0001"
        for i in 0..<8 where sb[i] != magic[i] { return false }

        let total = getU64(sb, 8)
        let inodes = Int(getU32(sb, 16))
        let itStart = getU32(sb, 20)
        let itSectors = getU32(sb, 24)
        let bmStart = getU32(sb, 28)
        let bmSectors = getU32(sb, 32)
        let dStart = getU32(sb, 36)
        let blkSectors = Int(getU32(sb, 40))

        guard inodes == inodeCount, blkSectors == blockSectors,
              itStart == inodeTableStart, itSectors == inodeTableSectors,
              bmStart == inodeTableStart + inodeTableSectors, bmSectors >= 1,
              dStart == bmStart + bmSectors,
              UInt64(dStart) < total, total <= BlockDev.blockCount else {
            klog("[fs] superblock failed sanity checks — not mounting")
            return false
        }

        totalSectors = total
        bitmapStart = bmStart
        bitmapSectors = bmSectors
        dataStart = dStart
        dataBlocks = Int(total - UInt64(dStart)) / blockSectors
        guard bitmapSectors >= UInt32((dataBlocks + 4095) / 4096) else {
            klog("[fs] bitmap too small for data area — not mounting")
            return false
        }

        guard let table = readSectors(UInt64(itStart), Int(itSectors)),
              let bm = readSectors(UInt64(bmStart), Int(bmSectors)) else {
            return false
        }
        guard table[0 + oType] == tDir else {
            klog("[fs] no root directory — not mounting")
            return false
        }
        inodeTable = table
        bitmap = bm
        isMounted = true
        klog("[fs] mounted: \(total) sectors, \(dataBlocks) data blocks, \(inodeCount) inodes")
        return true
    }

    /// Lays out a fresh filesystem over the whole disk and creates the root
    /// directory (inode 0). Returns false if the disk is implausibly small.
    static func format() -> Bool {
        isMounted = false
        let total = BlockDev.blockCount
        guard total >= 128 else {
            klog("[fs] disk too small to format (\(total) sectors)")
            return false
        }

        // bitmapSectors and dataStart depend on each other; iterate to a fixpoint.
        var bmSectors: UInt32 = 1
        while true {
            let dStart = inodeTableStart + inodeTableSectors + bmSectors
            let blocks = Int(total - UInt64(dStart)) / blockSectors
            let need = UInt32((blocks + 8 * 512 - 1) / (8 * 512))
            if need <= bmSectors { break }
            bmSectors = need
        }
        let dStart = inodeTableStart + inodeTableSectors + bmSectors
        let blocks = Int(total - UInt64(dStart)) / blockSectors

        var sb = [UInt8](repeating: 0, count: 512)
        let magic: [UInt8] = [0x53, 0x57, 0x46, 0x53, 0x30, 0x30, 0x30, 0x31]
        for i in 0..<8 { sb[i] = magic[i] }
        setU64(&sb, 8, total)
        setU32(&sb, 16, UInt32(inodeCount))
        setU32(&sb, 20, inodeTableStart)
        setU32(&sb, 24, inodeTableSectors)
        setU32(&sb, 28, inodeTableStart + inodeTableSectors)
        setU32(&sb, 32, bmSectors)
        setU32(&sb, 36, dStart)
        setU32(&sb, 40, UInt32(blockSectors))
        guard writeSectors(0, 1, sb) else { return false }

        totalSectors = total
        bitmapStart = inodeTableStart + inodeTableSectors
        bitmapSectors = bmSectors
        dataStart = dStart
        dataBlocks = blocks
        inodeTable = [UInt8](repeating: 0, count: inodeCount * inodeSize)
        bitmap = [UInt8](repeating: 0, count: Int(bmSectors) * 512)
        guard flushInodeTable(), flushBitmap(bits: 0..<dataBlocks) else { return false }

        // Inode 0: the root directory.
        encodeName("/", into: 0)
        inodeTable[oType] = tDir
        inodeTable[oParent] = 0
        guard flushInode(0) else { return false }

        isMounted = true
        klog("[fs] formatted: \(total) sectors, \(blocks) data blocks")
        return true
    }

    // MARK: - Inode queries

    /// Snapshots of every live inode, ordered by index (root first).
    static func dumpInodes() -> [SFInode] {
        guard isMounted else { return [] }
        var out: [SFInode] = []
        var i = 0
        while i < inodeCount {
            let t = inodeTable[i * inodeSize + oType]
            if t != tFree {
                out.append(SFInode(index: i,
                                   name: decodeName(i),
                                   isDirectory: t == tDir,
                                   parent: Int(inodeTable[i * inodeSize + oParent]),
                                   size: Int(getU32(inodeTable, i * inodeSize + oSize)),
                                   mtimeSecs: UInt64(getU32(inodeTable, i * inodeSize + oMtime)),
                                   executable: getU16(inodeTable, i * inodeSize + oFlags) & 1 != 0))
            }
            i += 1
        }
        return out
    }

    // MARK: - File data

    /// Reads a file's contents (its size prefix of the allocated span).
    static func readFile(_ index: Int) -> [UInt8]? {
        guard isMounted, index > 0, index < inodeCount else { return nil }
        let b = index * inodeSize
        guard inodeTable[b + oType] == tFile else { return nil }
        let size = Int(getU32(inodeTable, b + oSize))
        let count = Int(getU32(inodeTable, b + oCount))
        guard size > 0, count > 0 else { return [] }
        let first = Int(getU32(inodeTable, b + oFirst))
        guard var buf = readSectors(sectorOf(block: first), count * blockSectors) else {
            return nil
        }
        if buf.count > size { buf.removeLast(buf.count - size) }
        return buf
    }

    /// Writes a file's full contents. Fits go into the existing span in
    /// place; growth allocates a new contiguous span and frees the old one.
    /// `mtime` is seconds since 2024-01-01 UTC (the VFS converts wall-clock
    /// ms at the boundary); it is stored truncated to u32 on disk.
    static func writeFile(_ index: Int, _ data: [UInt8], mtime: UInt64) -> Bool {
        guard isMounted, index > 0, index < inodeCount else { return false }
        let b = index * inodeSize
        guard inodeTable[b + oType] == tFile else { return false }
        let needed = (data.count + blockBytes - 1) / blockBytes
        let curFirst = Int(getU32(inodeTable, b + oFirst))
        let curCount = Int(getU32(inodeTable, b + oCount))

        if needed <= curCount {
            if needed > 0 {
                var buf = [UInt8](repeating: 0, count: needed * blockBytes)
                var i = 0
                while i < data.count { buf[i] = data[i]; i += 1 }
                guard writeSectors(sectorOf(block: curFirst), needed * blockSectors, buf) else {
                    return false
                }
            }
        } else {
            guard let span = allocBlocks(needed) else {
                klog("[fs] out of space: need \(needed) blocks, wrote nothing")
                return false
            }
            var buf = [UInt8](repeating: 0, count: needed * blockBytes)
            var i = 0
            while i < data.count { buf[i] = data[i]; i += 1 }
            guard writeSectors(sectorOf(block: span), needed * blockSectors, buf) else {
                freeBlocks(span, needed)
                return false
            }
            if curCount > 0 { freeBlocks(curFirst, curCount) }
            setU32(&inodeTable, b + oFirst, UInt32(span))
            setU32(&inodeTable, b + oCount, UInt32(needed))
        }
        setU32(&inodeTable, b + oSize, UInt32(data.count))
        setU32(&inodeTable, b + oMtime, UInt32(mtime & 0xFFFF_FFFF))
        return flushInode(index)
    }

    // MARK: - Inode create / remove

    /// Allocates and initializes an inode. Returns its index, or nil when the
    /// table is full or the name does not fit/encodes to nothing.
    /// `mtime` is seconds since 2024-01-01 UTC (see writeFile).
    static func create(name: String, parent: Int, isDirectory: Bool,
                       executable: Bool, mtime: UInt64) -> Int? {
        guard isMounted, parent >= 0, parent < inodeCount else { return nil }
        var idx = 1   // inode 0 is the root
        while idx < inodeCount {
            if inodeTable[idx * inodeSize + oType] == tFree { break }
            idx += 1
        }
        guard idx < inodeCount else {
            klog("[fs] inode table full (\(inodeCount) inodes)")
            return nil
        }
        let b = idx * inodeSize
        var i = 0
        while i < inodeSize { inodeTable[b + i] = 0; i += 1 }
        guard encodeName(name, into: idx) else { return nil }
        inodeTable[b + oType] = isDirectory ? tDir : tFile
        inodeTable[b + oParent] = UInt8(parent)
        setU16(&inodeTable, b + oFlags, executable ? 1 : 0)
        setU32(&inodeTable, b + oMtime, UInt32(mtime & 0xFFFF_FFFF))
        guard flushInode(idx) else { return nil }
        return idx
    }

    /// Frees an inode and its data span. The root can never be removed; the
    /// VFS guarantees directories are empty before this is called.
    static func remove(_ index: Int) -> Bool {
        guard isMounted, index > 0, index < inodeCount else { return false }
        let b = index * inodeSize
        guard inodeTable[b + oType] != tFree else { return true }
        let first = Int(getU32(inodeTable, b + oFirst))
        let count = Int(getU32(inodeTable, b + oCount))
        if count > 0 { freeBlocks(first, count) }
        var i = 0
        while i < inodeSize { inodeTable[b + i] = 0; i += 1 }
        return flushInode(index)
    }

    /// Renames and/or reparents a live inode: rewrites the 44-byte name field
    /// and the parent link in place, then flushes the inode's sector. Data
    /// blocks, size, flags and mtime are untouched (POSIX rename preserves
    /// mtimes). The root (inode 0) can never be renamed. Names longer than
    /// 44 bytes truncate at a scalar boundary, exactly like create(); an
    /// empty name is rejected (every non-empty name encodes to >= 1 byte, so
    /// this fully covers encodeName's failure mode before we clobber the old
    /// name in the RAM cache).
    static func rename(_ index: Int, name: String, parent: Int) -> Bool {
        guard isMounted, index > 0, index < inodeCount,
              parent >= 0, parent < inodeCount, !name.isEmpty else { return false }
        let b = index * inodeSize
        guard inodeTable[b + oType] != tFree else { return false }
        var i = 0
        while i < nameMax { inodeTable[b + oName + i] = 0; i += 1 }
        guard encodeName(name, into: index) else { return false }
        inodeTable[b + oParent] = UInt8(parent)
        return flushInode(index)
    }

    // MARK: - Block allocation (first-fit, contiguous)

    private static func allocBlocks(_ count: Int) -> Int? {
        var run = 0, start = 0, blk = 0
        while blk < dataBlocks {
            if !bitTest(blk) {
                if run == 0 { start = blk }
                run += 1
                if run == count {
                    var j = start
                    while j < start + count { bitSet(j); j += 1 }
                    guard flushBitmap(bits: start..<(start + count)) else { return nil }
                    return start
                }
            } else {
                run = 0
            }
            blk += 1
        }
        return nil
    }

    private static func freeBlocks(_ first: Int, _ count: Int) {
        guard first >= 0, count > 0, first + count <= dataBlocks else { return }
        var j = first
        while j < first + count { bitClear(j); j += 1 }
        _ = flushBitmap(bits: first..<(first + count))
    }

    // MARK: - Bitmap helpers

    private static func bitTest(_ blk: Int) -> Bool {
        bitmap[blk / 8] & (UInt8(1) << UInt8(blk % 8)) != 0
    }

    private static func bitSet(_ blk: Int) {
        bitmap[blk / 8] |= UInt8(1) << UInt8(blk % 8)
    }

    private static func bitClear(_ blk: Int) {
        bitmap[blk / 8] &= ~(UInt8(1) << UInt8(blk % 8))
    }

    /// Writes every bitmap sector touched by the given bit range.
    private static func flushBitmap(bits range: Range<Int>) -> Bool {
        guard bitmapSectors > 0 else { return true }
        let firstByte = max(range.lowerBound / 8, 0)
        var lastByte = (max(range.upperBound - 1, range.lowerBound)) / 8
        if lastByte >= bitmap.count { lastByte = bitmap.count - 1 }
        guard firstByte <= lastByte else { return true }
        let firstSector = firstByte / 512
        let lastSector = lastByte / 512
        var ok = true
        bitmap.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { ok = false; return }
            var s = firstSector
            while s <= lastSector {
                if !BlockDev.writeBlocks(UInt64(bitmapStart) + UInt64(s), 1,
                                         from: base.advanced(by: s * 512)) {
                    ok = false
                    return
                }
                s += 1
            }
        }
        if !ok { klog("[fs] bitmap flush failed") }
        return ok
    }

    // MARK: - Inode table flushing

    /// Rewrites the single sector holding inode `index` from the RAM cache.
    private static func flushInode(_ index: Int) -> Bool {
        let sectorInTable = (index * inodeSize) / 512
        var ok = true
        inodeTable.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { ok = false; return }
            ok = BlockDev.writeBlocks(UInt64(inodeTableStart) + UInt64(sectorInTable), 1,
                                      from: base.advanced(by: sectorInTable * 512))
        }
        if !ok { klog("[fs] inode flush failed (inode \(index))") }
        return ok
    }

    private static func flushInodeTable() -> Bool {
        var ok = true
        inodeTable.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { ok = false; return }
            ok = BlockDev.writeBlocks(UInt64(inodeTableStart), UInt32(inodeTableSectors),
                                      from: base)
        }
        return ok
    }

    // MARK: - Sector I/O helpers

    private static func sectorOf(block: Int) -> UInt64 {
        UInt64(dataStart) + UInt64(block * blockSectors)
    }

    private static func readSectors(_ lba: UInt64, _ count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count * 512)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            return BlockDev.readBlocks(lba, UInt32(count), into: base)
        }
        return ok ? buf : nil
    }

    private static func writeSectors(_ lba: UInt64, _ count: Int, _ buf: [UInt8]) -> Bool {
        buf.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            return BlockDev.writeBlocks(lba, UInt32(count), from: base)
        }
    }

    // MARK: - Inode field codecs (little-endian)

    private static func getU16(_ buf: [UInt8], _ off: Int) -> UInt16 {
        UInt16(buf[off]) | UInt16(buf[off + 1]) << 8
    }

    private static func getU32(_ buf: [UInt8], _ off: Int) -> UInt32 {
        UInt32(buf[off]) | UInt32(buf[off + 1]) << 8 |
            UInt32(buf[off + 2]) << 16 | UInt32(buf[off + 3]) << 24
    }

    private static func getU64(_ buf: [UInt8], _ off: Int) -> UInt64 {
        UInt64(getU32(buf, off)) | UInt64(getU32(buf, off + 4)) << 32
    }

    private static func setU16(_ buf: inout [UInt8], _ off: Int, _ v: UInt16) {
        buf[off] = UInt8(v & 0xFF)
        buf[off + 1] = UInt8((v >> 8) & 0xFF)
    }

    private static func setU32(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {
        buf[off] = UInt8(v & 0xFF)
        buf[off + 1] = UInt8((v >> 8) & 0xFF)
        buf[off + 2] = UInt8((v >> 16) & 0xFF)
        buf[off + 3] = UInt8((v >> 24) & 0xFF)
    }

    private static func setU64(_ buf: inout [UInt8], _ off: Int, _ v: UInt64) {
        setU32(&buf, off, UInt32(v & 0xFFFF_FFFF))
        setU32(&buf, off + 4, UInt32(v >> 32))
    }

    // MARK: - Name codecs

    /// Writes `name` into the inode's zero-padded 44-byte field, truncating
    /// at a UTF-8 scalar boundary. False when nothing fits.
    @discardableResult
    private static func encodeName(_ name: String, into index: Int) -> Bool {
        let b = index * inodeSize
        var used = 0
        for scalar in name.unicodeScalars {
            let n = UTF8.width(scalar)
            if used + n > nameMax { break }
            for byte in String(scalar).utf8 {
                inodeTable[b + oName + used] = byte
                used += 1
            }
        }
        return used > 0
    }

    private static func decodeName(_ index: Int) -> String {
        let b = index * inodeSize
        var bytes: [UInt8] = []
        var i = 0
        while i < nameMax {
            let byte = inodeTable[b + oName + i]
            if byte == 0 { break }
            bytes.append(byte)
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

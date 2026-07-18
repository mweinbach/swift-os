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
//                       +44 journalStart u32     (0 = legacy image, no journal)
//                       +48 journalSectors u32   (0 = legacy image, no journal)
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
//   journalStart ..   metadata journal (journalSectors sectors; absent on
//                     legacy images — see JOURNAL below)
//   dataStart ..      data blocks, 8 sectors (4 KiB) each
//
// Design (per spec): directories have no data blocks — membership is encoded
// by the inode's parent link, so listing a directory is a scan of the inode
// table. Files are a single contiguous span; allocation is first-fit over the
// bitmap. Every content write is COPY-ON-WRITE: a fresh span is allocated and
// written, then ONE journaled inode flush repoints the file (the old span is
// freed only after the flip lands). A crash therefore always leaves the old
// file or the new file, never a torn one — at the price of a block leak in
// the crash window (harmless; the offline checker reports leaks as warnings).
//
// JOURNAL (physical redo, metadata only): every metadata sector mutation
// (inode-table sector, bitmap sector) is appended to the journal BEFORE it
// may reach its real location. One record = 3 sectors in a circular slot:
//
//   +0  payload  (512 bytes: the new contents of the target sector)
//   +1  header   +0 magic u32 "JNHR"  +4 seq u32  +8 targetSector u64
//                +16 payloadChecksum u32 (FNV-1a)  +20 headerChecksum u32
//   +2  commit   +0 magic u32 "JNCM"  +4 seq u32  +8 checksum u32
//
// Write order: payload -> header -> commit -> THEN the real sector. The
// commit sector is the record's durability point: a record without a valid
// commit is ignored at mount (its real sector was never touched); a
// committed record whose real write was cut short is redone at mount
// (idempotent sector rewrite). Journal slot = seq % slotCount, so the slots
// always hold a contiguous range of the newest <= slotCount records and
// replaying them in ascending seq order makes newest-wins for duplicate
// target sectors. Journal sector 0 is the journal superblock ("JNSB" +
// checkpointSeq): records with seq <= checkpointSeq are known-applied and
// skipped at mount. Checkpointing is trivially safe because records are
// applied synchronously at commit time (write-through for reads is
// unchanged); it runs inline every 16 records and after a replay — no
// kworker, no locking: SwiftFS is only ever called from the main thread
// (the VFS), same as BlockDev. Mount klogs "[fs] journal replayed N
// records" or "[fs] journal: clean".
//
// Legacy images (journalSectors == 0, e.g. disks written before the journal
// existed) mount read/write with journaling OFF (klogged); blank disks are
// formatted WITH a journal. format() writes the superblock LAST so an
// interrupted format never leaves a mountable half-image.
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

    // Journal geometry/state (filled in by mount()/format()). journalActive
    // is false on legacy images: flushes then go straight to disk.
    private static var journalActive = false
    private static var journalStart: UInt32 = 0
    private static var journalSectors: UInt32 = 0
    private static var journalSlots = 0          // (journalSectors - 1) / 3
    private static var nextSeq: UInt32 = 1       // seq of the next record
    private static var checkpointSeq: UInt32 = 0 // records <= this are applied
    private static var lastAppliedSeq: UInt32 = 0

    // Constants of the format.
    private static let inodeCount = 256
    private static let inodeSize = 64
    private static let inodeTableStart: UInt32 = 1
    private static let inodeTableSectors: UInt32 = UInt32(inodeCount * inodeSize / 512) // 32
    private static let blockSectors = 8
    private static let blockBytes = blockSectors * 512   // 4096
    private static let nameMax = 44

    // Constants of the journal (see the layout comment at the top).
    private static let journalTotalSectors: UInt32 = 64  // 1 super + 21 slots x 3
    private static let jMagicSuper: UInt32 = 0x4A4E_5342   // "JNSB"
    private static let jMagicHeader: UInt32 = 0x4A4E_4852  // "JNHR"
    private static let jMagicCommit: UInt32 = 0x4A4E_434D  // "JNCM"
    private static let jCheckpointEvery: UInt32 = 16

    // Reusable 512-byte scratch sectors for journal writes (SwiftFS is a
    // client of the heap; these are plain arrays, main-thread only).
    private static var jPayloadBuf = [UInt8](repeating: 0, count: 512)
    private static var jHeaderBuf = [UInt8](repeating: 0, count: 512)
    private static var jCommitBuf = [UInt8](repeating: 0, count: 512)
    private static var jSuperBuf = [UInt8](repeating: 0, count: 512)

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
        journalActive = false
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
        let jStart = getU32(sb, 44)
        let jSectors = getU32(sb, 48)

        // Two legal shapes: legacy (no journal: jStart/jSectors both zero,
        // data right after the bitmap) and journaled (journal between the
        // bitmap and the data area, 1 superblock + N x 3-sector slots).
        // Anything else is a corrupt superblock — refuse to mount.
        var slots = 0
        if jSectors == 0 {
            guard jStart == 0, dStart == bmStart + bmSectors else {
                klog("[fs] superblock failed sanity checks — not mounting")
                return false
            }
        } else {
            let spanOk = jStart == bmStart + bmSectors &&
                dStart == jStart + jSectors &&
                jSectors >= 4 && (jSectors - 1) % 3 == 0
            guard spanOk else {
                klog("[fs] superblock failed sanity checks — not mounting")
                return false
            }
            slots = Int((jSectors - 1) / 3)
        }

        guard inodes == inodeCount, blkSectors == blockSectors,
              itStart == inodeTableStart, itSectors == inodeTableSectors,
              bmStart == inodeTableStart + inodeTableSectors, bmSectors >= 1,
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

        // Replay BEFORE loading the RAM caches: committed-but-unapplied
        // records rewrite their real sectors here, so the caches below
        // always see post-replay state.
        if jSectors > 0 {
            journalStart = jStart
            journalSectors = jSectors
            journalSlots = slots
            journalActive = true
            journalRecover()
        } else {
            klog("[fs] legacy image (no journal region) — metadata journaling off")
        }

        guard let table = readSectors(UInt64(itStart), Int(itSectors)),
              let bm = readSectors(UInt64(bmStart), Int(bmSectors)) else {
            journalActive = false
            return false
        }
        guard table[0 + oType] == tDir else {
            klog("[fs] no root directory — not mounting")
            journalActive = false
            return false
        }
        inodeTable = table
        bitmap = bm
        isMounted = true
        klog("[fs] mounted: \(total) sectors, \(dataBlocks) data blocks, \(inodeCount) inodes")
        return true
    }

    /// Lays out a fresh journaled filesystem over the whole disk and creates
    /// the root directory (inode 0). Returns false if the disk is implausibly
    /// small. The superblock is written LAST, so a power cut mid-format
    /// leaves an unmountable disk that the next boot simply reformats.
    static func format() -> Bool {
        isMounted = false
        journalActive = false
        let total = BlockDev.blockCount
        guard total >= 128 else {
            klog("[fs] disk too small to format (\(total) sectors)")
            return false
        }

        // bitmapSectors and dataStart depend on each other; iterate to a fixpoint.
        // The journal sits between the bitmap and the data area.
        var bmSectors: UInt32 = 1
        while true {
            let dStart = inodeTableStart + inodeTableSectors + bmSectors + journalTotalSectors
            let blocks = Int(total - UInt64(dStart)) / blockSectors
            let need = UInt32((blocks + 8 * 512 - 1) / (8 * 512))
            if need <= bmSectors { break }
            bmSectors = need
        }
        let jStart = inodeTableStart + inodeTableSectors + bmSectors
        let dStart = jStart + journalTotalSectors
        let blocks = Int(total - UInt64(dStart)) / blockSectors

        totalSectors = total
        bitmapStart = inodeTableStart + inodeTableSectors
        bitmapSectors = bmSectors
        dataStart = dStart
        dataBlocks = blocks
        journalStart = jStart
        journalSectors = journalTotalSectors
        journalSlots = Int((journalTotalSectors - 1) / 3)
        inodeTable = [UInt8](repeating: 0, count: inodeCount * inodeSize)
        bitmap = [UInt8](repeating: 0, count: Int(bmSectors) * 512)

        // Inode table + bitmap go down unjournaled (nothing to redo yet),
        // then the journal region is zeroed (all slots invalid) and its
        // superblock written with an empty checkpoint.
        guard flushInodeTable(), flushBitmap(bits: 0..<dataBlocks) else { return false }
        guard writeSectors(UInt64(journalStart), Int(journalTotalSectors),
                           [UInt8](repeating: 0, count: Int(journalTotalSectors) * 512)) else {
            return false
        }
        nextSeq = 1
        checkpointSeq = 0
        lastAppliedSeq = 0
        guard journalCheckpoint(upto: 0) else { return false }

        // The superblock commits the format: until it lands, the disk is
        // garbage and the next boot formats again.
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
        setU32(&sb, 44, journalStart)
        setU32(&sb, 48, journalTotalSectors)
        guard writeSectors(0, 1, sb) else { return false }

        journalActive = true

        // Inode 0: the root directory (journaled like any later mutation).
        encodeName("/", into: 0)
        inodeTable[oType] = tDir
        inodeTable[oParent] = 0
        guard flushInode(0) else { return false }

        isMounted = true
        klog("[fs] formatted: \(total) sectors, \(blocks) data blocks, journal \(journalSlots) slots")
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

    /// Writes a file's full contents, copy-on-write: a fresh span is
    /// allocated and filled, then ONE journaled inode flush repoints the
    /// file at it (size/mtime travel with the same flush, so content and
    /// metadata commit atomically). The old span is freed only AFTER the
    /// flip lands — a crash in the window leaks blocks (reported as a
    /// warning by the offline checker) but never leaves the inode pointing
    /// at freed or half-written data. Never writes in place.
    /// `mtime` is seconds since 2024-01-01 UTC (the VFS converts wall-clock
    /// ms at the boundary); it is stored truncated to u32 on disk.
    static func writeFile(_ index: Int, _ data: [UInt8], mtime: UInt64) -> Bool {
        guard isMounted, index > 0, index < inodeCount else { return false }
        let b = index * inodeSize
        guard inodeTable[b + oType] == tFile else { return false }
        let needed = (data.count + blockBytes - 1) / blockBytes
        let curFirst = Int(getU32(inodeTable, b + oFirst))
        let curCount = Int(getU32(inodeTable, b + oCount))

        var newFirst = 0, newCount = 0
        if needed > 0 {
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
            newFirst = span
            newCount = needed
        }
        setU32(&inodeTable, b + oFirst, UInt32(newFirst))
        setU32(&inodeTable, b + oCount, UInt32(newCount))
        setU32(&inodeTable, b + oSize, UInt32(data.count))
        setU32(&inodeTable, b + oMtime, UInt32(mtime & 0xFFFF_FFFF))
        guard flushInode(index) else { return false }  // new span leaks on device fault
        if curCount > 0 { freeBlocks(curFirst, curCount) }
        return true
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

    /// Creates a file inode and its contents as ONE atomic metadata commit:
    /// the data span is allocated and written first, then a single journaled
    /// inode flush publishes name+parent+span+size together. A crash anywhere
    /// leaves either no trace or the complete file — never a zero-length
    /// phantom (the old create()+writeFile() pair had that window; the VFS
    /// uses this for new files instead). `mtime` is seconds since
    /// 2024-01-01 UTC (see writeFile). Returns the inode index, or nil on
    /// failure (full table, bad name, out of space, or device fault).
    static func createFile(name: String, parent: Int, executable: Bool,
                           mtime: UInt64, data: [UInt8]) -> Int? {
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
        let needed = (data.count + blockBytes - 1) / blockBytes
        var first = 0, count = 0
        if needed > 0 {
            guard let span = allocBlocks(needed) else {
                klog("[fs] out of space: need \(needed) blocks, wrote nothing")
                return nil
            }
            var buf = [UInt8](repeating: 0, count: needed * blockBytes)
            var i = 0
            while i < data.count { buf[i] = data[i]; i += 1 }
            guard writeSectors(sectorOf(block: span), needed * blockSectors, buf) else {
                freeBlocks(span, needed)
                return nil
            }
            first = span
            count = needed
        }
        let b = idx * inodeSize
        var i = 0
        while i < inodeSize { inodeTable[b + i] = 0; i += 1 }
        guard encodeName(name, into: idx) else {
            if count > 0 { freeBlocks(first, count) }
            return nil
        }
        inodeTable[b + oType] = tFile
        inodeTable[b + oParent] = UInt8(parent)
        setU16(&inodeTable, b + oFlags, executable ? 1 : 0)
        setU32(&inodeTable, b + oSize, UInt32(data.count))
        setU32(&inodeTable, b + oFirst, UInt32(first))
        setU32(&inodeTable, b + oCount, UInt32(count))
        setU32(&inodeTable, b + oMtime, UInt32(mtime & 0xFFFF_FFFF))
        guard flushInode(idx) else {
            // Undo the RAM cache so it matches the (unflushed) disk slot;
            // the span leaks on a real device fault rather than dangling.
            var j = 0
            while j < inodeSize { inodeTable[b + j] = 0; j += 1 }
            return nil
        }
        return idx
    }

    /// Frees an inode and its data span. The root can never be removed; the
    /// VFS guarantees directories are empty before this is called. The inode
    /// is zeroed and flushed FIRST, the span freed after — a crash in
    /// between leaks blocks instead of leaving the inode pointing at freed
    /// (and potentially reallocated) ones.
    static func remove(_ index: Int) -> Bool {
        guard isMounted, index > 0, index < inodeCount else { return false }
        let b = index * inodeSize
        guard inodeTable[b + oType] != tFree else { return true }
        let first = Int(getU32(inodeTable, b + oFirst))
        let count = Int(getU32(inodeTable, b + oCount))
        var i = 0
        while i < inodeSize { inodeTable[b + i] = 0; i += 1 }
        guard flushInode(index) else { return false }
        if count > 0 { freeBlocks(first, count) }
        return true
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
                if !writeSectorJournaled(UInt64(bitmapStart) + UInt64(s),
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
            ok = writeSectorJournaled(UInt64(inodeTableStart) + UInt64(sectorInTable),
                                      from: base.advanced(by: sectorInTable * 512))
        }
        if !ok { klog("[fs] inode flush failed (inode \(index))") }
        return ok
    }

    /// Whole-table write, used only by format() before the superblock lands
    /// (nothing to journal yet — an interrupted format reformats next boot).
    private static func flushInodeTable() -> Bool {
        var ok = true
        inodeTable.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { ok = false; return }
            ok = BlockDev.writeBlocks(UInt64(inodeTableStart), UInt32(inodeTableSectors),
                                      from: base)
        }
        return ok
    }

    // MARK: - Journal (physical redo of metadata sectors)

    /// One metadata sector to disk: through the journal when the image has
    /// one, direct on legacy images (and during format).
    private static func writeSectorJournaled(_ lba: UInt64, from src: UnsafeRawPointer) -> Bool {
        if journalActive {
            return journalWrite(lba: lba, from: src)
        }
        return BlockDev.writeBlocks(lba, 1, from: src)
    }

    /// Appends one record {seq, lba, 512 payload bytes} to the journal and
    /// applies it. Write order: payload, header, commit marker, THEN the
    /// real sector — the commit marker is the durability point. A power cut
    /// before the commit leaves the real sector untouched and the record is
    /// ignored at mount; a cut after it is redone by journalRecover().
    private static func journalWrite(lba: UInt64, from src: UnsafeRawPointer) -> Bool {
        var i = 0
        while i < 512 {
            jPayloadBuf[i] = src.load(fromByteOffset: i, as: UInt8.self)
            i += 1
        }
        let seq = nextSeq
        let slot = Int(seq % UInt32(journalSlots))
        let base = UInt64(journalStart) + 1 + UInt64(slot * 3)

        guard writeSectors(base, 1, jPayloadBuf) else { return false }

        var j = 0
        while j < 512 { jHeaderBuf[j] = 0; j += 1 }
        setU32(&jHeaderBuf, 0, jMagicHeader)
        setU32(&jHeaderBuf, 4, seq)
        setU64(&jHeaderBuf, 8, lba)
        setU32(&jHeaderBuf, 16, fnv1a(jPayloadBuf, 0, 512))
        setU32(&jHeaderBuf, 20, fnv1a(jHeaderBuf, 0, 20))
        guard writeSectors(base + 1, 1, jHeaderBuf) else { return false }

        var k = 0
        while k < 512 { jCommitBuf[k] = 0; k += 1 }
        setU32(&jCommitBuf, 0, jMagicCommit)
        setU32(&jCommitBuf, 4, seq)
        setU32(&jCommitBuf, 8, fnv1a(jCommitBuf, 0, 8))
        guard writeSectors(base + 2, 1, jCommitBuf) else { return false }

        // Committed — apply to the real location (replay redoes exactly this
        // write if the power dies inside it).
        guard writeSectors(lba, 1, jPayloadBuf) else { return false }
        lastAppliedSeq = seq
        nextSeq = seq &+ 1
        if nextSeq == 0 { nextSeq = 1 }   // seq 0 stays unused even at u32 wrap
        if lastAppliedSeq &- checkpointSeq >= jCheckpointEvery {
            _ = journalCheckpoint(upto: lastAppliedSeq)  // failure is non-fatal
        }
        return true
    }

    /// Marks every record up to `seq` as applied by rewriting the journal
    /// superblock. Cheap because records apply synchronously at commit time.
    private static func journalCheckpoint(upto seq: UInt32) -> Bool {
        var i = 0
        while i < 512 { jSuperBuf[i] = 0; i += 1 }
        setU32(&jSuperBuf, 0, jMagicSuper)
        setU32(&jSuperBuf, 4, seq)
        setU32(&jSuperBuf, 8, fnv1a(jSuperBuf, 0, 8))
        guard writeSectors(UInt64(journalStart), 1, jSuperBuf) else {
            klog("[fs] journal checkpoint write failed (non-fatal)")
            return false
        }
        checkpointSeq = seq
        return true
    }

    /// Mount-time recovery: read the journal superblock, validate every slot
    /// (magic + checksums + seq match = committed), and redo the committed
    /// records newer than the checkpoint in ascending seq order. A torn or
    /// stale record simply fails validation and is skipped; the circular
    /// slot mapping (slot = seq % slots) means the valid slots are always a
    /// contiguous tail of the sequence, so ascending replay is newest-wins
    /// for any sector journaled more than once. Ends by folding everything
    /// into a fresh checkpoint and re-arming the sequence counter.
    private static func journalRecover() {
        checkpointSeq = 0
        nextSeq = 1
        lastAppliedSeq = 0
        var highestSeq: UInt32 = 0
        if let jsb = readSectors(UInt64(journalStart), 1),
           getU32(jsb, 0) == jMagicSuper, getU32(jsb, 8) == fnv1a(jsb, 0, 8) {
            checkpointSeq = getU32(jsb, 4)
        } else {
            klog("[fs] journal superblock unreadable — replaying from seq 1")
        }

        var pending: [(seq: UInt32, lba: UInt64, data: [UInt8])] = []
        var slot = 0
        while slot < journalSlots {
            let base = UInt64(journalStart) + 1 + UInt64(slot * 3)
            if let hdr = readSectors(base + 1, 1),
               getU32(hdr, 0) == jMagicHeader, getU32(hdr, 20) == fnv1a(hdr, 0, 20) {
                let seq = getU32(hdr, 4)
                if let cmt = readSectors(base + 2, 1),
                   getU32(cmt, 0) == jMagicCommit, getU32(cmt, 4) == seq,
                   getU32(cmt, 8) == fnv1a(cmt, 0, 8),
                   let payload = readSectors(base, 1),
                   getU32(hdr, 16) == fnv1a(payload, 0, 512) {
                    if seq > highestSeq { highestSeq = seq }
                    let lba = getU64(hdr, 8)
                    if seq > checkpointSeq, lba + 1 <= BlockDev.blockCount {
                        pending.append((seq, lba, payload))
                    }
                }
            }
            slot += 1
        }

        if pending.isEmpty {
            klog("[fs] journal: clean")
        } else {
                pending.sort { a, b in a.seq < b.seq }
                var applied = 0
                for rec in pending {
                    if writeSectors(rec.lba, 1, rec.data) {
                        applied += 1
                    } else {
                        klog("[fs] journal replay: sector \(rec.lba) write FAILED")
                    }
                }
            klog("[fs] journal replayed \(applied) records")
        }

        nextSeq = (highestSeq > checkpointSeq ? highestSeq : checkpointSeq) &+ 1
        if nextSeq == 0 { nextSeq = 1 }
        lastAppliedSeq = nextSeq &- 1
        _ = journalCheckpoint(upto: lastAppliedSeq)
    }

    /// FNV-1a 32 over a byte slice — cheap, allocation-free, good enough to
    /// detect torn journal sectors (this is integrity, not security).
    private static func fnv1a(_ buf: [UInt8], _ off: Int, _ count: Int) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        var i = 0
        while i < count {
            h = (h ^ UInt32(buf[off + i])) &* 0x0100_0193
            i += 1
        }
        return h
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

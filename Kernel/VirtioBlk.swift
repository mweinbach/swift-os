// Virtio block driver (legacy virtio-mmio v1) for QEMU's virtio-blk-device.
//
// Same discovery model as the input driver (see VirtioInput.swift): the
// virtio-mmio slots from the device tree (Machine.virtioMmioBase +
// slot*0x200, default 0x0A00_0000, up to 32), legacy register interface
// only (-global virtio-mmio.force-legacy=on), DeviceID 2 = block.
//
// I/O model: fully synchronous polled requests, one at a time, no IRQs. Every
// request is a 3-descriptor chain {header out, data in/out, status in} placed
// in descriptors 0-2 of queue 0; we kick the device and spin on the used
// ring. The header (struct virtio_blk_outhdr) and status byte live in the
// unused tail of the vring's first page. Under QEMU TCG, device DMA is
// coherent with the CPU caches, so caller buffers are handed to the device
// directly (identity-mapped: virtual == physical).

import _Volatile

// File-local volatile accessors for sub-word MMIO and ring memory
// (MMIO.swift only has 32/64-bit variants).

@inline(__always)
private func bload8(_ a: UInt) -> UInt8 {
    VolatileMappedRegister<UInt8>(unsafeBitPattern: a).load()
}

@inline(__always)
private func bstore8(_ a: UInt, _ v: UInt8) {
    VolatileMappedRegister<UInt8>(unsafeBitPattern: a).store(v)
}

@inline(__always)
private func bload16(_ a: UInt) -> UInt16 {
    VolatileMappedRegister<UInt16>(unsafeBitPattern: a).load()
}

@inline(__always)
private func bstore16(_ a: UInt, _ v: UInt16) {
    VolatileMappedRegister<UInt16>(unsafeBitPattern: a).store(v)
}

@inline(__always)
private func bstore64(_ a: UInt, _ v: UInt64) {
    VolatileMappedRegister<UInt64>(unsafeBitPattern: a).store(v)
}

/// Synchronous polled virtio-blk device. All public entry points are safe to
/// call from the kernel main thread only (they spin on MMIO).
enum BlockDev {
    /// Total 512-byte sectors, valid after a successful initBlockDev().
    static private(set) var blockCount: UInt64 = 0
    /// Device faults contained at runtime (timeouts / ring desyncs that
    /// forced a full device reset). Diagnostics only; never reset to 0.
    static private(set) var errorCount: Int = 0

    private static var mmioBase: UInt { Machine.virtioMmioBase }
    private static let slotStride: UInt = 0x200
    private static var slotCount: Int { Machine.virtioMmioSlots }
    private static let sectorSize = 512

    // Legacy virtio-mmio register offsets (same layout as VirtioInput).
    private enum R {
        static let magicValue: UInt = 0x00
        static let version: UInt = 0x04
        static let deviceID: UInt = 0x08
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
        static let config: UInt = 0x100      // virtio_blk_config.capacity (u64)
    }

    // virtio_blk request types / status values.
    private static let tIn: UInt32 = 0       // read  (device writes data)
    private static let tOut: UInt32 = 1      // write (device reads data)
    private static let sOK: UInt8 = 0

    private static var base: UInt = 0
    private static var qsize: UInt16 = 0
    private static var descBase: UInt = 0    // vring descriptor table
    private static var availBase: UInt = 0   // vring avail ring
    private static var usedBase: UInt = 0    // vring used ring (4096-aligned)
    private static var hdrAddr: UInt = 0     // 16-byte request header scratch
    private static var statusAddr: UInt = 0  // 1-byte status scratch
    private static var availIdx: UInt16 = 0
    private static var lastUsed: UInt16 = 0
    private static var ready = false

    // MARK: - Initialization

    /// Scan the virtio-mmio slots and initialize the first legacy block
    /// device found. Returns false when no disk is attached (RAM-only boot).
    static func initBlockDev() -> Bool {
        ready = false
        blockCount = 0
        for slot in 0..<slotCount {
            let b = mmioBase + UInt(slot) * slotStride
            guard mmioRead32(b + R.magicValue) == 0x7472_6976 else { continue }
            guard mmioRead32(b + R.deviceID) == 2 else { continue }
            guard mmioRead32(b + R.version) == 1 else {
                klog("[blk] slot \(slot): modern-only virtio-blk device skipped")
                continue
            }
            guard setupDevice(base: b) else {
                klog("[blk] slot \(slot): setup FAILED")
                continue
            }
            base = b
            blockCount = mmioRead64(b + R.config)
            ready = true
            let mib = blockCount * UInt64(sectorSize) / (1024 * 1024)
            klog("[blk] virtio-blk (slot \(slot)): \(blockCount) sectors (\(mib) MiB)")
            return true
        }
        klog("[blk] no virtio-blk device found")
        return false
    }

    // virtio status register bits.
    private static let stAck: UInt32 = 1
    private static let stDriver: UInt32 = 2
    private static let stOK: UInt32 = 4
    private static let stFeatOK: UInt32 = 8

    /// Legacy virtio bring-up: bounded reset, status handshake, then vring 0
    /// setup. Any validation failure returns false — the block subsystem
    /// stays absent (RAM-only boot) instead of trusting a misbehaving device.
    private static func setupDevice(base b: UInt) -> Bool {
        guard resetDevice(b) else {
            klog("[blk] device did not complete reset")
            return false
        }
        handshake(b)

        mmioWrite32(b + R.guestPageSize, 4096)
        mmioWrite32(b + R.queueSel, 0)                      // queue 0 = requestq
        let qmax = mmioRead32(b + R.queueNumMax)
        guard qmax >= 4 else { return false }               // need 3-desc chains
        qsize = UInt16(min(qmax, 8))

        // Vring: descriptor table (qsize*16 B) + avail ring in page 0, used
        // ring at +4096 (QueueAlign). The request header and status byte
        // share the slack in page 0 (well past the avail ring). The pages are
        // allocated once here and reused by every later recovery reset.
        guard let vq = KernelHeap.allocPages(2) else { return false }
        descBase = vq
        bringUpQueue(b)
        return true
    }

    /// Full device reset: Status=0, then a BOUNDED poll for reset-complete —
    /// a device that never clears Status must not hang boot or recovery.
    private static func resetDevice(_ b: UInt) -> Bool {
        mmioWrite32(b + R.status, 0)
        var spins = 0
        while mmioRead32(b + R.status) != 0 {
            spins += 1
            if spins >= 1_000_000 { return false }
        }
        return true
    }

    /// Status handshake up to FEATURES_OK (we negotiate no features).
    private static func handshake(_ b: UInt) {
        mmioWrite32(b + R.status, stAck)
        mmioWrite32(b + R.status, stAck | stDriver)
        _ = mmioRead32(b + R.hostFeatures)                  // we require nothing
        mmioWrite32(b + R.guestFeatures, 0)
        // FEATURES_OK is optional on the legacy interface; continue either way.
        mmioWrite32(b + R.status, stAck | stDriver | stFeatOK)
        _ = mmioRead32(b + R.status)
    }

    /// (Re)program queue 0 on the already-allocated vring pages and set the
    /// device live. Shared by setupDevice() and runtime fault recovery.
    private static func bringUpQueue(_ b: UInt) {
        mmioWrite32(b + R.guestPageSize, 4096)
        mmioWrite32(b + R.queueSel, 0)
        mmioWrite32(b + R.queueNum, UInt32(qsize))
        mmioWrite32(b + R.queueAlign, 4096)

        let vq = descBase
        zeroRegion(vq, 2 * 4096)
        availBase = vq + UInt(qsize) * 16
        usedBase = vq + 4096
        hdrAddr = vq + 0x800
        statusAddr = vq + 0x810
        availIdx = 0
        lastUsed = 0
        mmioWrite32(b + R.queuePFN, UInt32(vq / 4096))

        bstore16(availBase, 1)  // VIRTQ_AVAIL_F_NO_INTERRUPT — we poll

        // Acknowledge any stale interrupt, then go live.
        mmioWrite32(b + R.interruptACK, mmioRead32(b + R.interruptStatus))
        mmioWrite32(b + R.status, stAck | stDriver | stFeatOK | stOK)
    }

    /// Contain a runtime device fault: full device reset + queue re-init on
    /// the existing vring pages, counted in errorCount, then carry on. Never
    /// spins forever; if the device refuses to reset, the block subsystem
    /// goes quiescent (ready=false) and later I/O fails fast.
    private static func recoverFromFault(_ what: String) {
        errorCount += 1
        klog("[blk] \(what) — resetting device")
        guard resetDevice(base) else {
            klog("[blk] device reset FAILED — block device disabled")
            ready = false
            return
        }
        handshake(base)
        bringUpQueue(base)
    }

    private static func zeroRegion(_ base: UInt, _ bytes: Int) {
        var off = 0
        while off < bytes {
            bstore64(base + UInt(off), 0)
            off += 8
        }
    }

    // MARK: - Sector I/O

    /// Reads `count` 512-byte sectors starting at `lba` into `into`
    /// (must point at count*512 contiguous bytes). Polls (bounded) until
    /// done; on a device fault the device is fully reset and the request
    /// retried ONCE — callers see false only for persistent failures.
    static func readBlocks(_ lba: UInt64, _ count: UInt32, into: UnsafeMutableRawPointer) -> Bool {
        guard ready, count > 0 else { return false }
        guard lba + UInt64(count) <= blockCount else {
            klog("[blk] request out of range: lba \(lba) count \(count)")
            return false
        }
        let buf = UInt(bitPattern: into)
        guard let fault = doRequest(type: tIn, lba: lba, count: count,
                                    buf: buf, deviceWritesData: true) else {
            return true                                     // nil = success
        }
        recoverFromFault(fault)
        if let again = doRequest(type: tIn, lba: lba, count: count,
                                 buf: buf, deviceWritesData: true) {
            klog("[blk] read retry failed: \(again)")
            return false
        }
        return true
    }

    /// Writes `count` 512-byte sectors starting at `lba` from `from`.
    /// Same reset + single-retry containment as readBlocks.
    static func writeBlocks(_ lba: UInt64, _ count: UInt32, from: UnsafeRawPointer) -> Bool {
        guard ready, count > 0 else { return false }
        guard lba + UInt64(count) <= blockCount else {
            klog("[blk] request out of range: lba \(lba) count \(count)")
            return false
        }
        let buf = UInt(bitPattern: from)
        guard let fault = doRequest(type: tOut, lba: lba, count: count,
                                    buf: buf, deviceWritesData: false) else {
            return true
        }
        recoverFromFault(fault)
        if let again = doRequest(type: tOut, lba: lba, count: count,
                                 buf: buf, deviceWritesData: false) {
            klog("[blk] write retry failed: \(again)")
            return false
        }
        return true
    }

    /// Submit one request as a 3-descriptor chain in descriptors 0-2 and spin
    /// (bounded) on the used ring. Only one request is ever in flight.
    /// Returns nil on success, or a fault description — the caller then
    /// resets the device and may retry once. Ring contents are validated
    /// before anything the device wrote is trusted, and after a fault is
    /// detected nothing here touches the rings again.
    private static func doRequest(type: UInt32, lba: UInt64, count: UInt32,
                                  buf: UInt, deviceWritesData: Bool) -> String? {
        guard ready else { return "device not ready" }

        // Header: struct virtio_blk_outhdr { u32 type; u32 ioprio; u64 sector }.
        mmioWrite32(hdrAddr, type)
        mmioWrite32(hdrAddr + 4, 0)
        bstore64(hdrAddr + 8, lba)
        bstore8(statusAddr, 0xFF)

        // Descriptor 0: header (device reads).
        setDesc(0, addr: hdrAddr, len: 16, flags: 1 /* NEXT */, next: 1)
        // Descriptor 1: data payload. VIRTQ_DESC_F_WRITE (2) marks a buffer the
        // DEVICE writes to — set for reads, clear for writes.
        setDesc(1, addr: buf, len: count * UInt32(sectorSize),
                flags: 1 | (deviceWritesData ? 2 : 0), next: 2)
        // Descriptor 2: status byte (device writes).
        setDesc(2, addr: statusAddr, len: 1, flags: 2, next: 0)

        // Publish the chain head in the avail ring and kick the device.
        bstore16(availBase + 4 + UInt(availIdx % qsize) * 2, 0)
        armDsbSy()
        availIdx &+= 1
        bstore16(availBase + 2, availIdx)
        armDsbSy()
        mmioWrite32(base + R.queueNotify, 0)

        // Spin on the used ring with a generous timeout (a hung device must
        // not wedge the kernel; callers degrade to RAM-only operation).
        var spins = 0
        while bload16(usedBase + 2) == lastUsed {
            spins += 1
            if spins > 100_000_000 {
                return "request timeout"
            }
        }

        // Ring validation before trusting anything the device wrote: the used
        // idx must have advanced monotonically by at most qsize, the used
        // element must reference a descriptor we own, and its byte count must
        // fit this chain's device-writable buffers (data on reads, the status
        // byte always). A violation means the ring is desynced; consuming it
        // could silently corrupt kernel memory.
        let usedIdx = bload16(usedBase + 2)
        let delta = usedIdx &- lastUsed
        guard delta >= 1, delta <= qsize else { return "ring desync" }
        let elem = usedBase + 4 + UInt(lastUsed % qsize) * 8
        let id = mmioRead32(elem)
        let usedLen = mmioRead32(elem + 4)
        let maxWritten = UInt32(deviceWritesData ? count * UInt32(sectorSize) : 0) + 1
        guard id < UInt32(qsize), usedLen <= maxWritten else { return "ring desync" }

        lastUsed &+= 1
        // Ack the (masked) interrupt to keep the device state tidy.
        mmioWrite32(base + R.interruptACK, mmioRead32(base + R.interruptStatus))

        let status = bload8(statusAddr)
        if status != sOK {
            return "request failed, status \(status)"
        }
        return nil
    }

    private static func setDesc(_ i: UInt16, addr: UInt, len: UInt32, flags: UInt16, next: UInt16) {
        let d = descBase + UInt(i) * 16
        bstore64(d, UInt64(addr))
        mmioWrite32(d + 8, len)
        bstore16(d + 12, flags)
        bstore16(d + 14, next)
    }
}

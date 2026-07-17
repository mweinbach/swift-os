// Virtio network driver (legacy virtio-mmio v1) for QEMU's virtio-net-device.
//
// Same discovery model as the input/block drivers (see VirtioInput.swift):
// up to 32 virtio-mmio slots at 0x0A00_0000 + slot*0x200, legacy register
// interface only (-global virtio-mmio.force-legacy=on), DeviceID 1 = net.
//
// I/O model: polled, no IRQs (VIRTQ_AVAIL_F_NO_INTERRUPT on both queues).
// Queue 0 (receiveq) stays filled with 8 posted buffers of 1600 bytes;
// pollRx() drains the used ring and hands each frame to Net.handleRxFrame
// (same thread — the buffer is reposted after return). Queue 1 (transmitq)
// sends one frame at a time from a single tx buffer and spins on the used
// ring until the device is done with it, so the buffer is reusable as soon
// as tx() returns.
//
// We negotiate NO features (guestFeatures = 0). In particular the legacy
// device then does not use VIRTIO_NET_F_MRG_RXBUF, so every packet in both
// directions is prefixed with the 10-byte legacy virtio_net_hdr
//   { u8 flags; u8 gso_type; u16 hdr_len; u16 gso_size;
//     u16 csum_start; u16 csum_offset }
// which we zero on transmit and skip on receive.
// Under QEMU TCG, device DMA is coherent with the CPU caches (see
// MMU.swift), and memory is identity-mapped (virtual == physical).

import _Volatile

// File-local volatile accessors for sub-word MMIO and ring memory
// (MMIO.swift only has 32/64-bit variants).

@inline(__always)
private func nload8(_ a: UInt) -> UInt8 {
    VolatileMappedRegister<UInt8>(unsafeBitPattern: a).load()
}

@inline(__always)
private func nload16(_ a: UInt) -> UInt16 {
    VolatileMappedRegister<UInt16>(unsafeBitPattern: a).load()
}

@inline(__always)
private func nstore8(_ a: UInt, _ v: UInt8) {
    VolatileMappedRegister<UInt8>(unsafeBitPattern: a).store(v)
}

@inline(__always)
private func nstore16(_ a: UInt, _ v: UInt16) {
    VolatileMappedRegister<UInt16>(unsafeBitPattern: a).store(v)
}

@inline(__always)
private func nstore64(_ a: UInt, _ v: UInt64) {
    VolatileMappedRegister<UInt64>(unsafeBitPattern: a).store(v)
}

/// Polled legacy virtio-net device. All entry points run on the kernel main
/// thread (they spin on MMIO).
enum NetDev {
    /// True after a successful initNetDev().
    static private(set) var ready = false
    /// Our MAC, 6 bytes packed big-endian into the low 48 bits
    /// (byte 0 of the address is bits 47...40). Broadcast is all-ones.
    static private(set) var mac: UInt64 = 0

    private static let mmioBase: UInt = 0x0A00_0000
    private static let slotStride: UInt = 0x200
    private static let slotCount = 32

    /// Bytes of legacy virtio_net_hdr prepended to every packet (no mrg rxbuf).
    private static let hdrLen = 10
    private static let rxBufLen: UInt = 1600

    // Legacy virtio-mmio register offsets (same layout as VirtioInput).
    private enum NReg {
        static let magicValue: UInt = 0x00
        static let version: UInt = 0x04
        static let deviceID: UInt = 0x08       // 1 = network card
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
        static let config: UInt = 0x100        // virtio_net_config.mac (6 bytes)
    }

    private static var base: UInt = 0
    private static var qsize: UInt16 = 0

    // Queue 0 (receiveq) state.
    private static var rxDesc: UInt = 0
    private static var rxAvail: UInt = 0
    private static var rxUsed: UInt = 0
    private static var rxBufs: UInt = 0      // qsize buffers of rxBufLen bytes
    private static var rxAvailIdx: UInt16 = 0
    private static var rxLastUsed: UInt16 = 0

    // Queue 1 (transmitq) state: single buffer, one frame in flight.
    private static var txDesc: UInt = 0
    private static var txAvail: UInt = 0
    private static var txUsed: UInt = 0
    private static var txBuf: UInt = 0       // one 4096-byte buffer
    private static var txAvailIdx: UInt16 = 0
    private static var txLastUsed: UInt16 = 0

    // MARK: - Initialization

    /// Scan the virtio-mmio slots and initialize the first legacy network
    /// device found. Returns false when no NIC is attached.
    static func initNetDev() -> Bool {
        ready = false
        mac = 0
        for slot in 0..<slotCount {
            let b = mmioBase + UInt(slot) * slotStride
            guard mmioRead32(b + NReg.magicValue) == 0x7472_6976 else { continue }
            guard mmioRead32(b + NReg.deviceID) == 1 else { continue }
            guard mmioRead32(b + NReg.version) == 1 else {
                klog("[net] slot \(slot): modern-only virtio-net device skipped")
                continue
            }
            guard setupDevice(base: b) else {
                klog("[net] slot \(slot): setup FAILED")
                continue
            }
            base = b
            var m: UInt64 = 0
            for i in 0..<6 {
                m = (m << 8) | UInt64(nload8(b + NReg.config + UInt(i)))
            }
            mac = m
            ready = true
            klog("[net] virtio-net (slot \(slot)): mac \(macString)")
            return true
        }
        klog("[net] no virtio-net device found")
        return false
    }

    /// "52:54:00:12:34:56" form of the packed MAC.
    static var macString: String {
        var s = ""
        for i in 0..<6 {
            if i > 0 { s += ":" }
            let byte = Int((mac >> UInt64(40 - i * 8)) & 0xFF)
            s += byte < 16 ? "0" + String(byte, radix: 16) : String(byte, radix: 16)
        }
        return s
    }

    /// Legacy virtio bring-up: status handshake, then both vrings + rx buffers.
    private static func setupDevice(base b: UInt) -> Bool {
        let stAck: UInt32 = 1, stDriver: UInt32 = 2, stOK: UInt32 = 4, stFeatOK: UInt32 = 8
        mmioWrite32(b + NReg.status, 0)                     // reset
        mmioWrite32(b + NReg.status, stAck)
        mmioWrite32(b + NReg.status, stAck | stDriver)
        _ = mmioRead32(b + NReg.hostFeatures)               // we require nothing
        mmioWrite32(b + NReg.guestFeatures, 0)
        // FEATURES_OK is optional on the legacy interface; continue either way.
        mmioWrite32(b + NReg.status, stAck | stDriver | stFeatOK)
        _ = mmioRead32(b + NReg.status)

        mmioWrite32(b + NReg.guestPageSize, 4096)

        // Both queues get the same (small) size; we only ever post 8 buffers.
        mmioWrite32(b + NReg.queueSel, 0)
        let rxMax = mmioRead32(b + NReg.queueNumMax)
        mmioWrite32(b + NReg.queueSel, 1)
        let txMax = mmioRead32(b + NReg.queueNumMax)
        let qs = min(min(rxMax, txMax), 8)
        guard qs >= 2 else { return false }
        qsize = UInt16(qs)

        // --- queue 0 (receiveq): vring (2 pages) + buffer pages -----------
        guard let rxq = KernelHeap.allocPages(2) else { return false }
        zeroRegion(rxq, 2 * 4096)
        let bufPages = (Int(qsize) * Int(rxBufLen) + 4095) / 4096
        guard let rxb = KernelHeap.allocPages(bufPages) else { return false }
        zeroRegion(rxb, bufPages * 4096)

        rxDesc = rxq
        rxAvail = rxq + UInt(qsize) * 16
        rxUsed = rxq + 4096
        rxBufs = rxb
        mmioWrite32(b + NReg.queueSel, 0)
        mmioWrite32(b + NReg.queueNum, UInt32(qsize))
        mmioWrite32(b + NReg.queueAlign, 4096)
        mmioWrite32(b + NReg.queuePFN, UInt32(rxq / 4096))

        nstore16(rxAvail, 1)  // VIRTQ_AVAIL_F_NO_INTERRUPT — we poll
        var i: UInt16 = 0
        while i < qsize {
            let desc = rxDesc + UInt(i) * 16
            nstore64(desc, UInt64(rxBufs + UInt(i) * rxBufLen))
            mmioWrite32(desc + 8, UInt32(rxBufLen))     // header + frame fit
            nstore16(desc + 12, 2)              // VIRTQ_DESC_F_WRITE (device writes)
            nstore16(desc + 14, 0)              // next
            nstore16(rxAvail + 4 + UInt(i) * 2, i)
            i += 1
        }
        armDsbSy()
        nstore16(rxAvail + 2, qsize)            // avail.idx: all buffers posted
        rxAvailIdx = qsize
        rxLastUsed = 0

        // --- queue 1 (transmitq): vring (2 pages) + one frame buffer -------
        guard let txq = KernelHeap.allocPages(2) else { return false }
        zeroRegion(txq, 2 * 4096)
        guard let txb = KernelHeap.allocPages(1) else { return false }
        zeroRegion(txb, 4096)

        txDesc = txq
        txAvail = txq + UInt(qsize) * 16
        txUsed = txq + 4096
        txBuf = txb
        mmioWrite32(b + NReg.queueSel, 1)
        mmioWrite32(b + NReg.queueNum, UInt32(qsize))
        mmioWrite32(b + NReg.queueAlign, 4096)
        mmioWrite32(b + NReg.queuePFN, UInt32(txq / 4096))

        nstore16(txAvail, 1)  // VIRTQ_AVAIL_F_NO_INTERRUPT — we poll
        txAvailIdx = 0
        txLastUsed = 0

        // Acknowledge any stale interrupt, go live, then kick the rx queue.
        mmioWrite32(b + NReg.interruptACK, mmioRead32(b + NReg.interruptStatus))
        mmioWrite32(b + NReg.status, stAck | stDriver | stFeatOK | stOK)
        armDsbSy()
        mmioWrite32(b + NReg.queueNotify, 0)
        return true
    }

    private static func zeroRegion(_ base: UInt, _ bytes: Int) {
        var off = 0
        while off < bytes {
            nstore64(base + UInt(off), 0)
            off += 8
        }
    }

    // MARK: - Transmit

    /// Send one ethernet frame (14-byte header included, no FCS). Copies the
    /// frame into the tx buffer behind a zeroed legacy virtio_net_hdr, kicks
    /// queue 1, and spins until the device has consumed it. Returns false on
    /// an overlong frame or a device timeout.
    static func tx(_ bytes: UnsafeRawPointer, _ len: Int) -> Bool {
        guard ready, len > 0, len <= 1514 else { return false }

        nstore64(txBuf, 0)                      // zero the 10-byte legacy header
        nstore16(txBuf + 8, 0)
        UnsafeMutableRawPointer(bitPattern: txBuf + UInt(hdrLen))!
            .copyMemory(from: bytes, byteCount: len)

        // One descriptor covering header + frame (device reads it).
        let d = txDesc
        nstore64(d, UInt64(txBuf))
        mmioWrite32(d + 8, UInt32(hdrLen + len))
        nstore16(d + 12, 0)                     // flags: device-read
        nstore16(d + 14, 0)                     // next

        nstore16(txAvail + 4 + UInt(txAvailIdx % qsize) * 2, 0)
        armDsbSy()
        txAvailIdx &+= 1
        nstore16(txAvail + 2, txAvailIdx)
        armDsbSy()
        mmioWrite32(base + NReg.queueNotify, 1)

        // Spin on the used ring with a bounded timeout (a hung device must
        // not wedge the kernel).
        var spins = 0
        while nload16(txUsed + 2) == txLastUsed {
            spins += 1
            if spins > 100_000_000 {
                klog("[net] TIMEOUT waiting for tx completion")
                return false
            }
        }
        txLastUsed &+= 1
        // Ack the (masked) interrupt to keep the device state tidy.
        mmioWrite32(base + NReg.interruptACK, mmioRead32(base + NReg.interruptStatus))
        return true
    }

    // MARK: - Receive

    /// Drain the receiveq used ring, handing each frame (without the 10-byte
    /// virtio header) to Net.handleRxFrame, then repost the buffer. Called
    /// from Net.poll() on the kernel main thread — never IRQ context.
    static func pollRx() {
        guard ready else { return }
        let usedIdx = nload16(rxUsed + 2)
        while rxLastUsed != usedIdx {
            let slot = rxLastUsed % qsize
            let elem = rxUsed + 4 + UInt(slot) * 8
            let id = UInt16(mmioRead32(elem) & 0xFFFF)
            let written = Int(mmioRead32(elem + 4))     // header + frame bytes
            if id < qsize {
                if written > hdrLen {
                    let b = rxBufs + UInt(id) * rxBufLen
                    let frameLen = min(written - hdrLen, Int(rxBufLen) - hdrLen)
                    Net.handleRxFrame(UnsafeRawPointer(bitPattern: b + UInt(hdrLen))!,
                                      frameLen)
                }
                // Repost the buffer and kick the device.
                nstore16(rxAvail + 4 + UInt(rxAvailIdx % qsize) * 2, id)
                armDsbSy()
                rxAvailIdx &+= 1
                nstore16(rxAvail + 2, rxAvailIdx)
                armDsbSy()
                mmioWrite32(base + NReg.queueNotify, 0)
            }
            rxLastUsed &+= 1
        }
    }
}

// IPv4 protocol stack on top of NetDev (virtio-net).
//
// Layers: ethernet (parse/build) → ARP (request/reply, 8-entry cache,
// synchronous resolve) → IPv4 (header build/parse + checksum) → ICMP
// (answers echo requests addressed to us; sends echo requests and times the
// replies for the `ping` shell command). The demo target is QEMU's user-mode
// networking (slirp): we are 10.0.2.15, the gateway 10.0.2.2 answers both
// ARP and ICMP echo.
//
// Everything is polled and single-threaded: Net.poll() is called from the
// kernel main loop (compositor), and Net.ping() pumps NetDev.pollRx() itself
// while it waits for replies. Nothing here runs in IRQ context, so
// allocation is allowed — but kept minimal: packets are built in place in
// two scratch pages, no per-packet buffers.
//
// UInt32 IPv4 addresses are packed big-endian (10.0.2.15 = 0x0A00_020F);
// MACs are 6 bytes packed into the low 48 bits of a UInt64 (byte 0 = bits
// 47...40), matching NetDev.mac.

enum Net {
    /// Our IPv4 address (QEMU slirp's default guest address).
    static private(set) var ourIP: UInt32 = 0x0A00_020F
    /// QEMU slirp's gateway/host address — answers ARP and ping.
    static let gatewayIP: UInt32 = 0x0A00_0202
    static let netmask: UInt32 = 0xFFFF_FF00

    /// True after a successful initNet() (NIC present, scratch allocated).
    static private(set) var ready = false

    // MARK: - Init / polling

    /// Bring up the virtio-net device and the protocol stack. False when no
    /// NIC is attached (ping then reports "network unavailable").
    static func initNet() -> Bool {
        ready = false
        guard NetDev.initNetDev() else { return false }
        guard let s = KernelHeap.allocPages(1), let a = KernelHeap.allocPages(1) else {
            klog("[net] scratch page allocation failed")
            return false
        }
        scratch = s
        arpScratch = a
        arpCache.reserveCapacity(arpCapacity)
        ready = true
        klog("[net] ipv4 \(dotted(ourIP)) gateway \(dotted(gatewayIP))")
        return true
    }

    /// Drain received frames into the stack. Hook for the compositor loop.
    static func poll() {
        NetDev.pollRx()
    }

    // MARK: - Constants / state

    private static let ethARP: UInt16 = 0x0806
    private static let ethIPv4: UInt16 = 0x0800
    private static let protoICMP: UInt8 = 1
    private static let pingID: UInt16 = 0x5357       // "SW"
    private static let broadcastMAC: UInt64 = 0x0000_FFFF_FFFF_FFFF
    private static let pingPayload = 56              // data bytes (real ping)

    /// Frame build area (ethernet header + IP packet, one page).
    private static var scratch: UInt = 0
    /// ARP packet build area — separate so ARP resolution never clobbers a
    /// half-built frame in `scratch`.
    private static var arpScratch: UInt = 0

    private struct ARPEntry {
        let ip: UInt32
        let mac: UInt64
    }
    private static let arpCapacity = 8
    private static var arpCache: [ARPEntry] = []
    private static var arpNextSlot = 0

    private static var ipID: UInt16 = 0

    // Last ICMP echo reply matching pingID (consumed by ping()).
    private static var lastReplySeq = 0
    private static var lastReplySrc: UInt32 = 0
    private static var lastReplyTTL = 0
    private static var lastReplyBytes = 0

    // MARK: - Big-endian field helpers (byte-wise: frames can be unaligned)

    @inline(__always)
    private static func rd8(_ p: UnsafeRawPointer, _ o: Int) -> UInt8 {
        p.load(fromByteOffset: o, as: UInt8.self)
    }

    @inline(__always)
    private static func rd16(_ p: UnsafeRawPointer, _ o: Int) -> UInt16 {
        UInt16(rd8(p, o)) << 8 | UInt16(rd8(p, o + 1))
    }

    @inline(__always)
    private static func rd32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
        UInt32(rd16(p, o)) << 16 | UInt32(rd16(p, o + 2))
    }

    @inline(__always)
    private static func wr8(_ a: UInt, _ v: UInt8) {
        UnsafeMutablePointer<UInt8>(bitPattern: a)!.pointee = v
    }

    @inline(__always)
    private static func wr16(_ a: UInt, _ v: UInt16) {
        wr8(a, UInt8(v >> 8))
        wr8(a + 1, UInt8(v & 0xFF))
    }

    @inline(__always)
    private static func wr32(_ a: UInt, _ v: UInt32) {
        wr16(a, UInt16(v >> 16))
        wr16(a + 2, UInt16(v & 0xFFFF))
    }

    private static func rdMAC(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
        var m: UInt64 = 0
        for i in 0..<6 { m = (m << 8) | UInt64(rd8(p, o + i)) }
        return m
    }

    private static func wrMAC(_ a: UInt, _ mac: UInt64) {
        for i in 0..<6 {
            wr8(a + UInt(i), UInt8((mac >> UInt64(40 - i * 8)) & 0xFF))
        }
    }

    /// Standard 16-bit one's-complement checksum (RFC 1071).
    private static func checksum(_ p: UnsafeRawPointer, _ len: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < len {
            sum &+= UInt32(rd16(p, i))
            i += 2
        }
        if i < len { sum &+= UInt32(rd8(p, i)) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    /// "10.0.2.15" dotted-quad form of a packed IPv4 address.
    static func dotted(_ ip: UInt32) -> String {
        "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
    }

    // MARK: - Receive path (called by NetDev.pollRx, main thread only)

    /// One received ethernet frame. The buffer is reposted when we return,
    /// so anything worth keeping is acted on inline.
    static func handleRxFrame(_ p: UnsafeRawPointer, _ len: Int) {
        guard ready, len >= 14 else { return }
        switch rd16(p, 12) {
        case ethARP:  handleARP(p + 14, len - 14)
        case ethIPv4: handleIPv4(p + 14, len - 14, srcMAC: rdMAC(p, 6))
        default:      break
        }
    }

    private static func handleARP(_ p: UnsafeRawPointer, _ len: Int) {
        guard len >= 28 else { return }
        guard rd16(p, 0) == 1, rd16(p, 2) == ethIPv4,
              rd8(p, 4) == 6, rd8(p, 5) == 4 else { return }
        let oper = rd16(p, 6)
        let sha = rdMAC(p, 8)
        let spa = rd32(p, 14)
        if spa != 0 { arpLearn(spa, sha) }
        // Answer "who has ourIP?" with our MAC.
        guard oper == 1, rd32(p, 24) == ourIP else { return }
        let b = arpScratch
        wrMAC(b + 0, sha)                     // dst = requester
        wrMAC(b + 6, NetDev.mac)              // src = us
        wr16(b + 12, ethARP)
        let a = b + 14
        wr16(a + 0, 1)                        // htype = ethernet
        wr16(a + 2, ethIPv4)                  // ptype
        wr8(a + 4, 6)                         // hlen
        wr8(a + 5, 4)                         // plen
        wr16(a + 6, 2)                        // oper = reply
        wrMAC(a + 8, NetDev.mac)
        wr32(a + 14, ourIP)
        wrMAC(a + 18, sha)
        wr32(a + 24, spa)
        _ = NetDev.tx(UnsafeRawPointer(bitPattern: b)!, 14 + 28)
    }

    private static func handleIPv4(_ p: UnsafeRawPointer, _ len: Int, srcMAC: UInt64) {
        guard len >= 20 else { return }
        let vihl = rd8(p, 0)
        guard vihl >> 4 == 4 else { return }
        let ihl = Int(vihl & 0xF) * 4
        guard ihl >= 20, len >= ihl else { return }
        let totalLen = Int(rd16(p, 2))
        guard totalLen >= ihl, totalLen <= len else { return }
        guard rd32(p, 16) == ourIP else { return }     // addressed to us only
        if rd8(p, 9) == protoICMP {
            handleICMP(p + ihl, totalLen - ihl,
                       srcIP: rd32(p, 12), srcMAC: srcMAC,
                       ipHeader: p, ihl: ihl)
        }
    }

    private static func handleICMP(_ p: UnsafeRawPointer, _ len: Int,
                                   srcIP: UInt32, srcMAC: UInt64,
                                   ipHeader: UnsafeRawPointer, ihl: Int) {
        guard len >= 8 else { return }
        switch rd8(p, 0) {
        case 8:     // echo request → reply with the same id/seq/payload
            let totLen = ihl + len
            guard 14 + totLen <= 4096 else { return }
            let s = scratch
            UnsafeMutableRawPointer(bitPattern: s + 14)!
                .copyMemory(from: ipHeader, byteCount: totLen)
            let ip = s + 14
            wr32(ip + 12, ourIP)              // new src = us
            wr32(ip + 16, srcIP)              // new dst = requester
            wr8(ip + 8, 64)                   // ttl
            wr16(ip + 10, 0)
            wr16(ip + 10, checksum(UnsafeRawPointer(bitPattern: ip)!, ihl))
            let icmp = ip + UInt(ihl)
            wr8(icmp + 0, 0)                  // type = echo reply
            wr16(icmp + 2, 0)
            wr16(icmp + 2, checksum(UnsafeRawPointer(bitPattern: icmp)!, len))
            wrMAC(s + 0, srcMAC)              // reply straight to the sender
            wrMAC(s + 6, NetDev.mac)
            wr16(s + 12, ethIPv4)
            _ = NetDev.tx(UnsafeRawPointer(bitPattern: s)!, 14 + totLen)
        case 0:     // echo reply — record it for ping()
            guard rd16(p, 4) == pingID else { return }
            lastReplySeq = Int(rd16(p, 6))
            lastReplySrc = srcIP
            lastReplyTTL = Int(rd8(ipHeader, 8))
            lastReplyBytes = len
        default:
            break
        }
    }

    // MARK: - ARP cache / resolution

    private static func arpLookup(_ ip: UInt32) -> UInt64? {
        for e in arpCache where e.ip == ip { return e.mac }
        return nil
    }

    private static func arpLearn(_ ip: UInt32, _ mac: UInt64) {
        for i in arpCache.indices where arpCache[i].ip == ip {
            arpCache[i] = ARPEntry(ip: ip, mac: mac)
            return
        }
        if arpCache.count < arpCapacity {
            arpCache.append(ARPEntry(ip: ip, mac: mac))
        } else {
            arpCache[arpNextSlot] = ARPEntry(ip: ip, mac: mac)
            arpNextSlot = (arpNextSlot + 1) % arpCapacity
        }
    }

    private static func sendArpRequest(_ target: UInt32) {
        let b = arpScratch
        wrMAC(b + 0, broadcastMAC)
        wrMAC(b + 6, NetDev.mac)
        wr16(b + 12, ethARP)
        let a = b + 14
        wr16(a + 0, 1)
        wr16(a + 2, ethIPv4)
        wr8(a + 4, 6)
        wr8(a + 5, 4)
        wr16(a + 6, 1)                        // oper = request
        wrMAC(a + 8, NetDev.mac)
        wr32(a + 14, ourIP)
        wrMAC(a + 18, 0)
        wr32(a + 24, target)
        _ = NetDev.tx(UnsafeRawPointer(bitPattern: b)!, 14 + 28)
    }

    /// Synchronous resolve: up to 3 broadcast requests, 300 ms apart,
    /// pumping the rx queue while waiting. Nil when nobody answers.
    private static func arpResolve(_ ip: UInt32) -> UInt64? {
        if let m = arpLookup(ip) { return m }
        var attempt = 0
        while attempt < 3 {
            sendArpRequest(ip)
            let deadline = Clock.uptimeMs + 300
            while Clock.uptimeMs < deadline {
                NetDev.pollRx()
                if let m = arpLookup(ip) { return m }
                armWfi()
            }
            attempt += 1
        }
        return nil
    }

    // MARK: - IPv4 / ICMP transmit

    /// Wrap the payload already sitting at scratch+34 in IP + ethernet
    /// headers and transmit to `mac`.
    private static func sendIPv4To(_ mac: UInt64, dstIP: UInt32,
                                   proto: UInt8, payloadLen: Int) -> Bool {
        let totalLen = 20 + payloadLen
        let ip = scratch + 14
        wr8(ip + 0, 0x45)                     // version 4, ihl 5
        wr8(ip + 1, 0)                        // tos
        wr16(ip + 2, UInt16(totalLen))
        wr16(ip + 4, ipID)
        ipID &+= 1
        wr16(ip + 6, 0)                       // flags / fragment offset
        wr8(ip + 8, 64)                       // ttl
        wr8(ip + 9, proto)
        wr16(ip + 10, 0)
        wr32(ip + 12, ourIP)
        wr32(ip + 16, dstIP)
        wr16(ip + 10, checksum(UnsafeRawPointer(bitPattern: ip)!, 20))
        wrMAC(scratch + 0, mac)
        wrMAC(scratch + 6, NetDev.mac)
        wr16(scratch + 12, ethIPv4)
        return NetDev.tx(UnsafeRawPointer(bitPattern: scratch)!, 14 + totalLen)
    }

    private static func sendEchoRequest(to ip: UInt32, via mac: UInt64, seq: UInt16) {
        let icmp = scratch + 14 + 20
        wr8(icmp + 0, 8)                      // echo request
        wr8(icmp + 1, 0)
        wr16(icmp + 2, 0)
        wr16(icmp + 4, pingID)
        wr16(icmp + 6, seq)
        var i = 0
        while i < pingPayload {
            wr8(icmp + 8 + UInt(i), UInt8(truncatingIfNeeded: i + 0x10))
            i += 1
        }
        wr16(icmp + 2, checksum(UnsafeRawPointer(bitPattern: icmp)!, 8 + pingPayload))
        _ = sendIPv4To(mac, dstIP: ip, proto: protoICMP, payloadLen: 8 + pingPayload)
    }

    // MARK: - ping

    /// Send `count` ICMP echo requests to `ip` (packed big-endian), waiting
    /// up to 1 s for each reply while pumping the rx queue. Returns output
    /// lines shaped like real ping ("64 bytes from ...", "no answer from ...",
    /// plus a statistics summary).
    static func ping(_ ip: UInt32, count: Int) -> [String] {
        let n = max(1, min(count, 100))
        let host = dotted(ip)
        var lines: [String] = ["PING \(host) (\(host)): \(pingPayload) data bytes"]
        guard ready else {
            lines.append("ping: network unavailable")
            return lines
        }
        // Off-subnet destinations go via the gateway's MAC (slirp routes).
        let onSubnet = (ip & netmask) == (ourIP & netmask)
        let destMAC = arpResolve(onSubnet ? ip : gatewayIP)

        lastReplySeq = 0                        // below any real seq
        var received = 0
        var seq = 1
        while seq <= n {
            var answered = false
            if let mac = destMAC {
                sendEchoRequest(to: ip, via: mac, seq: UInt16(seq))
                let sentTicks = Clock.uptimeTicks
                let deadline = Clock.uptimeMs + 1000
                while Clock.uptimeMs < deadline {
                    NetDev.pollRx()
                    if lastReplySeq == seq && lastReplySrc == ip {
                        answered = true
                        break
                    }
                    armWfi()
                }
                if answered {
                    received += 1
                    let rttMs = Double(Clock.uptimeTicks &- sentTicks) * 1000.0
                        / Double(Clock.frequency)
                    lines.append("\(lastReplyBytes) bytes from \(host): icmp_seq=\(seq) "
                                 + "ttl=\(lastReplyTTL) time=\(NumFmt.f1(rttMs)) ms")
                }
            }
            if !answered {
                lines.append("no answer from \(host) (icmp_seq=\(seq))")
            }
            seq += 1
        }
        lines.append("--- \(host) ping statistics ---")
        let loss = 100.0 * Double(n - received) / Double(n)
        lines.append("\(n) packets transmitted, \(received) packets received, "
                     + "\(NumFmt.f1(loss))% packet loss")
        return lines
    }
}

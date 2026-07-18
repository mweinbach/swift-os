// C-runtime / Swift-runtime support symbols for bare-metal Embedded Swift.
// Heap-backed allocation routes into KernelHeap (see Heap.swift).

@_silgen_name("arm_read_cntfrq") func armReadCntfrq() -> UInt64
@_silgen_name("arm_read_cntpct") func armReadCntpct() -> UInt64
@_silgen_name("arm_read_current_el") func armReadCurrentEL() -> UInt64
@_silgen_name("arm_wfi") func armWfi()
@_silgen_name("arm_dsb_sy") func armDsbSy()
@_silgen_name("arm_isb") func armIsb()
@_silgen_name("arm_irq_enable") func armIrqEnable()
@_silgen_name("arm_irq_disable") func armIrqDisable()

@_cdecl("__stack_chk_fail")
public func stackCheckFail() -> Never {
    kpanic("stack check failed")
}

@_cdecl("posix_memalign")
public func posixMemalign(_ memptr: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                          _ alignment: Int, _ size: Int) -> Int32 {
    guard let p = KernelHeap.alloc(size: size, alignment: alignment) else {
        KernelHeap.noteOutOfMemory()    // one-shot '[heap] OUT OF MEMORY' report
        return 12
    } // ENOMEM
    memptr.pointee = p
    return 0
}

@_cdecl("free")
public func free_(_ ptr: UnsafeMutableRawPointer?) {
    KernelHeap.free(ptr)
}

@_cdecl("memset")
public func memset_(_ dst: UnsafeMutableRawPointer?, _ c: Int32, _ n: Int) -> UnsafeMutableRawPointer? {
    let p = dst!
    let v = UInt8(c & 0xff)
    var d = UInt(bitPattern: p)
    let alignedEnd = (d + 7) & ~UInt(7)
    var i = 0
    while d < alignedEnd && i < n { p.storeBytes(of: v, toByteOffset: i, as: UInt8.self); i += 1; d += 1 }
    let word = UInt64(v) * 0x0101_0101_0101_0101
    while i + 8 <= n { p.storeBytes(of: word, toByteOffset: i, as: UInt64.self); i += 8 }
    while i < n { p.storeBytes(of: v, toByteOffset: i, as: UInt8.self); i += 1 }
    return dst
}

@_cdecl("memcpy")
public func memcpy_(_ dst: UnsafeMutableRawPointer?, _ src: UnsafeRawPointer?, _ n: Int) -> UnsafeMutableRawPointer? {
    let d = dst!, s = src!
    var i = 0
    while i + 8 <= n {
        d.storeBytes(of: s.load(fromByteOffset: i, as: UInt64.self), toByteOffset: i, as: UInt64.self)
        i += 8
    }
    while i < n {
        d.storeBytes(of: s.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self)
        i += 1
    }
    return dst
}

@_cdecl("memmove")
public func memmove_(_ dst: UnsafeMutableRawPointer?, _ src: UnsafeRawPointer?, _ n: Int) -> UnsafeMutableRawPointer? {
    let d = UInt(bitPattern: dst), s = UInt(bitPattern: src)
    if d == s || n == 0 { return dst }
    if d < s {
        return memcpy_(dst, src, n)
    }
    for i in stride(from: n - 1, through: 0, by: -1) {
        dst!.storeBytes(of: src!.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self)
    }
    return dst
}

// Unicode data shims required by the embedded stdlib's String grapheme
// breaking. Every scalar reports "Other", which is correct for ASCII and
// merely imprecise for exotic multi-scalar emoji — acceptable for a console OS.

@_cdecl("_swift_stdlib_getGraphemeBreakProperty")
public func graphemeBreakProperty(_ scalar: UInt32) -> UInt8 { 0 }

@_cdecl("_swift_stdlib_isInCB_Consonant")
public func isInCBConsonant(_ scalar: UInt32) -> Bool { false }

// MARK: - libm / libc / misc shims

@_cdecl("sqrt")
public func sqrt_(_ x: Double) -> Double {
    // NOTE: Double.squareRoot() lowers to a call to `sqrt` on this target —
    // do NOT use it here (that recurses forever, and it did).
    if !(x > 0) { return x == 0 ? 0 : x / x } // 0 -> 0, negatives/NaN -> NaN
    var g = x >= 1 ? x : 1.0
    var i = 0
    while i < 100 {
        let next = (g + x / g) / 2
        if next == g { break }
        g = next
        i += 1
    }
    return g
}

@_cdecl("fmod")
public func fmod_(_ x: Double, _ y: Double) -> Double {
    let q = x / y
    if q != q || q > 9.0e18 || q < -9.0e18 { return 0 } // NaN / out-of-range guard
    let t = Double(Int64(q)) // truncation toward zero
    return x - t * y
}

@_cdecl("memcmp")
public func memcmp_(_ a: UnsafeRawPointer?, _ b: UnsafeRawPointer?, _ n: Int) -> Int32 {
    var i = 0
    while i < n {
        let x = a!.load(fromByteOffset: i, as: UInt8.self)
        let y = b!.load(fromByteOffset: i, as: UInt8.self)
        if x != y { return Int32(x) - Int32(y) }
        i += 1
    }
    return 0
}

private var rngState: UInt64 = 0x2545_f491_4f6c_dd1d

@_cdecl("arc4random_buf")
public func arc4randomBuf(_ buf: UnsafeMutableRawPointer, _ n: Int) {
    var i = 0
    while i < n {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        buf.storeBytes(of: UInt8(truncatingIfNeeded: rngState), toByteOffset: i, as: UInt8.self)
        i += 1
    }
}

// MARK: - Unicode data shims (extended set).
// Only safe for ASCII: these back the stdlib's non-ASCII slow paths
// (case mapping, normalization, grapheme properties). ASCII input never
// reaches them; feeding exotic Unicode may misbehave but will not crash.

@_cdecl("_swift_stdlib_getBinaryProperties")
public func unicodeBinaryProperties(_ scalar: UInt32) -> UInt64 { 0 }

@_cdecl("_swift_stdlib_getNumericType")
public func unicodeNumericType(_ scalar: UInt32) -> UInt8 { 0 }

@_cdecl("_swift_stdlib_getNormData")
public func unicodeNormData(_ scalar: UInt32) -> UInt16 { 0 }

@_cdecl("_swift_stdlib_getMapping")
public func unicodeMapping(_ scalar: UInt32, _ mapping: UInt8) -> Int32 {
    // mapping: 0 = lowercase, 1 = uppercase (per stdlib convention); ASCII-correct.
    if mapping == 0 {
        if scalar >= 65 && scalar <= 90 { return Int32(scalar) + 32 }
    } else {
        if scalar >= 97 && scalar <= 122 { return Int32(scalar) - 32 }
    }
    return Int32(scalar)
}

@_cdecl("_swift_stdlib_getSpecialMapping")
public func unicodeSpecialMapping(_ scalar: UInt32, _ what: UInt8,
                                  _ outCount: UnsafeMutablePointer<Int>?) -> UnsafePointer<UInt8>? {
    if let outCount { outCount.pointee = 0 }
    return nil
}

@_cdecl("_swift_stdlib_getComposition")
public func unicodeComposition(_ x: UInt32, _ y: UInt32) -> UInt32 { 0xFFFFFFFF }

@_cdecl("_swift_stdlib_getDecompositionEntry")
public func unicodeDecompositionEntry(_ scalar: UInt32) -> UInt32 { 0 }

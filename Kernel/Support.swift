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
    guard let p = KernelHeap.alloc(size: size, alignment: alignment) else { return 12 } // ENOMEM
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

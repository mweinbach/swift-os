import _Volatile

// Volatile MMIO accessors — never cached or reordered by the compiler.

@inline(__always)
func mmioRead32(_ address: UInt) -> UInt32 {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: address).load()
}

@inline(__always)
func mmioWrite32(_ address: UInt, _ value: UInt32) {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: address).store(value)
}

@inline(__always)
func mmioRead64(_ address: UInt) -> UInt64 {
    VolatileMappedRegister<UInt64>(unsafeBitPattern: address).load()
}

@inline(__always)
func mmioWrite64(_ address: UInt, _ value: UInt64) {
    VolatileMappedRegister<UInt64>(unsafeBitPattern: address).store(value)
}

@inline(__always)
func mmioSetBits32(_ address: UInt, _ bits: UInt32) {
    mmioWrite32(address, mmioRead32(address) | bits)
}

@inline(__always)
func mmioClearBits32(_ address: UInt, _ bits: UInt32) {
    mmioWrite32(address, mmioRead32(address) & ~bits)
}

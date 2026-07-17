# SwiftOS — bare-metal Swift kernel + userland, for QEMU's aarch64 virt machine.

SWIFTC  := $(HOME)/Library/Developer/Toolchains/swift-6.2-RELEASE.xctoolchain/usr/bin/swiftc
LLD     := $(HOME)/.swiftly/bin/ld.lld
CLANG   := xcrun clang
QEMU    := qemu-system-aarch64

SWIFTFLAGS := -target aarch64-none-none-elf \
              -enable-experimental-feature Embedded \
              -wmo -Osize -parse-as-library -module-name SwiftOS

KERNEL_SRC   := $(wildcard Kernel/*.swift)
USERLAND_SRC := $(wildcard Userland/*.swift)
ASM_SRC      := $(wildcard Kernel/*.S)
ASM_OBJ      := $(patsubst Kernel/%.S,build/%.o,$(ASM_SRC))

QEMUFLAGS := -M virt -cpu cortex-a72 -m 512M \
             -device ramfb \
             -device virtio-keyboard-device \
             -device virtio-tablet-device \
             -global virtio-mmio.force-legacy=on

.PHONY: all run serial font app clean

all: build/swiftos.elf

build:
	mkdir -p build

build/swift.o: $(KERNEL_SRC) $(USERLAND_SRC) | build
	$(SWIFTC) $(SWIFTFLAGS) -c $(KERNEL_SRC) $(USERLAND_SRC) -o $@

build/%.o: Kernel/%.S | build
	$(CLANG) --target=aarch64-none-elf -c $< -o $@

build/swiftos.elf: build/swift.o $(ASM_OBJ) link.ld
	$(LLD) -T link.ld $(ASM_OBJ) build/swift.o -o $@

# Graphical run: cocoa window (ramfb), serial mirrored to build/serial.log
run: build/swiftos.elf
	$(QEMU) $(QEMUFLAGS) -display cocoa -serial file:build/serial.log \
	  -kernel build/swiftos.elf

# Headless serial run (Ctrl-A X to quit)
serial: build/swiftos.elf
	$(QEMU) $(QEMUFLAGS) -nographic -kernel build/swiftos.elf

# Regenerate the bitmap font compiled into the kernel (runs on macOS/CoreText)
font:
	xcrun swift tools/genfont.swift > Userland/FontData.swift

# macOS dev-harness app
app:
	cd Host-macOS && xcrun swift build

clean:
	rm -rf build

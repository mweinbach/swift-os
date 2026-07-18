// SwiftOS EL0 demo program — pure position-independent aarch64, no libc,
// no external symbols. Linked flat at address 0 by tools/mkblob.py; the
// kernel copies the image to the start of an EL0-mapped page and enters at
// offset 0 with SP = top of a separate user stack page.
//
// Two run modes, selected by x0 at entry (x1 carries the process serial):
//   mode 0 — LEGACY synchronous demo (UserProcess.runDemo, main thread):
//            hello + uptime, a 30 ms spin to prove IRQ preemption across
//            EL0, a yield, a done line, exit(0). Byte-for-byte the
//            original behaviour; udemo stays instant.
//   mode 1 — SCHEDULED user process (UserProcess.spawn): prints a tagged
//            hello ("user<N> alive at EL0..."), then ~5 s of svc yields
//            with a progress dot every ~1 s, a done line and exit(0) —
//            long enough to watch it in ps/top, preempt and kill it.
//
// Syscall ABI (svc #0, number in x8, args x0-x5, result in x0):
//   0 = write(fd, buf, len)   fd 1 only; bytes are captured by the kernel
//   1 = uptime_ms()           returns milliseconds since boot in x0
//   2 = exit(code)            never returns
//   3 = yield()               hands the CPU to the kernel scheduler

.text
.globl _start
_start:
    mov     x19, x0                     // run mode (survives svc: x19-x29 do)
    mov     x20, x1                     // process serial N
    cbnz    x19, scheduled

// ---------------------------------------------------------------------------
// Legacy mode (UserProcess.runDemo): unchanged round-2 behaviour.
// ---------------------------------------------------------------------------

    // write(1, msg_hello, MSG_HELLO_LEN)
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_hello
    mov     x2, #MSG_HELLO_LEN
    svc     #0

    // ms = uptime_ms(); decimal-convert into a stack scratch buffer
    // (digits accumulate reversed, then get mirrored in order).
    mov     x8, #1
    svc     #0
    sub     sp, sp, #48
    mov     x9, sp                      // reversed digits accumulate here
    mov     x10, #0                     // digit count
    mov     x11, #10
1:
    udiv    x12, x0, x11
    msub    x13, x12, x11, x0           // remainder = x0 - x12*10
    add     x13, x13, #'0'
    strb    w13, [x9, x10]
    add     x10, x10, #1
    mov     x0, x12
    cbnz    x0, 1b

    // write(1, "uptime: ", 8)
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_uptime
    mov     x2, #MSG_UPTIME_LEN
    svc     #0

    // Mirror the digits into [sp+24] in correct order.
    add     x14, sp, #24
    mov     x12, #0                     // output index
2:
    sub     x10, x10, #1
    ldrb    w13, [x9, x10]
    strb    w13, [x14, x12]
    add     x12, x12, #1
    cbnz    x10, 2b

    // write(1, sp+24, digitCount), then write(1, " ms\n", 4)
    mov     x8, #0
    mov     x0, #1
    add     x1, sp, #24
    mov     x2, x12
    svc     #0
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_ms
    mov     x2, #MSG_MS_LEN
    svc     #0
    add     sp, sp, #48

    // Spin on uptime_ms() until 30 ms have passed: guarantees a 100 Hz
    // timer IRQ lands while we are at EL0 and proves the kernel saves and
    // restores the EL0 context across preemption.
    mov     x8, #1
    svc     #0
    mov     x19, x0                     // start ms (no ABI to honor at EL0)
3:
    mov     x8, #1
    svc     #0
    sub     x9, x0, x19
    cmp     x9, #30
    b.lo    3b

    // yield()
    mov     x8, #3
    svc     #0

    // write(1, msg_done, MSG_DONE_LEN)
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_done
    mov     x2, #MSG_DONE_LEN
    svc     #0

    // exit(0)
    mov     x8, #2
    mov     x0, #0
    svc     #0
4:  b       4b                          // exit never returns; paranoia loop

// ---------------------------------------------------------------------------
// Scheduled mode (UserProcess.spawn): tagged hello, ~5 s of yields with a
// progress dot every ~1 s, done line, exit. Preemptible and killable the
// whole time — every loop iteration passes through the kernel.
// ---------------------------------------------------------------------------
scheduled:
    // write "user" + serial + " alive at EL0 (scheduled), uptime " + ms + " ms\n"
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_user
    mov     x2, #MSG_USER_LEN
    svc     #0
    mov     x0, x20                     // serial
    bl      print_dec
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_alive
    mov     x2, #MSG_ALIVE_LEN
    svc     #0
    mov     x8, #1
    svc     #0
    bl      print_dec
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_ms
    mov     x2, #MSG_MS_LEN
    svc     #0

    mov     x8, #1                      // start ms / last-dot ms
    svc     #0
    mov     x21, x0
    mov     x22, x0
    mov     x23, #5000                  // run length (~5 s)
5:
    mov     x8, #3                      // yield()
    svc     #0
    mov     x8, #1                      // uptime_ms()
    svc     #0
    mov     x9, x0
    sub     x10, x9, x22
    cmp     x10, #1000                  // a dot every ~1 s
    b.lo    6f
    mov     x22, x9
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_dot
    mov     x2, #MSG_DOT_LEN
    svc     #0
6:
    sub     x10, x9, x21
    cmp     x10, x23
    b.lo    5b

    // "\nuser" + serial + " done, exiting cleanly\n"
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_nluser
    mov     x2, #MSG_NLUSER_LEN
    svc     #0
    mov     x0, x20
    bl      print_dec
    mov     x8, #0
    mov     x0, #1
    adr     x1, msg_fin
    mov     x2, #MSG_FIN_LEN
    svc     #0

    // exit(0)
    mov     x8, #2
    mov     x0, #0
    svc     #0
7:  b       7b                          // exit never returns; paranoia loop

// print_dec(x0): write x0 in decimal to fd 1.
// Clobbers x9-x14 only; x30 is saved on the stack (an svc inside preserves
// it anyway via the kernel's exception frame — belt and braces).
print_dec:
    sub     sp, sp, #64
    str     x30, [sp, #48]
    mov     x9, sp                      // reversed digits accumulate here
    mov     x10, #0                     // digit count
    mov     x11, #10
1:
    udiv    x12, x0, x11
    msub    x13, x12, x11, x0           // remainder = x0 - x12*10
    add     x13, x13, #'0'
    strb    w13, [x9, x10]
    add     x10, x10, #1
    mov     x0, x12
    cbnz    x0, 1b
    add     x14, sp, #24                // mirror into [sp+24] in order
    mov     x12, #0
2:
    sub     x10, x10, #1
    ldrb    w13, [x9, x10]
    strb    w13, [x14, x12]
    add     x12, x12, #1
    cbnz    x10, 2b
    mov     x8, #0
    mov     x0, #1
    add     x1, sp, #24
    mov     x2, x12
    svc     #0
    ldr     x30, [sp, #48]
    add     sp, sp, #64
    ret

msg_hello:  .ascii "hello from EL0 (pid-less user code)\n"
msg_hello_end:
msg_uptime: .ascii "uptime: "
msg_uptime_end:
msg_ms:     .ascii " ms\n"
msg_ms_end:
msg_done:   .ascii "EL0 spin survived IRQ preemption; exiting cleanly\n"
msg_done_end:

msg_user:   .ascii "user"
msg_user_end:
msg_alive:  .ascii " alive at EL0 (scheduled), uptime "
msg_alive_end:
msg_dot:    .ascii "."
msg_dot_end:
msg_nluser: .ascii "\nuser"
msg_nluser_end:
msg_fin:    .ascii " done, exiting cleanly\n"
msg_fin_end:

.equ MSG_HELLO_LEN,  msg_hello_end - msg_hello
.equ MSG_UPTIME_LEN, msg_uptime_end - msg_uptime
.equ MSG_MS_LEN,     msg_ms_end - msg_ms
.equ MSG_DONE_LEN,   msg_done_end - msg_done
.equ MSG_USER_LEN,   msg_user_end - msg_user
.equ MSG_ALIVE_LEN,  msg_alive_end - msg_alive
.equ MSG_DOT_LEN,    msg_dot_end - msg_dot
.equ MSG_NLUSER_LEN, msg_nluser_end - msg_nluser
.equ MSG_FIN_LEN,    msg_fin_end - msg_fin

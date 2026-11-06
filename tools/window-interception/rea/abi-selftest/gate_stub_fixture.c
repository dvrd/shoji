// Validates the exact transaction-gate stub bytes the payload writes:
// movz w1, #op; ldr x16, #8; br x16; .quad impl (20 bytes, 32-byte slot).
// The previous layout placed a pad at +12, so the ldr consumed the pad and
// branched to impl_low32<<32, crashing WindowServer. Run on arm64 host.
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

static uint64_t marker_impl(uint64_t ctx, uint64_t op) {
    return op * 1000 + ctx;
}

int main(void) {
    uint8_t *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) { perror("mmap"); return 1; }
    uint64_t impl = (uint64_t)&marker_impl;
    for (uint32_t op = 1; op <= 3; op++) {
        uint8_t *slot = page + (op - 1) * 32;
        uint32_t *w = (uint32_t *)slot;
        w[0] = 0x52800001 | (op << 5); /* movz w1, #op */
        w[1] = 0x58000050;             /* ldr x16, #8 -> slot+12 */
        w[2] = 0xD61F0200;             /* br x16 */
        *(uint64_t *)(slot + 12) = impl;
    }
    __builtin___clear_cache((char *)page, (char *)page + 4096);
    if (mprotect(page, 4096, PROT_READ | PROT_EXEC) != 0) { perror("mprotect"); return 1; }
    int failures = 0;
    for (uint32_t op = 1; op <= 3; op++) {
        uint64_t (*fn)(uint64_t) = (uint64_t (*)(uint64_t))(page + (op - 1) * 32);
        uint64_t got = fn(42);
        uint64_t want = (uint64_t)op * 1000 + 42;
        printf("op %u: got=%llu want=%llu %s\n", op,
               (unsigned long long)got, (unsigned long long)want,
               got == want ? "ok" : "MISMATCH");
        if (got != want) failures++;
    }
    return failures ? 1 : 0;
}

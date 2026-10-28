#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Owned data only. No SkyLight calls, runtime attachment or code modification.
typedef int32_t (*ordering_callback)(void *, const uint32_t *, const int32_t *,
                                    const uint32_t *, uint32_t, bool);

struct fixture_context {
    uint64_t magic;
    uint32_t calls;
};

__attribute__((noinline))
static void shoji_abi_nonleaf(void) {
    __asm__ __volatile__("" ::: "memory");
}

__attribute__((noinline))
int32_t shoji_abi_original(void *opaque, const uint32_t *ids, const int32_t *ops,
                           const uint32_t *relative, uint32_t count, bool flag) {
    shoji_abi_nonleaf();
    struct fixture_context *context = opaque;
    if (context == NULL || context->magic != UINT64_C(0x13579bdf2468ace0)) {
        return -901;
    }
    context->calls++;
    if (count == 0) {
        return ids == NULL && ops == NULL && relative == NULL ? -304 : -902;
    }
    if (count != 3 || ids == NULL || ops == NULL || relative == NULL) {
        return -903;
    }
    if (ids[0] != UINT32_C(0x80000001) || ids[1] != UINT32_MAX || ids[2] != 7 ||
        ops[0] != -1 || ops[1] != 0 || ops[2] != 1 ||
        relative[0] != 0 || relative[1] != UINT32_MAX ||
        relative[2] != UINT32_C(0x80000002)) {
        return -904;
    }
    return flag ? -1001 : INT32_C(0x76543210);
}

int32_t shoji_abi_run(ordering_callback callback) {
    if (callback == NULL) {
        return 1;
    }
    struct fixture_context context = {UINT64_C(0x13579bdf2468ace0), 0};
    const uint32_t ids[] = {UINT32_C(0x80000001), UINT32_MAX, 7};
    const int32_t ops[] = {-1, 0, 1};
    const uint32_t relative[] = {0, UINT32_MAX, UINT32_C(0x80000002)};
    if (callback(&context, ids, ops, relative, 3, false) != INT32_C(0x76543210)) {
        return 2;
    }
    if (callback(&context, ids, ops, relative, 3, true) != -1001) {
        return 3;
    }
    if (callback(&context, NULL, NULL, NULL, 0, false) != -304 ||
        callback(&context, NULL, NULL, NULL, 0, true) != -304) {
        return 4;
    }
    return context.calls == 4 ? 0 : 5;
}

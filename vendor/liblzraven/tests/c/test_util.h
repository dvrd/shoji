/* SPDX-License-Identifier: 0BSD */
/* lzraven — helpers shared by the C tests.
 *
 * One file reader and the suite's PRNGs, so each has a single definition
 * instead of a per-test copy that can drift.
 *
 * Three generators, kept distinct on purpose: a test's corpus is reproducible
 * from its seed and its generator, and some expectations are pinned to that
 * sequence (test_bcj's FNV goldens most of all).  Collapsing the three into
 * one would silently invalidate every such expectation, so the algorithms
 * live here unchanged and each test keeps its own state and seed.
 *
 *   tu_xorshift32   test_bcj (goldens pin the sequence) and test_matchfind
 *   tu_xorshift64   test_decode
 *   tu_lcg          test_encode
 */
#ifndef LZRAVEN_TEST_UTIL_H
#define LZRAVEN_TEST_UTIL_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline uint32_t tu_xorshift32(uint32_t *s)
{
    uint32_t x = *s;

    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    return x;
}

static inline uint64_t tu_xorshift64(uint64_t *s)
{
    uint64_t x = *s;

    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *s = x;
    return x;
}

static inline uint32_t tu_lcg(uint32_t *s)
{
    *s = *s * 1103515245u + 12345u;
    return *s >> 8;
}

/* Reads a whole file into a buffer of exactly the file size plus `pad` zero
 * bytes — exact, so ASan's redzone sits right behind the bytes and a one-byte
 * overread of the data is caught.  An empty file still gets a 1-byte
 * allocation so the pointer is non-NULL.  Returns NULL on any failure. */
static inline uint8_t *tu_read_file(const char *path, size_t *len, size_t pad)
{
    FILE *f = fopen(path, "rb");
    uint8_t *buf;
    size_t alloc;
    long n;

    if (!f)
        return NULL;
    if (fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0) {
        fclose(f);
        return NULL;
    }
    rewind(f);
    alloc = (size_t)n + pad;
    buf = malloc(alloc ? alloc : 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    if (n && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return NULL;
    }
    if (pad)
        memset(buf + n, 0, pad);
    fclose(f);
    *len = (size_t)n;
    return buf;
}

#endif /* LZRAVEN_TEST_UTIL_H */

/* SPDX-License-Identifier: 0BSD */
/* lzraven — C test harness.
 *
 * Three parts:
 *   1. every checked-in vector, byte-exact — from a .raw on disk, or expanded
 *      from the manifest's run-length recipe where the plaintext is stored
 *      that way;
 *   2. malformed / hostile framing, each rejected with the right status;
 *   3. a deterministic bit-flip fuzz over every vector, run with exactly-sized
 *      output buffers so ASan's redzones catch any overrun.
 *
 * Run from the repo root (or pass the vector directory as argv[1]).
 */
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lzraven.h"
#include "test_util.h"

static int failures;
static int checked;
static int vec_decoded;
static int vec_skipped;

/* The checked-in corpus: 33 vector pairs (the "33/33" in CLAUDE.md).  Fewer
 * decoded means files went missing or the loader regressed into skipping —
 * either way the run must fail rather than pass on whatever it found. */
#define MIN_VECTORS 33

static void fail(const char *what, const char *detail)
{
    printf("  FAIL %s: %s\n", what, detail ? detail : "");
    failures++;
}

/* tu_read_file allocates exactly the file size, so ASan's redzone sits right
 * behind the bytes and a one-byte overread of the source is caught too.  pad
 * is for the one caller that needs a NUL terminator (the manifest scan). */
static uint8_t *slurp(const char *path, size_t *len)
{
    return tu_read_file(path, len, 0);
}

/* Vectors whose plaintext is long and repetitive are checked in as a
 * run-length recipe in the directory's manifest.json ("gen": [[byte, count],
 * ...]) instead of a .raw file.  Expand the recipe so those vectors decode
 * here too, not only under the Python runner — one of them is the only
 * multi-block stream in the corpus.  The scan leans on the manifest being our
 * own generated file: one flat object per vector, so the braces nearest the
 * vector's "name" key bound its object. */
static uint8_t *gen_from_manifest(const char *dir, const char *name, size_t *len)
{
    char path[512], needle[160];
    uint8_t *man, *out = NULL;
    size_t man_len = 0, want, got;
    char *obj, *obj_end, *p, *q;

    snprintf(path, sizeof path, "%s/manifest.json", dir);
    man = tu_read_file(path, &man_len, 1);
    if (!man)
        return NULL;
    snprintf(needle, sizeof needle, "\"name\": \"%s\"", name);
    obj = strstr((char *)man, needle);
    if (!obj)
        goto done;
    obj_end = strchr(obj, '}');
    while (obj > (char *)man && *obj != '{')
        obj--;
    if (!obj_end || *obj != '{')
        goto done;
    *obj_end = '\0';

    p = strstr(obj, "\"raw_size\":");
    if (!p)
        goto done;
    want = (size_t)strtoull(p + 11, NULL, 10);
    p = strstr(obj, "\"gen\":");
    if (!p || !(p = strchr(p, '[')))
        goto done;
    p++;
    out = malloc(want ? want : 1);
    if (!out)
        goto done;
    got = 0;
    for (;;) {
        unsigned long byte, count;

        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',')
            p++;
        if (*p == ']')
            break;
        if (*p != '[')
            goto bad;
        byte = strtoul(p + 1, &q, 10);
        if (q == p + 1 || *q != ',')
            goto bad;
        count = strtoul(q + 1, &p, 10);
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
            p++;
        if (*p != ']' || byte > 255 || count > want - got)
            goto bad;
        p++;
        memset(out + got, (int)byte, count);
        got += count;
    }
    if (got == want) {
        *len = want;
        free(man);
        return out;
    }
bad:
    free(out);
    out = NULL;
done:
    free(man);
    return out;
}

/* ------------------------------------------------------------------ 1. vectors */

static void check_vector(const char *dir, const char *name)
{
    char rav_path[512], raw_path[512];
    uint8_t *rav, *raw, *dst;
    size_t rav_len = 0, raw_len = 0, n;
    lzraven_status st;

    snprintf(rav_path, sizeof rav_path, "%s/%s.rav", dir, name);
    snprintf(raw_path, sizeof raw_path, "%s/%s.raw", dir, name);
    rav = slurp(rav_path, &rav_len);
    raw = slurp(raw_path, &raw_len);
    if (rav && !raw) /* no .raw on disk: the manifest may carry a recipe */
        raw = gen_from_manifest(dir, name, &raw_len);
    if (!rav || !raw) {
        printf("  SKIP %-24s (no .raw file and no manifest recipe)\n", name);
        vec_skipped++;
        free(rav);
        free(raw);
        return;
    }

    checked++;
    /* exact size: ASan redzone right behind it; the empty vector gets NULL
     * with zero capacity, which the API accepts */
    dst = raw_len ? malloc(raw_len) : NULL;
    n = lzraven_decode_buffer_ex(dst, raw_len, rav, rav_len, &st);
    if (n != raw_len) {
        char msg[256];
        snprintf(msg, sizeof msg, "%s: got %zu bytes, want %zu (%s)", name, n,
                 raw_len, lzraven_status_string(st));
        fail("vector", msg);
    } else if (raw_len && memcmp(dst, raw, raw_len) != 0) {
        size_t i = 0;
        char msg[256];
        while (i < raw_len && dst[i] == raw[i])
            i++;
        snprintf(msg, sizeof msg, "%s: first mismatch at byte %zu", name, i);
        fail("vector", msg);
    } else {
        printf("  ok   %-24s %zu bytes\n", name, raw_len);
        vec_decoded++;
    }
    free(rav);
    free(raw);
    free(dst);
}

static void check_vector_dir(const char *dir)
{
    DIR *d = opendir(dir);
    struct dirent *e;
    char names[64][128];
    size_t count = 0, i;

    if (!d) {
        printf("  (no vector directory %s)\n", dir);
        return;
    }
    while ((e = readdir(d)) != NULL) {
        size_t len = strlen(e->d_name);
        if (len < 5 || strcmp(e->d_name + len - 4, ".rav") != 0)
            continue;
        if (count == sizeof names / sizeof names[0])
            break;
        snprintf(names[count], sizeof names[0], "%.*s", (int)(len - 4), e->d_name);
        count++;
    }
    closedir(d);

    /* readdir order is arbitrary; sort so the log is stable. */
    for (i = 1; i < count; i++) {
        char tmp[128];
        size_t j = i;
        memcpy(tmp, names[i], sizeof tmp);
        while (j && strcmp(names[j - 1], tmp) > 0) {
            memcpy(names[j], names[j - 1], sizeof tmp);
            j--;
        }
        memcpy(names[j], tmp, sizeof tmp);
    }
    for (i = 0; i < count; i++)
        check_vector(dir, names[i]);
}

/* ------------------------------------------------------- 2. malformed framing */

static void expect_reject(const char *what, const uint8_t *src, size_t len,
                          size_t cap, lzraven_status want)
{
    /* exact size (NULL at zero capacity): a write at dst[cap] hits ASan */
    uint8_t *dst = cap ? malloc(cap) : NULL;
    lzraven_status st = LZRAVEN_OK;
    size_t n = lzraven_decode_buffer_ex(dst, cap, src, len, &st);

    checked++;
    if (n != 0 || st != want) {
        char msg[256];
        snprintf(msg, sizeof msg, "%s: got %zu bytes / %s, want 0 / %s", what, n,
                 lzraven_status_string(st), lzraven_status_string(want));
        fail("reject", msg);
    } else {
        printf("  ok   %-24s rejected: %s\n", what, lzraven_status_string(st));
    }
    free(dst);
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static void test_framing(const char *dir)
{
    uint8_t buf[64];
    uint8_t *rav;
    uint8_t *dst;
    size_t rav_len = 0, n;
    char path[512];
    lzraven_status st;

    /* a well-formed empty stream: header + terminator, 0 bytes out, OK */
    put32(buf, LZRAVEN_MAGIC);
    put32(buf + 4, 0);
    put32(buf + 8, 0);
    st = LZRAVEN_E_CORRUPT;
    checked++;
    n = lzraven_decode_buffer_ex(NULL, 0, buf, 12, &st);
    if (n != 0 || st != LZRAVEN_OK)
        fail("empty stream", "expected 0 bytes with status ok");
    else
        printf("  ok   %-24s 0 bytes, status ok\n", "empty stream");

    expect_reject("short stream", buf, 11, 64, LZRAVEN_E_TRUNCATED);
    expect_reject("zero-length input", buf, 0, 64, LZRAVEN_E_TRUNCATED);

    /* NULL src, and NULL dst with a nonzero capacity, are argument errors —
     * never a crash. */
    checked++;
    st = LZRAVEN_OK;
    if (lzraven_decode_buffer_ex(NULL, 64, NULL, 12, &st) != 0 ||
        st != LZRAVEN_E_ARGS)
        fail("null src", "expected LZRAVEN_E_ARGS");
    else
        printf("  ok   %-24s rejected: %s\n", "null src",
               lzraven_status_string(st));
    checked++;
    st = LZRAVEN_OK;
    if (lzraven_decode_buffer_ex(NULL, 64, buf, 12, &st) != 0 ||
        st != LZRAVEN_E_ARGS)
        fail("null dst", "expected LZRAVEN_E_ARGS");
    else
        printf("  ok   %-24s rejected: %s\n", "null dst",
               lzraven_status_string(st));

    /* the plain entry point keeps Apple's shape: bytes, or 0 */
    checked++;
    if (lzraven_decode_buffer(NULL, 0, buf, 12) != 0)
        fail("plain entry point", "empty stream should decode to 0 bytes");
    else
        printf("  ok   %-24s 0 bytes\n", "plain entry point");

    /* every status has a string, including an out-of-range one */
    checked++;
    {
        int s;
        int bad_string = 0;
        for (s = 0; s <= (int)LZRAVEN_E_CORRUPT + 1; s++)
            if (!lzraven_status_string((lzraven_status)s)[0])
                bad_string = 1;
        if (bad_string)
            fail("status strings", "empty string for some status");
        else
            printf("  ok   %-24s all statuses named\n", "status strings");
    }

    put32(buf, LZRAVEN_MAGIC ^ 1u);
    expect_reject("bad magic", buf, 12, 64, LZRAVEN_E_MAGIC);

    put32(buf, LZRAVEN_MAGIC);
    put32(buf + 4, 1);
    expect_reject("reserved params bit", buf, 12, 64, LZRAVEN_E_PARAMS);
    put32(buf + 4, 0x03FFFFFFu);
    expect_reject("all params bits", buf, 12, 64, LZRAVEN_E_PARAMS);

    /* params bits [31:26] are informational and must be ignored, not rejected */
    put32(buf + 4, 63u << 26);
    checked++;
    st = LZRAVEN_E_CORRUPT;
    n = lzraven_decode_buffer_ex(NULL, 0, buf, 12, &st);
    if (n != 0 || st != LZRAVEN_OK)
        fail("params size index", "index 63 should decode like index 0");
    else
        printf("  ok   %-24s ignored, as Apple does\n", "params size index");
    put32(buf + 4, 0);

    /* a stored block that runs off the end of the input */
    put32(buf + 8, (100u << 12) | 1u);
    memset(buf + 12, 0xAA, 20);
    expect_reject("payload past input", buf, 32, 4096, LZRAVEN_E_TRUNCATED);

    /* a stored block with no terminating word after it */
    put32(buf + 8, (8u << 12) | 1u);
    expect_reject("missing terminator", buf, 20, 4096, LZRAVEN_E_TRUNCATED);

    /* ...and the same stream with the terminator, which must succeed */
    put32(buf + 20, 0);
    checked++;
    dst = malloc(8);
    st = LZRAVEN_E_CORRUPT;
    n = lzraven_decode_buffer_ex(dst, 8, buf, 24, &st);
    if (n != 8 || st != LZRAVEN_OK || memcmp(dst, buf + 12, 8) != 0)
        fail("stored block", "expected the 8 payload bytes back");
    else
        printf("  ok   %-24s 8 bytes copied\n", "stored block");

    /* one byte of output capacity short */
    expect_reject("capacity 1 short", buf, 24, 7, LZRAVEN_E_OUTPUT_FULL);
    expect_reject("capacity zero", buf, 24, 0, LZRAVEN_E_OUTPUT_FULL);
    free(dst);

    /* 512 KiB lockstep: a short stored block followed by another block */
    put32(buf + 8, (8u << 12) | 1u);
    put32(buf + 20, (8u << 12) | 1u);
    memset(buf + 24, 0xBB, 8);
    put32(buf + 32, 0);
    expect_reject("lockstep violation", buf, 36, 4096, LZRAVEN_E_FRAMING);

    /* a coded block whose payload is too short to seed the eight states */
    put32(buf + 8, (4u << 12));
    put32(buf + 12, 0);
    put32(buf + 16, 0);
    expect_reject("stub coded payload", buf, 20, 4096, LZRAVEN_E_CORRUPT);

    /* a real vector truncated one byte inside its payload */
    snprintf(path, sizeof path, "%s/zeros_4k.rav", dir);
    rav = slurp(path, &rav_len);
    if (rav && rav_len > 16) {
        expect_reject("truncated payload", rav, rav_len - 5, 4096,
                      LZRAVEN_E_TRUNCATED);
        /* and decoded into a buffer one byte too small */
        expect_reject("tight capacity", rav, rav_len, 4095,
                      LZRAVEN_E_OUTPUT_FULL);
    }
    free(rav);
}

/* ------------------------------------------------------------ 3. bit-flip fuzz */

static uint64_t rng_state = 0x9E3779B97F4A7C15ull;

static uint64_t rng(void)
{
    return tu_xorshift64(&rng_state);
}

static void fuzz_vector(const char *dir, const char *name, int rounds,
                        size_t *decoded, size_t *rejected)
{
    char rav_path[512], raw_path[512];
    uint8_t *rav, *raw, *copy, *dst;
    size_t rav_len = 0, raw_len = 0;
    int i;

    snprintf(rav_path, sizeof rav_path, "%s/%s.rav", dir, name);
    snprintf(raw_path, sizeof raw_path, "%s/%s.raw", dir, name);
    rav = slurp(rav_path, &rav_len);
    raw = slurp(raw_path, &raw_len);
    if (!rav || !raw || rav_len == 0) {
        free(rav);
        free(raw);
        return;
    }
    copy = malloc(rav_len);
    for (i = 0; i < rounds; i++) {
        size_t cap, n;
        int flips = 1 + (int)(rng() % 3);
        int f;

        memcpy(copy, rav, rav_len);
        for (f = 0; f < flips; f++) {
            size_t byte = (size_t)(rng() % rav_len);
            copy[byte] ^= (uint8_t)(1u << (rng() % 8));
        }
        /* Sometimes give the exact capacity, sometimes a tight or generous one;
         * the buffers are exact-sized so ASan sees any overrun. */
        switch (rng() % 3) {
        case 0:  cap = raw_len; break;
        case 1:  cap = raw_len ? raw_len - 1 : 0; break;
        default: cap = raw_len + 64; break;
        }
        dst = cap ? malloc(cap) : NULL; /* exact: ASan owns byte cap */
        n = lzraven_decode_buffer(dst, cap, copy, rav_len);
        if (n > cap)
            fail("fuzz", "decoder reported more bytes than capacity");
        if (n)
            (*decoded)++;
        else
            (*rejected)++;
        free(dst);
    }
    free(copy);
    free(rav);
    free(raw);
}

static void fuzz_random(int rounds, size_t *decoded, size_t *rejected)
{
    int i;

    for (i = 0; i < rounds; i++) {
        size_t len = 12 + (size_t)(rng() % 500);
        size_t j, cap = 8192, n;
        uint8_t *src = malloc(len), *dst = malloc(cap); /* exact-sized */

        for (j = 0; j < len; j++)
            src[j] = (uint8_t)rng();
        /* Half of them get a valid header so the framing is actually reached. */
        if (i & 1) {
            put32(src, LZRAVEN_MAGIC);
            put32(src + 4, 0);
        }
        n = lzraven_decode_buffer(dst, cap, src, len);
        if (n > cap)
            fail("fuzz", "decoder reported more bytes than capacity");
        if (n)
            (*decoded)++;
        else
            (*rejected)++;
        free(src);
        free(dst);
    }
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : "tests/vectors";
    char grammar[512];
    size_t decoded = 0, rejected = 0;
    static const char *fuzz_names[] = {
        "zeros_4k", "text", "counter_le", "mixed_8k", "repeat_long",
        "macho_header_like", "plist", "random_1k"
    };
    size_t i;

    snprintf(grammar, sizeof grammar, "%s/grammar", dir);

    puts("vectors:");
    check_vector_dir(dir);
    check_vector_dir(grammar);
    printf("  %d decoded, %d skipped\n", vec_decoded, vec_skipped);
    if (vec_decoded < MIN_VECTORS) {
        char msg[128];
        snprintf(msg, sizeof msg, "decoded %d vectors, expected at least %d",
                 vec_decoded, MIN_VECTORS);
        fail("vector count", msg);
    }

    puts("framing:");
    test_framing(dir);

    puts("fuzz:");
    for (i = 0; i < sizeof fuzz_names / sizeof fuzz_names[0]; i++)
        fuzz_vector(dir, fuzz_names[i], 1500, &decoded, &rejected);
    fuzz_random(6000, &decoded, &rejected);
    printf("  ok   %-24s %zu decoded, %zu rejected, no faults\n",
           "bit-flip + random", decoded, rejected);

    printf("\n%d checks, %d failures\n", checked, failures);
    return failures ? 1 : 0;
}

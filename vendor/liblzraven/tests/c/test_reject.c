/* SPDX-License-Identifier: 0BSD */
/* test_reject — the rejection fixtures, through the C decoder itself.
 *
 * The .rav files in tests/vectors/known-divergence/ are streams we once
 * wrongly ACCEPTED (the coded-region overshoot bug); the .stricter files in
 * tests/vectors/apple-accepts/ are streams Apple accepts and we reject on
 * purpose (the state-drain check, SPEC.md §9).  Both READMEs pin the required
 * outcome: LZRAVEN_E_CORRUPT.
 *
 * tests/validate_symbols.py checks the same fixtures against the Python
 * reference decoder; this binary is the C library's own gate, so a regression
 * reintroducing either accept-gap fails `make test` rather than only the
 * oracle tier.  The directories are scanned, not hardcoded, and a minimum
 * count is enforced — an emptied fixture directory is a failure, not a pass.
 */
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lzraven.h>

#include "test_util.h"

/* Big enough that rejection can only come from the decoder's own checks:
 * undrained-state-2 would decode to 1,170,128 bytes if wrongly accepted, and a
 * capacity smaller than that would fail with E_OUTPUT_FULL before the drain
 * check is ever reached. */
#define DST_CAP (2u << 20)

static int fail;

static uint8_t *read_file(const char *path, size_t *len)
{
    uint8_t *buf = tu_read_file(path, len, 0);

    if (!buf) {
        fprintf(stderr, "FAIL %s: cannot read\n", path);
        fail = 1;
    }
    return buf;
}

static void check_reject(const char *path, uint8_t *dst)
{
    size_t src_len, got;
    uint8_t *src = read_file(path, &src_len);
    lzraven_status st = LZRAVEN_OK;

    if (!src)
        return;
    got = lzraven_decode_buffer_ex(dst, DST_CAP, src, src_len, &st);
    free(src);

    if (st == LZRAVEN_E_CORRUPT && got == 0) {
        printf("%-52s OK     rejected: %s\n", path, lzraven_status_string(st));
    } else if (st == LZRAVEN_OK) {
        fprintf(stderr, "%-52s FAIL   accepted %zu bytes — must reject\n",
                path, got);
        fail = 1;
    } else {
        fprintf(stderr, "%-52s FAIL   %s — expected LZRAVEN_E_CORRUPT\n",
                path, lzraven_status_string(st));
        fail = 1;
    }
}

/* Walk one fixture directory, checking every file with the given extension.
 * Returns the number checked, so main can hold the count against a floor. */
static int check_dir(const char *dir, const char *ext, uint8_t *dst)
{
    DIR *d = opendir(dir);
    struct dirent *e;
    int n = 0;

    if (!d) {
        fprintf(stderr, "FAIL %s: cannot open directory\n", dir);
        fail = 1;
        return 0;
    }
    while ((e = readdir(d)) != NULL) {
        size_t nl = strlen(e->d_name), el = strlen(ext);
        char path[512];

        if (nl <= el || strcmp(e->d_name + nl - el, ext) != 0)
            continue;
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        check_reject(path, dst);
        n++;
    }
    closedir(d);
    return n;
}

int main(int argc, char **argv)
{
    const char *vecdir = argc > 1 ? argv[1] : "tests/vectors";
    char dir[512];
    uint8_t *dst = malloc(DST_CAP);
    int n_gap, n_strict;

    if (!dst) {
        fprintf(stderr, "FAIL: out of memory\n");
        return 1;
    }

    snprintf(dir, sizeof dir, "%s/known-divergence", vecdir);
    n_gap = check_dir(dir, ".rav", dst);
    snprintf(dir, sizeof dir, "%s/apple-accepts", vecdir);
    n_strict = check_dir(dir, ".stricter", dst);
    free(dst);

    /* The committed set is two of each; fewer means fixtures went missing and
     * the gate is no longer testing what it claims to. */
    if (n_gap < 2 || n_strict < 2) {
        fprintf(stderr, "FAIL: expected >= 2 fixtures per directory, "
                        "got %d known-divergence, %d apple-accepts\n",
                n_gap, n_strict);
        fail = 1;
    }

    if (fail)
        return 1;
    printf("%d/%d must-reject streams rejected by the C decoder\n",
           n_gap + n_strict, n_gap + n_strict);
    return 0;
}

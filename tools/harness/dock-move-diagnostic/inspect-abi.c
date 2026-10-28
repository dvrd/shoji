#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!h) { fputs(dlerror(), stderr); return 1; }
    const char *names[] = {"SLSReassociateWindowsSpacesByGeometry", "SLSMoveWindowWithGroup"};
    FILE *f = fopen(argv[1], "w");
    if (!f) return 1;
    fputs(".text\n", f);
    for (int k = 0; k < 2; k++) {
        const uint32_t *p = dlsym(h, names[k]);
        if (!p) { fprintf(stderr, "missing %s\n", names[k]); fclose(f); return 1; }
        fprintf(f, ".global _%s\n_%s:\n", names[k], names[k]);
        for (int i = 0; i < 256; i++) fprintf(f, ".long 0x%08x\n", p[i]);
    }
    return fclose(f) != 0;
}

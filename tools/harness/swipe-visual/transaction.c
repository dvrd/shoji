#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

extern CFTypeRef SLSTransactionCreate(int32_t);
extern void SLSTransactionSetWindowTransform(CFTypeRef, uint32_t, int32_t, int32_t, CGAffineTransform);
extern void SLSTransactionCommit(CFTypeRef, int32_t);
extern int32_t SLSGetWindowTransform(int32_t, uint32_t, CGAffineTransform *);
extern int32_t SLSGetWindowBounds(int32_t, uint32_t, CGRect *);

static CGAffineTransform owned_original, fixture_original;
static int originals_saved;

int shoji_test_transform(int32_t connection, uint32_t owned, uint32_t fixture, double tx) {
    if (!originals_saved) {
        if (SLSGetWindowTransform(connection, owned, &owned_original) ||
            SLSGetWindowTransform(connection, fixture, &fixture_original)) return -2;
        originals_saved = 1;
    }
    CFTypeRef transaction = SLSTransactionCreate(connection);
    if (!transaction) return -1;
    CGAffineTransform owned_transform = owned_original;
    CGAffineTransform fixture_transform = fixture_original;
    owned_transform.tx += tx;
    fixture_transform.tx += tx;
    SLSTransactionSetWindowTransform(transaction, owned, 0, 0, owned_transform);
    SLSTransactionSetWindowTransform(transaction, fixture, 0, 0, fixture_transform);
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
    return 0;
}

int shoji_test_get_transform(int32_t connection, uint32_t window, double *x) {
    CGAffineTransform transform = CGAffineTransformIdentity;
    int32_t code = SLSGetWindowTransform(connection, window, &transform);
    *x = transform.tx;
    return code;
}

int shoji_test_window_x(int32_t connection, uint32_t window, double *x) {
    CGRect frame = CGRectZero;
    int32_t code = SLSGetWindowBounds(connection, window, &frame);
    *x = frame.origin.x;
    return code;
}

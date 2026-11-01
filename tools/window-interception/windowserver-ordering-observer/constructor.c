// Explicit constructor bridge; the normalized arm64e payload must not rely on
// Odin's private initializer section surviving image loading unchanged.
extern void shoji_ws_observer_start(void);
int shoji_ws_observer_constructor_anchor(void) { return 1; }

__attribute__((constructor))
static void shoji_ws_observer_constructor(void) {
    shoji_ws_observer_start();
}

/* No-op IME backend used on platforms that do not have a real IME
 * integration yet (macOS, Linux). Lets glfw_shim.c call nm_ime_attach
 * and nm_ime_set_cursor_pos unconditionally.
 *
 * Built only for non-Windows targets (see build.zig). */

#ifndef _WIN32

#include "internal.h"

void nm_ime_attach(nmWindow* w) {
    (void)w;
}

void nm_ime_set_cursor_pos(nmWindow* w, int x, int y, int height) {
    (void)w;
    (void)x;
    (void)y;
    (void)height;
}

#endif /* !_WIN32 */

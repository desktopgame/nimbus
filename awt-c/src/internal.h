#ifndef NIMBUS_AWT_C_INTERNAL_H
#define NIMBUS_AWT_C_INTERNAL_H

/* awt-c の内部ヘッダー。translate-c 経由で awt (Zig) 層からのみ参照される。
 * libnimbus 利用者には露出しない。 */

/* Build-sanity helper. Will be removed once higher-level coverage exists. */
int nimbus_awt_test_double(int x);

/* Global lifecycle. Returns 0 on success. */
int nimbus_awt_init(void);
void nimbus_awt_terminate(void);

/* Backend identification string (for diagnostics / version display). */
const char* nimbus_awt_backend_version(void);

/* Window: opaque handle. Implementation detail is the GLFW window pointer,
 * but the type is intentionally hidden so the rest of the codebase never
 * pulls in GLFW headers. */
typedef struct nimbus_window nimbus_window;

nimbus_window* nimbus_window_create(const char* title, int width, int height);
void nimbus_window_destroy(nimbus_window* w);
int nimbus_window_should_close(nimbus_window* w);
void nimbus_window_swap_buffers(nimbus_window* w);

/* Event pump. */
void nimbus_awt_poll_events(void);
void nimbus_awt_wait_events(void);

#endif /* NIMBUS_AWT_C_INTERNAL_H */

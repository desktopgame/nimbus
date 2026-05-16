#pragma once

/* awt-c の内部ヘッダー。translate-c 経由で awt (Zig) 層からのみ参照される。
 * libnimbus 利用者には露出しない。 */

/* Global lifecycle. Returns 0 on success. */
int nmInitAwt(void);
void nmTerminateAwt(void);

/* Backend identification string (for diagnostics / version display). */
const char* nmGetBackendVersion(void);

/* Window: opaque handle. Implementation detail is the GLFW window pointer,
 * but the type is hidden so the rest of the codebase never pulls in GLFW
 * headers. */
typedef struct nmWindow nmWindow;

nmWindow* nmCreateWindow(const char* title, int width, int height);
void nmDestroyWindow(nmWindow* self);
int nmShouldClose(nmWindow* self);
void nmSwapBuffers(nmWindow* self);

/* Event pump. */
void nmPollEvents(void);
void nmWaitEvents(void);

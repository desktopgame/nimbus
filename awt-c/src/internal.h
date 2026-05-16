#pragma once

/* awt-c internal header. Only accessed from the awt (Zig) layer via translate-c.
 * Never exposed to libnimbus consumers. */

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

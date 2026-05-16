/* Public log API (nmSetLogCallback) and internal nm_log helper.
 * Cross-platform: built on every target. */

#include "internal.h"

#include <stdarg.h>
#include <stdio.h>
#include <stddef.h>

static nmLogCallback g_log_cb = NULL;
static void*         g_log_user = NULL;

static const char* level_str(nmLogLevel level) {
    switch (level) {
        case nmLogLevelDebug: return "DEBUG";
        case nmLogLevelInfo:  return "INFO";
        case nmLogLevelWarn:  return "WARN";
        case nmLogLevelError: return "ERROR";
        default:              return "?";
    }
}

void nmSetLogCallback(nmLogCallback cb, void* user_data) {
    g_log_cb = cb;
    g_log_user = user_data;
}

/* Internal entry point used by every awt-c module. */
void nm_log(nmLogLevel level, const char* category, const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    if (g_log_cb) {
        g_log_cb(level, category, buf, g_log_user);
    } else {
        fprintf(stderr, "[%s] [%s] %s\n", level_str(level), category, buf);
        fflush(stderr);
    }
}

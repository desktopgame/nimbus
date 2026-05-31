#pragma once
/* GENERATED FILE — do not edit by hand.
 * Source spec:  tools/apigen/nimbus.api
 * Regenerate:   zig build apigen
 * Hand-written bootstrap declarations live in tools/apigen/preamble.h. */

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* Borrowed UTF-8 string slice (NOT NUL-terminated). Valid only until the
 * source widget mutates (e.g. setText) or is destroyed — copy it immediately.
 * `ptr` is null when the value is absent (optional getters). */
typedef struct { const char* ptr; size_t len; } nmStr;

#ifdef __cplusplus
extern "C" {
#endif

/* ── error reporting (see CLAUDE.md「エラーのC_ABIでの表現」) ── */
int nmLastErrorCode(void);
const char* nmLastErrorMessage(void);

/* ── backend ── */
const char* nmGetBackendVersion(void);

/* ── event accessors (for the opaque `event` in listener callbacks) ── */
/* kind: 0 = change, 1 = action */
int nmEventKind(const void* event);
void* nmEventSource(const void* event);

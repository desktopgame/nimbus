#pragma once
/* GENERATED FILE — do not edit by hand.
 * Source spec:  tools/apigen/nimbus.api
 * Regenerate:   zig build apigen
 * Header top matter is tools/apigen/preamble.h; hand-written prototypes (which
 * may reference opaque types) are in tools/apigen/preamble_protos.h. */

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

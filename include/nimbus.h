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

/* ── opaque handles ── */
typedef struct nmComponent nmComponent;
typedef struct nmContainer nmContainer;
typedef struct nmButton nmButton;
typedef struct nmComboBox nmComboBox;
typedef struct nmFrame nmFrame;
typedef struct nmApplication nmApplication;

/* ── value structs ── */
typedef struct { float r; float g; float b; float a; } nmColor;

/* ── enums ── */
typedef enum { nmAlignment_start, nmAlignment_center, nmAlignment_end, nmAlignment_stretch } nmAlignment;

/* ── event-handler callbacks ── */
typedef struct { void (*fn)(void* userdata, const void* event); void* userdata; } nmChangeListener;
/* Hand-written prototypes. Emitted by tools/apigen AFTER the generated opaque
 * typedefs, so they may reference handle types (e.g. nmApplication). Their
 * implementations live in tools/apigen/preamble.zig. Keep the two in sync. */

/* ── error reporting (see CLAUDE.md「エラーのC_ABIでの表現」) ── */
int nmLastErrorCode(void);
const char* nmLastErrorMessage(void);

/* ── backend ── */
const char* nmGetBackendVersion(void);

/* ── event accessors (for the opaque `event` in listener callbacks) ── */
/* kind: 0 = change, 1 = action */
int nmEventKind(const void* event);
void* nmEventSource(const void* event);

/* ── bootstrap (needs allocator / io; nmAppRun is generated) ── */
nmApplication* nmAppCreate(void);
void nmAppDestroy(nmApplication* self);

/* ── functions ── */
int nmAppRun(nmApplication* self);
nmButton* nmAppButton(nmApplication* self, const char* text);
int nmButtonSetText(nmButton* self, const char* text);
int nmContainerAdd(nmContainer* self, nmComponent* child);
void nmButtonSetColor(nmButton* self, nmColor c);
nmColor nmButtonGetColor(const nmButton* self);
nmStr nmButtonGetText(const nmButton* self);
nmStr nmComboBoxGetSelected(const nmComboBox* self);
nmFrame* nmAppFrame(nmApplication* self, const char* title, uint32_t w, uint32_t h);
void nmComponentSetGrowX(nmComponent* self, float v);
float nmComponentGetGrowX(nmComponent* self);
void nmComponentSetAlignX(nmComponent* self, nmAlignment a);
nmAlignment nmComponentGetAlignX(nmComponent* self);
int nmComboBoxOnChange(nmComboBox* self, nmChangeListener* cb);
void nmComboBoxOffChange(nmComboBox* self, nmChangeListener* cb);

/* ── upcasts ── */
nmComponent* nmButtonAsComponent(nmButton* self);
nmComponent* nmContainerAsComponent(nmContainer* self);

/* ── destructors ── */
void nmComponentDestroy(nmComponent* self);

#ifdef __cplusplus
}
#endif

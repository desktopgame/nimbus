#pragma once
/* GENERATED FILE — do not edit by hand.
 * Source spec:  tools/apigen/nimbus.api
 * Regenerate:   zig build apigen
 * Hand-written bootstrap declarations live in tools/apigen/preamble.h. */

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── error reporting (see CLAUDE.md「エラーのC_ABIでの表現」) ── */
int nmLastErrorCode(void);
const char* nmLastErrorMessage(void);

/* ── backend ── */
const char* nmGetBackendVersion(void);

/* ── opaque handles ── */
typedef struct nmComponent nmComponent;
typedef struct nmContainer nmContainer;
typedef struct nmButton nmButton;
typedef struct nmFrame nmFrame;
typedef struct nmApplication nmApplication;

/* ── value structs ── */
typedef struct { float r; float g; float b; float a; } nmColor;

/* ── enums ── */
typedef enum { nmAlignment_start, nmAlignment_center, nmAlignment_end, nmAlignment_stretch } nmAlignment;

/* ── functions ── */
nmButton* nmAppButton(nmApplication* self, const char* text);
int nmButtonSetText(nmButton* self, const char* text);
int nmContainerAdd(nmContainer* self, nmComponent* child);
void nmButtonSetColor(nmButton* self, nmColor c);
nmColor nmButtonGetColor(const nmButton* self);
nmFrame* nmAppFrame(nmApplication* self, const char* title, uint32_t w, uint32_t h);
void nmComponentSetGrowX(nmComponent* self, float v);
float nmComponentGetGrowX(nmComponent* self);
void nmComponentSetAlignX(nmComponent* self, nmAlignment a);
nmAlignment nmComponentGetAlignX(nmComponent* self);

/* ── upcasts ── */
nmComponent* nmButtonAsComponent(nmButton* self);
nmComponent* nmContainerAsComponent(nmContainer* self);

/* ── destructors ── */
void nmComponentDestroy(nmComponent* self);

#ifdef __cplusplus
}
#endif

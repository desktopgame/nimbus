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
typedef struct nmApplication nmApplication;

/* ── functions ── */
nmButton* nmAppButton(nmApplication* self, const char* text);
int nmButtonSetText(nmButton* self, const char* text);
int nmContainerAdd(nmContainer* self, nmComponent* child);

/* ── upcasts ── */
nmComponent* nmButtonAsComponent(nmButton* self);
nmComponent* nmContainerAsComponent(nmContainer* self);

/* ── destructors ── */
void nmComponentDestroy(nmComponent* self);

#ifdef __cplusplus
}
#endif

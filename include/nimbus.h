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
typedef struct nmImage nmImage;

/* ── value structs ── */
typedef struct { float r; float g; float b; float a; } nmColor;
typedef struct { float width; float height; } nmSize;

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

/* ── images / icons (bespoke; see doc/c_api_codegen.md「Image / icon」) ──
 * An nmImage wraps a GPU texture (awt.Image). Two ownership classes:
 *   - owned   : nmAppLoadImage returns a heap-boxed Image; free it once with
 *               nmImageDestroy (deinits the texture + frees the box).
 *   - borrowed: nmAppIcon / nmAppIconNamed / nmButtonGetIcon return a pointer
 *               into the Application's icon cache / a Button's icon field. Do
 *               NOT call nmImageDestroy on these; they live as long as their
 *               owner (Application / Button). */

/* Curated built-in icons (nimbus-owned, ABI-stable order). Names map to lucide
 * glyphs internally (e.g. cut → scissors). For icons outside this set, use
 * nmAppIconNamed with the lucide member name. */
typedef enum {
    nmIcon_open,    /* lucide: folder_open    */
    nmIcon_save,    /* lucide: save           */
    nmIcon_save_as, /* lucide: save_all       */
    nmIcon_undo,    /* lucide: undo           */
    nmIcon_redo,    /* lucide: redo           */
    nmIcon_cut,     /* lucide: scissors       */
    nmIcon_copy,    /* lucide: copy           */
    nmIcon_paste,   /* lucide: clipboard_paste */
} nmIcon;

/* Decode encoded image bytes (PNG / JPEG / GIF / BMP) into an OWNED Image.
 * Failure = NULL + last_error. Free with nmImageDestroy. */
nmImage* nmAppLoadImage(nmApplication* app, const uint8_t* bytes, size_t len);
/* Free an OWNED Image (from nmAppLoadImage only — never a borrowed one). */
void nmImageDestroy(nmImage* self);
int32_t nmImageWidth(const nmImage* self);
int32_t nmImageHeight(const nmImage* self);

/* Built-in icon as a BORROWED Image (cache pointer; lives with the App).
 * First use decodes + caches; failure = NULL + last_error. */
nmImage* nmAppIcon(nmApplication* self, nmIcon id);
nmImage* nmAppIconNamed(nmApplication* self, const char* name);

/* Button icon. getIcon returns a BORROWED pointer into the Button's icon field
 * (NULL = no icon, not an error). setIcon copies the Image by value (borrow);
 * pass NULL to clear. The Image must outlive its use by the Button. */
nmImage* nmButtonGetIcon(nmButton* self);
void nmButtonSetIcon(nmButton* self, nmImage* icon);

/* ── functions ── */
int nmAppRun(nmApplication* self);
nmButton* nmAppButton(nmApplication* self, const char* text);
int nmButtonSetText(nmButton* self, const char* text);
int nmContainerAdd(nmContainer* self, nmComponent* child);
void nmButtonSetColor(nmButton* self, nmColor c);
nmColor nmButtonGetColor(const nmButton* self);
nmStr nmButtonGetText(const nmButton* self);
nmStr nmComboBoxGetSelected(const nmComboBox* self);
void nmButtonSetIconSize(nmButton* self, const nmSize* sz);
bool nmButtonGetIconSize(const nmButton* self, nmSize* out);
nmFrame* nmAppFrame(nmApplication* self, const char* title, uint32_t w, uint32_t h);
void nmComponentSetGrowX(nmComponent* self, float v);
float nmComponentGetGrowX(nmComponent* self);
void nmComponentSetAlignX(nmComponent* self, nmAlignment a);
nmAlignment nmComponentGetAlignX(nmComponent* self);
nmComboBox* nmAppComboBox(nmApplication* self, const char* const* items, size_t items_len);
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

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

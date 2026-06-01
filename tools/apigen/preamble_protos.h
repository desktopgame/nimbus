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

/* ── List cell protocol (bespoke; see doc/c_api_codegen.md「List / CellFactory」) ──
 * A List materializes real cell subtrees only for the visible range and
 * recycles them on scroll (JavaFX VirtualFlow). You supply a factory that
 * builds one cell; the List calls `update` to (re)bind a cell to a row and
 * `destroy` to tear it down. Indices are rows in the ListModel; `value` is the
 * void* item you added (cast it back to your row struct). */

/* Per-bind context handed to nmCell.update. `value` is the ListModel item. */
typedef struct {
    nmList* list;
    void*   value;     /* the item you passed to nmListModelAdd */
    size_t  index;     /* its row */
    bool    selected;
    bool    focused;
} nmCellContext;

/* One cell instance you build in the factory. `component` is the subtree root
 * (e.g. from nmAppPanel). `update` rebinds it to a row (recycle). `destroy`
 * must tear down `component` (nmComponentDestroy) AND free `user_data`. Return
 * a cell with component == NULL to signal a creation failure. */
typedef struct {
    void* component;   /* nmComponent* — cell subtree root; NULL = create failed */
    void (*update)(void* cell_ud, const nmCellContext* ctx);
    void (*destroy)(void* cell_ud);
    void* user_data;   /* your cell state (you own it; freed in destroy) */
} nmCell;

/* The factory. `create` builds a fresh cell on demand. You own the factory and
 * must keep it alive for the List's lifetime (the List borrows it). */
typedef struct {
    nmCell (*create)(void* factory_ud);
    void* factory_ud;
} nmCellFactory;

/* Create a List with the given cell factory (owns an internal ListModel).
 * Owned like any widget: add via nmContainerAdd or free via its component. */
nmList* nmAppList(nmApplication* app, const nmCellFactory* factory);
/* The List's ListModel (borrowed; freed with the List). */
nmListModel* nmListGetModel(nmList* self);
/* Selection: -1 = none. setSelected with idx < 0 clears. */
int64_t nmListGetSelected(nmList* self);
void nmListSetSelected(nmList* self, int64_t idx);
/* Begin editing a row (no-op if the cell is read-only / out of range). */
void nmListEdit(nmList* self, size_t idx);

/* ListModel: items are borrowed void* (you own the backing memory; it must
 * outlive the List). add returns nonzero on failure (0 = ok). */
int nmListModelAdd(nmListModel* self, void* item);
void nmListModelRemove(nmListModel* self, size_t idx);
void nmListModelClear(nmListModel* self);
void nmListModelMove(nmListModel* self, size_t from, size_t to);
size_t nmListModelGetSize(nmListModel* self);
void* nmListModelGetElementAt(nmListModel* self, size_t idx);

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
typedef struct nmLabel nmLabel;
typedef struct nmPanel nmPanel;
typedef struct nmCheckBox nmCheckBox;
typedef struct nmRadioButton nmRadioButton;
typedef struct nmSlider nmSlider;
typedef struct nmScrollBar nmScrollBar;
typedef struct nmTextField nmTextField;
typedef struct nmTextArea nmTextArea;
typedef struct nmScrollPane nmScrollPane;
typedef struct nmWindow nmWindow;
typedef struct nmDialog nmDialog;
typedef struct nmMenuItem nmMenuItem;
typedef struct nmCheckBoxMenuItem nmCheckBoxMenuItem;
typedef struct nmMenu nmMenu;
typedef struct nmMenuBar nmMenuBar;
typedef struct nmMenuSeparator nmMenuSeparator;
typedef struct nmPopupMenu nmPopupMenu;
typedef struct nmButtonModel nmButtonModel;
typedef struct nmToggleButtonModel nmToggleButtonModel;
typedef struct nmBoundedRangeModel nmBoundedRangeModel;
typedef struct nmLayoutManager nmLayoutManager;
typedef struct nmImage nmImage;
typedef struct nmList nmList;
typedef struct nmListModel nmListModel;

/* ── value structs ── */
typedef struct { float r; float g; float b; float a; } nmColor;
typedef struct { float width; float height; } nmSize;
typedef struct { int32_t x; int32_t y; } nmWindowPoint;
typedef struct { int32_t width; int32_t height; } nmWindowSize;
typedef struct { float x; float y; } nmPoint;
typedef struct { float x; float y; float width; float height; } nmRect;

/* ── enums ── */
typedef enum { nmAlignment_start, nmAlignment_center, nmAlignment_end, nmAlignment_stretch } nmAlignment;
typedef enum { nmOrientation_horizontal, nmOrientation_vertical } nmOrientation;
typedef enum { nmScrollOrientation_horizontal, nmScrollOrientation_vertical } nmScrollOrientation;
typedef enum { nmBorderRegion_north, nmBorderRegion_south, nmBorderRegion_east, nmBorderRegion_west, nmBorderRegion_center } nmBorderRegion;
typedef enum { nmDialogResult_none, nmDialogResult_ok, nmDialogResult_cancel } nmDialogResult;
typedef enum { nmScrollPanePolicy_as_needed, nmScrollPanePolicy_always, nmScrollPanePolicy_never } nmScrollPanePolicy;

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
/* nmListEdit (begin editing a row) is generated — see nimbus.api. */

/* ListModel: items are borrowed void* (you own the backing memory; it must
 * outlive the List). add returns nonzero on failure (0 = ok). */
int nmListModelAdd(nmListModel* self, void* item);
void nmListModelRemove(nmListModel* self, size_t idx);
void nmListModelClear(nmListModel* self);
void nmListModelMove(nmListModel* self, size_t from, size_t to);
size_t nmListModelGetSize(nmListModel* self);
void* nmListModelGetElementAt(nmListModel* self, size_t idx);

/* Free an OWNED Dialog (from nmAppDialog). Caller-owned: the Application never
 * frees dialogs. Deinits the window + frees the box. Do not call while shown
 * modally. The rest of the Dialog API is generated — see nimbus.api. */
void nmDialogDestroy(nmDialog* self);

/* ── functions ── */
int nmAppRun(nmApplication* self);
nmButton* nmAppButton(nmApplication* self, const char* text);
int nmButtonSetText(nmButton* self, const char* text);
int nmContainerAdd(nmContainer* self, nmComponent* child);
void nmContainerRemove(nmContainer* self, nmComponent* child);
void nmButtonSetColor(nmButton* self, nmColor c);
nmColor nmButtonGetColor(const nmButton* self);
nmButtonModel* nmButtonGetModel(const nmButton* self);
nmStr nmButtonGetText(const nmButton* self);
nmStr nmComboBoxGetSelected(const nmComboBox* self);
void nmButtonSetIconSize(nmButton* self, const nmSize* sz);
bool nmButtonGetIconSize(const nmButton* self, nmSize* out);
nmFrame* nmAppFrame(nmApplication* self, const char* title, uint32_t w, uint32_t h);
void nmComponentSetGrowX(nmComponent* self, float v);
float nmComponentGetGrowX(nmComponent* self);
void nmComponentSetAlignX(nmComponent* self, nmAlignment a);
nmAlignment nmComponentGetAlignX(nmComponent* self);
void nmComponentSetGrowY(nmComponent* self, float v);
float nmComponentGetGrowY(nmComponent* self);
void nmComponentSetAlignY(nmComponent* self, nmAlignment a);
nmAlignment nmComponentGetAlignY(nmComponent* self);
bool nmComponentIsFocusable(nmComponent* self);
void nmComponentSetFocusable(nmComponent* self, bool v);
void nmComponentRequestFocus(nmComponent* self);
void nmComponentRepaint(nmComponent* self);
void nmComponentMarkLayoutDirty(nmComponent* self);
nmStr nmComponentGetName(const nmComponent* self);
void nmComponentSetName(nmComponent* self, const char* name);
bool nmComponentContainsWindowPoint(nmComponent* self, float x, float y);
nmRect nmComponentGetBounds(const nmComponent* self);
void nmComponentSetBounds(nmComponent* self, nmRect r);
nmPoint nmComponentAbsoluteOrigin(nmComponent* self);
nmComboBox* nmAppComboBox(nmApplication* self, const char* const* items, size_t items_len);
int nmComboBoxOnChange(nmComboBox* self, nmChangeListener* cb);
void nmComboBoxOffChange(nmComboBox* self, nmChangeListener* cb);
size_t nmComboBoxGetSelectedIndex(const nmComboBox* self);
void nmComboBoxSetSelectedIndex(nmComboBox* self, size_t idx);
size_t nmComboBoxItemCount(const nmComboBox* self);
nmStr nmComboBoxGetItem(const nmComboBox* self, size_t idx);
bool nmComboBoxIsEnabled(const nmComboBox* self);
void nmComboBoxSetEnabled(nmComboBox* self, bool v);
float nmListGetRowHeight(const nmList* self);
void nmListSetRowHeight(nmList* self, float h);
void nmListEdit(nmList* self, size_t idx);
int nmListOnChange(nmList* self, nmChangeListener* cb);
void nmListOffChange(nmList* self, nmChangeListener* cb);
nmLabel* nmAppLabel(nmApplication* self, const char* text);
nmContainer* nmAppContainer(nmApplication* self);
nmPanel* nmAppPanel(nmApplication* self);
nmCheckBox* nmAppCheckBox(nmApplication* self, const char* text);
nmRadioButton* nmAppRadioButton(nmApplication* self, const char* text);
nmSlider* nmAppSlider(nmApplication* self, nmOrientation orientation, int32_t min, int32_t value, int32_t max);
nmScrollBar* nmAppScrollBar(nmApplication* self, nmScrollOrientation orientation, int32_t min, int32_t value, int32_t max);
nmTextField* nmAppTextField(nmApplication* self, const char* text);
nmTextArea* nmAppTextArea(nmApplication* self, const char* text);
nmPanel* nmAppFiller(nmApplication* self);
nmPanel* nmAppToolBar(nmApplication* self);
nmMenu* nmAppMenu(nmApplication* self, const char* text);
nmMenuItem* nmAppMenuItem(nmApplication* self, const char* text);
nmCheckBoxMenuItem* nmAppCheckBoxMenuItem(nmApplication* self, const char* text);
nmMenuBar* nmAppMenuBar(nmApplication* self);
nmPopupMenu* nmAppPopupMenu(nmApplication* self);
nmMenuSeparator* nmAppMenuSeparator(nmApplication* self);
int nmLabelSetText(nmLabel* self, const char* text);
nmStr nmLabelGetText(const nmLabel* self);
void nmLabelSetColor(nmLabel* self, nmColor c);
nmColor nmLabelGetColor(const nmLabel* self);
nmStr nmCheckBoxGetText(const nmCheckBox* self);
int nmCheckBoxSetText(nmCheckBox* self, const char* text);
bool nmCheckBoxIsSelected(const nmCheckBox* self);
void nmCheckBoxSetSelected(nmCheckBox* self, bool v);
nmToggleButtonModel* nmCheckBoxGetModel(const nmCheckBox* self);
nmStr nmRadioButtonGetText(const nmRadioButton* self);
int nmRadioButtonSetText(nmRadioButton* self, const char* text);
bool nmRadioButtonIsSelected(const nmRadioButton* self);
void nmRadioButtonSetSelected(nmRadioButton* self, bool v);
nmToggleButtonModel* nmRadioButtonGetModel(const nmRadioButton* self);
nmOrientation nmSliderGetOrientation(const nmSlider* self);
void nmSliderSetOrientation(nmSlider* self, nmOrientation o);
nmBoundedRangeModel* nmSliderGetModel(const nmSlider* self);
nmBoundedRangeModel* nmScrollBarGetModel(const nmScrollBar* self);
int32_t nmScrollBarGetValue(const nmScrollBar* self);
void nmScrollBarSetValue(nmScrollBar* self, int32_t v);
nmScrollOrientation nmScrollBarGetOrientation(const nmScrollBar* self);
void nmScrollBarSetUnitIncrement(nmScrollBar* self, int32_t px);
void nmScrollBarSetBlockIncrement(nmScrollBar* self, int32_t px);
int nmScrollBarOnChange(nmScrollBar* self, nmChangeListener* cb);
void nmScrollBarOffChange(nmScrollBar* self, nmChangeListener* cb);
bool nmPanelGetBackground(const nmPanel* self, nmColor* out);
void nmPanelSetBackground(nmPanel* self, const nmColor* c);
nmStr nmTextFieldGetText(const nmTextField* self);
int nmTextFieldSetText(nmTextField* self, const char* text);
nmColor nmTextFieldGetCaretColor(const nmTextField* self);
void nmTextFieldSetCaretColor(nmTextField* self, nmColor c);
nmColor nmTextFieldGetBackground(const nmTextField* self);
void nmTextFieldSetBackground(nmTextField* self, nmColor c);
int nmTextFieldOnSubmit(nmTextField* self, nmChangeListener* cb);
void nmTextFieldOffSubmit(nmTextField* self, nmChangeListener* cb);
int nmTextFieldOnCancel(nmTextField* self, nmChangeListener* cb);
void nmTextFieldOffCancel(nmTextField* self, nmChangeListener* cb);
nmStr nmTextAreaGetText(nmTextArea* self);
int nmTextAreaSetText(nmTextArea* self, const char* text);
bool nmTextAreaGetLineWrap(const nmTextArea* self);
void nmTextAreaSetLineWrap(nmTextArea* self, bool wrap);
nmColor nmTextAreaGetCaretColor(const nmTextArea* self);
void nmTextAreaSetCaretColor(nmTextArea* self, nmColor c);
nmColor nmTextAreaGetBackground(const nmTextArea* self);
void nmTextAreaSetBackground(nmTextArea* self, nmColor c);
int nmWindowSetTitle(nmWindow* self, const char* title);
nmStr nmWindowGetTitle(const nmWindow* self);
int nmWindowAdd(nmWindow* self, nmComponent* child);
void nmWindowSetPos(nmWindow* self, int32_t x, int32_t y);
void nmWindowSetSize(nmWindow* self, int32_t width, int32_t height);
nmWindowPoint nmWindowGetPos(const nmWindow* self);
nmWindowSize nmWindowGetSize(const nmWindow* self);
nmColor nmWindowGetBackground(const nmWindow* self);
void nmWindowSetBackground(nmWindow* self, nmColor c);
void nmWindowRepaint(nmWindow* self);
void nmWindowRedraw(nmWindow* self);
void nmWindowDispose(nmWindow* self);
bool nmWindowShouldClose(const nmWindow* self);
int nmWindowSetMenuBar(nmWindow* self, nmComponent* bar);
void nmWindowRequestFocus(nmWindow* self, nmComponent* c);
int nmFrameSetMenuBar(nmFrame* self, nmMenuBar* bar);
int nmFrameSetMenuBarBorrowed(nmFrame* self, nmMenuBar* bar);
nmMenuBar* nmFrameGetMenuBar(const nmFrame* self);
nmDialog* nmAppDialog(nmApplication* self, nmWindow* owner, const char* title, uint32_t w, uint32_t h);
nmDialogResult nmDialogShowModal(nmDialog* self);
int nmDialogShow(nmDialog* self);
void nmDialogClose(nmDialog* self, nmDialogResult result);
nmDialogResult nmDialogGetResult(const nmDialog* self);
bool nmDialogIsModal(const nmDialog* self);
bool nmDialogIsShown(const nmDialog* self);
nmStr nmMenuItemGetText(const nmMenuItem* self);
int nmMenuItemSetText(nmMenuItem* self, const char* text);
nmButtonModel* nmMenuItemGetModel(const nmMenuItem* self);
nmStr nmCheckBoxMenuItemGetText(const nmCheckBoxMenuItem* self);
int nmCheckBoxMenuItemSetText(nmCheckBoxMenuItem* self, const char* text);
bool nmCheckBoxMenuItemIsChecked(const nmCheckBoxMenuItem* self);
void nmCheckBoxMenuItemSetChecked(nmCheckBoxMenuItem* self, bool v);
nmToggleButtonModel* nmCheckBoxMenuItemGetModel(const nmCheckBoxMenuItem* self);
nmStr nmMenuGetText(const nmMenu* self);
int nmMenuSetText(nmMenu* self, const char* text);
nmButtonModel* nmMenuGetModel(const nmMenu* self);
int nmMenuAdd(nmMenu* self, nmComponent* child);
int nmMenuAddSeparator(nmMenu* self);
int nmMenuShow(nmMenu* self, nmWindow* w, nmPoint anchor);
void nmMenuHide(nmMenu* self);
int nmMenuBarAdd(nmMenuBar* self, nmMenu* menu);
size_t nmMenuBarCount(const nmMenuBar* self);
nmMenu* nmMenuBarAt(const nmMenuBar* self, size_t index);
int nmPopupMenuAdd(nmPopupMenu* self, nmComponent* item);
int nmPopupMenuAddSeparator(nmPopupMenu* self);
int nmPopupMenuShow(nmPopupMenu* self, nmWindow* w, float x, float y);
void nmPopupMenuHide(nmPopupMenu* self);
void nmPopupMenuDestroy(nmPopupMenu* self);
void nmButtonModelSetPressed(nmButtonModel* self, bool v);
bool nmButtonModelIsPressed(nmButtonModel* self);
void nmButtonModelSetArmed(nmButtonModel* self, bool v);
bool nmButtonModelIsArmed(nmButtonModel* self);
void nmButtonModelSetRollover(nmButtonModel* self, bool v);
bool nmButtonModelIsRollover(nmButtonModel* self);
void nmButtonModelSetEnabled(nmButtonModel* self, bool v);
bool nmButtonModelIsEnabled(nmButtonModel* self);
void nmButtonModelFireAction(nmButtonModel* self);
int nmButtonModelOnChange(nmButtonModel* self, nmChangeListener* cb);
void nmButtonModelOffChange(nmButtonModel* self, nmChangeListener* cb);
int nmButtonModelOnAction(nmButtonModel* self, nmChangeListener* cb);
void nmButtonModelOffAction(nmButtonModel* self, nmChangeListener* cb);
bool nmToggleButtonModelIsSelected(nmToggleButtonModel* self);
void nmToggleButtonModelSetSelected(nmToggleButtonModel* self, bool v);
void nmToggleButtonModelFireAction(nmToggleButtonModel* self);
int nmToggleButtonModelOnChange(nmToggleButtonModel* self, nmChangeListener* cb);
void nmToggleButtonModelOffChange(nmToggleButtonModel* self, nmChangeListener* cb);
int nmToggleButtonModelOnAction(nmToggleButtonModel* self, nmChangeListener* cb);
void nmToggleButtonModelOffAction(nmToggleButtonModel* self, nmChangeListener* cb);
int32_t nmBoundedRangeModelGetValue(nmBoundedRangeModel* self);
void nmBoundedRangeModelSetValue(nmBoundedRangeModel* self, int32_t v);
int32_t nmBoundedRangeModelGetMin(nmBoundedRangeModel* self);
int32_t nmBoundedRangeModelGetMax(nmBoundedRangeModel* self);
int32_t nmBoundedRangeModelGetExtent(nmBoundedRangeModel* self);
void nmBoundedRangeModelSetRange(nmBoundedRangeModel* self, int32_t min, int32_t max);
void nmBoundedRangeModelSetExtent(nmBoundedRangeModel* self, int32_t extent);
void nmBoundedRangeModelSetRangeProperties(nmBoundedRangeModel* self, int32_t min, int32_t value, int32_t max, int32_t extent);
int nmBoundedRangeModelOnChange(nmBoundedRangeModel* self, nmChangeListener* cb);
void nmBoundedRangeModelOffChange(nmBoundedRangeModel* self, nmChangeListener* cb);
nmLayoutManager* nmBoxLayoutHorizontal(void);
nmLayoutManager* nmBoxLayoutVertical(void);
nmLayoutManager* nmBorderLayoutGet(void);
void nmContainerSetLayout(nmContainer* self, nmLayoutManager* layout);
nmLayoutManager* nmContainerGetLayout(nmContainer* self);
int nmBorderLayoutAdd(nmContainer* container, nmBorderRegion region, nmComponent* child);
nmScrollPane* nmAppScrollPane(nmApplication* self, nmComponent* view);
nmComponent* nmScrollPaneGetView(const nmScrollPane* self);
void nmScrollPaneSetView(nmScrollPane* self, nmComponent* view);
float nmScrollPaneGetScrollX(const nmScrollPane* self);
float nmScrollPaneGetScrollY(const nmScrollPane* self);
void nmScrollPaneSetScrollX(nmScrollPane* self, float px);
void nmScrollPaneSetScrollY(nmScrollPane* self, float px);
void nmScrollPaneSetHorizontalPolicy(nmScrollPane* self, nmScrollPanePolicy policy);
void nmScrollPaneSetVerticalPolicy(nmScrollPane* self, nmScrollPanePolicy policy);
void nmScrollPaneSetUnitIncrement(nmScrollPane* self, float px);
void nmScrollPaneScrollRectToVisible(nmScrollPane* self, nmRect rect);
int nmScrollPaneOnChange(nmScrollPane* self, nmChangeListener* cb);
void nmScrollPaneOffChange(nmScrollPane* self, nmChangeListener* cb);

/* ── upcasts ── */
nmComponent* nmButtonAsComponent(nmButton* self);
nmComponent* nmContainerAsComponent(nmContainer* self);
nmComponent* nmListAsComponent(nmList* self);
nmComponent* nmLabelAsComponent(nmLabel* self);
nmComponent* nmCheckBoxAsComponent(nmCheckBox* self);
nmComponent* nmRadioButtonAsComponent(nmRadioButton* self);
nmComponent* nmSliderAsComponent(nmSlider* self);
nmComponent* nmScrollBarAsComponent(nmScrollBar* self);
nmComponent* nmTextFieldAsComponent(nmTextField* self);
nmComponent* nmTextAreaAsComponent(nmTextArea* self);
nmComponent* nmMenuItemAsComponent(nmMenuItem* self);
nmComponent* nmCheckBoxMenuItemAsComponent(nmCheckBoxMenuItem* self);
nmComponent* nmMenuAsComponent(nmMenu* self);
nmComponent* nmMenuBarAsComponent(nmMenuBar* self);
nmComponent* nmMenuSeparatorAsComponent(nmMenuSeparator* self);
nmContainer* nmPanelAsContainer(nmPanel* self);
nmContainer* nmScrollPaneAsContainer(nmScrollPane* self);
nmWindow* nmFrameAsWindow(nmFrame* self);
nmContainer* nmWindowAsContainer(nmWindow* self);
nmWindow* nmDialogAsWindow(nmDialog* self);

/* ── destructors ── */
void nmComponentDestroy(nmComponent* self);

#ifdef __cplusplus
}
#endif

/* cnimbus_editor — drive the nimbus framework purely through its C ABI.
 *
 * Builds a small editor-shell window using only include/nimbus.h + the
 * generated C ABI (libnimbus); no Zig:
 *   - a menu bar (File / Edit)
 *   - a toolbar across the top (north region)
 *   - a text area inside a scroll pane filling the rest (center region)
 *
 * The C counterpart to the widget_* Zig examples. Build / run:
 *     zig build                      (built alongside the other examples)
 *     zig build run-cnimbus_editor
 */
#include <stdio.h>
#include <stdlib.h>
#include "nimbus.h"

/* Every nmApp* / factory returns NULL + sets the last error on failure
 * (see CLAUDE.md「エラーのC_ABIでの表現」). Bail loudly on the spot. */
static void* must(void* p) {
    if (p == NULL) {
        fprintf(stderr, "nimbus error: %s\n", nmLastErrorMessage());
        exit(1);
    }
    return p;
}

int main(void) {
    nmApplication* app = must(nmAppCreate());

    /* The Frame is owned by the Application (freed on app destroy); do not
     * free it here. Its root Container defaults to a BorderLayout, so children
     * are placed by region via nmBorderLayoutAdd. */
    nmFrame* frame = must(nmAppFrame(app, "nimbus C editor", 720, 480));
    nmWindow* win = nmFrameAsWindow(frame);
    nmContainer* root = nmWindowAsContainer(win);

    /* ── menu bar (frame takes ownership via setMenuBar) ─────────────── */
    nmMenuBar* bar = must(nmAppMenuBar(app));

    nmMenu* file = must(nmAppMenu(app, "File"));
    nmMenuAdd(file, nmMenuItemAsComponent(must(nmAppMenuItem(app, "New"))));
    nmMenuAdd(file, nmMenuItemAsComponent(must(nmAppMenuItem(app, "Open"))));
    nmMenuAddSeparator(file);
    nmMenuAdd(file, nmMenuItemAsComponent(must(nmAppMenuItem(app, "Quit"))));
    nmMenuBarAdd(bar, file);

    nmMenu* edit = must(nmAppMenu(app, "Edit"));
    nmMenuAdd(edit, nmMenuItemAsComponent(must(nmAppMenuItem(app, "Cut"))));
    nmMenuAdd(edit, nmMenuItemAsComponent(must(nmAppMenuItem(app, "Copy"))));
    nmMenuAdd(edit, nmMenuItemAsComponent(must(nmAppMenuItem(app, "Paste"))));
    nmMenuBarAdd(bar, edit);

    nmFrameSetMenuBar(frame, bar);

    /* ── toolbar across the top (text buttons) ───────────────────────── */
    nmPanel* toolbar = must(nmAppToolBar(app));
    nmContainer* tbc = nmPanelAsContainer(toolbar);
    static const char* const tools[] = { "New", "Open", "Save", "Cut", "Copy", "Paste" };
    for (size_t i = 0; i < sizeof(tools) / sizeof(tools[0]); i++) {
        nmButton* b = must(nmAppButton(app, tools[i]));
        nmContainerAdd(tbc, nmButtonAsComponent(b));
    }
    nmBorderLayoutAdd(root, nmBorderRegion_north, nmContainerAsComponent(tbc));

    /* ── scroll area + text area filling the center ──────────────────── */
    nmTextArea* ta = must(nmAppTextArea(app,
        "nimbus, driven from C.\n\n"
        "This multi-line text area lives inside a scroll pane that fills the\n"
        "window's center region. Type to edit; the caret scrolls into view.\n"));
    nmScrollPane* sp = must(nmAppScrollPane(app, nmTextAreaAsComponent(ta)));
    nmScrollPaneSetVerticalPolicy(sp, nmScrollPanePolicy_as_needed);
    nmScrollPaneSetHorizontalPolicy(sp, nmScrollPanePolicy_as_needed);
    /* ScrollPane -> Container -> Component: the two single-stage upcasts a
     * language binding would compose internally (no 2-stage cast needed). */
    nmComponent* view = nmContainerAsComponent(nmScrollPaneAsContainer(sp));
    nmBorderLayoutAdd(root, nmBorderRegion_center, view);

    printf("cnimbus_editor: menu bar + toolbar + scrollable text area, all via the C ABI.\n");

    int rc = nmAppRun(app);
    nmAppDestroy(app);
    return rc;
}

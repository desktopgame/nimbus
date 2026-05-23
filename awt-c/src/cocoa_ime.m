/* macOS Cocoa IME backend for awt-c.
 *
 * GLFW's NSWindow content view already conforms to NSTextInputClient — its
 * `insertText:` delivers committed characters via glfwSetCharCallback. What it
 * does NOT expose is the under-composition (marked / preedit) string, nor a
 * way for nimbus to anchor the candidate window at the caret.
 *
 * To intercept preedit without forking GLFW, we subclass the content view's
 * class at runtime and swap the instance's isa to the subclass. Three methods
 * are overridden:
 *   - setMarkedText:selectedRange:replacementRange:  → emit composition event
 *   - unmarkText                                     → emit "cleared" event
 *   - firstRectForCharacterRange:actualRange:        → answer with cached caret
 *
 * `insertText:` is left alone so committed characters still flow through GLFW
 * to the existing char callback. The committed string therefore does NOT come
 * through the composition callback — consumers should treat the composition
 * event as preedit only (matching the Windows backend's contract).
 *
 * Build only on macOS. ime_stub.c provides matching no-op entry points on
 * other platforms. */

#ifdef __APPLE__

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <stdlib.h>
#include <string.h>

#include <GLFW/glfw3.h>

#include "internal.h"
#include "window_internal.h"

/* Associated-object key for stashing the nmWindowCallbacks* on a content view.
 * The address of the static variable is the key — its value is irrelevant. */
static const void* kNmCbsKey = &kNmCbsKey;

static nmWindowCallbacks* view_get_cbs(NSView* view) {
    /* Stored via OBJC_ASSOCIATION_ASSIGN — no retention, raw pointer round-trip. */
    return (nmWindowCallbacks*)objc_getAssociatedObject(view, kNmCbsKey);
}

/* ─── UTF-16 → UTF-8 with index map ──────────────────────────────────────
 * Build a UTF-8 byte buffer plus a `boundaries` array such that
 * boundaries[i] is the UTF-8 byte offset corresponding to UTF-16 unit i,
 * and boundaries[wlen] is the total UTF-8 byte length. This mirrors
 * win32_ime.c so target_start/end mapping behaves identically on both
 * platforms. Both `out_utf8` and `out_bounds` must be freed by the caller. */
static int wide_to_utf8_with_boundaries(
    const unichar* wstr, size_t wlen,
    char** out_utf8, size_t* out_byte_len,
    size_t** out_bounds
) {
    *out_utf8 = NULL;
    *out_byte_len = 0;
    *out_bounds = NULL;

    /* 3 bytes per BMP code unit max; surrogate pairs use 6 input bytes for
     * 4 output bytes so 3*wlen is a safe upper bound. +1 for trailing NUL. */
    char* utf8 = (char*)malloc(wlen * 3 + 1);
    if (!utf8) return -1;
    size_t* bounds = (size_t*)malloc((wlen + 1) * sizeof(size_t));
    if (!bounds) { free(utf8); return -1; }

    size_t bi = 0;
    for (size_t i = 0; i < wlen; i++) {
        bounds[i] = bi;
        unsigned int cp;
        unichar c = wstr[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < wlen) {
            unichar lo = wstr[i + 1];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                cp = 0x10000 + (((unsigned int)c - 0xD800) << 10)
                             + ((unsigned int)lo - 0xDC00);
                i++;
                utf8[bi++] = (char)(0xF0 | (cp >> 18));
                utf8[bi++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                utf8[bi++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                utf8[bi++] = (char)(0x80 | (cp & 0x3F));
                bounds[i] = bi;
                continue;
            }
            cp = 0xFFFD;  /* unpaired high surrogate */
        } else if (c >= 0xDC00 && c <= 0xDFFF) {
            cp = 0xFFFD;  /* unpaired low surrogate */
        } else {
            cp = (unsigned int)c;
        }
        if (cp < 0x80) {
            utf8[bi++] = (char)cp;
        } else if (cp < 0x800) {
            utf8[bi++] = (char)(0xC0 | (cp >> 6));
            utf8[bi++] = (char)(0x80 | (cp & 0x3F));
        } else {
            utf8[bi++] = (char)(0xE0 | (cp >> 12));
            utf8[bi++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            utf8[bi++] = (char)(0x80 | (cp & 0x3F));
        }
    }
    bounds[wlen] = bi;
    utf8[bi] = 0;

    *out_utf8 = utf8;
    *out_byte_len = bi;
    *out_bounds = bounds;
    return 0;
}

/* Extract the underlying NSString from either an NSString or NSAttributedString. */
static NSString* coerce_marked_string(id markedText) {
    if (!markedText) return nil;
    if ([markedText isKindOfClass:[NSAttributedString class]]) {
        return [(NSAttributedString*)markedText string];
    }
    if ([markedText isKindOfClass:[NSString class]]) {
        return (NSString*)markedText;
    }
    return nil;
}

/* ─── Override IMPs ─────────────────────────────────────────────────────
 * Installed via class_addMethod on a dynamically created subclass. They do
 * NOT chain to super — GLFW's NSTextInputClient implementation only tracks
 * marked text for its own (unused) bookkeeping, so dropping the chain is
 * harmless. */

static void nim_setMarkedText(id self, SEL _cmd,
                              id markedText, NSRange selectedRange,
                              NSRange replacementRange) {
    (void)_cmd;
    (void)replacementRange;

    nmWindowCallbacks* cbs = view_get_cbs((NSView*)self);
    if (!cbs || !cbs->composition_cb) return;

    NSString* str = coerce_marked_string(markedText);
    NSUInteger wlen = str ? [str length] : 0;

    if (wlen == 0) {
        /* Empty marked text behaves like unmark — emit cleared. */
        nmCompositionEvent ev = {
            .text = "", .text_len = 0,
            .target_start = 0, .target_end = 0,
        };
        cbs->composition_cb((nmWindow*)[(NSView*)self window], &ev, cbs->composition_user);
        return;
    }

    /* Copy UTF-16 units into a heap buffer (NSString getCharacters: is the
     * cheapest path; the inline buffer route requires CFAttribute APIs). */
    unichar* wbuf = (unichar*)malloc(wlen * sizeof(unichar));
    if (!wbuf) return;
    [str getCharacters:wbuf range:NSMakeRange(0, wlen)];

    char* utf8 = NULL;
    size_t utf8_len = 0;
    size_t* bounds = NULL;
    int rc = wide_to_utf8_with_boundaries(wbuf, (size_t)wlen, &utf8, &utf8_len, &bounds);
    free(wbuf);
    if (rc != 0) return;

    /* macOS hands us the selected range inside the marked text directly —
     * it is already the "target clause" in Cocoa's model. Clamp defensively
     * before indexing into the boundaries map. */
    NSUInteger sel_loc = selectedRange.location;
    NSUInteger sel_end = selectedRange.location + selectedRange.length;
    if (sel_loc == NSNotFound || sel_loc > wlen) sel_loc = wlen;
    if (sel_end == NSNotFound || sel_end > wlen) sel_end = wlen;
    if (sel_end < sel_loc) sel_end = sel_loc;

    nmCompositionEvent ev = {
        .text = utf8,
        .text_len = utf8_len,
        .target_start = bounds[sel_loc],
        .target_end = bounds[sel_end],
    };
    cbs->composition_cb((nmWindow*)[(NSView*)self window], &ev, cbs->composition_user);

    free(utf8);
    free(bounds);
}

static void nim_unmarkText(id self, SEL _cmd) {
    (void)_cmd;
    nmWindowCallbacks* cbs = view_get_cbs((NSView*)self);
    if (!cbs || !cbs->composition_cb) return;
    nmCompositionEvent ev = {
        .text = "", .text_len = 0,
        .target_start = 0, .target_end = 0,
    };
    cbs->composition_cb((nmWindow*)[(NSView*)self window], &ev, cbs->composition_user);
}

/* The IME pulls the caret rect (in screen coordinates, bottom-left origin)
 * to anchor its candidate window. We answer with the framework-pushed caret
 * position. Returning NSZeroRect or a default makes the popup land at the
 * window origin, which is jarring. */
static NSRect nim_firstRectForCharacterRange(id self, SEL _cmd,
                                             NSRange range, NSRangePointer actualRange) {
    (void)_cmd;
    (void)range;
    if (actualRange) *actualRange = NSMakeRange(NSNotFound, 0);

    NSView* view = (NSView*)self;
    NSWindow* window = [view window];
    nmWindowCallbacks* cbs = view_get_cbs(view);
    if (!cbs || !window) return NSZeroRect;

    /* Cached caret position: window-local top-left origin, in points
     * (matches the rest of nimbus's logical coordinate system). Cocoa
     * non-flipped views use bottom-left origin, so flip Y inside the view's
     * bounds. */
    const CGFloat caret_x = (CGFloat)cbs->composition_cursor_x;
    const CGFloat caret_y_topdown = (CGFloat)cbs->composition_cursor_y;
    const CGFloat caret_h = (CGFloat)cbs->composition_cursor_h;

    NSRect bounds = [view bounds];
    CGFloat origin_y;
    if ([view isFlipped]) {
        origin_y = caret_y_topdown;
    } else {
        origin_y = bounds.size.height - caret_y_topdown - caret_h;
    }
    NSRect caretInView = NSMakeRect(caret_x, origin_y, 1.0, caret_h);
    NSRect caretInWindow = [view convertRect:caretInView toView:nil];
    return [window convertRectToScreen:caretInWindow];
}

/* ─── Subclass installation ───────────────────────────────────────────── */

/* Create a one-shot subclass of the GLFW content view's class. The class
 * is allocated and registered the first time we attach to any window;
 * subsequent attaches reuse it. Returns Nil if class creation failed. */
static Class get_or_create_ime_subclass(Class base) {
    static Class cached = Nil;
    static Class cached_base = Nil;
    if (cached && cached_base == base) return cached;

    /* Unique name per process. The address of `kNmCbsKey` is unique enough
     * to avoid collisions if multiple loaders run (e.g. dlopen scenarios). */
    char name[128];
    snprintf(name, sizeof(name), "NimbusIMEContentView_%p", (void*)kNmCbsKey);

    Class cls = objc_allocateClassPair(base, name, 0);
    if (!cls) {
        /* Already registered (e.g. previous module-load lifecycle); look it up. */
        cls = objc_getClass(name);
        if (!cls) return Nil;
    } else {
        /* Pull the type encodings from the base class so the runtime knows
         * argument / return ABI for our IMPs. */
        Method m1 = class_getInstanceMethod(base,
            @selector(setMarkedText:selectedRange:replacementRange:));
        Method m2 = class_getInstanceMethod(base, @selector(unmarkText));
        Method m3 = class_getInstanceMethod(base,
            @selector(firstRectForCharacterRange:actualRange:));

        const char* t1 = m1 ? method_getTypeEncoding(m1) : "v@:@{_NSRange=QQ}{_NSRange=QQ}";
        const char* t2 = m2 ? method_getTypeEncoding(m2) : "v@:";
        const char* t3 = m3 ? method_getTypeEncoding(m3) : "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}";

        class_addMethod(cls,
            @selector(setMarkedText:selectedRange:replacementRange:),
            (IMP)nim_setMarkedText, t1);
        class_addMethod(cls, @selector(unmarkText), (IMP)nim_unmarkText, t2);
        class_addMethod(cls,
            @selector(firstRectForCharacterRange:actualRange:),
            (IMP)nim_firstRectForCharacterRange, t3);

        objc_registerClassPair(cls);
    }
    cached = cls;
    cached_base = base;
    return cls;
}

/* ─── exported entry points (called from glfw_shim.c) ────────────────── */

void nm_ime_attach(nmWindow* w) {
    if (!w) return;
    NSWindow* nsw = (NSWindow*)nm_internal_get_nswindow(w);
    if (!nsw) return;
    NSView* view = [nsw contentView];
    if (!view) return;

    /* GLFW's per-window user pointer is the nmWindowCallbacks table —
     * glfw_shim.c allocates it in nmCreateWindow and frees in destroy. */
    nmWindowCallbacks* cbs =
        (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)w);
    if (!cbs) return;

    Class base = object_getClass(view);
    Class sub = get_or_create_ime_subclass(base);
    if (sub && base != sub) {
        object_setClass(view, sub);
    }
    /* OBJC_ASSOCIATION_ASSIGN: cbs lives in glfw_shim's malloc table, freed
     * in nmDestroyWindow — we only need a non-retaining handle. */
    objc_setAssociatedObject(view, kNmCbsKey, (id)cbs, OBJC_ASSOCIATION_ASSIGN);
}

void nm_ime_set_cursor_pos(nmWindow* w, int x, int y, int height) {
    (void)x; (void)y; (void)height;  /* cache lives in nmWindowCallbacks */
    if (!w) return;
    NSWindow* nsw = (NSWindow*)nm_internal_get_nswindow(w);
    if (!nsw) return;
    NSView* view = [nsw contentView];
    if (!view) return;

    /* Invalidate the IME's cached coordinates so the next paint pulls
     * firstRectForCharacterRange: again. Without this, the candidate
     * window stays anchored at the old caret position until the IME
     * decides to re-query. */
    NSTextInputContext* ic = [view inputContext];
    if (ic) [ic invalidateCharacterCoordinates];
}

#endif /* __APPLE__ */

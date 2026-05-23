/* Windows IME (IMM32) backend for awt-c.
 *
 * Subclasses GLFW's wndproc so we can intercept WM_IME_* messages without
 * monkey-patching the upstream library. Reads the preedit string and the
 * "target clause" attribute via ImmGetCompositionStringW, converts UTF-16
 * to UTF-8 for the framework callback, and pushes the framework's
 * latest caret position back to the OS so the IME candidate window
 * appears at the right place.
 *
 * Build only on Windows. On other platforms ime_stub.c provides no-op
 * versions of the same entry points so glfw_shim.c can call them
 * unconditionally. */

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <imm.h>
#include <stdlib.h>
#include <string.h>

#include <GLFW/glfw3.h>

#include "internal.h"
#include "window_internal.h"

/* Forward decl: the subclassed wndproc. Set as the new GWLP_WNDPROC,
 * tail-calls the previously-installed (GLFW) wndproc for messages we do
 * not handle. */
static LRESULT CALLBACK ime_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);

/* Read GCS_* slice from the IME context as UTF-16 into a malloc'd buffer.
 * Returns NULL on allocation failure or empty. Caller frees with free(). */
static wchar_t* read_ime_string_w(HIMC himc, DWORD gcs, size_t* out_wchars) {
    *out_wchars = 0;
    /* First call: size in BYTES (LONG, may be negative on error). */
    LONG bytes = ImmGetCompositionStringW(himc, gcs, NULL, 0);
    if (bytes <= 0) return NULL;
    size_t wlen = (size_t)bytes / sizeof(wchar_t);
    wchar_t* buf = (wchar_t*)malloc((wlen + 1) * sizeof(wchar_t));
    if (!buf) return NULL;
    ImmGetCompositionStringW(himc, gcs, buf, (DWORD)bytes);
    buf[wlen] = 0;
    *out_wchars = wlen;
    return buf;
}

/* Read GCS_COMPATTR (one byte per UTF-16 unit). NULL if absent / fails. */
static unsigned char* read_ime_attr(HIMC himc, size_t* out_len) {
    *out_len = 0;
    LONG bytes = ImmGetCompositionStringW(himc, GCS_COMPATTR, NULL, 0);
    if (bytes <= 0) return NULL;
    unsigned char* buf = (unsigned char*)malloc((size_t)bytes);
    if (!buf) return NULL;
    ImmGetCompositionStringW(himc, GCS_COMPATTR, buf, (DWORD)bytes);
    *out_len = (size_t)bytes;
    return buf;
}

/* Read GCS_CURSORPOS — caret offset in UTF-16 units inside the preedit. */
static int read_ime_cursor_pos(HIMC himc) {
    LONG p = ImmGetCompositionStringW(himc, GCS_CURSORPOS, NULL, 0);
    return p < 0 ? 0 : (int)p;
}

/* Walk `wstr[0..wlen]` while building a UTF-8 buffer, and record the byte
 * offset corresponding to each UTF-16 index (boundaries[i] = byte offset
 * at the start of wstr[i]; boundaries[wlen] = total UTF-8 byte length).
 * Returns NULL on alloc failure. Caller frees `out_utf8` and `out_bounds`
 * with free(). On success, *out_byte_len is the UTF-8 length excluding
 * the trailing NUL written for safety. */
static int wide_to_utf8_with_boundaries(
    const wchar_t* wstr, size_t wlen,
    char** out_utf8, size_t* out_byte_len,
    size_t** out_bounds
) {
    *out_utf8 = NULL;
    *out_byte_len = 0;
    *out_bounds = NULL;

    /* Best-case worst-case: a single BMP code unit → up to 3 bytes,
     * a surrogate pair (2 units) → 4 bytes. So allocate 3 * wlen + 1
     * which is safe even for surrogate-heavy strings (each pair would
     * use 6 bytes of budget for 4 bytes of output). */
    char* utf8 = (char*)malloc(wlen * 3 + 1);
    if (!utf8) return -1;
    size_t* bounds = (size_t*)malloc((wlen + 1) * sizeof(size_t));
    if (!bounds) { free(utf8); return -1; }

    size_t bi = 0; /* byte index */
    for (size_t i = 0; i < wlen; i++) {
        bounds[i] = bi;
        unsigned int cp;
        wchar_t c = wstr[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < wlen) {
            wchar_t lo = wstr[i + 1];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                cp = 0x10000 + (((unsigned int)c - 0xD800) << 10) + ((unsigned int)lo - 0xDC00);
                /* boundary for the trailing surrogate slot is the same byte
                 * offset (the pair encodes one codepoint) — set after encoding. */
                i++;
                /* Encode (4 bytes). */
                utf8[bi++] = (char)(0xF0 | (cp >> 18));
                utf8[bi++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                utf8[bi++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                utf8[bi++] = (char)(0x80 | (cp & 0x3F));
                bounds[i] = bi; /* trailing surrogate slot → same byte after encode */
                continue;
            }
            /* Unpaired high surrogate — emit replacement char U+FFFD. */
            cp = 0xFFFD;
        } else if (c >= 0xDC00 && c <= 0xDFFF) {
            cp = 0xFFFD;
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

/* Find the [start, end) UTF-16 range marked as TARGET_CONVERTED (or
 * TARGET_NOTCONVERTED — both indicate the clause the user is editing).
 * Falls back to [cursor_pos, cursor_pos) if no target attribute is set. */
static void find_target_range_w(
    const unsigned char* attr, size_t attr_len, int cursor_pos,
    size_t* out_start_w, size_t* out_end_w
) {
    size_t start = (size_t)cursor_pos;
    size_t end = (size_t)cursor_pos;
    int in_range = 0;
    for (size_t i = 0; i < attr_len; i++) {
        unsigned char a = attr[i];
        int is_target = (a == ATTR_TARGET_CONVERTED) || (a == ATTR_TARGET_NOTCONVERTED);
        if (is_target && !in_range) {
            start = i;
            in_range = 1;
        }
        if (is_target) {
            end = i + 1;
        } else if (in_range) {
            break;
        }
    }
    *out_start_w = start;
    *out_end_w = end;
}

/* Fire the framework composition callback with the current preedit state. */
static void emit_composition(HWND hwnd, nmWindowCallbacks* cbs) {
    if (!cbs->composition_cb) return;

    HIMC himc = ImmGetContext(hwnd);
    if (!himc) {
        /* No context → emit "cleared". */
        nmCompositionEvent ev = { .text = "", .text_len = 0, .target_start = 0, .target_end = 0 };
        cbs->composition_cb((nmWindow*)hwnd, &ev, cbs->composition_user);
        return;
    }

    size_t wlen = 0;
    wchar_t* wstr = read_ime_string_w(himc, GCS_COMPSTR, &wlen);

    size_t attr_len = 0;
    unsigned char* attr = (wlen > 0) ? read_ime_attr(himc, &attr_len) : NULL;
    int cursor_w = (wlen > 0) ? read_ime_cursor_pos(himc) : 0;

    ImmReleaseContext(hwnd, himc);

    if (!wstr || wlen == 0) {
        nmCompositionEvent ev = { .text = "", .text_len = 0, .target_start = 0, .target_end = 0 };
        cbs->composition_cb((nmWindow*)hwnd, &ev, cbs->composition_user);
        if (wstr) free(wstr);
        if (attr) free(attr);
        return;
    }

    char* utf8 = NULL;
    size_t utf8_len = 0;
    size_t* bounds = NULL; /* size: wlen + 1 */
    if (wide_to_utf8_with_boundaries(wstr, wlen, &utf8, &utf8_len, &bounds) != 0) {
        free(wstr);
        if (attr) free(attr);
        return;
    }

    size_t target_start_w, target_end_w;
    if (attr) {
        find_target_range_w(attr, attr_len, cursor_w, &target_start_w, &target_end_w);
    } else {
        target_start_w = target_end_w = (size_t)cursor_w;
    }

    /* Clamp UTF-16 indices defensively before indexing `bounds`. */
    if (target_start_w > wlen) target_start_w = wlen;
    if (target_end_w > wlen) target_end_w = wlen;

    nmCompositionEvent ev = {
        .text = utf8,
        .text_len = utf8_len,
        .target_start = bounds[target_start_w],
        .target_end = bounds[target_end_w],
    };
    cbs->composition_cb((nmWindow*)hwnd, &ev, cbs->composition_user);

    free(wstr);
    if (attr) free(attr);
    free(utf8);
    free(bounds);
}

/* Tell the IME where to draw its composition + candidate windows.
 *
 * Setting both `COMPOSITIONFORM` and `CANDIDATEFORM` is required because
 * different IMEs (MS-IME, Google IME, ATOK, ...) honor different forms.
 * Candidate window uses CFS_EXCLUDE with a 1-px-wide rect at the caret
 * column spanning the line height — the IME interprets this as "avoid
 * overlapping this rectangle", and most place the popup just below it.
 *
 * Called from nm_ime_set_cursor_pos (framework push) and also during
 * WM_IME_STARTCOMPOSITION (so the IME picks up our value at the moment
 * it is about to place its windows — pushing once up-front before a
 * composition exists is often dropped).
 *
 * Re-entry guard: ImmSetCompositionWindow / ImmSetCandidateWindow each
 * synthesize an IMN_SETCANDIDATEPOS / IMN_SETCOMPOSITIONWINDOW back to
 * our subclassed wndproc, which would call us again → infinite recursion
 * and stack overflow. UI is single-threaded so a static flag suffices. */
static int g_pushing = 0;

static void push_candidate_pos(HWND hwnd, int x, int y, int height) {
    if (g_pushing) return;
    g_pushing = 1;

    HIMC himc = ImmGetContext(hwnd);
    if (!himc) {
        g_pushing = 0;
        return;
    }

    COMPOSITIONFORM cf;
    cf.dwStyle = CFS_POINT;
    cf.ptCurrentPos.x = x;
    cf.ptCurrentPos.y = y;
    cf.rcArea.left = cf.rcArea.top = cf.rcArea.right = cf.rcArea.bottom = 0;
    ImmSetCompositionWindow(himc, &cf);

    CANDIDATEFORM candf;
    candf.dwIndex = 0;
    candf.dwStyle = CFS_EXCLUDE;
    candf.ptCurrentPos.x = x;
    candf.ptCurrentPos.y = y;
    candf.rcArea.left = x;
    candf.rcArea.top = y;
    candf.rcArea.right = x + 1;
    candf.rcArea.bottom = y + height;
    ImmSetCandidateWindow(himc, &candf);

    ImmReleaseContext(hwnd, himc);
    g_pushing = 0;
}

/* Re-push the cached cursor pos. Used at IME lifecycle events so the
 * value framework provided sticks to the correct HIMC state. */
static void repush_cached_pos(HWND hwnd, nmWindowCallbacks* cbs) {
    push_candidate_pos(hwnd,
        cbs->composition_cursor_x,
        cbs->composition_cursor_y,
        cbs->composition_cursor_h);
}

static LRESULT CALLBACK ime_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    /* GLFW does not use GWLP_USERDATA — it stores its own state via a
     * window-property name internally — so we are free to reuse it for
     * the awt callbacks pointer. The attach helper sets this. */
    WNDPROC prev = cbs ? cbs->prev_wndproc : NULL;

    switch (msg) {
    case WM_IME_STARTCOMPOSITION:
        /* Push the cached caret pos NOW so the IME picks it up for the
         * candidate / composition windows it is about to spawn. Without
         * this, the IME tends to default to a system-default location
         * (e.g. screen bottom-right). */
        if (cbs) {
            repush_cached_pos(hwnd, cbs);
            emit_composition(hwnd, cbs);
        }
        return 0;
    case WM_IME_COMPOSITION:
        if (lp & GCS_COMPSTR) {
            if (cbs) emit_composition(hwnd, cbs);
        }
        /* Let DefWindowProc (via prev) handle GCS_RESULTSTR — the resulting
         * characters reach us through WM_CHAR / glfwSetCharCallback, so we
         * do not duplicate the commit path here. */
        break;
    case WM_IME_ENDCOMPOSITION:
        if (cbs && cbs->composition_cb) {
            nmCompositionEvent ev = { .text = "", .text_len = 0, .target_start = 0, .target_end = 0 };
            cbs->composition_cb((nmWindow*)hwnd, &ev, cbs->composition_user);
        }
        break;
    case WM_IME_NOTIFY:
        /* IME is about to open or move its candidate window — re-push our
         * cached pos so it lands at the caret instead of the previous /
         * default position.
         *
         * IMPORTANT: IMN_SETCANDIDATEPOS / IMN_SETCOMPOSITIONWINDOW are
         * synthesized BY our own ImmSet*Window calls — responding to
         * them would loop forever. Only act on user-driven events. */
        if (cbs && (wp == IMN_OPENCANDIDATE
                 || wp == IMN_CHANGECANDIDATE))
        {
            repush_cached_pos(hwnd, cbs);
        }
        break;
    default:
        break;
    }
    return prev ? CallWindowProcW(prev, hwnd, msg, wp, lp)
                : DefWindowProcW(hwnd, msg, wp, lp);
}

/* ─── exported entry points (called from glfw_shim.c) ────────────────── */

void nm_ime_attach(nmWindow* w) {
    if (!w) return;
    HWND hwnd = nm_internal_get_hwnd(w);
    if (!hwnd) return;

    /* glfw stores its callback table via glfwSetWindowUserPointer, which
     * is independent of GWLP_USERDATA. Store our callbacks pointer in
     * GWLP_USERDATA so the subclassed wndproc can reach it without
     * needing GLFW APIs (which would be re-entrant during message
     * dispatch). */
    nmWindowCallbacks* cbs =
        (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)w);
    if (!cbs) return;
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cbs);

    /* Swap in our wndproc; remember the prior one for chaining. */
    LONG_PTR prev = SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)ime_wndproc);
    cbs->prev_wndproc = (WNDPROC)prev;
}

void nm_ime_set_cursor_pos(nmWindow* w, int x, int y, int height) {
    if (!w) return;
    HWND hwnd = nm_internal_get_hwnd(w);
    if (!hwnd) return;
    push_candidate_pos(hwnd, x, y, height);
}

#endif /* _WIN32 */

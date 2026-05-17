/* Font: thin freetype wrapper. Holds the process-wide FT_Library used by all
 * nmFont instances. FT_Library is created in nmInitAwt and destroyed in
 * nmTerminateAwt; we keep it cross-platform here (freetype is portable). */

#include "internal.h"

#include <ft2build.h>
#include FT_FREETYPE_H

#include <stdlib.h>

/* Implemented in nm_log.c (cross-platform). */
void nm_log(nmLogLevel level, const char* category, const char* fmt, ...);

static FT_Library g_ft = NULL;

/* Called from glfw_shim.c::nmInitAwt / nmTerminateAwt. */
int  nm_font_internal_init(void);
void nm_font_internal_terminate(void);

int nm_font_internal_init(void) {
    if (g_ft) return 0;
    FT_Error err = FT_Init_FreeType(&g_ft);
    if (err) {
        nm_log(nmLogLevelError, "font", "FT_Init_FreeType failed (err=%d)", (int)err);
        g_ft = NULL;
        return -1;
    }
    return 0;
}

void nm_font_internal_terminate(void) {
    if (g_ft) {
        FT_Done_FreeType(g_ft);
        g_ft = NULL;
    }
}

struct nmFont {
    FT_Face face;
};

nmFont* nmCreateFont(const void* data, size_t size, int face_index) {
    if (!g_ft || !data || size == 0) return NULL;

    nmFont* f = (nmFont*)calloc(1, sizeof(nmFont));
    if (!f) return NULL;

    FT_Error err = FT_New_Memory_Face(g_ft,
        (const FT_Byte*)data, (FT_Long)size, (FT_Long)face_index, &f->face);
    if (err) {
        nm_log(nmLogLevelError, "font",
            "FT_New_Memory_Face failed (err=%d face_index=%d)", (int)err, face_index);
        free(f);
        return NULL;
    }
    return f;
}

void nmDestroyFont(nmFont* self) {
    if (!self) return;
    if (self->face) FT_Done_Face(self->face);
    free(self);
}

void nmSetFontPixelSize(nmFont* self, int pixel_size) {
    if (!self || !self->face) return;
    FT_Error err = FT_Set_Pixel_Sizes(self->face, 0, (FT_UInt)pixel_size);
    if (err) {
        nm_log(nmLogLevelError, "font",
            "FT_Set_Pixel_Sizes failed (err=%d size=%d)", (int)err, pixel_size);
    }
}

void nmGetFontMetrics(nmFont* self, nmFontMetrics* out) {
    if (!self || !self->face || !out) return;
    /* face->size->metrics fields are in 26.6 fixed point (1 unit = 1/64 px). */
    FT_Size_Metrics m = self->face->size->metrics;
    out->ascender    = (float)m.ascender  / 64.0f;
    out->descender   = (float)(-m.descender) / 64.0f;  /* report as positive */
    out->line_gap    = (float)(m.height - m.ascender + m.descender) / 64.0f;
    out->line_height = (float)m.height / 64.0f;
}

int nmRasterizeGlyph(nmFont* self, uint32_t codepoint,
                     nmGlyphMetrics* out_metrics,
                     const uint8_t** out_bitmap) {
    if (!self || !self->face || !out_metrics || !out_bitmap) return -1;

    FT_Error err = FT_Load_Char(self->face, (FT_ULong)codepoint, FT_LOAD_RENDER);
    if (err) {
        nm_log(nmLogLevelWarn, "font",
            "FT_Load_Char failed (err=%d codepoint=U+%04X)", (int)err, codepoint);
        return -1;
    }

    FT_GlyphSlot g = self->face->glyph;
    out_metrics->bitmap_width  = (int)g->bitmap.width;
    out_metrics->bitmap_height = (int)g->bitmap.rows;
    /* `pitch` is signed in freetype (negative means upward flow); we take
     * absolute value because FT_LOAD_RENDER on grayscale always produces
     * top-down bitmaps but the field type still permits negatives. */
    out_metrics->bitmap_pitch  = (g->bitmap.pitch < 0) ? -g->bitmap.pitch : g->bitmap.pitch;
    out_metrics->bearing_x     = g->bitmap_left;
    out_metrics->bearing_y     = g->bitmap_top;
    out_metrics->advance_x     = (float)g->advance.x / 64.0f;
    *out_bitmap = g->bitmap.buffer;
    return 0;
}

float nmGetGlyphAdvance(nmFont* self, uint32_t codepoint) {
    if (!self || !self->face) return 0.0f;
    FT_Error err = FT_Load_Char(self->face, (FT_ULong)codepoint,
                                FT_LOAD_DEFAULT | FT_LOAD_ADVANCE_ONLY);
    if (err) return 0.0f;
    return (float)self->face->glyph->advance.x / 64.0f;
}

int nmFontHasGlyph(nmFont* self, uint32_t codepoint) {
    if (!self || !self->face) return 0;
    return FT_Get_Char_Index(self->face, (FT_ULong)codepoint) != 0;
}

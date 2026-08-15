/*
 * shaders.c
 * Copyright (C) 2017 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#include "fonts.h"
#include "gl.h"
#include "cleanup.h"
#include "colors.h"
#include <stddef.h>
#include <string.h>
#include "animation.h"
#ifndef KITTY_BACKEND_METAL
// Static parser helpers, consumed only by the GL-only custom-end pipeline parser.
#include "animation-parse.h"
#endif
#include "text-cache.h"
#include "tupleobject.h"
#include "window_logo.h"
#include "srgb_gamma.h"
#include "state.h"
#ifdef KITTY_BACKEND_METAL
// W27 P3.5b: kitty_drawable_primaries_wide() gates the packed colour-table
// wide-region fill below to the Metal wide arms.
#include "metal_drawable_format.h"
#endif

// D2: per-line dirty upload helpers. On Metal these bridge to the persistent
// ring (metal.m): D2_TAKE_FRESH reports whether the just-mapped cell ring slot
// is fresh (=> full write), D2_NOTE_BYTES accumulates the frame's upload bytes
// for the metal_stats bytes= probe. On the OpenGL backend the buffer is orphaned
// fresh every frame, so full write always (true) and byte-tracking is a no-op.
#ifdef KITTY_BACKEND_METAL
#define D2_TAKE_FRESH(vao_idx, bufnum) metal_cell_ring_take_fresh((vao_idx), (bufnum))
#define D2_NOTE_BYTES(n) metal_note_upload_bytes((uint64_t)(n))
#else
#define D2_TAKE_FRESH(vao_idx, bufnum) true
#define D2_NOTE_BYTES(n) ((void)(n))
#endif

enum {
    CELL_PROGRAM,
    CELL_FG_PROGRAM,
    CELL_BG_PROGRAM,
    CELL_PROGRAM_SENTINEL,
    BORDERS_PROGRAM,
    GRAPHICS_PROGRAM,
    GRAPHICS_PREMULT_PROGRAM,
    GRAPHICS_ALPHA_MASK_PROGRAM,
    BGIMAGE_PROGRAM,
    TINT_PROGRAM,
    TRAIL_PROGRAM,
    BLIT_PROGRAM,
    SCREENSHOT_PROGRAM,
    ROUNDED_RECT_PROGRAM,
    PADDING_PROGRAM,

    CUSTOM_END_PROGRAM,

    NUM_PROGRAMS
};
enum { SPRITE_MAP_UNIT, GRAPHICS_UNIT, SPRITE_DECORATIONS_MAP_UNIT, COLOR_SPRITE_MAP_UNIT, COLOR_SPRITE_DECORATIONS_MAP_UNIT, CUSTOM_END_TEXTURE_A_UNIT, CUSTOM_END_TEXTURE_B_UNIT, CUSTOM_END_TEXTURE_PERSIST_UNIT };

typedef struct UIRenderData {
    unsigned screen_width, screen_height, cell_width, cell_height, screen_left, screen_top, full_framebuffer_width, full_framebuffer_height;
    Window *window;
    Screen *screen;
    OSWindow *os_window;
    GraphicsRenderData grd;
    WindowLogoRenderData *window_logo;
    float bg_alpha, inactive_text_alpha;
    bool has_background_image;
    color_type background_color; // RGB only
    monotonic_t now;
} UIRenderData;

static inline float
row_offset_for_screen(const Screen *screen) {
    if (!pixel_scroll_enabled(screen) || !screen->cell_size.height) return 0.f;
    return -1.f + (float)(screen->pixel_scroll_offset_y / (double)screen->cell_size.height);
}

static inline float
scroll_offset_lines_for_screen(const Screen *screen) {
    if (!pixel_scroll_enabled(screen) || !screen->cell_size.height) return 0.f;
    return (float)(screen->pixel_scroll_offset_y / (double)screen->cell_size.height);
}

// Sprites {{{
typedef struct {
    int xnum, ynum, x, y, z, last_num_of_layers, last_ynum;
    GLuint texture_id;
    GLint max_texture_size, max_array_texture_layers;
    struct decorations_map {
        GLuint texture_id;
        unsigned width, height;
        size_t count;
    } decorations_map;
    // F1: the colored (RGBA emoji) atlas and its own decorations map. Only
    // populated when r8_sprite_atlas_enabled(); the mono texture_id above then
    // becomes single-channel R8. Under the kill switch these stay zero and all
    // sprites live in the single RGBA texture_id/decorations_map as before.
    GLuint color_texture_id;
    int color_last_num_of_layers, color_last_ynum;
    struct decorations_map color_decorations_map;
} SpriteMap;

static const SpriteMap NEW_SPRITE_MAP = { .xnum = 1, .ynum = 1, .last_num_of_layers = 1, .last_ynum = -1, .color_last_num_of_layers = 1, .color_last_ynum = -1 };
static GLint max_texture_size = 0, max_array_texture_layers = 0;

static GLfloat
srgb_color(uint8_t color) {
    return srgb_lut[color];
}

static void
color_vec3(GLint location, color_type color) {
    glUniform3f(location, srgb_lut[(color >> 16) & 0xFF], srgb_lut[(color >> 8) & 0xFF], srgb_lut[color & 0xFF]);
}

static void
color_vec4_premult(GLint location, color_type color, GLfloat alpha) {
    glUniform4f(location, srgb_lut[(color >> 16) & 0xFF] * alpha, srgb_lut[(color >> 8) & 0xFF] * alpha, srgb_lut[color & 0xFF] * alpha, alpha);
}

static void
color_vec4(GLint location, color_type color, GLfloat alpha) {
    glUniform4f(location, srgb_lut[(color >> 16) & 0xFF], srgb_lut[(color >> 8) & 0xFF], srgb_lut[color & 0xFF], alpha);
}



#ifndef KITTY_BACKEND_METAL
// GL-only: the Metal backend clears its memoryless working surface via the
// render pass loadAction in metal_begin_layered_frame (M1), so this shim helper
// has no caller there.
static void
clear_current_framebuffer(void) { glClearColor(0, 0, 0, 0); glClear(GL_COLOR_BUFFER_BIT); }
#endif

SPRITE_MAP_HANDLE
alloc_sprite_map(void) {
    if (!max_texture_size) {
        glGetIntegerv(GL_MAX_TEXTURE_SIZE, &(max_texture_size));
        glGetIntegerv(GL_MAX_ARRAY_TEXTURE_LAYERS, &(max_array_texture_layers));
#ifdef __APPLE__
        // Since on Apple we could have multiple GPUs, with different capabilities,
        // upper bound the values according to the data from https://developer.apple.com/graphicsimaging/opengl/capabilities/
        max_texture_size = MIN(8192, max_texture_size);
        max_array_texture_layers = MIN(512, max_array_texture_layers);
#endif
        sprite_tracker_set_limits(max_texture_size, max_array_texture_layers);
    }
    SpriteMap *ans = calloc(1, sizeof(SpriteMap));
    if (!ans) fatal("Out of memory allocating a sprite map");
    *ans = NEW_SPRITE_MAP;
    ans->max_texture_size = max_texture_size;
    ans->max_array_texture_layers = max_array_texture_layers;
    return (SPRITE_MAP_HANDLE)ans;
}

void
free_sprite_data(FONTS_DATA_HANDLE fg) {
    SpriteMap *sprite_map = (SpriteMap *)fg->sprite_map;
    if (sprite_map) {
        if (sprite_map->texture_id) free_texture(&sprite_map->texture_id);
        if (sprite_map->decorations_map.texture_id) free_texture(&sprite_map->decorations_map.texture_id);
        if (sprite_map->color_texture_id) free_texture(&sprite_map->color_texture_id);
        if (sprite_map->color_decorations_map.texture_id) free_texture(&sprite_map->color_decorations_map.texture_id);
        free(sprite_map);
        fg->sprite_map = NULL;
    }
}


static void
copy_32bit_texture(GLuint old_texture, GLuint new_texture, GLenum texture_type) {
    // requires new texture to be at least as big as old texture. Assumes textures are 32bits per pixel
    GLint width, height, layers;
    glBindTexture(texture_type, old_texture);
    glGetTexLevelParameteriv(texture_type, 0, GL_TEXTURE_WIDTH, &width);
    glGetTexLevelParameteriv(texture_type, 0, GL_TEXTURE_HEIGHT, &height);
    glGetTexLevelParameteriv(texture_type, 0, GL_TEXTURE_DEPTH, &layers);
    if (GLAD_GL_ARB_copy_image) {
        glCopyImageSubData(old_texture, texture_type, 0, 0, 0, 0, new_texture, texture_type, 0, 0, 0, 0, width, height, layers);
        return;
    }

    static bool copy_image_warned = false;
    // ARB_copy_image not available, do a slow roundtrip copy
    if (!copy_image_warned) {
        copy_image_warned = true;
        log_error("WARNING: Your system's OpenGL implementation does not have glCopyImageSubData, falling back to a slower implementation");
    }

    GLint internal_format;
    glGetTexLevelParameteriv(texture_type, 0, GL_TEXTURE_INTERNAL_FORMAT, &internal_format);
    GLenum format, type;
    unsigned bpp;  // bytes per texel of the round-trip (GPU->CPU->GPU) buffer
    switch(internal_format) {
        case GL_R8UI: case GL_R8I: case GL_R16UI: case GL_R16I: case GL_R32UI: case GL_R32I: case GL_RG8UI: case GL_RG8I:
        case GL_RG16UI: case GL_RG16I: case GL_RG32UI: case GL_RG32I: case GL_RGB8UI: case GL_RGB8I: case GL_RGB16UI:
        case GL_RGB16I: case GL_RGB32UI: case GL_RGB32I: case GL_RGBA8UI: case GL_RGBA8I: case GL_RGBA16UI: case GL_RGBA16I:
        case GL_RGBA32UI: case GL_RGBA32I:
            format = GL_RED_INTEGER;
            type = GL_UNSIGNED_INT;
            bpp = 4;
            break;
        case GL_R8: case GL_RED:
            // F1: single-channel mono atlas. macOS GL 4.1 has no ARB_copy_image,
            // so this slow round-trip runs for real on the GL backend during
            // atlas growth; read/write one byte per texel rather than assuming 4.
            format = GL_RED;
            type = GL_UNSIGNED_BYTE;
            bpp = 1;
            break;
        default:
            format = GL_RGBA;
            type = GL_UNSIGNED_INT_8_8_8_8;
            bpp = 4;
            break;
    }
    const GLint alignment = bpp >= 4 ? 4 : 1;  // R8 rows are byte-tight
    RAII_ALLOC(uint8_t, pixels, malloc((size_t)width * height * layers * bpp));
    if (!pixels) fatal("Out of memory");
    // glGetTexImage is a pack (GPU->CPU) op, glTexSubImage an unpack (CPU->GPU) op.
    glPixelStorei(GL_PACK_ALIGNMENT, alignment);
    glGetTexImage(texture_type, 0, format, type, pixels);
    glBindTexture(texture_type, new_texture);
    glPixelStorei(GL_UNPACK_ALIGNMENT, alignment);
    if (texture_type == GL_TEXTURE_2D_ARRAY) glTexSubImage3D(GL_TEXTURE_2D_ARRAY, 0, 0, 0, 0, width, height, layers, format, type, pixels);
    else glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, format, type, pixels);
}

static GLuint
setup_new_sprites_texture(GLenum texture_type) {
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(texture_type, tex);
    // We use GL_NEAREST otherwise glyphs that touch the edge of the cell
    // often show a border between cells
    glTexParameteri(texture_type, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(texture_type, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(texture_type, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(texture_type, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return tex;
}

// F1: GL_TEXTURE_SWIZZLE_* are core GL 3.3 but this build's GLAD header
// (kitty/gl-wrapper.h) and the Metal shim both omit them, so define them here
// for whichever backend is compiling. On the Metal backend glTexParameteri is a
// no-op (metal.h) and the swizzle is instead applied in metal_gl_tex_storage_3d.
#ifndef GL_TEXTURE_SWIZZLE_R
#define GL_TEXTURE_SWIZZLE_R 0x8E42
#endif
#ifndef GL_TEXTURE_SWIZZLE_G
#define GL_TEXTURE_SWIZZLE_G 0x8E43
#endif
#ifndef GL_TEXTURE_SWIZZLE_B
#define GL_TEXTURE_SWIZZLE_B 0x8E44
#endif
#ifndef GL_TEXTURE_SWIZZLE_A
#define GL_TEXTURE_SWIZZLE_A 0x8E45
#endif

// F1: report the atlas byte totals on every atlas (re)alloc when KITTY_METAL_STATS
// or debug_rendering is on, so the harness can confirm the mono atlas shrank to
// ~1/4 its former size (R8 vs the old RGBA). mono/color are the two array-texture
// atlases; the small R32UI decorations maps are not counted here.
static void
log_sprite_atlas_bytes(FONTS_DATA_HANDLE fg) {
    static int env = -1;
    if (env < 0) { const char *v = getenv("KITTY_METAL_STATS"); env = (v && v[0] && strcmp(v, "0") != 0) ? 1 : 0; }
    if (!env && !global_state.debug_rendering) return;
    unsigned mx, my, mz;
    sprite_tracker_current_layout(fg, &mx, &my, &mz);
    size_t cell_w = fg->fcm.cell_width, cell_h1 = (size_t)fg->fcm.cell_height + 1u;
    size_t mono_bpp = r8_sprite_atlas_enabled() ? 1u : 4u;
    size_t mono = (size_t)mx * cell_w * (size_t)my * cell_h1 * (mz + 1u) * mono_bpp;
    size_t color = 0;
    if (r8_sprite_atlas_enabled()) {
        unsigned cx, cy, cz;
        color_sprite_tracker_current_layout(fg, &cx, &cy, &cz);
        color = (size_t)cx * cell_w * (size_t)cy * cell_h1 * (cz + 1u) * 4u;
    }
    fprintf(stderr, "sprite_atlas_bytes total=%zu mono=%zu color=%zu\n", mono + color, mono, color);
}

static void
realloc_sprite_decorations_texture_if_needed(FONTS_DATA_HANDLE fg, struct decorations_map *dm) {
    SpriteMap *sm = (SpriteMap*)fg->sprite_map;
    size_t current_capacity = (size_t)dm->width * dm->height;
    if (dm->count < current_capacity && dm->texture_id) return;
    GLint new_capacity = dm->count + 256;
    GLint width = new_capacity, height = 1;
    if (new_capacity > sm->max_texture_size) {
        width = sm->max_texture_size;
        height = 1 + new_capacity / width;
    }
    if (height > sm->max_texture_size) fatal("Max texture size too small for sprite decorations map, maybe switch to using a GL_TEXTURE_2D_ARRAY");
    const GLenum texture_type = GL_TEXTURE_2D;
    GLuint tex = setup_new_sprites_texture(texture_type);
    glTexImage2D(texture_type, 0, GL_R32UI, width, height, 0, GL_RED_INTEGER, GL_UNSIGNED_INT, NULL);
    if (dm->texture_id) {  // copy data from old texture
        copy_32bit_texture(dm->texture_id, tex, texture_type);
        free_texture(&dm->texture_id);
    }
    glBindTexture(texture_type, 0);
    dm->texture_id = tex; dm->width = width; dm->height = height;
}

static void
realloc_sprite_texture(FONTS_DATA_HANDLE fg) {
    unsigned int xnum, ynum, z, znum, width, height;
    sprite_tracker_current_layout(fg, &xnum, &ynum, &z);
    znum = z + 1;
    SpriteMap *sprite_map = (SpriteMap *)fg->sprite_map;
    width = xnum * fg->fcm.cell_width;
    height = ynum * (fg->fcm.cell_height + 1);
    const GLenum texture_type = GL_TEXTURE_2D_ARRAY;
    GLuint tex = setup_new_sprites_texture(texture_type);
    // F1: the mono atlas only ever needs the coverage (alpha) channel, so store
    // it single-channel R8 and swizzle so a sampler still reads coverage in .a
    // (RGB<-1). glyph .rgb is unused for mono cells (colored_sprite==0 selects
    // cell_foreground), so the visible result is identical to the old
    // SRGB8_ALPHA8 atlas whose alpha channel is likewise linear coverage.
    const bool r8 = r8_sprite_atlas_enabled();
    glTexStorage3D(texture_type, 1, r8 ? GL_R8 : GL_SRGB8_ALPHA8, width, height, znum);
    if (r8) {
        glTexParameteri(texture_type, GL_TEXTURE_SWIZZLE_R, GL_ONE);
        glTexParameteri(texture_type, GL_TEXTURE_SWIZZLE_G, GL_ONE);
        glTexParameteri(texture_type, GL_TEXTURE_SWIZZLE_B, GL_ONE);
        glTexParameteri(texture_type, GL_TEXTURE_SWIZZLE_A, GL_RED);
    }
    if (sprite_map->texture_id) { // copy old texture data into new texture
        copy_32bit_texture(sprite_map->texture_id, tex, texture_type);
        free_texture(&sprite_map->texture_id);
    }
    glBindTexture(texture_type, 0);
    sprite_map->last_num_of_layers = znum;
    sprite_map->last_ynum = ynum;
    sprite_map->texture_id = tex;
    log_sprite_atlas_bytes(fg);
}

// F1: the colored (emoji) atlas — always RGBA, its own index namespace/layout
// (color_sprite_tracker). Only reached when r8_sprite_atlas_enabled(); under the
// kill switch colored sprites go into the single mono atlas via
// realloc_sprite_texture above, exactly as before F1.
static void
realloc_color_sprite_texture(FONTS_DATA_HANDLE fg) {
    unsigned int xnum, ynum, z, znum, width, height;
    color_sprite_tracker_current_layout(fg, &xnum, &ynum, &z);
    znum = z + 1;
    SpriteMap *sprite_map = (SpriteMap*)fg->sprite_map;
    width = xnum * fg->fcm.cell_width; height = ynum * (fg->fcm.cell_height + 1);
    const GLenum texture_type = GL_TEXTURE_2D_ARRAY;
    GLuint tex = setup_new_sprites_texture(texture_type);
    glTexStorage3D(texture_type, 1, GL_SRGB8_ALPHA8, width, height, znum);
    if (sprite_map->color_texture_id) {
        copy_32bit_texture(sprite_map->color_texture_id, tex, texture_type);
        free_texture(&sprite_map->color_texture_id);
    }
    glBindTexture(texture_type, 0);
    sprite_map->color_last_num_of_layers = znum;
    sprite_map->color_last_ynum = ynum;
    sprite_map->color_texture_id = tex;
    log_sprite_atlas_bytes(fg);
}

static void
ensure_sprite_map(FONTS_DATA_HANDLE fg) {
    SpriteMap *sprite_map = (SpriteMap*)fg->sprite_map;
    const bool r8 = r8_sprite_atlas_enabled();
    if (!sprite_map->texture_id) realloc_sprite_texture(fg);
    if (!sprite_map->decorations_map.texture_id) realloc_sprite_decorations_texture_if_needed(fg, &sprite_map->decorations_map);
    if (r8) {
        if (!sprite_map->color_texture_id) realloc_color_sprite_texture(fg);
        if (!sprite_map->color_decorations_map.texture_id) realloc_sprite_decorations_texture_if_needed(fg, &sprite_map->color_decorations_map);
    }
    // We have to rebind since we don't know if the texture was ever bound
    // in the context of the current OSWindow.
    // F1: keep the color-atlas sampler units complete. When the split atlas is
    // active they hold the real colored atlas + its decorations map; under the
    // kill switch they mirror the mono textures so the (never-sampled, because
    // color_atlas_active==0) color samplers still reference a valid texture.
    // These are bound FIRST so the last glActiveTexture leaves the mono
    // SPRITE_MAP_UNIT active exactly as the pre-F1 code did -- a later
    // send_image_to_gpu() (graphics upload this same frame) binds without
    // re-selecting a unit, so the trailing active unit must stay unit 0.
    glActiveTexture(GL_TEXTURE0 + COLOR_SPRITE_MAP_UNIT);
    glBindTexture(GL_TEXTURE_2D_ARRAY, r8 ? sprite_map->color_texture_id : sprite_map->texture_id);
    glActiveTexture(GL_TEXTURE0 + COLOR_SPRITE_DECORATIONS_MAP_UNIT);
    glBindTexture(GL_TEXTURE_2D, r8 ? sprite_map->color_decorations_map.texture_id : sprite_map->decorations_map.texture_id);
    glActiveTexture(GL_TEXTURE0 + SPRITE_DECORATIONS_MAP_UNIT);
    glBindTexture(GL_TEXTURE_2D, sprite_map->decorations_map.texture_id);
    glActiveTexture(GL_TEXTURE0 + SPRITE_MAP_UNIT);
    glBindTexture(GL_TEXTURE_2D_ARRAY, sprite_map->texture_id);
}

// F1: grow-only scratch for extracting the R8 coverage byte from an RGBA canvas
// tile. Main-thread only (render path), so a single shared buffer is safe.
static uint8_t *r8_extract_scratch = NULL;
static size_t r8_extract_scratch_px = 0;

void
send_sprite_to_gpu(FONTS_DATA_HANDLE fg, sprite_index idx, pixel *buf, sprite_index decoration_idx, bool colored) {
    SpriteMap *sprite_map = (SpriteMap*)fg->sprite_map;
    const bool use_color = colored && r8_sprite_atlas_enabled();
    const bool r8_mono = !colored && r8_sprite_atlas_enabled();
    unsigned int xnum, ynum, znum, x, y, z;

    // Decorations map: colored and mono sprites have separate index namespaces,
    // so each has its own map. The value written is always a mono-namespace
    // decoration index (decorations are only ever rendered into the mono atlas).
    struct decorations_map *dm = use_color ? &sprite_map->color_decorations_map : &sprite_map->decorations_map;
    if (idx >= dm->count) dm->count = idx + 1;
    realloc_sprite_decorations_texture_if_needed(fg, dm);
    div_t d = div(idx, dm->width);
    x = d.rem; y = d.quot;
    glActiveTexture(GL_TEXTURE0 + (use_color ? COLOR_SPRITE_DECORATIONS_MAP_UNIT : SPRITE_DECORATIONS_MAP_UNIT));
    glBindTexture(GL_TEXTURE_2D, dm->texture_id);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexSubImage2D(GL_TEXTURE_2D, 0, x, y, 1, 1, GL_RED_INTEGER, GL_UNSIGNED_INT, &decoration_idx);

    // Atlas upload into the selected namespace.
    if (use_color) {
        color_sprite_tracker_current_layout(fg, &xnum, &ynum, &znum);
        if ((int)znum >= sprite_map->color_last_num_of_layers || (znum == 0 && (int)ynum > sprite_map->color_last_ynum)) {
            realloc_color_sprite_texture(fg);
            color_sprite_tracker_current_layout(fg, &xnum, &ynum, &znum);
        }
        glActiveTexture(GL_TEXTURE0 + COLOR_SPRITE_MAP_UNIT);
        glBindTexture(GL_TEXTURE_2D_ARRAY, sprite_map->color_texture_id);
    } else {
        sprite_tracker_current_layout(fg, &xnum, &ynum, &znum);
        if ((int)znum >= sprite_map->last_num_of_layers || (znum == 0 && (int)ynum > sprite_map->last_ynum)) {
            realloc_sprite_texture(fg);
            sprite_tracker_current_layout(fg, &xnum, &ynum, &znum);
        }
        glActiveTexture(GL_TEXTURE0 + SPRITE_MAP_UNIT);
        glBindTexture(GL_TEXTURE_2D_ARRAY, sprite_map->texture_id);
    }
    sprite_index_to_pos(idx, xnum, ynum, &x, &y, &z);
    x *= fg->fcm.cell_width; y *= (fg->fcm.cell_height + 1);
    if (r8_mono) {
        // Extract the coverage (alpha) byte from each RGBA canvas pixel into a
        // tight R8 buffer. GL_UNSIGNED_INT_8_8_8_8 keeps alpha in the low byte
        // (buf[i] & 0xff) — exactly the channel the sampler reads as .a today —
        // so the R8 upload is byte-identical in coverage to the old RGBA upload.
        size_t npx = (size_t)fg->fcm.cell_width * (fg->fcm.cell_height + 1u);
        if (npx > r8_extract_scratch_px) {
            uint8_t *grown = realloc(r8_extract_scratch, npx);
            if (!grown) { log_error("Out of memory extracting R8 sprite mask (%zu px); skipping upload", npx); return; }
            r8_extract_scratch = grown; r8_extract_scratch_px = npx;
        }
        for (size_t i = 0; i < npx; i++) r8_extract_scratch[i] = (uint8_t)(buf[i] & 0xffu);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexSubImage3D(GL_TEXTURE_2D_ARRAY, 0, x, y, z, fg->fcm.cell_width, fg->fcm.cell_height + 1, 1, GL_RED, GL_UNSIGNED_BYTE, r8_extract_scratch);
    } else {
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
        glTexSubImage3D(GL_TEXTURE_2D_ARRAY, 0, x, y, z, fg->fcm.cell_width, fg->fcm.cell_height + 1, 1, GL_RGBA, GL_UNSIGNED_INT_8_8_8_8, buf);
    }
}

// W27 P4.2: the source layout for an image upload. An HDR (f=3232) image is
// four float32 components per pixel and its texture is GL_RGBA32F, which is the
// only internal format in this pipeline that can hold the >1.0 components EDR
// needs; every other image keeps the GL_SRGB_ALPHA 8-bit storage unchanged.
#define IMAGE_UPLOAD_SRC_FORMAT(is_hdr, is_opaque) ((is_hdr) ? GL_RGBA : ((is_opaque) ? GL_RGB : GL_RGBA))
#define IMAGE_UPLOAD_SRC_TYPE(is_hdr) ((is_hdr) ? GL_FLOAT : GL_UNSIGNED_BYTE)

void
send_image_to_gpu(GLuint *tex_id, const void* data, GLsizei width, GLsizei height, bool is_opaque, bool is_4byte_aligned, bool linear, RepeatStrategy repeat, bool is_hdr) {
    if (!(*tex_id)) { glGenTextures(1, tex_id);  }
    glBindTexture(GL_TEXTURE_2D, *tex_id);
    glPixelStorei(GL_UNPACK_ALIGNMENT, is_4byte_aligned ? 4 : 1);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, linear ? GL_LINEAR : GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, linear ? GL_LINEAR : GL_NEAREST);
    RepeatStrategy r;
    switch (repeat) {
        case REPEAT_MIRROR: r = GL_MIRRORED_REPEAT; break;
        case REPEAT_CLAMP: {
            static const GLfloat border_color[4] = {0};
            glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, border_color);
            r = GL_CLAMP_TO_BORDER;
            break;
        }
        default: r = GL_REPEAT;
    }
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, r);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, r);
    glTexImage2D(GL_TEXTURE_2D, 0, is_hdr ? GL_RGBA32F : GL_SRGB_ALPHA, width, height, 0,
                 IMAGE_UPLOAD_SRC_FORMAT(is_hdr, is_opaque), IMAGE_UPLOAD_SRC_TYPE(is_hdr), data);
}

void
update_image_on_gpu(GLuint tex_id, const void* data, GLsizei width, GLsizei height, bool is_opaque, bool is_4byte_aligned, bool is_hdr) {
    // G1: in-place pixel update of an already-allocated GL_SRGB_ALPHA texture
    // (filter/wrap/storage were set by send_image_to_gpu at allocation time and
    // survive a SubImage). On Metal this maps to replaceRegion -- no MTLTexture
    // release/newTextureWithDescriptor, i.e. no per-frame realloc for animations.
    // is_opaque only selects the source format (GL_RGB expands to RGBA, alpha=1);
    // the texture's internal format is unchanged, so switching opaque<->alpha
    // between frames needs no reallocation.
    glBindTexture(GL_TEXTURE_2D, tex_id);
    glPixelStorei(GL_UNPACK_ALIGNMENT, is_4byte_aligned ? 4 : 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height,
                    IMAGE_UPLOAD_SRC_FORMAT(is_hdr, is_opaque), IMAGE_UPLOAD_SRC_TYPE(is_hdr), data);
}

void
update_image_sub_region(GLuint tex_id, const void* data, GLsizei x, GLsizei y, GLsizei width, GLsizei height, bool is_opaque, bool is_4byte_aligned) {
    // G3-lite: upload only a sub-rectangle of an already-allocated image texture.
    // The rest of the texture (the coalesced base frame) is left intact, so a
    // non-blended animation delta becomes a small replaceRegion instead of a full
    // coalesce + full-image upload. `data` is the tightly packed delta (width px
    // per row); is_opaque selects the source format exactly as update_image_on_gpu.
    glBindTexture(GL_TEXTURE_2D, tex_id);
    glPixelStorei(GL_UNPACK_ALIGNMENT, is_4byte_aligned ? 4 : 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, x, y, width, height, is_opaque ? GL_RGB : GL_RGBA, GL_UNSIGNED_BYTE, data);
}

// }}}

// Rounded rect {{{
static double
thickness_as_float(const OSWindow *os_window, unsigned level) {
    level = MIN(level, arraysz(OPT(box_drawing_scale)));
    double pts = OPT(box_drawing_scale)[level];
    double dpi = (os_window->fonts_data->logical_dpi_x + os_window->fonts_data->logical_dpi_y) / 2.0;
    return pts * dpi / 72.0;
}


static void
draw_rounded_rect(
    const OSWindow *os_window,
    Viewport rect,
    unsigned framebuffer_height,
    unsigned thickness_level,
    unsigned corner_radius_px,
    color_type srgb_color,
    color_type srgb_background,
    float bg_alpha) {
    float thickness = (float)thickness_as_float(os_window, thickness_level);
    bind_program(ROUNDED_RECT_PROGRAM);
    color_vec4(program_uniform_location(ROUNDED_RECT_PROGRAM, "color"), srgb_color, 1.f);
    color_vec4(program_uniform_location(ROUNDED_RECT_PROGRAM, "background_color"), srgb_background, bg_alpha);
    // y co-ord has to be changed to co-ord system with origin at bottom left
    float y = (float)framebuffer_height - (float)(rect.top + rect.height);
    glUniform4f(program_uniform_location(ROUNDED_RECT_PROGRAM, "rect"), rect.left, y, rect.width, rect.height);
    glUniform2f(program_uniform_location(ROUNDED_RECT_PROGRAM, "params"), thickness, corner_radius_px);
    save_viewport_using_top_left_origin(rect.left, rect.top, rect.width, rect.height, framebuffer_height);
    draw_quad(true, 0);
    restore_viewport();
}
// }}}

// Cell {{{

enum {
    CELL_RENDER_DATA_BINDING_POINT = 0,
    COLOR_TABLE_BINDING_POINT = 1,
    GAMMA_LUT_BINDING_POINT = 2,
    BORDER_COLORS_BINDING_POINT = 3,
    CUSTOM_END_DATA_BINDING_POINT = 4
};
enum { GAMMA_LUT_GLOBAL_BUFFER, BORDER_COLORS_GLOBAL_BUFFER };
// VAOs used only to hold buffers for UBOs that are shared amongst programs/windows,
// their vertex attribute/array facilities are unused.
static ssize_t shader_globals_vao_idx = -1;
static ssize_t custom_end_vao_idx = -1;

typedef enum { CUSTOM_SHADER_TEXTURE_DEFAULT, CUSTOM_SHADER_TEXTURE_A, CUSTOM_SHADER_TEXTURE_B, CUSTOM_SHADER_TEXTURE_PERSIST } NamedTexture;

typedef struct CustomShaderGroup {
    struct {
        float x, y;
    } viewport_pos;
    struct {
        float w, h;
    } viewport_size;
    NamedTexture output_texture;
    unsigned animation_start_events;    // bitmask of ShaderAnimationEvent values; 0 = no own animation
    unsigned animation_end_events;      // bitmask of events that stop the animation; 0 = none
    monotonic_t animation_end_duration; // nanoseconds; 0 = no time limit, < 0 = use cursor_stop_blinking_after
    monotonic_t animation_step;         // nanoseconds between animation samples
    Animation *animation_curve;         // parsed easing curve; NULL = no animation
    bool animation_curve_is_shared;     // true if animation_curve is owned by an earlier group
    bool attached;                      // true = always active when the preceding group is active
} CustomShaderGroup;

typedef struct CustomShaderPipeline {
    unsigned textures; // bit mask of named textures from above enum
    CustomShaderGroup groups[MAX_CUSTOM_SHADER_GROUPS];
    size_t num_groups;
    bool active;
    bool bypass_builtin_trail;           // true when any group subscribes to cursor-trail-move
    unsigned all_animation_start_events; // union of animation_start_events across all groups
} CustomShaderPipeline;

static struct {
    CustomShaderPipeline end;
    size_t count;
} custom_shaders;

static void
write_float_array_to_ubo(void *dest, const GLfloat *src, size_t count, const ArrayInformation *ai) {
    GLint stride = MAX((GLint)sizeof(GLfloat), ai->stride);
    uint8_t *buf = (uint8_t *)dest + ai->offset;
    for (size_t i = 0; i < count; i++, buf += stride) memcpy(buf, src + i, sizeof(GLfloat));
}

#ifndef KITTY_BACKEND_METAL
static void
write_uint_array_to_ubo(void *dest, const GLuint *src, size_t count, const ArrayInformation *ai) {
    GLint stride = MAX((GLint)sizeof(GLuint), ai->stride);
    uint8_t *buf = (uint8_t *)dest + ai->offset;
    for (size_t i = 0; i < count; i++, buf += stride) memcpy(buf, src + i, sizeof(GLuint));
}
#endif

static void
init_cell_program(void) {
    GLint gamma_lut_buf_size = 0;
    for (int i = CELL_PROGRAM; i < CELL_PROGRAM_SENTINEL; i++) {
        UniformBlock crd = program_uniform_block(i, "CellRenderData");
        glUniformBlockBinding(program_id(i), crd.index, CELL_RENDER_DATA_BINDING_POINT);
        UniformBlock ct = program_uniform_block(i, "ColorTable");
        glUniformBlockBinding(program_id(i), ct.index, COLOR_TABLE_BINDING_POINT);
        UniformBlock glut = program_uniform_block(i, "GammaLUT");
        glUniformBlockBinding(program_id(i), glut.index, GAMMA_LUT_BINDING_POINT);
        gamma_lut_buf_size = MAX(gamma_lut_buf_size, glut.size);
    }

#ifndef KITTY_BACKEND_METAL
    // Sanity check to ensure the attribute location binding worked (OpenGL only)
#define C(p, name, expected) { int aloc = attrib_location(p, #name); if (aloc != expected && aloc != -1) fatal("The attribute location for %s is %d != %d in program: %d", #name, aloc, expected, p); }
    for (int p = CELL_PROGRAM; p < CELL_PROGRAM_SENTINEL; p++) {
        C(p, colors, 0);
        C(p, sprite_idx, 1);
        C(p, is_selected, 2);
        C(p, decorations_sprite_map, 3);
    }
#undef C
#endif
    UniformBlock border_colors = program_uniform_block(BORDERS_PROGRAM, "Colors");
    glUniformBlockBinding(program_id(BORDERS_PROGRAM), border_colors.index, BORDER_COLORS_BINDING_POINT);
    UniformBlock border_glut = program_uniform_block(BORDERS_PROGRAM, "GammaLUT");
    glUniformBlockBinding(program_id(BORDERS_PROGRAM), border_glut.index, GAMMA_LUT_BINDING_POINT);

    // The padding program shares the cell background computation and so uses the
    // same uniform blocks bound to the same binding points as the cell programs.
    {
        UniformBlock crd = program_uniform_block(PADDING_PROGRAM, "CellRenderData");
        glUniformBlockBinding(program_id(PADDING_PROGRAM), crd.index, CELL_RENDER_DATA_BINDING_POINT);
        UniformBlock ct = program_uniform_block(PADDING_PROGRAM, "ColorTable");
        glUniformBlockBinding(program_id(PADDING_PROGRAM), ct.index, COLOR_TABLE_BINDING_POINT);
        UniformBlock glut = program_uniform_block(PADDING_PROGRAM, "GammaLUT");
        glUniformBlockBinding(program_id(PADDING_PROGRAM), glut.index, GAMMA_LUT_BINDING_POINT);
    }
#ifndef KITTY_BACKEND_METAL
    // OpenGL only: the Metal attrib_location stub answers 0 for every name
    // (bindings live in the pipeline vertex descriptors), so this check would
    // always trip there.
#define C(name, expected)                                                                                                                     \
    {                                                                                                                                         \
        int aloc = attrib_location(PADDING_PROGRAM, #name);                                                                                   \
        if (aloc != expected && aloc != -1) fatal("The attribute location for %s is %d != %d in the padding program", #name, aloc, expected); \
    }
    C(colors, 0);
    C(sprite_idx, 1);
    C(is_selected, 2);
#undef C
#endif

    // The gamma LUT is a constant, shared amongst all the programs that use it via a single UBO.
    if (shader_globals_vao_idx == -1) {
        shader_globals_vao_idx = create_vao();
        add_buffer_to_vao(shader_globals_vao_idx, GL_UNIFORM_BUFFER);
        add_buffer_to_vao(shader_globals_vao_idx, GL_UNIFORM_BUFFER);
        gamma_lut_buf_size = MAX(gamma_lut_buf_size, border_glut.size);
        void *gamma_lut_buf = alloc_and_map_vao_buffer(shader_globals_vao_idx, gamma_lut_buf_size, GAMMA_LUT_GLOBAL_BUFFER, false);
        const ArrayInformation a = program_uniform_array(CELL_PROGRAM, "gamma_lut");
        write_float_array_to_ubo(gamma_lut_buf, srgb_lut, arraysz(srgb_lut), &a);
#ifdef KITTY_BACKEND_METAL
        // The Metal shim builds its resident gamma-LUT buffer (M5c) from a
        // glUniform1fv capture, not from the GammaLUT UBO written above (that
        // block never reaches the hand-written MSL). The fork's init fed it
        // through the per-program layout caches; feed the capture directly.
        for (int i = CELL_PROGRAM; i < CELL_PROGRAM_SENTINEL; i++) {
            bind_program(i);
            glUniform1fv(program_uniform_location(i, "gamma_lut"), arraysz(srgb_lut), srgb_lut);
        }
        bind_program(BORDERS_PROGRAM);
        glUniform1fv(program_uniform_location(BORDERS_PROGRAM, "gamma_lut"), arraysz(srgb_lut), srgb_lut);
#endif
        unmap_vao_buffer(shader_globals_vao_idx, GAMMA_LUT_GLOBAL_BUFFER);
        // The border colors change on every draw, but are shared amongst all border VAOs (only one is ever drawn at a time)
        alloc_vao_buffer(shader_globals_vao_idx, border_colors.size, BORDER_COLORS_GLOBAL_BUFFER, GL_STREAM_DRAW);
    }
    bind_shader_globals_to_current_context();
}

static void
init_custom_programs(void) {
    custom_shaders.count = 0;
    for (int i = CUSTOM_END_PROGRAM; i < NUM_PROGRAMS; i++) {
        Program *p = program_ptr(i);
        if (p && p->id) {
            custom_shaders.count++;
            if (i == CUSTOM_END_PROGRAM) {
                bind_program(i);
                glUniform1i(program_uniform_location(i, "backbuffer"), GRAPHICS_UNIT);
#define set_optional_sampler(name, unit)                   \
    {                                                      \
        GLint loc = try_program_uniform_location(i, name); \
        if (loc >= 0) glUniform1i(loc, unit);              \
    }
                set_optional_sampler("a", CUSTOM_END_TEXTURE_A_UNIT);
                set_optional_sampler("b", CUSTOM_END_TEXTURE_B_UNIT);
                set_optional_sampler("persist", CUSTOM_END_TEXTURE_PERSIST_UNIT);
#undef set_optional_sampler
                glUniform1i(program_uniform_location(i, "group"), 0);
                UniformBlock ubd = program_uniform_block(i, "KittyCustomShaderData");
                glUniformBlockBinding(program_id(i), ubd.index, CUSTOM_END_DATA_BINDING_POINT);
                if (custom_end_vao_idx == -1) {
                    custom_end_vao_idx = create_vao();
                    add_buffer_to_vao(custom_end_vao_idx, GL_UNIFORM_BUFFER);
                    alloc_vao_buffer(custom_end_vao_idx, ubd.size, 0, GL_STREAM_DRAW);
                }
            }
        }
    }
    // Free global named textures that are no longer declared in the pipeline
    if (!(custom_shaders.end.textures & (1u << CUSTOM_SHADER_TEXTURE_A))) {
        if (global_state.layers_render_texture.texture_a_id) free_texture(&global_state.layers_render_texture.texture_a_id);
        if (global_state.layers_render_texture.texture_a_fbo_id) free_framebuffer(&global_state.layers_render_texture.texture_a_fbo_id);
    }
    if (!(custom_shaders.end.textures & (1u << CUSTOM_SHADER_TEXTURE_B))) {
        if (global_state.layers_render_texture.texture_b_id) free_texture(&global_state.layers_render_texture.texture_b_id);
        if (global_state.layers_render_texture.texture_b_fbo_id) free_framebuffer(&global_state.layers_render_texture.texture_b_fbo_id);
    }
    // persist is per-window and freed lazily in start_os_window_rendering
    // Non-animated, non-attached groups are always active; animated groups start inactive.
    // Attached groups inherit their initial active state from their predecessor.
    bool any_initially_active = false;
    {
        bool prev_init = false;
        for (size_t i = 0; i < custom_shaders.end.num_groups; i++) {
            const CustomShaderGroup *cg = &custom_shaders.end.groups[i];
            bool this_init = cg->attached ? prev_init : (cg->animation_start_events == 0);
            if (this_init) any_initially_active = true;
            prev_init = this_init;
        }
    }
    bool initially_active = custom_shaders.count > 0 && any_initially_active;
    for (size_t w = 0; w < global_state.num_os_windows; w++) {
        OSWindow *osw = global_state.os_windows + w;
        zero_at_ptr_count(osw->shader_group_anim, custom_shaders.end.num_groups);
        // Initialize active=true for attached groups that follow always-active predecessors
        bool prev_init = false;
        for (size_t i = 0; i < custom_shaders.end.num_groups; i++) {
            const CustomShaderGroup *cg = &custom_shaders.end.groups[i];
            bool this_init = cg->attached ? prev_init : (cg->animation_start_events == 0);
            if (cg->attached && this_init) osw->shader_group_anim[i].active = true;
            prev_init = this_init;
        }
        osw->has_active_custom_shaders = initially_active;
        osw->shader_anim_min_step = MONOTONIC_T_MAX;
        osw->shader_anim_next_end_at = MONOTONIC_T_MAX;
        // Synthesize focus events for windows that already have focus so that
        // animations triggered by os-window-focus-in start on the first render
        // after shader compilation (the focus-in event fired before shaders were
        // compiled and was consumed without being processed).
        if (osw->is_focused) { osw->shader_anim_event_registry |= (1u << SHADER_ANIM_EVENT_OS_WINDOW_FOCUS_IN) | (1u << SHADER_ANIM_EVENT_WINDOW_FOCUS_IN); }
    }
    debug_rendering(
        "Custom shaders: %zu program(s), %zu group(s), textures_mask=0x%x, initially_active=%d\n",
        custom_shaders.count,
        custom_shaders.end.num_groups,
        custom_shaders.end.textures,
        initially_active);
}

static const char *
shader_anim_event_mask_str(unsigned mask) {
    static char buf[256];
    char *p = buf;
    char *const end = buf + sizeof(buf) - 1;
    static const struct {
        unsigned bit;
        const char *name;
    } events[] = {
        {1u << SHADER_ANIM_EVENT_POINTER_LEFT_BUTTON_PRESS, "pointer-left-button-press"},
        {1u << SHADER_ANIM_EVENT_OS_WINDOW_FOCUS_IN, "os-window-focus-in"},
        {1u << SHADER_ANIM_EVENT_OS_WINDOW_FOCUS_OUT, "os-window-focus-out"},
        {1u << SHADER_ANIM_EVENT_WINDOW_FOCUS_IN, "window-focus-in"},
        {1u << SHADER_ANIM_EVENT_WINDOW_FOCUS_OUT, "window-focus-out"},
        {1u << SHADER_ANIM_EVENT_TAB_CHANGE, "tab-change"},
        {1u << SHADER_ANIM_EVENT_BELL_IN_WINDOW, "bell-in-window"},
        {1u << SHADER_ANIM_EVENT_USER_ACTIVITY, "user-activity"},
        {1u << SHADER_ANIM_EVENT_USER_IDLE, "user-idle"},
        {1u << SHADER_ANIM_EVENT_CURSOR_TRAIL_MOVE, "cursor-trail-move"},
        {1u << SHADER_ANIM_EVENT_CURSOR_TRAIL_STOP, "cursor-trail-stop"},
    };
    bool first = true;
    for (size_t i = 0; i < sizeof(events) / sizeof(events[0]); i++) {
        if (!(mask & events[i].bit)) continue;
        if (!first && p < end) *p++ = '|';
        size_t len = strlen(events[i].name);
        if (p + len >= end) break;
        memcpy(p, events[i].name, len);
        p += len;
        first = false;
    }
    if (first) {
        memcpy(buf, "(none)", 7);
    } else {
        *p = '\0';
    }
    return buf;
}

monotonic_t
update_custom_shader_animations(unsigned event_mask, monotonic_t now, OSWindow *os_window) {
    if (!custom_shaders.count) {
        os_window->has_active_custom_shaders = false;
        return MONOTONIC_T_MAX;
    }
    // Fast path: no events and no duration-bounded animation expiring this frame.
    // Cached state is still valid — skip group iteration entirely.
    if (!event_mask && now < os_window->shader_anim_next_end_at) return os_window->shader_anim_min_step;

    // Slow path: update per-group state and recompute cached values in one pass.
    CustomShaderPipeline *p = &custom_shaders.end;
    bool any_active = false;
    monotonic_t min_step = MONOTONIC_T_MAX;
    monotonic_t next_end = MONOTONIC_T_MAX;
    bool prev_active = false;
    for (size_t i = 0; i < p->num_groups; i++) {
        const CustomShaderGroup *cg = &p->groups[i];
        bool this_active;
        if (!cg->attached && cg->animation_start_events == 0) {
            // Always-active, non-attached group — never enters the state machine.
            any_active = true;
            this_active = true;
        } else {
            monotonic_t eff_dur = cg->animation_end_duration < 0 ? OPT(cursor_stop_blinking_after) : cg->animation_end_duration;
            if (cg->animation_start_events != 0) {
                // Check end conditions before start so simultaneous start+end lets start win,
                // except for focus-out events which act as hard stops (see below).
                if (os_window->shader_group_anim[i].active) {
                    bool end = (cg->animation_end_events && (event_mask & cg->animation_end_events)) ||
                               (eff_dur > 0 && now - os_window->shader_group_anim[i].started_at >= eff_dur);
                    if (end) {
                        os_window->shader_group_anim[i].active = false;
                        debug_rendering("Custom shader group %zu animation stopped (events=%s)\n", i, shader_anim_event_mask_str(event_mask));
                    }
                }
                if (event_mask & cg->animation_start_events) {
                    // Focus-out events are hard stops: if a focus-out stop condition is present in
                    // the same tick as a start event (e.g. user-activity fired by the click that
                    // moved focus away), the focus-out wins and the animation is not restarted.
                    const unsigned focus_out_mask = (1u << SHADER_ANIM_EVENT_OS_WINDOW_FOCUS_OUT) | (1u << SHADER_ANIM_EVENT_WINDOW_FOCUS_OUT);
                    if (!(cg->animation_end_events & event_mask & focus_out_mask)) {
                        os_window->shader_group_anim[i].active = true;
                        os_window->shader_group_anim[i].started_at = now;
                        debug_rendering("Custom shader group %zu animation started (events=%s)\n", i, shader_anim_event_mask_str(event_mask));
                    }
                }
            }
            // Attach: follow the previous group's effective active state.
            if (cg->attached) {
                if (prev_active && !os_window->shader_group_anim[i].active) {
                    os_window->shader_group_anim[i].active = true;
                    // Sync animation timing with the previous group when possible.
                    monotonic_t prev_started = (i > 0) ? os_window->shader_group_anim[i - 1].started_at : 0;
                    os_window->shader_group_anim[i].started_at = prev_started ? prev_started : now;
                    debug_rendering("Custom shader group %zu activated via attach\n", i);
                } else if (!prev_active && cg->animation_start_events == 0 && os_window->shader_group_anim[i].active) {
                    // No own events: mirror the previous group's deactivation.
                    os_window->shader_group_anim[i].active = false;
                }
            }
            this_active = os_window->shader_group_anim[i].active;
            if (this_active) {
                any_active = true;
                min_step = MIN(min_step, cg->animation_step);
                // Only track next_end for groups with own stop conditions; attached-only groups
                // deactivate when their predecessor does (already tracked by the predecessor).
                if (cg->animation_start_events != 0 && eff_dur > 0) next_end = MIN(next_end, os_window->shader_group_anim[i].started_at + eff_dur);
            }
        }
        prev_active = this_active;
    }
    bool prev_has_active = os_window->has_active_custom_shaders;
    os_window->has_active_custom_shaders = any_active;
    if (prev_has_active != any_active) debug_rendering("has_active_custom_shaders: %d -> %d\n", prev_has_active, any_active);
    os_window->shader_anim_min_step = min_step;
    os_window->shader_anim_next_end_at = next_end;
    return min_step;
}

void
bind_shader_globals_to_current_context(void) {
    if (shader_globals_vao_idx == -1) return;
    bind_vao_uniform_buffer(shader_globals_vao_idx, GAMMA_LUT_GLOBAL_BUFFER, GAMMA_LUT_BINDING_POINT);
    bind_vao_uniform_buffer(shader_globals_vao_idx, BORDER_COLORS_GLOBAL_BUFFER, BORDER_COLORS_BINDING_POINT);
}

#define CELL_BUFFERS enum { cell_data_buffer, selection_buffer, uniform_buffer, color_table_buffer, padding_cell_data_buffer, padding_selection_buffer };

ssize_t
create_cell_vao(void) {
    ssize_t vao_idx = create_vao();
#define A(name, size, dtype, offset, stride) \
    add_attribute_to_vao(                    \
        vao_idx, program_attribute_location(CELL_PROGRAM, name), /*size=*/size, /*dtype=*/dtype, /*stride=*/stride, /*offset=*/offset, /*divisor=*/1);
#define A1(name, size, dtype, offset) A(name, size, dtype, (void *)(offsetof(GPUCell, offset)), sizeof(GPUCell))

    add_buffer_to_vao(vao_idx, GL_ARRAY_BUFFER);
    A1("sprite_idx", 2, GL_UNSIGNED_INT, sprite_idx);
    A1("colors", 3, GL_UNSIGNED_INT, fg);

    add_buffer_to_vao(vao_idx, GL_ARRAY_BUFFER);
    A("is_selected", 1, GL_UNSIGNED_BYTE, NULL, 0);

    size_t bufnum = add_buffer_to_vao(vao_idx, GL_UNIFORM_BUFFER);
    alloc_vao_buffer(vao_idx, program_uniform_block(CELL_PROGRAM, "CellRenderData").size, bufnum, GL_STREAM_DRAW);

    size_t ctbufnum = add_buffer_to_vao(vao_idx, GL_UNIFORM_BUFFER);
    alloc_vao_buffer(vao_idx, program_uniform_block(CELL_PROGRAM, "ColorTable").size, ctbufnum, GL_STATIC_DRAW);

    add_buffer_to_vao(vao_idx, GL_ARRAY_BUFFER); // padding_cell_data_buffer (slot 4)
    add_buffer_to_vao(vao_idx, GL_ARRAY_BUFFER); // padding_selection_buffer  (slot 5)

    return vao_idx;
#undef A
#undef A1
}

#define IS_SPECIAL_COLOR(name)                                          \
    (screen->color_profile->overridden.name.type == COLOR_IS_SPECIAL || \
     (screen->color_profile->overridden.name.type == COLOR_NOT_SET && screen->color_profile->configured.name.type == COLOR_IS_SPECIAL))

static void
pick_cursor_color(color_type cell_fg, color_type cell_bg, color_type *cursor_fg, color_type *cursor_bg, color_type default_fg, color_type default_bg) {
    ARGB32 fg, bg, dfg, dbg;
    fg.rgb = cell_fg;
    bg.rgb = cell_bg;
    *cursor_fg = cell_bg;
    *cursor_bg = cell_fg;
    double cell_contrast = rgb_contrast(fg, bg);
    if (cell_contrast < 2.5) {
        dfg.rgb = default_fg;
        dbg.rgb = default_bg;
        if (rgb_contrast(dfg, dbg) > cell_contrast) {
            *cursor_fg = default_bg;
            *cursor_bg = default_fg;
        }
    }
}

static bool
has_bgimage(OSWindow *w) {
    return background_image_for_os_window(w) != NULL;
}

struct GPUCellRenderData {
    GLfloat use_cell_bg_for_selection_fg, use_cell_fg_for_selection_color, use_cell_for_selection_bg;

    GLuint default_fg, highlight_fg, highlight_bg, main_cursor_fg, main_cursor_bg, url_color, url_style, inverted, extra_cursor_fg, extra_cursor_bg;

    GLuint columns, lines, sprites_xnum, sprites_ynum, cursor_shape, cell_width, cell_height;
    GLuint cursor_x1, cursor_x2, cursor_y1, cursor_y2;
    GLfloat cursor_opacity, inactive_text_alpha, fg_override_threshold, row_offset, dim_opacity, blink_opacity;

    GLuint bg_colors0, bg_colors1, bg_colors2, bg_colors3, bg_colors4, bg_colors5, bg_colors6, bg_colors7;
    GLfloat bg_opacities0, bg_opacities1, bg_opacities2, bg_opacities3, bg_opacities4, bg_opacities5, bg_opacities6, bg_opacities7;

    // F1: colored-atlas layout + activation flag. Appended so all prior std140
    // offsets are unchanged; mirrors MetalCellRenderData / the CellRenderData UBO
    // block in cell_vertex.glsl.
    GLuint color_sprites_xnum, color_sprites_ynum, color_atlas_active;
};

// Drift gate: the Metal backend reads this exact buffer back as
// MetalCellRenderData (kitty/metal_uniforms.h, included verbatim by
// cell_shaders.metal). A field inserted HERE shifts every later member on that
// side only, and the asserts over there -- which pin MetalCellRenderData against
// hardcoded byte offsets -- cannot see it. Upstream adding fg_override_threshold
// and row_offset to the block did exactly that, silently. Pin the pair.
_Static_assert(sizeof(struct GPUCellRenderData) == sizeof(MetalCellRenderData), "GPUCellRenderData and MetalCellRenderData sizes drifted");
_Static_assert(offsetof(struct GPUCellRenderData, fg_override_threshold) == offsetof(MetalCellRenderData, fg_override_threshold), "fg_override_threshold offset drifted");
_Static_assert(offsetof(struct GPUCellRenderData, row_offset) == offsetof(MetalCellRenderData, row_offset), "row_offset offset drifted");
_Static_assert(offsetof(struct GPUCellRenderData, dim_opacity) == offsetof(MetalCellRenderData, dim_opacity), "dim_opacity offset drifted");
_Static_assert(offsetof(struct GPUCellRenderData, bg_colors0) == offsetof(MetalCellRenderData, bg_colors0), "bg_colors offset drifted");
_Static_assert(offsetof(struct GPUCellRenderData, bg_opacities0) == offsetof(MetalCellRenderData, bg_opacities0), "bg_opacities offset drifted");
_Static_assert(offsetof(struct GPUCellRenderData, color_sprites_xnum) == offsetof(MetalCellRenderData, color_sprites_xnum), "R8-atlas block offset drifted");

// D4: per-VAO shadow of the last GPUCellRenderData actually written to the GPU
// buffer. Lets cell_update_uniform_block() elide the map+write (which on the
// Metal backend advances the persistent buffer ring and copies-forward the slot
// contents, see map_vao_buffer_for_write_only()/ring_acquire_slot() in metal.m --
// and on GL remaps the buffer range) whenever this render produces byte-identical
// uniform data to
// what is already resident: idle cursor blink between opacity steps, or any
// render triggered by another window's damage. Indexed 1:1 with the vao_idx
// space both backends use (kitty/gl.c, kitty/metal.m: `vaos[4*MAX_CHILDREN+10]`),
// so every valid vao_idx has a slot; statically zero-initialized, so a slot
// recycled by remove_vao()+create_vao() for an unrelated window starts
// "invalid" and is forced to write on its first use below. That first write is
// guaranteed: every (re)association of a Screen with GPU resources sets
// screen->reload_all_gpu_data = true (new_screen_object() in screen.c;
// attach_window() in state.c), which this function also treats as "any doubt,
// write" and never skips on.
#define MAX_CELL_UNIFORM_VAOS (4 * MAX_CHILDREN + 10)
typedef struct UniformBlockShadow { bool valid; struct GPUCellRenderData data; } UniformBlockShadow;
static UniformBlockShadow cell_uniform_shadows[MAX_CELL_UNIFORM_VAOS] = {{0}};

static UniformBlockShadow*
uniform_block_shadow_for_vao(ssize_t vao_idx) {
    if (vao_idx < 0 || (size_t)vao_idx >= arraysz(cell_uniform_shadows)) return NULL;
    return &cell_uniform_shadows[vao_idx];
}

static color_type
cell_update_uniform_block(ssize_t vao_idx, Screen *screen, int uniform_buffer, int color_table_buf, const CursorRenderInfo *cursor, OSWindow *os_window, float inactive_text_alpha, float bg_alpha) {
    // Send the uniform data
    ColorProfile *cp = screen->paused_rendering.expires_at ? &screen->paused_rendering.color_profile : screen->color_profile;
    if (cp->dirty || screen->reload_all_gpu_data) {
        const ArrayInformation ai = program_uniform_array(CELL_PROGRAM, "color_table");
        uint8_t *base = (uint8_t *)map_vao_buffer_for_write_only(vao_idx, color_table_buf, 0, program_uniform_block(CELL_PROGRAM, "ColorTable").size);
        GLuint *ct_buf = (GLuint *)(base + ai.offset);
        copy_color_table_to_buffer(cp, ct_buf, 0, ai.stride / sizeof(GLuint));
#ifdef KITTY_BACKEND_METAL
        // W27 P3.5b: the wide-gamut colour carrier's GPU-side table. Metal
        // packed layout only (the array stride is 1 uint there): 264 uints
        // (1056 B, see METAL_COLOR_TABLE_ENTRIES in kitty/metal.m) followed
        // by 264 float4s that the block size grows the buffer to fit. Gated on
        // the compile-time Metal backend selector (not just the runtime
        // drawable-format probe) so a real-GL macOS build with the env var
        // set for some other reason never overwrites its own colour table.
        if (kitty_drawable_primaries_wide()) {
            colorprofile_fill_wide_gpu(cp, (uint32_t*)ct_buf, (float*)(ct_buf + 264), 264);
        }
#endif
        unmap_vao_buffer(vao_idx, color_table_buf);
        D2_NOTE_BYTES(program_uniform_block(CELL_PROGRAM, "ColorTable").size);
    }
    UniformBlockShadow *shadow = uniform_block_shadow_for_vao(vao_idx);
    struct GPUCellRenderData computed;
    // Seed from the shadow (last value actually written to the GPU buffer) so
    // fields not assigned on every path below -- main_cursor_fg/main_cursor_bg
    // when the cursor is not visible -- carry forward their previous value
    // exactly as the mapped GPU buffer used to preserve them across an orphan
    // (Metal) or invalidate-range remap (GL). A never-written slot starts zeroed.
    if (shadow && shadow->valid) computed = shadow->data; else memset(&computed, 0, sizeof(computed));
    struct GPUCellRenderData *rd = &computed;
#define COLOR(name) colorprofile_to_color(cp, cp->overridden.name, cp->configured.name).rgb
    rd->default_fg = COLOR(default_fg);
    rd->highlight_fg = COLOR(highlight_fg);
    rd->highlight_bg = COLOR(highlight_bg);
    rd->extra_cursor_fg = screen->extra_cursors.color.text.val;
    rd->extra_cursor_bg = screen->extra_cursors.color.cursor.val;
    rd->bg_colors0 = COLOR(default_bg);
    rd->bg_opacities0 = bg_alpha;
    rd->fg_override_threshold = OPT(text_fg_override_threshold);
    rd->row_offset = row_offset_for_screen(screen);
#define SETBG(which) \
    { colorprofile_to_transparent_color(cp, which - 1, &rd->bg_colors##which, &rd->bg_opacities##which); }
    SETBG(1);
    SETBG(2);
    SETBG(3);
    SETBG(4);
    SETBG(5);
    SETBG(6);
    SETBG(7);
#undef SETBG
    // selection
    if (IS_SPECIAL_COLOR(highlight_fg)) {
        if (IS_SPECIAL_COLOR(highlight_bg)) {
            rd->use_cell_bg_for_selection_fg = 1.f;
            rd->use_cell_fg_for_selection_color = 0.f;
        } else {
            rd->use_cell_bg_for_selection_fg = 0.f;
            rd->use_cell_fg_for_selection_color = 1.f;
        }
    } else {
        rd->use_cell_bg_for_selection_fg = 0.f;
        rd->use_cell_fg_for_selection_color = 0.f;
    }
    rd->use_cell_for_selection_bg = IS_SPECIAL_COLOR(highlight_bg) ? 1. : 0.;
    // Cursor position
    Line *line_for_cursor = NULL;
    rd->cursor_opacity = MAX(0, MIN(cursor->cursor_opacity, 1));
    rd->blink_opacity = MAX(0, MIN(cursor->text_blink_opacity, 1));
    if (rd->cursor_opacity != 0 && cursor->is_visible) {
        rd->cursor_x1 = cursor->x, rd->cursor_y1 = cursor->y;
        rd->cursor_x2 = cursor->x, rd->cursor_y2 = cursor->y;
        if (pixel_scroll_enabled(screen)) {
            rd->cursor_y1 += 1;
            rd->cursor_y2 += 1;
        }
        CursorShape cs = (cursor->is_focused || OPT(cursor_shape_unfocused) == NO_CURSOR_SHAPE) ? cursor->shape : OPT(cursor_shape_unfocused);
        rd->cursor_shape = cs;
        color_type cell_fg = rd->default_fg, cell_bg = rd->bg_colors0;
        index_type cell_color_x = cursor->x;
        bool reversed = false;
        if (cursor->x < screen->columns && cursor->y < screen->lines) {
            if (screen->paused_rendering.expires_at) {
                linebuf_init_line(screen->paused_rendering.linebuf, cursor->y);
                line_for_cursor = screen->paused_rendering.linebuf->line;
            } else {
                linebuf_init_line(screen->linebuf, cursor->y);
                line_for_cursor = screen->linebuf->line;
            }
        }
        if (line_for_cursor) {
            colors_for_cell(line_for_cursor, cp, &cell_color_x, &cell_fg, &cell_bg, &reversed);
            const CPUCell *cursor_cell;
            const bool large_cursor = ((cursor_cell = &line_for_cursor->cpu_cells[cursor->x])->is_multicell) && cursor_cell->x == 0 && cursor_cell->y == 0;
            if (large_cursor) {
                switch (cs) {
                    case CURSOR_BEAM: rd->cursor_y2 += cursor_cell->scale - 1; break;
                    case CURSOR_UNDERLINE:
                        rd->cursor_y1 += cursor_cell->scale - 1;
                        rd->cursor_y2 = rd->cursor_y1;
                        rd->cursor_x2 += mcd_x_limit(cursor_cell) - 1;
                        break;
                    case CURSOR_BLOCK:
                        rd->cursor_y2 += cursor_cell->scale - 1;
                        rd->cursor_x2 += mcd_x_limit(cursor_cell) - 1;
                        break;
                    case CURSOR_HOLLOW:
                    case NUM_OF_CURSOR_SHAPES:
                    case NO_CURSOR_SHAPE: break;
                };
            }
        }
        // If you change the following algorithm remember to change it in the cell shader for extra cursors too
        if (IS_SPECIAL_COLOR(cursor_color)) {
            if (line_for_cursor) pick_cursor_color(cell_fg, cell_bg, &rd->main_cursor_fg, &rd->main_cursor_bg, rd->default_fg, rd->bg_colors0);
            else {
                rd->main_cursor_fg = rd->bg_colors0;
                rd->main_cursor_bg = rd->default_fg;
            }
            if (cell_bg == cell_fg) {
                rd->main_cursor_fg = rd->bg_colors0;
                rd->main_cursor_bg = rd->default_fg;
            } else {
                rd->main_cursor_fg = cell_bg;
                rd->main_cursor_bg = cell_fg;
            }
        } else {
            rd->main_cursor_bg = COLOR(cursor_color);
            if (IS_SPECIAL_COLOR(cursor_text_color)) rd->main_cursor_fg = cell_bg;
            else rd->main_cursor_fg = COLOR(cursor_text_color);
        }
        // store last rendered cursor color for trail rendering
        screen->last_rendered.cursor_bg = rd->main_cursor_bg;
    } else {
        rd->cursor_shape = 0;
        rd->cursor_x1 = screen->columns + 1;
        rd->cursor_x2 = screen->columns;
        rd->cursor_y1 = screen->lines + 1;
        rd->cursor_y2 = screen->lines;
    }

    rd->columns = screen->columns;
    rd->lines = screen->lines;

    unsigned int x, y, z;
    sprite_tracker_current_layout(os_window->fonts_data, &x, &y, &z);
    rd->sprites_xnum = x; rd->sprites_ynum = y;
    // F1: colored-atlas layout + activation. When disabled the shader keeps
    // sampling the single mono atlas (color_atlas_active==0), so these values are
    // unused; set them anyway to keep the uniform block deterministic.
    unsigned int cx, cy, cz;
    color_sprite_tracker_current_layout(os_window->fonts_data, &cx, &cy, &cz);
    rd->color_sprites_xnum = cx; rd->color_sprites_ynum = cy;
    rd->color_atlas_active = r8_sprite_atlas_enabled() ? 1u : 0u;
    rd->inverted = screen_invert_colors(screen) ? 1 : 0;
    rd->cell_width = os_window->fonts_data->fcm.cell_width;
    rd->cell_height = os_window->fonts_data->fcm.cell_height;
    rd->inactive_text_alpha = inactive_text_alpha;
    rd->dim_opacity = OPT(dim_opacity);

#undef COLOR
    rd->url_color = OPT(url_color);
    rd->url_style = OPT(url_style);
    color_type default_bg = rd->bg_colors0;
    // D4: only publish to the GPU buffer when the computed data actually
    // differs from what is already resident there. Any doubt writes: a missing
    // shadow slot, a never-yet-written slot, or reload_all_gpu_data (the same
    // "force everything" signal already used for the color table above) all
    // force the write, matching cp->dirty's precedent.
    if (!shadow || !shadow->valid || screen->reload_all_gpu_data || memcmp(&shadow->data, &computed, sizeof(computed)) != 0) {
        struct GPUCellRenderData *gpu = (struct GPUCellRenderData*)map_vao_buffer_for_write_only(vao_idx, uniform_buffer, 0, program_uniform_block(CELL_PROGRAM, "CellRenderData").size);
        if (gpu) {
            *gpu = computed;
            unmap_vao_buffer(vao_idx, uniform_buffer);
            D2_NOTE_BYTES(program_uniform_block(CELL_PROGRAM, "CellRenderData").size);
        }
        if (shadow) { shadow->data = computed; shadow->valid = true; }
    }
    return default_bg;
}

static bool
cell_prepare_to_render(ssize_t vao_idx, Screen *screen, FONTS_DATA_HANDLE fonts_data) {
    size_t sz;
    CELL_BUFFERS;
    void *address;
    bool changed = false;

    ensure_sprite_map(fonts_data);
    const Cursor *cursor = screen->paused_rendering.expires_at ? &screen->paused_rendering.cursor : screen->cursor;

    bool cursor_pos_changed = cursor->x != screen->last_rendered.cursor.x || cursor->y != screen->last_rendered.cursor.y;
    bool disable_ligatures = screen->disable_ligatures == DISABLE_LIGATURES_CURSOR;
    bool screen_resized = screen->last_rendered.columns != screen->columns || screen->last_rendered.lines != screen->lines;

#define update_cell_data { \
        const unsigned int render_lines = render_lines_for_screen(screen); \
        sz = sizeof(GPUCell) * render_lines * screen->columns; \
        address = alloc_and_map_vao_buffer(vao_idx, sz, cell_data_buffer, true); \
        const bool cell_force_full = D2_TAKE_FRESH(vao_idx, cell_data_buffer); \
        D2_NOTE_BYTES(screen_update_cell_data(screen, address, fonts_data, disable_ligatures && cursor_pos_changed, cell_force_full)); \
        unmap_vao_buffer(vao_idx, cell_data_buffer); address = NULL; \
        changed = true; \
}

    if (screen->paused_rendering.expires_at) {
        if (!screen->paused_rendering.cell_data_updated) update_cell_data;
    } else if (screen->reload_all_gpu_data || screen->scroll_changed || screen->is_dirty || screen_resized || (disable_ligatures && cursor_pos_changed))
        update_cell_data;

#define update_selection_data { \
    const unsigned int render_lines = render_lines_for_screen(screen); \
    sz = (size_t)render_lines * screen->columns; \
    address = alloc_and_map_vao_buffer(vao_idx, sz, selection_buffer, true); \
    screen_apply_selection(screen, address, sz); \
    D2_NOTE_BYTES(sz); /* selection stays a full rewrite, but only when dirty (already gated) */ \
    unmap_vao_buffer(vao_idx, selection_buffer); address = NULL; \
    changed = true; \
}

#define update_graphics_data(grman)             \
    grman_update_layers(                        \
        grman,                                  \
        screen->scrolled_by,                    \
        scroll_offset_lines_for_screen(screen), \
        -1.f,                                   \
        1.f,                                    \
        2.f / screen->columns,                  \
        2.f / screen->lines,                    \
        screen->columns,                        \
        screen->lines,                          \
        screen->cell_size)

    if (screen->paused_rendering.expires_at) {
        if (!screen->paused_rendering.cell_data_updated) {
            update_selection_data;
            update_graphics_data(screen->paused_rendering.grman);
        }
        screen->paused_rendering.cell_data_updated = true;
        screen->last_rendered.scrolled_by = screen->paused_rendering.scrolled_by;
    } else {
        if (screen->reload_all_gpu_data || screen_resized || screen_is_selection_dirty(screen)) update_selection_data;
        if (update_graphics_data(screen->grman)) changed = true;
        screen->last_rendered.scrolled_by = screen->scrolled_by;
    }
#undef update_selection_data
#undef update_cell_data
    screen->last_rendered.columns = screen->columns;
    screen->last_rendered.lines = screen->lines;
    screen->last_rendered.cursor = screen->cursor_render_info;

    return changed;
}

// G2 kill switch: KITTY_NO_INSTANCED_IMAGE_DRAWS=1 reverts to one draw call per
// image ref (chunk size 1), for A/B verification and as a safety revert.
static bool
instanced_image_draws_enabled(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *v = getenv("KITTY_NO_INSTANCED_IMAGE_DRAWS");
        cached = (v && v[0] && strcmp(v, "0") != 0) ? 0 : 1;
    }
    return cached == 1;
}

static void
draw_graphics(int program, ImageRenderData *data, GLuint start, GLuint count, float extra_alpha, float edr_headroom) {
    bind_program(program);
#ifdef KITTY_BACKEND_METAL
    // G2 + W27 P4.2: the fork's instanced path pairs with graphics_fork.slang's
    // instanced vertex shader and per-image HDR tone-map uniforms; the GL arm
    // below pairs with upstream's one-draw-per-ref graphics shaders.
    const bool is_alpha_mask = program == GRAPHICS_ALPHA_MASK_PROGRAM;
    if (!is_alpha_mask) {
        glUniform1f(program_uniform_location(program, "extra_alpha"), extra_alpha);
        // W27 P4.2: the tone map's ceiling. Floored at 1.0 because a headroom
        // below that is not a dimmer screen, it is an unread/absent value, and
        // the shader would clamp to it.
        glUniform1f(program_uniform_location(program, "edr_headroom"), edr_headroom >= 1.f ? edr_headroom : 1.f);
    }
    glActiveTexture(GL_TEXTURE0 + GRAPHICS_UNIT);
    const GLuint max_chunk = instanced_image_draws_enabled() ? MAX_IMAGE_INSTANCES : 1;
    const GLint src_is_hdr_loc = is_alpha_mask ? -1 : program_uniform_location(program, "src_is_hdr");
    const GLint src_max_component_loc = is_alpha_mask ? -1 : program_uniform_location(program, "src_max_component");
    const GLint src_rects_loc = program_uniform_location(program, "src_rects");
    const GLint dest_rects_loc = program_uniform_location(program, "dest_rects");
    for (GLuint i=0; i < count;) {
        ImageRenderData *group = data + start + i;
        glBindTexture(GL_TEXTURE_2D, group->texture_id);
        if (group->group_count == 0) { i++; continue; }
        const GLuint g = group->group_count;
        // Per source image, so a mixed SDR/HDR screen tone-maps each image
        // against its own range. Refs are grouped by image, so this is one pair
        // of uniform writes per texture, not per instance.
        if (!is_alpha_mask) {
            glUniform1f(src_is_hdr_loc, group->src_is_hdr);
            glUniform1f(src_max_component_loc, group->src_max_component);
        }
        // G2: draw the whole same-texture group as instanced quads -- one image
        // ref per instance -- chunked to MAX_IMAGE_INSTANCES. Refs are consumed in
        // their sorted order and chunks issue in sequence, so overlapping blends
        // resolve identically to the old one-draw-per-ref path.
        for (GLuint done = 0; done < g; ) {
            const GLuint chunk = MIN(g - done, max_chunk);
            float srcs[MAX_IMAGE_INSTANCES * 4] = {0}, dests[MAX_IMAGE_INSTANCES * 4] = {0};
            for (GLuint k = 0; k < chunk; k++) {
                ImageRenderData *rd = data + start + i + done + k;
                srcs[k*4+0] = rd->src_rect.left;   srcs[k*4+1] = rd->src_rect.top;   srcs[k*4+2] = rd->src_rect.right;   srcs[k*4+3] = rd->src_rect.bottom;
                dests[k*4+0] = rd->dest_rect.left;  dests[k*4+1] = rd->dest_rect.top;  dests[k*4+2] = rd->dest_rect.right;  dests[k*4+3] = rd->dest_rect.bottom;
            }
            // Always upload the full array so the Metal shim routes it to the
            // array-uniform store (its count>1 rule); only `chunk` instances draw.
            glUniform4fv(src_rects_loc, MAX_IMAGE_INSTANCES, srcs);
            glUniform4fv(dest_rects_loc, MAX_IMAGE_INSTANCES, dests);
            draw_quad(true, chunk);
            done += chunk;
        }
        i += g;
    }
#else
    (void)edr_headroom;
    if (program != GRAPHICS_ALPHA_MASK_PROGRAM) glUniform1f(program_uniform_location(program, "extra_alpha"), extra_alpha);
    glActiveTexture(GL_TEXTURE0 + GRAPHICS_UNIT);
    GLint src_rect_loc = program_uniform_location(program, "src_rect");
    GLint dest_rect_loc = program_uniform_location(program, "dest_rect");
    for (GLuint i = 0; i < count;) {
        ImageRenderData *group = data + start + i;
        glBindTexture(GL_TEXTURE_2D, group->texture_id);
        if (group->group_count == 0) {
            i++;
            continue;
        }
        for (GLuint k = 0; k < group->group_count; k++, i++) {
            ImageRenderData *rd = data + start + i;
            glUniform4f(src_rect_loc, rd->src_rect.left, rd->src_rect.top, rd->src_rect.right, rd->src_rect.bottom);
            glUniform4f(dest_rect_loc, rd->dest_rect.left, rd->dest_rect.top, rd->dest_rect.right, rd->dest_rect.bottom);
            draw_quad(true, 0);
        }
    }
#endif
}

static ImageRenderData *
load_alpha_mask_texture(size_t width, size_t height, uint8_t *canvas) {
    static ImageRenderData data = {.group_count = 1};
    if (!data.texture_id) { glGenTextures(1, &data.texture_id); }
    glBindTexture(GL_TEXTURE_2D, data.texture_id);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RED, width, height, 0, GL_RED, GL_UNSIGNED_BYTE, canvas);
    return &data;
}

static void
setup_texture_as_render_target(unsigned width, unsigned height, GLuint *texture_id, GLuint *framebuffer_id) {
    glGenTextures(1, texture_id);
    glGenFramebuffers(1, framebuffer_id);
    glBindTexture(GL_TEXTURE_2D, *texture_id);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    // We use GL_RGBA16 to avoid incorrect colors due to quantization loss when
    // blending, see https://github.com/kovidgoyal/kitty/issues/8953
    static struct {
        bool ok;
        int fmt;
    } status = {false, GL_RGBA16};
    glTexImage2D(GL_TEXTURE_2D, 0, status.fmt, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    bind_framebuffer_for_output(*framebuffer_id);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, *texture_id, 0);
    if (!status.ok) {
        if (check_framebuffer_status() == NULL) {
            status.ok = true;
        } else {
            if (status.fmt == GL_RGBA16) {
                // Driver does not support 16 bit FBO so let it choose the
                // format. It will probably end up choosing 8 bit but
                // inaccurate colors are better than completely broken rendering.
                // See https://github.com/kovidgoyal/kitty/issues/9068
                status.fmt = GL_RGBA;
                free_framebuffer(framebuffer_id);
                free_texture(texture_id);
                setup_texture_as_render_target(width, height, texture_id, framebuffer_id);
                log_error("WARNING: Your GPU driver does not support 16bit textures as framebuffer targets, some colors may be slightly inaccurate.");
            } else {
                fatal("Your GPU driver does not support indirect rendering to a GL_RGBA texture via a framebuffer");
            }
        }
    }
}

static void
set_cell_uniforms(bool force) {
    static bool constants_set = false;
    if (!constants_set || force) {
        float text_contrast = 1.0f + OPT(text_contrast) * 0.01f;
        float text_gamma_adjustment = OPT(text_gamma_adjustment) < 0.01f ? 1.0f : 1.0f / OPT(text_gamma_adjustment);
        for (int i = GRAPHICS_PROGRAM; i <= GRAPHICS_ALPHA_MASK_PROGRAM; i++) {
            bind_program(i);
            glUniform1i(program_uniform_location(i, "image"), GRAPHICS_UNIT);
        }
        for (int i = CELL_PROGRAM; i < CELL_PROGRAM_SENTINEL; i++) {
#ifdef KITTY_BACKEND_METAL
            // The Metal cell shader is the fork's hand-written MSL and keeps the
            // colored-sprite atlas pair (F1 R8); the GL arm is upstream's cell
            // pipeline, which has no such samplers.
            bind_program(i);
            glUniform1i(program_uniform_location(i, "sprites"), SPRITE_MAP_UNIT);
            glUniform1i(program_uniform_location(i, "sprite_decorations_map"), SPRITE_DECORATIONS_MAP_UNIT);
            glUniform1i(program_uniform_location(i, "color_sprites"), COLOR_SPRITE_MAP_UNIT);
            glUniform1i(program_uniform_location(i, "color_sprite_decorations_map"), COLOR_SPRITE_DECORATIONS_MAP_UNIT);
            glUniform1f(program_uniform_location(i, "text_contrast"), text_contrast);
            glUniform1f(program_uniform_location(i, "text_gamma_adjustment"), text_gamma_adjustment);
#else
            bind_program(i);
            glUniform1i(program_uniform_location(i, "sprites"), SPRITE_MAP_UNIT);
            glUniform1i(program_uniform_location(i, "sprite_decorations_map"), SPRITE_DECORATIONS_MAP_UNIT);
            glUniform1f(program_uniform_location(i, "text_contrast"), text_contrast);
            glUniform1f(program_uniform_location(i, "text_gamma_adjustment"), text_gamma_adjustment);
#endif
        }
        bind_program(BLIT_PROGRAM);
        glUniform1i(program_uniform_location(BLIT_PROGRAM, "image"), GRAPHICS_UNIT);
        bind_program(SCREENSHOT_PROGRAM);
        glUniform1i(program_uniform_location(SCREENSHOT_PROGRAM, "image"), GRAPHICS_UNIT);
        constants_set = true;
    }
}


// UI Layer {{{
static Animation *default_visual_bell_animation = NULL;

static float
get_visual_bell_intensity(Screen *screen) {
    if (screen->start_visual_bell_at > 0) {
        if (!default_visual_bell_animation) {
            default_visual_bell_animation = alloc_animation();
            if (!default_visual_bell_animation) fatal("Out of memory");
            add_cubic_bezier_animation(default_visual_bell_animation, 0, 1, EASE_IN_OUT);
            add_cubic_bezier_animation(default_visual_bell_animation, 1, 0, EASE_IN_OUT);
        }
        const monotonic_t progress = monotonic() - screen->start_visual_bell_at;
        const monotonic_t duration = OPT(visual_bell_duration) / 2;
        if (progress <= duration) {
            Animation *a = animation_is_valid(OPT(animation.visual_bell)) ? OPT(animation.visual_bell) : default_visual_bell_animation;
            return (float)apply_easing_curve(a, progress / (double)duration, duration);
        }
        screen->start_visual_bell_at = 0;
    }
    return 0.0f;
}

static void
draw_visual_bell_flash(GLfloat intensity, const color_type flash) {
    bind_program(TINT_PROGRAM);
    GLfloat attenuation = 0.4f;
#define C(shift) srgb_color((flash >> shift) & 0xFF)
    const GLfloat r = C(16), g = C(8), b = C(0);
    const GLfloat max_channel = r > g ? (r > b ? r : b) : (g > b ? g : b);
#undef C
#define C(x) (x * intensity * attenuation)
    if (max_channel > 0.45) attenuation = 0.6f; // light color
    glUniform4f(program_uniform_location(TINT_PROGRAM, "tint_color"), C(r), C(g), C(b), C(1));
#undef C
    glUniform4f(program_uniform_location(TINT_PROGRAM, "edges"), -1, 1, 1, -1);
    draw_quad(true, 0);
}

static color_type
get_flash_color(const Screen *screen) {
#define COLOR(name, fallback)                       \
    colorprofile_to_color_with_fallback(            \
        screen->color_profile,                      \
        screen->color_profile->overridden.name,     \
        screen->color_profile->configured.name,     \
        screen->color_profile->overridden.fallback, \
        screen->color_profile->configured.fallback)
    return !IS_SPECIAL_COLOR(highlight_bg) ? COLOR(visual_bell_color, highlight_bg) : COLOR(visual_bell_color, default_fg);
#undef COLOR
}

static void
draw_visual_bell(const UIRenderData *ui) {
    if (!ui->screen->start_visual_bell_at) return;
    Screen *screen = ui->screen;
    float intensity = get_visual_bell_intensity(screen);
    if (intensity <= 0) return;
    draw_visual_bell_flash(intensity, get_flash_color(screen));
}

static void
draw_drag_preview_overlay(const UIRenderData *ui) {
    const Screen *screen = ui->screen;
    if (!screen->start_drag_overlay_at || !screen->drag_overlay_quadrant) return;
    const monotonic_t elapsed = monotonic() - screen->start_drag_overlay_at;
    const monotonic_t fade_ms = ms_to_monotonic_t(150ll);
    float intensity = elapsed >= fade_ms ? 1.0f : (float)elapsed / (float)fade_ms;
    GLfloat left = -1.f, top = 1.f, right = 1.f, bottom = -1.f;
    switch (screen->drag_overlay_quadrant) {
        case 1: right = 0.f; break;  // left half
        case 2: left = 0.f; break;   // right half
        case 3: bottom = 0.f; break; // top half
        case 4: top = 0.f; break;    // bottom half
        case 5: break;               // full window + title bar highlight (title bar hover)
        case 6: break;               // full window, no title bar highlight (body hover)
        default: return;
    }
    bind_program(TINT_PROGRAM);
    float a = intensity * 0.25f;
    color_type hint = get_flash_color(screen);
#define C(shift) (srgb_color((hint >> shift) & 0xFF) * a)
    glUniform4f(program_uniform_location(TINT_PROGRAM, "tint_color"), C(16), C(8), C(0), a);
#undef C
    glUniform4f(program_uniform_location(TINT_PROGRAM, "edges"), left, top, right, bottom);
    draw_quad(true, 0);
}

static bool
has_scrollbar(Window *w, Screen *screen) {
    if (screen->linebuf != screen->main_linebuf || !screen->historybuf->count) return false;
    switch (OPT(scrollbar)) {
        case SCROLLBAR_NEVER: return false;
        case SCROLLBAR_ALWAYS: return true;
        case SCROLLBAR_ON_SCROLLED: return screen->scrolled_by > 0;
        case SCROLLBAR_ON_HOVERED: return w->scrollbar.is_hovering;
        case SCROLLBAR_ON_SCROLL_AND_HOVER: return screen->scrolled_by > 0 && w->scrollbar.is_hovering;
        case SCROLLBAR_ON_SCROLL_OR_HOVER: return screen->scrolled_by > 0 || w->scrollbar.is_hovering;
    }
    return false;
}

static unsigned
render_a_bar(const UIRenderData *ui, WindowBarData *bar, PyObject *title, bool along_bottom) {
    unsigned border_width = (unsigned)ceil(thickness_as_float(ui->os_window, 1));
    unsigned bar_height = ui->cell_height + 2;
    unsigned bar_width = ui->screen_width - 2 * border_width;
    if (!bar->buf || bar->width != bar_width || bar->height != bar_height) {
        free(bar->buf);
        bar->buf = malloc((size_t)4 * bar_width * bar_height);
        if (!bar->buf) return 0;
        bar->height = bar_height;
        bar->width = bar_width;
        bar->needs_render = true;
    }
#define RGBCOL(which, fallback)                                       \
    (0xff000000 | colorprofile_to_color_with_fallback(                \
                      ui->screen->color_profile,                      \
                      ui->screen->color_profile->overridden.which,    \
                      ui->screen->color_profile->configured.which,    \
                      ui->screen->color_profile->overridden.fallback, \
                      ui->screen->color_profile->configured.fallback))
    color_type fg = RGBCOL(default_fg, default_fg), bg = RGBCOL(default_bg, default_bg);
#undef RGBCOL
    if (bar->last_drawn_title_object_id != title || bar->needs_render) {
        static char titlebuf[2048] = {0};
        if (!title) return 0;
        snprintf(titlebuf, arraysz(titlebuf), " %s", PyUnicode_AsUTF8(title));
        if (!draw_window_title(
                ui->os_window->fonts_data->font_sz_in_pts, ui->os_window->fonts_data->logical_dpi_y, titlebuf, fg, bg, bar->buf, bar_width, bar_height, NULL))
            return 0;
        Py_CLEAR(bar->last_drawn_title_object_id);
        bar->last_drawn_title_object_id = Py_NewRef(title);
    }
    static ImageRenderData data = {.group_count = 1};
    gpu_data_for_image(&data, -1, 1, 1, -1);
    glGenTextures(1, &data.texture_id);
    glBindTexture(GL_TEXTURE_2D, data.texture_id);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_SRGB_ALPHA, bar_width, bar_height, 0, GL_RGBA, GL_UNSIGNED_BYTE, bar->buf);
    bind_program(GRAPHICS_PROGRAM);
    Viewport border_rect = {.height = bar_height + 2 * border_width, .left = ui->screen_left, .width = ui->screen_width, .top = ui->screen_top};
    if (along_bottom) border_rect.top += ui->screen_height - border_rect.height;
    const unsigned sh = ui->full_framebuffer_height;
    // first blank the area to be drawn to background
    enable_scissor_using_top_left_origin(border_rect, sh);
    blank_canvas(ui->bg_alpha, bg, false);
    disable_scissor();
    // then draw the rendered text
    save_viewport_using_top_left_origin(
        border_rect.left + border_width, border_rect.top + border_width, bar_width, bar_height, sh);
    draw_graphics(GRAPHICS_PROGRAM, &data, 0, 1, 1.f, ui->os_window->edr_headroom);
    restore_viewport();
    free_texture(&data.texture_id);
    // finally draw border with transparent bg
    draw_rounded_rect(ui->os_window, border_rect, sh, 1, ui->cell_width, fg, bg, 0.f);
    return border_rect.height;
}

static bool
show_hyperlink_targets_with_modifiers(int mods) {
    switch (OPT(show_hyperlink_targets)) {
        case SHOW_HYPERLINK_TARGETS_ALWAYS: return true;
        case SHOW_HYPERLINK_TARGETS_CTRL: return (mods & GLFW_MOD_CONTROL) != 0;
        case SHOW_HYPERLINK_TARGETS_SHIFT: return (mods & GLFW_MOD_SHIFT) != 0;
        case SHOW_HYPERLINK_TARGETS_SUPER: return (mods & GLFW_MOD_SUPER) != 0;
        case SHOW_HYPERLINK_TARGETS_ALT: return (mods & GLFW_MOD_ALT) != 0;
        default: return false;
    }
}

static bool
has_hyperlink_target(OSWindow *os_window, Window *w, Screen *screen) {
    return show_hyperlink_targets_with_modifiers(global_state.mods_at_last_key_or_button_event) && screen->current_hyperlink_under_mouse.id && w &&
           !is_mouse_hidden(os_window) && global_state.mouse_hover_in_window == w->id;
}

static void
draw_hyperlink_target(const UIRenderData *ui) {
    if (!has_hyperlink_target(ui->os_window, ui->window, ui->screen)) return;
    Screen *screen = ui->screen;
    Window *window = ui->window;
    const bool along_bottom = screen->current_hyperlink_under_mouse.y < 3;
    WindowBarData *bd = &window->url_target_bar_data;
    hyperlink_id_type hid = screen->current_hyperlink_under_mouse.id;
    if (bd->hyperlink_id_for_title_object != hid) {
        bd->hyperlink_id_for_title_object = hid;
        Py_CLEAR(bd->last_drawn_title_object_id);
        const char *url = get_hyperlink_for_id(screen->hyperlink_pool, bd->hyperlink_id_for_title_object, true);
        if (url == NULL) url = "";
        bd->last_drawn_title_object_id = PyObject_CallMethod(global_state.boss, "sanitize_url_for_display_to_user", "s", url);
        if (bd->last_drawn_title_object_id == NULL) {
            PyErr_Print();
            return;
        }
        bd->needs_render = true;
    }
    if (bd->last_drawn_title_object_id == NULL) return;
    PyObject *ref = Py_NewRef(bd->last_drawn_title_object_id); // render_a_bar clears bd->last_drawn_title_object_id
    render_a_bar(ui, &window->title_bar_data, bd->last_drawn_title_object_id, along_bottom);
    Py_DECREF(ref);
}

static bool
has_window_number(Window *w, Screen *screen) {
    return w != NULL && screen->display_window_char != 0;
}

static void
draw_window_number(const UIRenderData *ui) {
    if (!has_window_number(ui->window, ui->screen)) return;
    unsigned title_bar_height = 0, requested_height = ui->screen_height;
    if (ui->window->title && PyUnicode_Check(ui->window->title) && (requested_height > (ui->cell_height + 1) * 2)) {
        title_bar_height = render_a_bar(ui, &ui->window->title_bar_data, ui->window->title, false);
    }
    unsigned height_for_letter = ui->screen_height - title_bar_height - ui->cell_height;
    unsigned width_for_letter = ui->screen_width - ui->cell_width;
    requested_height = MIN(12 * ui->cell_height, MIN(height_for_letter, width_for_letter));
    if (requested_height < 4) return;
#define lr ui->screen->last_rendered_window_char
    if (!lr.canvas || lr.ch != ui->screen->display_window_char || lr.requested_height != requested_height) {
        free(lr.canvas);
        lr.canvas = NULL;
        lr.requested_height = requested_height;
        lr.height_px = requested_height;
        lr.ch = 0;
        lr.canvas = draw_single_ascii_char(ui->screen->display_window_char, &lr.width_px, &lr.height_px);
        if (lr.height_px < 4 || lr.width_px < 4 || !lr.canvas) return;
        lr.ch = ui->screen->display_window_char;
    }
    unsigned letter_x = 0, letter_y = title_bar_height;
    if (lr.width_px < ui->screen_width) letter_x = (ui->screen_width - lr.width_px) / 2;
    if (lr.height_px + title_bar_height < ui->screen_height) letter_y += (ui->screen_height - lr.height_px - title_bar_height) / 2;
    bind_program(GRAPHICS_ALPHA_MASK_PROGRAM);
    ImageRenderData *ird = load_alpha_mask_texture(lr.width_px, lr.height_px, lr.canvas);
    gpu_data_for_image(ird, -1, 1, 1, -1);
    glUniform1i(program_uniform_location(GRAPHICS_ALPHA_MASK_PROGRAM, "image"), GRAPHICS_UNIT);
    color_type digit_color = colorprofile_to_color_with_fallback(
        ui->screen->color_profile,
        ui->screen->color_profile->overridden.highlight_bg,
        ui->screen->color_profile->configured.highlight_bg,
        ui->screen->color_profile->overridden.default_fg,
        ui->screen->color_profile->configured.default_fg);
    color_vec3(program_uniform_location(GRAPHICS_ALPHA_MASK_PROGRAM, "amask_fg"), digit_color);
    glUniform4f(program_uniform_location(GRAPHICS_ALPHA_MASK_PROGRAM, "amask_bg_premult"), 0.f, 0.f, 0.f, 0.f);
    save_viewport_using_top_left_origin(ui->screen_left + letter_x, ui->screen_top + letter_y, lr.width_px, lr.height_px, ui->full_framebuffer_height);
    draw_graphics(GRAPHICS_ALPHA_MASK_PROGRAM, ird, 0, 1, 1.f, ui->os_window->edr_headroom);
    restore_viewport();
#undef lr
}

// Helper function to extract and apply opacity to color components
static void
set_color_uniform_with_opacity(color_type color, float opacity) {
    float r = srgb_color((color >> 16) & 0xFF) * opacity;
    float g = srgb_color((color >> 8) & 0xFF) * opacity;
    float b = srgb_color(color & 0xFF) * opacity;
    glUniform4f(program_uniform_location(TINT_PROGRAM, "tint_color"), r, g, b, opacity);
}

static color_type
scrollbar_color(Screen *screen, unsigned val) {
    switch (val & 0xff) {
#define C(which) colorprofile_to_color(screen->color_profile, screen->color_profile->overridden.which, screen->color_profile->configured.which).rgb
        case 0: return C(default_fg);
        case 1: return C(highlight_bg);
#undef C
        default: return val >> 8;
    }
}

static void
draw_scrollbar(const UIRenderData *ui) {
    Screen *screen = ui->screen;
    Window *window = ui->window;
    if (!window || !screen || !has_scrollbar(window, screen)) return;

    color_type bar_color = scrollbar_color(screen, OPT(scrollbar_handle_color)), track_color = scrollbar_color(screen, OPT(scrollbar_track_color));
    double cell_frac = (double)screen->pixel_scroll_offset_y / screen->cell_size.height;
    if (!OPT(pixel_scroll)) cell_frac = 0;
    float bar_frac = (float)(screen->scrolled_by + cell_frac) / MAX(1u, (float)screen->historybuf->count);
    float opacity = OPT(scrollbar_handle_opacity);
    float track_opacity = window->scrollbar.is_hovering ? OPT(scrollbar_track_hover_opacity) : OPT(scrollbar_track_opacity);
    GLsizei scrollbar_width_px = (GLsizei)(OPT(scrollbar_width) * ui->cell_width);
    if (window->scrollbar.is_hovering) scrollbar_width_px = (GLsizei)(OPT(scrollbar_hover_width) * ui->cell_width);
    GLsizei scrollbar_gap_px = (GLsizei)(OPT(scrollbar_gap) * ui->cell_width);
    unsigned scrollbar_radius = (unsigned)(OPT(scrollbar_radius) * ui->cell_width);

    // Calculate window boundaries including padding
    GLsizei window_right_edge = ui->screen_left + ui->screen_width + window->render_data.geometry.spaces.right;
    GLsizei window_top_edge = ui->screen_top - window->render_data.geometry.spaces.top;
    GLsizei window_height = ui->screen_height + window->render_data.geometry.spaces.top + window->render_data.geometry.spaces.bottom;

    // Position scrollbar on right side with gap
    GLsizei scrollbar_left = window_right_edge - scrollbar_width_px - scrollbar_gap_px;
    GLsizei scrollbar_top = window_top_edge + scrollbar_gap_px;
    GLsizei scrollbar_height = window_height - 2 * scrollbar_gap_px;

    // Calculate thumb size and position
    float visible_fraction = (float)screen->lines / (float)(screen->lines + screen->historybuf->count);
    float min_thumb_height_fraction = (OPT(scrollbar_min_handle_height) * ui->cell_height) / (float)window_height;
    float thumb_height_fraction = MAX(min_thumb_height_fraction, visible_fraction);

    // Convert to OpenGL coordinates (range -1.0 to 1.0, total span = 2.0)
    const float GL_COORD_SPAN = 2.0f;
    float thumb_height_gl = thumb_height_fraction * GL_COORD_SPAN;
    float available_space = GL_COORD_SPAN - thumb_height_gl;
    float thumb_bottom_gl = -1.0f + available_space * bar_frac;
    float thumb_top_gl = thumb_bottom_gl + thumb_height_gl;

    // Store thumb position for mouse interaction (normalized window coordinates)
    float scrollbar_top_in_window = (float)(window_top_edge + scrollbar_gap_px) / (float)ui->full_framebuffer_height;
    float scrollbar_height_in_window = (float)(window_height - 2 * scrollbar_gap_px) / (float)ui->full_framebuffer_height;
    float thumb_top_fraction = (1.0f - thumb_top_gl) / 2.0f;
    float thumb_bottom_fraction = (1.0f - thumb_bottom_gl) / 2.0f;
    window->scrollbar.thumb_top = scrollbar_top_in_window + thumb_top_fraction * scrollbar_height_in_window;
    window->scrollbar.thumb_bottom = scrollbar_top_in_window + thumb_bottom_fraction * scrollbar_height_in_window;

    // Set viewport for scrollbar area
    save_viewport_using_top_left_origin(scrollbar_left, scrollbar_top, scrollbar_width_px, scrollbar_height, ui->full_framebuffer_height);

    // Draw scrollbar track (background)
    if (track_opacity > 0) {
        bind_program(TINT_PROGRAM);
        set_color_uniform_with_opacity(track_color, track_opacity);
        glUniform4f(program_uniform_location(TINT_PROGRAM, "edges"), -1.f, 1.f, 1.f, -1.f);
        draw_quad(true, 0);
    }

    // Draw scrollbar thumb (handle)
    if (scrollbar_radius > 0) {
        // Rounded thumb - use separate viewport and rounded rect program
        GLsizei thumb_height_px = (GLsizei)(thumb_height_fraction * scrollbar_height);
        GLsizei thumb_top_px = scrollbar_top + (GLsizei)(thumb_top_fraction * scrollbar_height);

        restore_viewport();

        bind_program(ROUNDED_RECT_PROGRAM);
        color_vec4(program_uniform_location(ROUNDED_RECT_PROGRAM, "color"), bar_color, opacity);
        color_vec4(program_uniform_location(ROUNDED_RECT_PROGRAM, "background_color"), 0, 0.0f);

        float y = (float)ui->full_framebuffer_height - (float)(thumb_top_px + thumb_height_px);
        glUniform4f(program_uniform_location(ROUNDED_RECT_PROGRAM, "rect"), (float)scrollbar_left, y, (float)scrollbar_width_px, (float)thumb_height_px);

        float thickness = (float)MAX(scrollbar_width_px, thumb_height_px);
        glUniform2f(program_uniform_location(ROUNDED_RECT_PROGRAM, "params"), thickness, (float)scrollbar_radius);

        save_viewport_using_top_left_origin(scrollbar_left, thumb_top_px, scrollbar_width_px, thumb_height_px, ui->full_framebuffer_height);
        draw_quad(true, 0);
        restore_viewport();
    } else {
        set_color_uniform_with_opacity(bar_color, opacity);
        glUniform4f(program_uniform_location(TINT_PROGRAM, "edges"), -1.f, thumb_top_gl, 1.f, thumb_bottom_gl);
        draw_quad(true, 0);
        restore_viewport();
    }
}

static bool
has_progress_bar(Screen *screen) {
    if (OPT(progress_bar) == PROGRESS_BAR_HIDDEN) return false;
    return screen && screen->progress_state != PROGRESS_STATE_UNSET;
}

static void
draw_progress_handle(
    const UIRenderData *ui,
    color_type bar_color,
    float opacity,
    unsigned bar_radius,
    GLsizei track_left,
    GLsizei track_top,
    GLsizei track_width,
    GLsizei track_height,
    float handle_start,
    float handle_size,
    bool is_horizontal) {
    // handle_start and handle_size are fractions of the track length (0..1)
    // For horizontal: handle moves left-to-right; For vertical: handle moves top-to-bottom
    // Use lroundf to avoid sub-pixel jitter at the leading edge
    GLsizei handle_left, handle_top;
    GLsizei handle_w, handle_h;
    if (is_horizontal) {
        GLsizei handle_start_px = (GLsizei)lroundf(handle_start * track_width);
        GLsizei handle_end_px = (GLsizei)lroundf((handle_start + handle_size) * track_width);
        GLsizei handle_w_px = handle_end_px - handle_start_px;
        if (handle_w_px < 1) handle_w_px = 1;
        handle_left = track_left + handle_start_px;
        handle_top = track_top;
        handle_w = handle_w_px;
        handle_h = track_height;
    } else {
        GLsizei handle_start_px = (GLsizei)lroundf(handle_start * track_height);
        GLsizei handle_end_px = (GLsizei)lroundf((handle_start + handle_size) * track_height);
        GLsizei handle_h_px = handle_end_px - handle_start_px;
        if (handle_h_px < 1) handle_h_px = 1;
        handle_left = track_left;
        handle_top = track_top + handle_start_px;
        handle_w = track_width;
        handle_h = handle_h_px;
    }

    if (bar_radius > 0) {
        bind_program(ROUNDED_RECT_PROGRAM);
        color_vec4(program_uniform_location(ROUNDED_RECT_PROGRAM, "color"), bar_color, opacity);
        color_vec4(program_uniform_location(ROUNDED_RECT_PROGRAM, "background_color"), 0, 0.0f);

        float y = (float)ui->full_framebuffer_height - (float)(handle_top + handle_h);
        glUniform4f(program_uniform_location(ROUNDED_RECT_PROGRAM, "rect"), (float)handle_left, y, (float)handle_w, (float)handle_h);

        float thickness = (float)(is_horizontal ? handle_h : handle_w);
        glUniform2f(program_uniform_location(ROUNDED_RECT_PROGRAM, "params"), thickness, (float)bar_radius);

        save_viewport_using_top_left_origin(handle_left, handle_top, handle_w, handle_h, ui->full_framebuffer_height);
        draw_quad(true, 0);
        restore_viewport();
    } else {
        // Use GL coordinates within the track viewport, snapped to pixel boundaries
        GLsizei track_len = is_horizontal ? track_width : track_height;
        float start_snapped = (float)lroundf(handle_start * track_len) / (float)track_len;
        float end_snapped = (float)lroundf((handle_start + handle_size) * track_len) / (float)track_len;
        float start_gl = -1.0f + 2.0f * start_snapped;
        float end_gl = -1.0f + 2.0f * end_snapped;
        bind_program(TINT_PROGRAM);
        set_color_uniform_with_opacity(bar_color, opacity);
        if (is_horizontal) {
            // edges: left, top, right, bottom
            save_viewport_using_top_left_origin(track_left, track_top, track_width, track_height, ui->full_framebuffer_height);
            glUniform4f(program_uniform_location(TINT_PROGRAM, "edges"), start_gl, 1.f, end_gl, -1.f);
        } else {
            save_viewport_using_top_left_origin(track_left, track_top, track_width, track_height, ui->full_framebuffer_height);
            // For vertical: start_gl is top in GL coords (inverted y), so bottom_gl = -end_gl, top_gl = -start_gl
            glUniform4f(program_uniform_location(TINT_PROGRAM, "edges"), -1.f, -start_gl, 1.f, -end_gl);
        }
        draw_quad(true, 0);
        restore_viewport();
    }
}

static void
draw_progress_bar(const UIRenderData *ui) {
    Screen *screen = ui->screen;
    Window *window = ui->window;
    if (!window || !has_progress_bar(screen)) return;

    const ProgressBarPosition pos = OPT(progress_bar);
    const bool is_horizontal = (pos == PROGRESS_BAR_TOP || pos == PROGRESS_BAR_BOTTOM);
    color_type bar_color = scrollbar_color(screen, OPT(scrollbar_handle_color));
    color_type track_color = scrollbar_color(screen, OPT(scrollbar_track_color));
    float opacity = OPT(scrollbar_handle_opacity);
    float track_opacity = OPT(scrollbar_track_hover_opacity);
    GLsizei bar_thickness_px = (GLsizei)(OPT(scrollbar_width) * ui->cell_width);
    GLsizei gap_px = (GLsizei)(OPT(scrollbar_gap) * ui->cell_width);
    unsigned bar_radius = (unsigned)(OPT(scrollbar_radius) * ui->cell_width);
    if (bar_thickness_px < 1) return;

    // Calculate window boundaries including padding
    GLsizei window_left_edge = ui->screen_left - (GLsizei)window->render_data.geometry.spaces.left;
    GLsizei window_top_edge = ui->screen_top - (GLsizei)window->render_data.geometry.spaces.top;
    GLsizei window_width = ui->screen_width + (GLsizei)(window->render_data.geometry.spaces.left + window->render_data.geometry.spaces.right);
    GLsizei window_height = ui->screen_height + (GLsizei)(window->render_data.geometry.spaces.top + window->render_data.geometry.spaces.bottom);

    // Position the track depending on the chosen edge
    GLsizei track_left, track_top, track_width, track_height;
    switch (pos) {
        case PROGRESS_BAR_BOTTOM:
            track_left = window_left_edge + gap_px;
            track_width = window_width - 2 * gap_px;
            track_height = bar_thickness_px;
            track_top = window_top_edge + window_height - bar_thickness_px - gap_px;
            break;
        case PROGRESS_BAR_TOP:
            track_left = window_left_edge + gap_px;
            track_width = window_width - 2 * gap_px;
            track_height = bar_thickness_px;
            track_top = window_top_edge + gap_px;
            break;
        case PROGRESS_BAR_LEFT:
            track_left = window_left_edge + gap_px;
            track_width = bar_thickness_px;
            track_top = window_top_edge + gap_px;
            track_height = window_height - 2 * gap_px;
            break;
        case PROGRESS_BAR_RIGHT:
            track_left = window_left_edge + window_width - bar_thickness_px - gap_px;
            track_width = bar_thickness_px;
            track_top = window_top_edge + gap_px;
            track_height = window_height - 2 * gap_px;
            break;
        default: return;
    }
    if (track_width <= 0 || track_height <= 0) return;

    // Calculate fill fraction and indeterminate animation
    float fill_fraction = 0.0f;
    bool is_indeterminate = false;
    switch (screen->progress_state) {
        case PROGRESS_STATE_SET:
        case PROGRESS_STATE_PAUSED: fill_fraction = screen->progress_percent / 100.0f; break;
        case PROGRESS_STATE_ERROR: fill_fraction = 1.0f; break;
        case PROGRESS_STATE_INDETERMINATE: is_indeterminate = true; break;
        default: return;
    }

    // Draw track (background)
    save_viewport_using_top_left_origin(track_left, track_top, track_width, track_height, ui->full_framebuffer_height);
    if (track_opacity > 0) {
        bind_program(TINT_PROGRAM);
        set_color_uniform_with_opacity(track_color, track_opacity);
        glUniform4f(program_uniform_location(TINT_PROGRAM, "edges"), -1.f, 1.f, 1.f, -1.f);
        draw_quad(true, 0);
    }
    restore_viewport();

    // Draw fill or indeterminate handle
    // For vertical bars, progress grows from bottom to top, so invert the fraction
    if (is_indeterminate) {
        // Animate a handle bouncing back and forth like a scrollbar thumb
        const float handle_size = 0.15f;                        // 15% of track length
        const monotonic_t cycle = s_double_to_monotonic_t(2.0); // 2 second full cycle (forth and back)
        monotonic_t elapsed = screen->progress_indeterminate_anim_at > 0 ? monotonic() - screen->progress_indeterminate_anim_at : 0;
        double t = (double)(elapsed % cycle) / (double)cycle; // 0..1 over one cycle
        // Triangle wave: goes 0→1→0 over one cycle
        float pos_frac = (float)(t < 0.5 ? t * 2.0 : 2.0 - t * 2.0);
        if (!is_horizontal) pos_frac = 1.0f - pos_frac; // vertical: bounce bottom-to-top first
        float handle_start = pos_frac * (1.0f - handle_size);
        if (opacity > 0.0f) {
            draw_progress_handle(
                ui, bar_color, opacity, bar_radius, track_left, track_top, track_width, track_height, handle_start, handle_size, is_horizontal);
        }
    } else if (fill_fraction > 0.0f && opacity > 0.0f) {
        float handle_start = is_horizontal ? 0.0f : 1.0f - fill_fraction;
        draw_progress_handle(ui, bar_color, opacity, bar_radius, track_left, track_top, track_width, track_height, handle_start, fill_fraction, is_horizontal);
    }
}


static void
draw_window_logo(const UIRenderData *ui) {
    struct {
        unsigned width, height;
        int left, top;
    } w;
    WindowLogoRenderData *wl = ui->window_logo;
    w.height = wl->instance->height;
    w.width = wl->instance->width;
    if (OPT(window_logo_scale.width) > 0 || OPT(window_logo_scale.height) > 0) {
        unsigned scaled_wl_width = ui->screen_width, scaled_wl_height = ui->screen_height;

        // [sx] Scales logo to sx % of the viewports shortest dimension, preserving aspect ratio
        if (OPT(window_logo_scale.height) < 0) {
            if (ui->screen_height < ui->screen_width) {
                scaled_wl_height = (int)(ui->screen_height * OPT(window_logo_scale.width) / 100);
                scaled_wl_width = wl->instance->width * scaled_wl_height / wl->instance->height;
            } else {
                scaled_wl_width = (int)(ui->screen_width * OPT(window_logo_scale.width) / 100);
                scaled_wl_height = wl->instance->height * scaled_wl_width / wl->instance->width;
            }
        }
        // [0 sy] Scales logo's y dimension to sy % of viewporty keeping original x dimension
        else if (OPT(window_logo_scale.width) == 0.0) {
            scaled_wl_height = (int)(scaled_wl_height * OPT(window_logo_scale.height) / 100);
            scaled_wl_width = wl->instance->width;
        }
        // [sx 0] Scales logo's x dimension to sx % of viewportx keeping original y dimension
        else if (OPT(window_logo_scale.height) == 0.0) {
            scaled_wl_width = (int)(scaled_wl_width * OPT(window_logo_scale.width) / 100);
            scaled_wl_height = wl->instance->height;
        }
        // [sx sy] Scales logo's x and y dimension to sx and sy % of viewportx and viewporty respectively
        else {
            scaled_wl_height = (int)(scaled_wl_height * OPT(window_logo_scale.height) / 100);
            scaled_wl_width = (int)(scaled_wl_width * OPT(window_logo_scale.width) / 100);
        }
        w.width = scaled_wl_width;
        w.height = scaled_wl_height;
    }
    w.left = (int)(ui->screen_width * wl->position.canvas_x - w.width * wl->position.image_x);
    w.top = (int)(ui->screen_height * wl->position.canvas_y - w.height * wl->position.image_y);
    float left = gl_pos_x(w.left, ui->screen_width), top = gl_pos_y(w.top, ui->screen_height);
    ImageRenderData d = {.texture_id = wl->instance->texture_id};
    gpu_data_for_image(&d, left, top, left + gl_size(w.width, ui->screen_width), top - gl_size(w.height, ui->screen_height));
    draw_graphics(GRAPHICS_PROGRAM, &d, 0, 1, ui->inactive_text_alpha * OPT(window_logo_alpha), ui->os_window->edr_headroom);
}

bool
screen_needs_rendering_in_layers(OSWindow *os_window, Window *w, Screen *screen) {
    const bool has_ui = w && ((screen->start_visual_bell_at | screen->start_drag_overlay_at) || has_scrollbar(w, screen) || has_progress_bar(screen) ||
                              has_hyperlink_target(os_window, w, screen) || has_window_number(w, screen) || w->window_logo.id);
    GraphicsManager *grman = screen->paused_rendering.expires_at && screen->paused_rendering.grman ? screen->paused_rendering.grman : screen->grman;
    return has_ui || grman_has_images(grman);
}

bool
current_framebuffer_is_ok(void) {
    return check_framebuffer_status() == NULL;
}

// }}}

enum { DRAW_NEITHER_BG = 0, DRAW_DEFAULT_BG = 1, DRAW_NON_DEFAULT_BG = 2, DRAW_BOTH_BG = 3 };

static void
call_cell_program(int program, const UIRenderData *ui, ssize_t vao_idx, bool for_final_output, unsigned draw_bg_bitfield) {
    bind_program(program);
    CELL_BUFFERS;
    bind_vao_uniform_buffer(vao_idx, uniform_buffer, CELL_RENDER_DATA_BINDING_POINT);
    bind_vao_uniform_buffer(vao_idx, color_table_buffer, COLOR_TABLE_BINDING_POINT);
    glUniform1ui(program_uniform_location(program, "draw_bg_bitfield"), draw_bg_bitfield);
    // C1: on the Metal backend the drawable is a plain BGRA8Unorm and the cell
    // fragment sRGB-encodes its output in-shader (the TARGET_COLOR_SPACE
    // function constant resolves to ENCODE_SRGB for that attachment), so
    // GL_FRAMEBUFFER_SRGB is a no-op there. The GL backend keeps the sRGB
    // framebuffer toggle.
#ifndef KITTY_BACKEND_METAL
    if (for_final_output) glEnable(GL_FRAMEBUFFER_SRGB);
#endif
    draw_quad(!for_final_output, render_lines_for_screen(ui->screen) * ui->screen->columns);
#ifndef KITTY_BACKEND_METAL
    if (for_final_output) glDisable(GL_FRAMEBUFFER_SRGB);
#endif
}

static void
draw_cells_without_layers(const UIRenderData *ui, ssize_t vao_idx) {
    call_cell_program(CELL_PROGRAM, ui, vao_idx, true, DRAW_BOTH_BG);
}

#ifndef KITTY_BACKEND_METAL
static void
configure_cell_vao_attributes(ssize_t vao_idx, unsigned int base_cell, unsigned int cell_step) {
    // (Re)point the instanced cell attributes so that instance i corresponds to
    // the cell at (base_cell + i*cell_step). Used to restore the canonical
    // layout after padding draws (base_cell=0, cell_step=1). The VAO must be
    // bound before calling this.
    CELL_BUFFERS;
    const GLsizei cell_stride = (GLsizei)(cell_step * sizeof(GPUCell));
    const uintptr_t cell_base = (uintptr_t)base_cell * sizeof(GPUCell);
    set_vao_attribute(
        vao_idx,
        cell_data_buffer,
        program_attribute_location(CELL_PROGRAM, "sprite_idx"),
        2,
        GL_UNSIGNED_INT,
        cell_stride,
        (void *)(cell_base + offsetof(GPUCell, sprite_idx)),
        1);
    set_vao_attribute(
        vao_idx,
        cell_data_buffer,
        program_attribute_location(CELL_PROGRAM, "colors"),
        3,
        GL_UNSIGNED_INT,
        cell_stride,
        (void *)(cell_base + offsetof(GPUCell, fg)),
        1);
    set_vao_attribute(
        vao_idx,
        selection_buffer,
        program_attribute_location(CELL_PROGRAM, "is_selected"),
        1,
        GL_UNSIGNED_BYTE,
        (GLsizei)(cell_step * sizeof(GLubyte)),
        (void *)((uintptr_t)base_cell * sizeof(GLubyte)),
        1);
}

static void
configure_padding_vao_attributes(ssize_t vao_idx) {
    // Point the instanced cell attributes at the dedicated padding buffers
    // (base=0, stride=sizeof(GPUCell)), which are pre-packed before each
    // combined draw. The VAO must be bound before calling this.
    CELL_BUFFERS;
    set_vao_attribute(
        vao_idx,
        padding_cell_data_buffer,
        program_attribute_location(CELL_PROGRAM, "sprite_idx"),
        2,
        GL_UNSIGNED_INT,
        sizeof(GPUCell),
        (void *)offsetof(GPUCell, sprite_idx),
        1);
    set_vao_attribute(
        vao_idx,
        padding_cell_data_buffer,
        program_attribute_location(CELL_PROGRAM, "colors"),
        3,
        GL_UNSIGNED_INT,
        sizeof(GPUCell),
        (void *)offsetof(GPUCell, fg),
        1);
    set_vao_attribute(
        vao_idx, padding_selection_buffer, program_attribute_location(CELL_PROGRAM, "is_selected"), 1, GL_UNSIGNED_BYTE, sizeof(GLubyte), NULL, 1);
}
#endif

static void
draw_window_padding(const UIRenderData *ui, Window *window, ssize_t vao_idx, bool for_final_output) {
    // Color the compensatory padding strips (the innermost slice of the window
    // padding, arising from the window size not being an exact multiple of the
    // cell size) to match their neighboring cell. The strips lie outside the
    // per-window cell viewport, so this runs with the full framebuffer viewport.
    //
    // Two instanced draws are issued: one covers the horizontal pair (top+bottom)
    // and one the vertical pair (left+right). Each draw packs its strip cells into
    // a dedicated buffer so the VAO needs no per-strip reconfiguration. The shader
    // selects per-strip geometry and cell indices branch-free via lerp.
    //
    // Both backends share the geometry, the uniform pushes and the draws. They
    // differ in how the shader reaches cell data: the GL arm packs the strip
    // cells into dedicated instanced-attribute buffers (GPU region copies for
    // rows, a CPU gather for columns), while the Metal arm's padding_fork.slang
    // fetches the live cell/selection streams by grid index in the vertex, so
    // the packing (and the attribute repointing around it) is GL-only.
    if (!window || OPT(padding_fill_strategy) != PADDING_FILL_NEIGHBORING_CELL) return;
    const unsigned int cl = window->size_mismatch_padding.left, ct = window->size_mismatch_padding.top, cr = window->size_mismatch_padding.right,
                       cb = window->size_mismatch_padding.bottom;
    if (!(cl | ct | cr | cb)) return;
    Screen *screen = ui->screen;
    const unsigned int columns = screen->columns, lines = screen->lines;
    if (!columns || !lines) return;
    const unsigned int render_offset = pixel_scroll_enabled(screen) ? 1u : 0u;
    const unsigned int top_row = render_offset, bottom_row = render_offset + lines - 1u;

    const float fbw = (float)ui->full_framebuffer_width, fbh = (float)ui->full_framebuffer_height;
    const float cw = (float)ui->cell_width, ch = (float)ui->cell_height;
    const float fL = (float)ui->screen_left, T = (float)ui->screen_top;
    const float R = fL + (float)ui->screen_width, B = T + (float)ui->screen_height;
#define NX(px) (2.f * (px) / fbw - 1.f)
#define NY(px) (1.f - 2.f * (px) / fbh)
    const float dx = 2.f * cw / fbw, dy = 2.f * ch / fbh;

    bind_program(PADDING_PROGRAM);
    bind_vertex_array(vao_idx);
    CELL_BUFFERS;
    bind_vao_uniform_buffer(vao_idx, uniform_buffer, CELL_RENDER_DATA_BINDING_POINT);
    bind_vao_uniform_buffer(vao_idx, color_table_buffer, COLOR_TABLE_BINDING_POINT);
    if (for_final_output) glEnable(GL_FRAMEBUFFER_SRGB);

#ifndef KITTY_BACKEND_METAL
    // Point instanced attributes at the padding-specific buffers once for both draws.
    configure_padding_vao_attributes(vao_idx);
#endif

#define PL(x) program_uniform_location(PADDING_PROGRAM, #x)

    // Horizontal combined draw: top strip (strip 0) + bottom strip (strip 1).
    // Cell data is packed contiguously via GPU-side copies (no CPU round-trip).
    if (ct || cb) {
        const unsigned int nH = (ct ? 1u : 0u) + (cb ? 1u : 0u);
#ifndef KITTY_BACKEND_METAL
        alloc_vao_buffer(vao_idx, (GLsizeiptr)(sizeof(GPUCell) * nH * columns), padding_cell_data_buffer, GL_DYNAMIC_DRAW);
        alloc_vao_buffer(vao_idx, (GLsizeiptr)(sizeof(GLubyte) * nH * columns), padding_selection_buffer, GL_DYNAMIC_DRAW);

        unsigned int sidx = 0u;
        if (ct) {
            copy_vao_buffer_region(
                vao_idx,
                cell_data_buffer,
                (GLintptr)(sizeof(GPUCell) * top_row * columns),
                padding_cell_data_buffer,
                (GLintptr)(sizeof(GPUCell) * sidx * columns),
                (GLsizeiptr)(columns * sizeof(GPUCell)));
            copy_vao_buffer_region(
                vao_idx,
                selection_buffer,
                (GLintptr)(sizeof(GLubyte) * top_row * columns),
                padding_selection_buffer,
                (GLintptr)(sizeof(GLubyte) * sidx * columns),
                (GLsizeiptr)(columns * sizeof(GLubyte)));
            sidx++;
        }
        if (cb) {
            copy_vao_buffer_region(
                vao_idx,
                cell_data_buffer,
                (GLintptr)(sizeof(GPUCell) * bottom_row * columns),
                padding_cell_data_buffer,
                (GLintptr)(sizeof(GPUCell) * sidx * columns),
                (GLsizeiptr)(sizeof(GPUCell) * columns));
            copy_vao_buffer_region(
                vao_idx,
                selection_buffer,
                (GLintptr)(sizeof(GLubyte) * bottom_row * columns),
                padding_selection_buffer,
                (GLintptr)(sizeof(GLubyte) * sidx * columns),
                (GLsizeiptr)(columns * sizeof(GLubyte)));
        }
#endif

        // Strip-0 is top (or bottom when only bottom exists); strip-1 is bottom.
        // For a single-strip draw base_instance2/across2 equal strip-0 values so
        // the shader lerp is a no-op for all instances (strip_f is always 0.0).
        const unsigned int base0 = (ct ? top_row : bottom_row) * columns;
        const unsigned int base1 = bottom_row * columns;
        glUniform1ui(PL(is_horizontal), 1u);
        glUniform1ui(PL(along_count), columns);
        glUniform1ui(PL(instance_step), 1u);
        glUniform1ui(PL(base_instance), base0);
        glUniform1ui(PL(base_instance2), base1);
        glUniform2f(PL(across), ct ? NY(T - ct) : NY(B), ct ? NY(T) : NY(B + cb));
        glUniform2f(PL(across2), NY(B), NY(B + cb));
        glUniform1f(PL(along_start), NX(fL));
        glUniform1f(PL(along_step), dx);
        glUniform2f(PL(along_clamp), NX(fL), NX(R));
        draw_quad(!for_final_output, nH * columns);
    }

    // Vertical combined draw: left strip (strip 0) + right strip (strip 1).
    // Column cells are non-contiguous in the cell buffer so we gather them
    // CPU-side by mapping the buffer for reading, then upload in one shot.
    if (cl || cr) {
        const unsigned int nV = (cl ? 1u : 0u) + (cr ? 1u : 0u);
#ifndef KITTY_BACKEND_METAL
        // VLA sizes: lines is bounded by the window height / cell height (~<500).
        GPUCell gathered_cells[2 * lines];
        GLubyte gathered_sel[2 * lines];

        const unsigned int strip0_col = cl ? 0u : (columns - 1u);
        const unsigned int strip1_col = columns - 1u;

        const GPUCell *cells = (const GPUCell *)map_vao_buffer_for_reading(vao_idx, cell_data_buffer);
        for (unsigned int i = 0; i < lines; i++) {
            gathered_cells[i] = cells[(top_row + i) * columns + strip0_col];
            if (nV == 2u) gathered_cells[lines + i] = cells[(top_row + i) * columns + strip1_col];
        }
        unmap_vao_buffer(vao_idx, cell_data_buffer);

        const GLubyte *sel = (const GLubyte *)map_vao_buffer_for_reading(vao_idx, selection_buffer);
        for (unsigned int i = 0; i < lines; i++) {
            gathered_sel[i] = sel[(top_row + i) * columns + strip0_col];
            if (nV == 2u) gathered_sel[lines + i] = sel[(top_row + i) * columns + strip1_col];
        }
        unmap_vao_buffer(vao_idx, selection_buffer);

        void *dst = alloc_and_map_vao_buffer(vao_idx, (GLsizeiptr)(sizeof(GPUCell) * nV * lines), padding_cell_data_buffer, false);
        memcpy(dst, gathered_cells, sizeof(GPUCell) * nV * lines);
        unmap_vao_buffer(vao_idx, padding_cell_data_buffer);

        dst = alloc_and_map_vao_buffer(vao_idx, (GLsizeiptr)(sizeof(GLubyte) * nV * lines), padding_selection_buffer, false);
        memcpy(dst, gathered_sel, sizeof(GLubyte) * nV * lines);
        unmap_vao_buffer(vao_idx, padding_selection_buffer);
#endif

        const unsigned int base0 = top_row * columns + (cl ? 0u : (columns - 1u));
        const unsigned int base1 = top_row * columns + (columns - 1u);
        glUniform1ui(PL(is_horizontal), 0u);
        glUniform1ui(PL(along_count), lines);
        glUniform1ui(PL(instance_step), columns);
        glUniform1ui(PL(base_instance), base0);
        glUniform1ui(PL(base_instance2), base1);
        glUniform2f(PL(across), cl ? NX(fL - cl) : NX(R), cl ? NX(fL) : NX(R + cr));
        glUniform2f(PL(across2), NX(R), NX(R + cr));
        glUniform1f(PL(along_start), NY(T));
        glUniform1f(PL(along_step), -dy);
        glUniform2f(PL(along_clamp), NY(T - ct), NY(B + cb));
        draw_quad(!for_final_output, nV * lines);
    }

#undef PL
    if (for_final_output) glDisable(GL_FRAMEBUFFER_SRGB);
#ifndef KITTY_BACKEND_METAL
    // Restore the canonical cell attribute layout so subsequent cell rendering is unaffected.
    configure_cell_vao_attributes(vao_idx, 0u, 1u);
#endif
    unbind_program();
#undef NX
#undef NY
}

static void
draw_tint(const UIRenderData *ui) {
    bind_program(TINT_PROGRAM);
    color_vec4_premult(program_uniform_location(TINT_PROGRAM, "tint_color"), ui->background_color, OPT(background_tint));
    glUniform4f(program_uniform_location(TINT_PROGRAM, "edges"), -1, 1, 1, -1);
    draw_quad(true, 0);
}

static void
draw_cells_with_layers(const UIRenderData *ui, ssize_t vao_idx) {
    if (ui->has_background_image && OPT(background_tint) > 0) draw_tint(ui);
    const bool has_content_between_background_and_foreground = ui->window_logo != NULL || ui->grd.num_of_below_refs > 0 || ui->grd.num_of_negative_refs > 0;
    if (has_content_between_background_and_foreground) {
        if (!ui->has_background_image) call_cell_program(CELL_BG_PROGRAM, ui, vao_idx, false, DRAW_DEFAULT_BG);
        if (ui->window_logo != NULL) draw_window_logo(ui);
        if (ui->grd.num_of_below_refs > 0) draw_graphics(
                GRAPHICS_PROGRAM, ui->grd.images, 0, ui->grd.num_of_below_refs, ui->inactive_text_alpha,
                ui->os_window->edr_headroom);
        call_cell_program(CELL_BG_PROGRAM, ui, vao_idx, false, DRAW_NON_DEFAULT_BG);
        if (ui->grd.num_of_negative_refs) draw_graphics(
                GRAPHICS_PROGRAM, ui->grd.images, ui->grd.num_of_below_refs, ui->grd.num_of_negative_refs,
                ui->inactive_text_alpha, ui->os_window->edr_headroom);
        call_cell_program(CELL_FG_PROGRAM, ui, vao_idx, false, DRAW_NEITHER_BG);
    } else call_cell_program(CELL_PROGRAM, ui, vao_idx, false, ui->has_background_image ? DRAW_NON_DEFAULT_BG : DRAW_BOTH_BG);

    if (ui->grd.num_of_positive_refs > 0) draw_graphics(
            GRAPHICS_PROGRAM, ui->grd.images, ui->grd.num_of_below_refs + ui->grd.num_of_negative_refs,
            ui->grd.num_of_positive_refs, ui->inactive_text_alpha, ui->os_window->edr_headroom);

    draw_visual_bell(ui);
    draw_drag_preview_overlay(ui);
    draw_progress_bar(ui);
    draw_scrollbar(ui);
    draw_hyperlink_target(ui);
    draw_window_number(ui);
}

void
blank_canvas(float background_opacity, color_type color_in_srgb, bool for_final_output) {
    if (for_final_output) {
        // we need to write pre-multiplied sRGB color to framebuffer
#define C(shift) ((((color_in_srgb >> shift) & 0xFF) / 255.f) * background_opacity)
        glClearColor(C(16), C(8), C(0), background_opacity);
#undef C
    } else {
        // we need to write pre-multiplied linear color to framebuffer
#define C(shift) srgb_color((color_in_srgb >> shift) & 0xFF) * background_opacity
        glClearColor(C(16), C(8), C(0), background_opacity);
#undef C
    }
    glClear(GL_COLOR_BUFFER_BIT);
}

bool
send_cell_data_to_gpu(ssize_t vao_idx, Screen *screen, OSWindow *os_window) {
    bool changed = false;
    if (os_window->fonts_data) {
        if (cell_prepare_to_render(vao_idx, screen, os_window->fonts_data)) changed = true;
    }
    // W27 P4.2: cell_prepare_to_render has just refreshed this screen's visible
    // image refs (grman_update_layers), so this is the first moment the answer
    // to "does this OS window show HDR content?" is current for this screen.
    // Accumulate with OR across every screen prepared this tick; the caller
    // (child-monitor's prepare_to_render_os_window) clears the flag before the
    // sweep and reads it after, which is what makes engagement drop back to
    // disengaged as soon as the last HDR image stops being visible.
    GraphicsManager *grman = screen->paused_rendering.expires_at && screen->paused_rendering.grman ?
        screen->paused_rendering.grman : screen->grman;
    if (grman_has_hdr_refs(grman)) os_window->has_hdr_content = true;
    return changed;
}

void
draw_cells(const WindowRenderData *srd, OSWindow *os_window, bool is_active_window, bool is_tab_bar, bool is_single_window, Window *window, monotonic_t now) {
    Screen *screen = srd->screen;
    CELL_BUFFERS;
    bind_vertex_array(srd->vao_idx);
    // When inactive_text_alpha is negative, its absolute value is used as the
    // opacity and fading is based only on whether the current window is active.
    const float inactive_text_alpha = fabsf(OPT(inactive_text_alpha));
    const bool use_active_window_only = OPT(inactive_text_alpha) < 0.f;
    float current_inactive_text_alpha =
        use_active_window_only
            ? (is_tab_bar || is_active_window ? 1.0f : inactive_text_alpha)
            : (is_tab_bar || (!is_single_window && is_active_window) || (is_single_window && screen->cursor_render_info.is_focused) ? 1.0f
                                                                                                                                    : inactive_text_alpha);
    float bg_alpha = effective_os_window_alpha(os_window);

    color_type default_bg = cell_update_uniform_block(
        srd->vao_idx, screen, uniform_buffer, color_table_buffer, &screen->cursor_render_info, os_window, current_inactive_text_alpha, bg_alpha);
    set_cell_uniforms(screen->reload_all_gpu_data);
    WindowLogoRenderData *wl;
    if (window && (wl = &window->window_logo) && wl->id && (wl->instance = find_window_logo(global_state.all_window_logos, wl->id)) &&
        wl->instance->load_from_disk_ok) {
        if (!window->window_logo.instance->texture_id) { set_on_gpu_state(window->window_logo.instance, true); }
    } else wl = NULL;
    GraphicsManager *grman = screen->paused_rendering.expires_at && screen->paused_rendering.grman ? screen->paused_rendering.grman : screen->grman;
    UIRenderData ui = {
        .screen_width = srd->geometry.right - srd->geometry.left,
        .screen_height = srd->geometry.bottom - srd->geometry.top,
        .cell_width = os_window->fonts_data->fcm.cell_width,
        .cell_height = os_window->fonts_data->fcm.cell_height,
        .screen_left = srd->geometry.left,
        .screen_top = srd->geometry.top,
        .full_framebuffer_width = os_window->viewport_width,
        .full_framebuffer_height = os_window->viewport_height,
        .window = window,
        .screen = screen,
        .os_window = os_window,
        .grd = grman_render_data(grman),
        .window_logo = wl,
        .inactive_text_alpha = current_inactive_text_alpha,
        .has_background_image = has_bgimage(os_window),
        .background_color = default_bg,
        .bg_alpha = effective_os_window_alpha(os_window),
        .now = now,
    };
    screen->reload_all_gpu_data = false;
    save_viewport_using_top_left_origin(ui.screen_left, ui.screen_top, ui.screen_width, ui.screen_height, ui.full_framebuffer_height);
    if (ui.os_window->needs_layers) draw_cells_with_layers(&ui, srd->vao_idx);
    else draw_cells_without_layers(&ui, srd->vao_idx);
    restore_viewport();
    // The compensatory padding lies outside the per-window cell viewport, so it
    // is drawn after restoring the full framebuffer viewport.
    draw_window_padding(&ui, window, srd->vao_idx, !ui.os_window->needs_layers);
}
// }}}

// Borders {{{

ssize_t
create_border_vao(void) {
    ssize_t vao_idx = create_vao();

    add_buffer_to_vao(vao_idx, GL_ARRAY_BUFFER);
    add_attribute_to_vao(
        vao_idx,
        program_attribute_location(BORDERS_PROGRAM, "rect"),
        /*size=*/4,
        /*dtype=*/GL_FLOAT,
        /*stride=*/sizeof(BorderRect),
        /*offset=*/(void *)offsetof(BorderRect, left),
        /*divisor=*/1);
    add_attribute_to_vao(
        vao_idx,
        program_attribute_location(BORDERS_PROGRAM, "rect_color"),
        /*size=*/1,
        /*dtype=*/GL_UNSIGNED_INT,
        /*stride=*/sizeof(BorderRect),
        /*offset=*/(void *)(offsetof(BorderRect, color)),
        /*divisor=*/1);

    return vao_idx;
}

void
draw_borders(
    ssize_t vao_idx,
    unsigned int num_border_rects,
    BorderRect *rect_buf,
    bool rect_data_is_dirty,
    color_type active_window_bg,
    unsigned int num_visible_windows,
    bool all_windows_have_same_bg,
    OSWindow *w) {
    float background_opacity = effective_os_window_alpha(w);
    if (!num_border_rects) return;
    bind_program(BORDERS_PROGRAM);
    bind_vertex_array(vao_idx);
    const bool has_background_image = has_bgimage(w);
    if (has_background_image) background_opacity = OPT(background_tint) * OPT(background_tint_gaps);
    if (rect_data_is_dirty) {
        const size_t sz = sizeof(BorderRect) * num_border_rects;
        void *borders_buf_address = alloc_and_map_vao_buffer(vao_idx, sz, 0, false);
        if (borders_buf_address) memcpy(borders_buf_address, rect_buf, sz);
        unmap_vao_buffer(vao_idx, 0);
    }
    color_type default_bg = (num_visible_windows > 1 && !all_windows_have_same_bg) ? OPT(background) : active_window_bg;
    GLuint colors[9] = {
        default_bg, OPT(active_border_color), OPT(inactive_border_color), 0,
        OPT(bell_border_color), OPT(tab_bar_background), OPT(tab_bar_margin_color),
        w->tab_bar_edge_color.left, w->tab_bar_edge_color.right
    };
#ifdef KITTY_BACKEND_METAL
    // border_fork.slang keeps the fork's uniform-array colour block (routed to
    // the value store by the shim), not the UBO upstream moved the GL arm to.
    glUniform1uiv(program_uniform_location(BORDERS_PROGRAM, "colors"), arraysz(colors), colors);
#else
    void *colors_buf =
        map_vao_buffer_for_write_only(shader_globals_vao_idx, BORDER_COLORS_GLOBAL_BUFFER, 0, program_uniform_block(BORDERS_PROGRAM, "Colors").size);
    const ArrayInformation border_colors_array = program_uniform_array(BORDERS_PROGRAM, "colors");
    write_uint_array_to_ubo(colors_buf, colors, arraysz(colors), &border_colors_array);
    unmap_vao_buffer(shader_globals_vao_idx, BORDER_COLORS_GLOBAL_BUFFER);
#endif
    glUniform1f(program_uniform_location(BORDERS_PROGRAM, "background_opacity"), background_opacity);
    // C1: Metal sRGB-encodes in the border fragment (TARGET_COLOR_SPACE ==
    // ENCODE_SRGB) for the opaque/drawable path, so the framebuffer toggle is a
    // no-op there.
#ifndef KITTY_BACKEND_METAL
    if (!w->needs_layers) glEnable(GL_FRAMEBUFFER_SRGB);
#endif
    draw_quad(has_background_image, num_border_rects);
#ifndef KITTY_BACKEND_METAL
    if (!w->needs_layers) glDisable(GL_FRAMEBUFFER_SRGB);
#endif
    unbind_program(); unbind_vertex_array();
}

// }}}

// Cursor Trail {{{
void
draw_cursor_trail(CursorTrail *trail, Window *active_window) {
    bind_program(TRAIL_PROGRAM);

    glUniform4fv(program_uniform_location(TRAIL_PROGRAM, "x_coords"), 1, trail->corner_x);
    glUniform4fv(program_uniform_location(TRAIL_PROGRAM, "y_coords"), 1, trail->corner_y);

    glUniform2fv(program_uniform_location(TRAIL_PROGRAM, "cursor_edge_x"), 1, trail->cursor_edge_x);
    glUniform2fv(program_uniform_location(TRAIL_PROGRAM, "cursor_edge_y"), 1, trail->cursor_edge_y);

    color_type trail_color = OPT(cursor_trail_color);
    if (trail_color == 0) { // 0 means "none" was specified
        trail_color = active_window ? active_window->render_data.screen->last_rendered.cursor_bg : OPT(foreground);
    }
    color_vec3(program_uniform_location(TRAIL_PROGRAM, "trail_color"), trail_color);

    glUniform1f(program_uniform_location(TRAIL_PROGRAM, "trail_opacity"), trail->opacity);

    draw_quad(true, 0);
    unbind_program();
}

// }}}

// OSWindow {{{
static void
draw_bg_image(OSWindow *os_window, Tab *tab) {
    BackgroundImage *bg = background_image_for_os_window(os_window);
    if (!bg) return;
    BackgroundImageLayout layout = os_window->background_image.has_layout ? os_window->background_image.layout : OPT(background_image_layout);
    BackgroundImageRenderSettings s = {
        .os_window.width = os_window->viewport_width,
        .os_window.height = os_window->viewport_height,
        .instance_id = bg->id,
        .layout = layout,
        .linear = OPT(background_image_linear),
        .bgcolor = OPT(background),
        .opacity = effective_os_window_alpha(os_window),
    };
    GLfloat iwidth = bg->width, iheight = bg->height;
    GLfloat vwidth = s.os_window.width, vheight = s.os_window.height;
    if (CENTER_SCALED == layout) {
        GLfloat ifrac = iwidth / iheight;
        if (ifrac > (vwidth / vheight)) {
            iheight = vheight;
            iwidth = iheight * ifrac;
        } else {
            iwidth = vwidth;
            iheight = iwidth / ifrac;
        }
    }
    GLfloat tiled = 0.f;
    ;
    GLfloat left = -1.0, top = 1.0, right = 1.0, bottom = -1.0;
    switch (layout) {
        case TILING:
        case MIRRORED:
        case CLAMPED: tiled = 1.f; break;
        case SCALED: break;
        case CENTER_CLAMPED:
        case CENTER_SCALED: {
            GLfloat wfrac = (vwidth - iwidth) / vwidth;
            GLfloat hfrac = (vheight - iheight) / vheight;
            left += wfrac;
            right -= wfrac;
            top -= hfrac;
            bottom += hfrac;
        } break;
    }
    bind_program(BGIMAGE_PROGRAM);
    // altough we dont use this VO we need to ensure *some* VAO is bound at this point.
    bind_vertex_array(tab->border_rects.vao_idx);
    glUniform4f(program_uniform_location(BGIMAGE_PROGRAM, "sizes"), vwidth, vheight, iwidth, iheight);
    glUniform1f(program_uniform_location(BGIMAGE_PROGRAM, "tiled"), tiled);
    glUniform4f(program_uniform_location(BGIMAGE_PROGRAM, "positions"), left, top, right, bottom);
    glUniform1i(program_uniform_location(BGIMAGE_PROGRAM, "image"), GRAPHICS_UNIT);
    color_vec4(program_uniform_location(BGIMAGE_PROGRAM, "background"), s.bgcolor, s.opacity);
    glActiveTexture(GL_TEXTURE0 + GRAPHICS_UNIT);
    glBindTexture(GL_TEXTURE_2D, bg->texture_id);
    draw_quad(false, 0);
    unbind_program();
}

static void
gpu_data_for_centered_image(ImageRenderData *ans, unsigned int screen_width_px, unsigned int screen_height_px, unsigned int width, unsigned int height) {
    float width_frac = 2 * MIN(1, width / (float)screen_width_px), height_frac = 2 * MIN(1, height / (float)screen_height_px);
    float hmargin = (2 - width_frac) / 2;
    float vmargin = (2 - height_frac) / 2;
    gpu_data_for_image(ans, -1 + hmargin, 1 - vmargin, -1 + hmargin + width_frac, 1 - vmargin - height_frac);
}

static void
draw_centered_alpha_mask(size_t screen_width, size_t screen_height, size_t width, size_t height, uint8_t *canvas, float background_opacity) {
    ImageRenderData *data = load_alpha_mask_texture(width, height, canvas);
    gpu_data_for_centered_image(data, screen_width, screen_height, width, height);
    bind_program(GRAPHICS_ALPHA_MASK_PROGRAM);
    glUniform1i(program_uniform_location(GRAPHICS_ALPHA_MASK_PROGRAM, "image"), GRAPHICS_UNIT);
    color_vec3(program_uniform_location(GRAPHICS_ALPHA_MASK_PROGRAM, "amask_fg"), OPT(foreground));
    color_vec4_premult(program_uniform_location(GRAPHICS_ALPHA_MASK_PROGRAM, "amask_bg_premult"), OPT(background), background_opacity);
    // No OS window in scope here (the live-resize / "resizing" overlay path) and
    // the alpha-mask program does not tone-map, so an SDR headroom is exact.
    draw_graphics(GRAPHICS_ALPHA_MASK_PROGRAM, data, 0, 1, 1.0, 1.f);
}

static void
draw_resizing_text(OSWindow *w) {
    if (monotonic() - w->created_at > ms_to_monotonic_t(1000) && w->live_resize.num_of_resize_events > 1) {
        char text[32] = {0};
        unsigned int width = w->live_resize.width, height = w->live_resize.height;
        snprintf(text, sizeof(text), "%u by %u cells", width / w->fonts_data->fcm.cell_width, height / w->fonts_data->fcm.cell_height);
        StringCanvas rendered = render_simple_text(w->fonts_data, text);
        if (rendered.canvas) {
            draw_centered_alpha_mask(width, height, rendered.width, rendered.height, rendered.canvas, MAX(0.2f, MIN(OPT(background_opacity), 0.8f)));
            free(rendered.canvas);
        }
    }
}

void
blank_os_window(OSWindow *osw) {
    color_type color = OPT(background);
    if (osw->num_tabs > 0) {
        Tab *t = osw->tabs + osw->active_tab;
        if (t->num_windows == 1) {
            Window *w = t->windows + t->active_window;
            Screen *s = w->render_data.screen;
            if (s) { color = colorprofile_to_color(s->color_profile, s->color_profile->overridden.default_bg, s->color_profile->configured.default_bg).rgb; }
        }
    }
    blank_canvas(effective_os_window_alpha(osw), color, true);
}

static void
start_os_window_rendering(OSWindow *os_window, Tab *tab) {
    // note that during live resize rendering is done in layers
    if (os_window->live_resize.in_progress) blank_os_window(os_window);
    if (os_window->needs_layers) {
#ifdef KITTY_BACKEND_METAL
        // M1: single-pass layered rendering. Open ONE render pass whose color
        // attachment 0 is a memoryless RGBA16Unorm working surface and attachment
        // 1 is the drawable; the bg image and all subsequent layered draws
        // composite linear-premultiplied into att0. metal_resolve_layered_frame()
        // (in stop_os_window_rendering) performs the in-shader linear->sRGB resolve
        // onto the drawable in the same pass — no RGBA16 DRAM FBO, no separate BLIT
        // pass (~123 MB/frame round trip and the 2nd pass eliminated). The
        // save_viewport here balances the restore_viewport in stop.
        metal_begin_layered_frame();
        save_viewport_using_bottom_left_origin(0, 0, os_window->viewport_width, os_window->viewport_height);
        draw_bg_image(os_window, tab);
#else
        // Ensure the global shared texture is large enough for this window
        if (global_state.layers_render_texture.width < os_window->viewport_width || global_state.layers_render_texture.height < os_window->viewport_height) {
            if (global_state.layers_render_texture.texture_id) free_texture(&global_state.layers_render_texture.texture_id);
            if (global_state.layers_render_texture.framebuffer_id) free_framebuffer(&global_state.layers_render_texture.framebuffer_id);
            if (global_state.layers_render_texture.extra_texture_id) free_texture(&global_state.layers_render_texture.extra_texture_id);
            if (global_state.layers_render_texture.extra_texture_setup_fbo_id) free_framebuffer(&global_state.layers_render_texture.extra_texture_setup_fbo_id);
            if (global_state.layers_render_texture.texture_a_id) free_texture(&global_state.layers_render_texture.texture_a_id);
            if (global_state.layers_render_texture.texture_a_fbo_id) free_framebuffer(&global_state.layers_render_texture.texture_a_fbo_id);
            if (global_state.layers_render_texture.texture_b_id) free_texture(&global_state.layers_render_texture.texture_b_id);
            if (global_state.layers_render_texture.texture_b_fbo_id) free_framebuffer(&global_state.layers_render_texture.texture_b_fbo_id);
            unsigned new_w = (unsigned)MAX(global_state.layers_render_texture.width, os_window->viewport_width);
            unsigned new_h = (unsigned)MAX(global_state.layers_render_texture.height, os_window->viewport_height);
            setup_texture_as_render_target(new_w, new_h, &global_state.layers_render_texture.texture_id, &global_state.layers_render_texture.framebuffer_id);
            global_state.layers_render_texture.width = (int)new_w;
            global_state.layers_render_texture.height = (int)new_h;
            global_state.layers_render_texture.texture_generation++;
        }
        // Create per-window framebuffer if needed and attach the global texture to it
        if (!os_window->indirect_output.framebuffer_id) glGenFramebuffers(1, &os_window->indirect_output.framebuffer_id);
        if (os_window->indirect_output.attached_texture_generation != global_state.layers_render_texture.texture_generation) {
            bind_framebuffer_for_output(os_window->indirect_output.framebuffer_id);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, global_state.layers_render_texture.texture_id, 0);
            os_window->indirect_output.attached_texture_generation = global_state.layers_render_texture.texture_generation;
        }
        if (custom_shaders.end.num_groups > 1) {
            // Lazily create the global shared extra texture (ping-pong target for multi-group end shaders)
            if (!global_state.layers_render_texture.extra_texture_id) {
                setup_texture_as_render_target(
                    (unsigned)global_state.layers_render_texture.width,
                    (unsigned)global_state.layers_render_texture.height,
                    &global_state.layers_render_texture.extra_texture_id,
                    &global_state.layers_render_texture.extra_texture_setup_fbo_id);
            }
            // Create/re-attach per-window extra FBO when generation changes
            if (os_window->indirect_output.extra_fbo_generation != global_state.layers_render_texture.texture_generation) {
                if (os_window->indirect_output.extra_fbo_id) free_framebuffer(&os_window->indirect_output.extra_fbo_id);
                glGenFramebuffers(1, &os_window->indirect_output.extra_fbo_id);
                bind_framebuffer_for_output(os_window->indirect_output.extra_fbo_id);
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, global_state.layers_render_texture.extra_texture_id, 0);
                os_window->indirect_output.extra_fbo_generation = global_state.layers_render_texture.texture_generation;
            }
        }
        // Named texture A: global shared, per-window FBO
        if (custom_shaders.end.textures & (1u << CUSTOM_SHADER_TEXTURE_A)) {
            if (!global_state.layers_render_texture.texture_a_id) {
                setup_texture_as_render_target(
                    (unsigned)global_state.layers_render_texture.width,
                    (unsigned)global_state.layers_render_texture.height,
                    &global_state.layers_render_texture.texture_a_id,
                    &global_state.layers_render_texture.texture_a_fbo_id);
            }
            if (os_window->indirect_output.fbo_a_generation != global_state.layers_render_texture.texture_generation) {
                if (os_window->indirect_output.fbo_a_id) free_framebuffer(&os_window->indirect_output.fbo_a_id);
                glGenFramebuffers(1, &os_window->indirect_output.fbo_a_id);
                bind_framebuffer_for_output(os_window->indirect_output.fbo_a_id);
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, global_state.layers_render_texture.texture_a_id, 0);
                os_window->indirect_output.fbo_a_generation = global_state.layers_render_texture.texture_generation;
            }
        } else {
            if (os_window->indirect_output.fbo_a_id) free_framebuffer(&os_window->indirect_output.fbo_a_id);
        }
        // Named texture B: global shared, per-window FBO
        if (custom_shaders.end.textures & (1u << CUSTOM_SHADER_TEXTURE_B)) {
            if (!global_state.layers_render_texture.texture_b_id) {
                setup_texture_as_render_target(
                    (unsigned)global_state.layers_render_texture.width,
                    (unsigned)global_state.layers_render_texture.height,
                    &global_state.layers_render_texture.texture_b_id,
                    &global_state.layers_render_texture.texture_b_fbo_id);
            }
            if (os_window->indirect_output.fbo_b_generation != global_state.layers_render_texture.texture_generation) {
                if (os_window->indirect_output.fbo_b_id) free_framebuffer(&os_window->indirect_output.fbo_b_id);
                glGenFramebuffers(1, &os_window->indirect_output.fbo_b_id);
                bind_framebuffer_for_output(os_window->indirect_output.fbo_b_id);
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, global_state.layers_render_texture.texture_b_id, 0);
                os_window->indirect_output.fbo_b_generation = global_state.layers_render_texture.texture_generation;
            }
        } else {
            if (os_window->indirect_output.fbo_b_id) free_framebuffer(&os_window->indirect_output.fbo_b_id);
        }
        // Named texture persist: per-window, recreated when global texture dimensions change
        if (custom_shaders.end.textures & (1u << CUSTOM_SHADER_TEXTURE_PERSIST)) {
            if (os_window->persist_texture_generation != global_state.layers_render_texture.texture_generation) {
                if (os_window->persist_texture_id) free_texture(&os_window->persist_texture_id);
                if (os_window->persist_fbo_id) free_framebuffer(&os_window->persist_fbo_id);
                setup_texture_as_render_target(
                    (unsigned)global_state.layers_render_texture.width,
                    (unsigned)global_state.layers_render_texture.height,
                    &os_window->persist_texture_id,
                    &os_window->persist_fbo_id);
                os_window->persist_texture_generation = global_state.layers_render_texture.texture_generation;
            }
        } else {
            if (os_window->persist_texture_id) free_texture(&os_window->persist_texture_id);
            if (os_window->persist_fbo_id) free_framebuffer(&os_window->persist_fbo_id);
        }
        set_framebuffer_to_use_for_output(os_window->indirect_output.framebuffer_id);
        bind_framebuffer_for_output(0);
        save_viewport_using_bottom_left_origin(0, 0, os_window->viewport_width, os_window->viewport_height);
        clear_current_framebuffer();
        draw_bg_image(os_window, tab);
#endif
    }
}

#ifndef KITTY_BACKEND_METAL
// Custom end shaders never activate on the Metal backend (see compile_program),
// so their GL render pass is compiled out there.
static void
run_custom_end_shader(OSWindow *os_window, float sx, float sy, monotonic_t now) {
    bind_program(CUSTOM_END_PROGRAM);
    struct GPUCustomEndData {
        float src_rect[4];
        float dest_rect[4];
        float background[4];
        float foreground[4];
        float active_window_background[4];
        float mouse_pos[4];
        float mouse_button_pressed[4];
        float active_window_geometry[4];
        float bell_window_geometry[4];
        float central_area[4];
        float cursor_trail_corners_x[4];
        float cursor_trail_corners_y[4];
        float cursor_trail_edge[4];
        float cursor_trail_prev_edge[4];
        float cursor_color[4];
        float cursor_trail_color[4];
        uint32_t viewport_size_pixels[2];
        float mouse_pointer_hidden;
        float cursor_trail_state;
        float timestamp, last_rendered_at;
        uint32_t frame_counter;
        float cursor_trail_change_time;
    };
    struct GPUCustomEndData *d = (struct GPUCustomEndData *)map_vao_buffer_for_write_only(
        custom_end_vao_idx, 0, 0, program_uniform_block(CUSTOM_END_PROGRAM, "KittyCustomShaderData").size);
    memset(d, 0, sizeof(struct GPUCustomEndData));
    d->src_rect[1] = sy;
    d->src_rect[2] = sx;
    d->dest_rect[0] = -1;
    d->dest_rect[1] = 1;
    d->dest_rect[2] = 1;
    d->dest_rect[3] = -1;
#define FILL_COLOR(dst, c)                         \
    do {                                           \
        (dst)[0] = srgb_color(((c) >> 16) & 0xFF); \
        (dst)[1] = srgb_color(((c) >> 8) & 0xFF);  \
        (dst)[2] = srgb_color((c) & 0xFF);         \
        (dst)[3] = 1.f;                            \
    } while (0)
    FILL_COLOR(d->background, OPT(background));
    FILL_COLOR(d->foreground, OPT(foreground));
    color_type active_bg = OPT(background);
    color_type cursor_color = OPT(foreground);
    float cursor_opacity = 0.f;
    WindowGeometry active_win_geom = {0};
    if (os_window->num_tabs > 0) {
        Tab *t = os_window->tabs + os_window->active_tab;
        if (t->num_windows) {
            Window *w = t->windows + t->active_window;
            active_win_geom = w->render_data.geometry;
            Screen *s = w->render_data.screen;
            if (s) {
                active_bg = colorprofile_to_color(s->color_profile, s->color_profile->overridden.default_bg, s->color_profile->configured.default_bg).rgb;
                cursor_color = s->last_rendered.cursor_bg;
                cursor_opacity = MAX(0.f, MIN(s->cursor_render_info.cursor_opacity, 1.f));
            }
        }
    }
    FILL_COLOR(d->active_window_background, active_bg);
#undef FILL_COLOR
    {
        CursorTrail *ct = NULL;
        if (OPT(cursor_trail) && os_window->num_tabs > 0) {
            CursorTrail *candidate = &os_window->tabs[os_window->active_tab].cursor_trail;
            if (candidate->needs_render) ct = candidate;
        }
        if (ct) {
#define NDC_TO_UV(v) (((v) + 1.0f) * 0.5f)
            for (int i = 0; i < 4; i++) {
                d->cursor_trail_corners_x[i] = NDC_TO_UV(ct->corner_x[i]);
                d->cursor_trail_corners_y[i] = NDC_TO_UV(ct->corner_y[i]);
            }
            d->cursor_trail_edge[0] = NDC_TO_UV(ct->cursor_edge_x[0]); // left
            d->cursor_trail_edge[1] = NDC_TO_UV(ct->cursor_edge_x[1]); // right
            d->cursor_trail_edge[2] = NDC_TO_UV(ct->cursor_edge_y[0]); // top
            d->cursor_trail_edge[3] = NDC_TO_UV(ct->cursor_edge_y[1]); // bottom
            if (ct->prev_edge_valid) {
                d->cursor_trail_prev_edge[0] = NDC_TO_UV(ct->prev_cursor_edge_x[0]); // left
                d->cursor_trail_prev_edge[1] = NDC_TO_UV(ct->prev_cursor_edge_x[1]); // right
                d->cursor_trail_prev_edge[2] = NDC_TO_UV(ct->prev_cursor_edge_y[0]); // top
                d->cursor_trail_prev_edge[3] = NDC_TO_UV(ct->prev_cursor_edge_y[1]); // bottom
            }
#undef NDC_TO_UV
            d->cursor_trail_color[3] = ct->opacity;
            d->cursor_trail_state = 1.0f;
            d->cursor_trail_change_time = ((float)monotonic_t_to_ms(ct->cursor_changed_at)) / 1e3f;
        }
    }
#define FILL_COLOR3(dst, c)                        \
    do {                                           \
        (dst)[0] = srgb_color(((c) >> 16) & 0xFF); \
        (dst)[1] = srgb_color(((c) >> 8) & 0xFF);  \
        (dst)[2] = srgb_color((c) & 0xFF);         \
    } while (0)
    FILL_COLOR3(d->cursor_color, cursor_color);
    d->cursor_color[3] = cursor_opacity;
    {
        color_type trail_color = OPT(cursor_trail_color);
        if (trail_color == 0) trail_color = cursor_color;
        FILL_COLOR3(d->cursor_trail_color, trail_color);
    }
#undef FILL_COLOR3
    d->viewport_size_pixels[0] = (uint32_t)os_window->viewport_width;
    d->viewport_size_pixels[1] = (uint32_t)os_window->viewport_height;
    const float vpw = (float)os_window->viewport_width, vph = (float)os_window->viewport_height;
    if (vpw > 0 && vph > 0) {
        d->mouse_pos[0] = (float)os_window->mouse_x / vpw;
        d->mouse_pos[1] = 1.f - (float)os_window->mouse_y / vph;
        d->mouse_pos[2] = (float)os_window->mouse_left_press_x / vpw;
        d->mouse_pos[3] = 1.f - (float)os_window->mouse_left_press_y / vph;
    }
    d->mouse_button_pressed[0] = os_window->mouse_button_pressed[GLFW_MOUSE_BUTTON_LEFT];
    d->mouse_button_pressed[1] = os_window->mouse_button_pressed[GLFW_MOUSE_BUTTON_RIGHT];
    d->mouse_button_pressed[2] = os_window->mouse_button_pressed[GLFW_MOUSE_BUTTON_MIDDLE];
    d->mouse_button_pressed[3] = os_window->mouse_button_pressed[3];
    d->mouse_pointer_hidden = is_mouse_hidden(os_window) ? 1.f : 0.f;
    d->timestamp = ((float)monotonic_t_to_ms(now)) / 1e3f;
    d->last_rendered_at = ((float)monotonic_t_to_ms(os_window->last_rendered_at)) / 1e3f;
    d->frame_counter = os_window->frame_counter;
    if (vpw > 0 && vph > 0 && active_win_geom.right > active_win_geom.left) {
        d->active_window_geometry[0] = (float)active_win_geom.left / vpw;
        d->active_window_geometry[1] = 1.f - (float)active_win_geom.bottom / vph;
        d->active_window_geometry[2] = (float)(active_win_geom.right - active_win_geom.left) / vpw;
        d->active_window_geometry[3] = (float)(active_win_geom.bottom - active_win_geom.top) / vph;
    }
    if (vpw > 0 && vph > 0) {
        Region central_rgn = {0}, tab_bar_rgn = {0};
        os_window_regions(os_window, &central_rgn, &tab_bar_rgn);
        d->central_area[0] = (float)central_rgn.left / vpw;
        d->central_area[1] = 1.f - (float)central_rgn.bottom / vph;
        d->central_area[2] = (float)(central_rgn.right - central_rgn.left) / vpw;
        d->central_area[3] = (float)(central_rgn.bottom - central_rgn.top) / vph;
    } else {
        d->central_area[2] = 1.f;
        d->central_area[3] = 1.f;
    }
    if (os_window->last_bell_window_id && os_window->num_tabs > 0 && vpw > 0 && vph > 0) {
        WindowGeometry bell_win_geom = {0};
        bool bell_win_found = false;
        Tab *bt = os_window->tabs + os_window->active_tab;
        for (unsigned i = 0; i < bt->num_windows; i++) {
            Window *bw = bt->windows + i;
            if (bw->id == os_window->last_bell_window_id && bw->visible) {
                bell_win_geom = bw->render_data.geometry;
                bell_win_found = true;
                break;
            }
        }
        if (bell_win_found && bell_win_geom.right > bell_win_geom.left) {
            d->bell_window_geometry[0] = (float)bell_win_geom.left / vpw;
            d->bell_window_geometry[1] = 1.f - (float)bell_win_geom.bottom / vph;
            d->bell_window_geometry[2] = (float)(bell_win_geom.right - bell_win_geom.left) / vpw;
            d->bell_window_geometry[3] = (float)(bell_win_geom.bottom - bell_win_geom.top) / vph;
        } else {
            memcpy(d->bell_window_geometry, d->central_area, sizeof(d->bell_window_geometry));
        }
    }
    unmap_vao_buffer(custom_end_vao_idx, 0);
    bind_vao_uniform_buffer(custom_end_vao_idx, 0, CUSTOM_END_DATA_BINDING_POINT);

    GLint group_loc = program_uniform_location(CUSTOM_END_PROGRAM, "group");
    GLint viewport_loc = program_uniform_location(CUSTOM_END_PROGRAM, "viewport");
    GLint anim_progress_loc = program_uniform_location(CUSTOM_END_PROGRAM, "animation_progress");
    GLint convert_to_srgb_loc = program_uniform_location(CUSTOM_END_PROGRAM, "convert_to_srgb");
    const unsigned num_groups = (unsigned)custom_shaders.end.num_groups;
    const unsigned textures_mask = custom_shaders.end.textures;
    const int vw = os_window->viewport_width, vh = os_window->viewport_height;

    // Named texture IDs and their render-target FBOs, indexed by NamedTexture enum value
    const GLuint named_tex_ids[4] = {
        0, // DEFAULT — unused
        global_state.layers_render_texture.texture_a_id,
        global_state.layers_render_texture.texture_b_id,
        os_window->persist_texture_id,
    };
    const GLuint named_tex_fbos[4] = {
        0, // DEFAULT — unused
        os_window->indirect_output.fbo_a_id,
        os_window->indirect_output.fbo_b_id,
        os_window->persist_fbo_id,
    };
    static const int named_tex_units[4] = {
        GRAPHICS_UNIT, // DEFAULT maps to backbuffer slot
        CUSTOM_END_TEXTURE_A_UNIT,
        CUSTOM_END_TEXTURE_B_UNIT,
        CUSTOM_END_TEXTURE_PERSIST_UNIT,
    };

    // Pre-scan to find the last group that will actually run this frame.
    // That group gets convert_to_srgb=true so its draw call replaces the
    // blit pass; all other groups write premultiplied linear RGB and skip it.
    int last_active_g = -1;
    for (unsigned g = 0; g < num_groups; g++) {
        const CustomShaderGroup *cg = &custom_shaders.end.groups[g];
        // Non-attached always-active groups always run; attached and animated groups run only when active.
        if ((!cg->attached && cg->animation_start_events == 0) || os_window->shader_group_anim[g].active) last_active_g = (int)g;
    }

    // Ping-pong state: when true, backbuffer = texture_id and the ping-pong
    // target is extra_texture_id; toggled each time a group outputs to DEFAULT.
    bool backbuffer_is_main = true;

    struct AnimCacheEntry {
        Animation *curve;
        monotonic_t started_at, duration;
        float progress;
    } anim_cache[MAX_CUSTOM_SHADER_GROUPS];
    size_t num_anim_cached = 0;

    for (unsigned g = 0; g < num_groups; g++) {
        const CustomShaderGroup *cg = &custom_shaders.end.groups[g];
        const bool is_last = (last_active_g >= 0 && g == (unsigned)last_active_g);

        // Skip inactive groups. Non-attached, non-animated groups always run; all others require
        // shader_group_anim[g].active (set by update_custom_shader_animations, including attach logic).
        if ((cg->animation_start_events != 0 || cg->attached) && !os_window->shader_group_anim[g].active) continue;
        const GLuint backbuffer = backbuffer_is_main ? global_state.layers_render_texture.texture_id : global_state.layers_render_texture.extra_texture_id;

        // Bind backbuffer to the backbuffer texture unit
        glActiveTexture(GL_TEXTURE0 + GRAPHICS_UNIT);
        glBindTexture(GL_TEXTURE_2D, backbuffer);

        // Bind each named texture to its own unit.
        // If the texture is the output for this group, or is not declared in the
        // pipeline, fall back to backbuffer so the sampler is always valid.
        for (int t = CUSTOM_SHADER_TEXTURE_A; t <= CUSTOM_SHADER_TEXTURE_PERSIST; t++) {
            GLuint tex;
            if (!is_last && cg->output_texture == (NamedTexture)t) {
                tex = backbuffer; // can't read from the render target we're writing to
            } else if (textures_mask & (1u << t)) {
                tex = named_tex_ids[t];
            } else {
                tex = backbuffer; // not present — fall back to backbuffer
            }
            glActiveTexture(GL_TEXTURE0 + named_tex_units[t]);
            glBindTexture(GL_TEXTURE_2D, tex);
        }

        // Set the output framebuffer
        if (is_last) {
            set_framebuffer_to_use_for_output(0);
            bind_framebuffer_for_output(0);
        } else if (cg->output_texture != CUSTOM_SHADER_TEXTURE_DEFAULT) {
            // Output to named texture; backbuffer is unchanged for the next group
            bind_framebuffer_for_output(named_tex_fbos[cg->output_texture]);
        } else {
            // Ping-pong: output to the other texture, which becomes the new backbuffer
            bind_framebuffer_for_output(backbuffer_is_main ? os_window->indirect_output.extra_fbo_id : os_window->indirect_output.framebuffer_id);
            backbuffer_is_main = !backbuffer_is_main;
        }

        // Set the viewport
        float vp_x, vp_y, vp_w, vp_h;
        if (is_last) {
            // Last group always covers the full screen region
            if (os_window->live_resize.in_progress) {
                glViewport(0, os_window->live_resize.height - vh, vw, vh);
            } else {
                glViewport(0, 0, vw, vh);
            }
            vp_x = 0.f;
            vp_y = 0.f;
            vp_w = 1.f;
            vp_h = 1.f;
        } else {
            float px = cg->viewport_pos.x, py = cg->viewport_pos.y;
            float sw = cg->viewport_size.w, sh = cg->viewport_size.h;
            // viewport_pos/size are standard UV (origin at bottom-left, y increasing
            // upward), which matches GL pixel coords directly — no y-flip needed.
            GLint x0 = MAX(0, (GLint)(px * vw));
            GLint y0 = MAX(0, (GLint)(py * vh));
            GLint x1 = MIN(vw, (GLint)((px + sw) * vw));
            GLint y1 = MIN(vh, (GLint)((py + sh) * vh));
            glViewport(x0, y0, MAX(0, x1 - x0), MAX(0, y1 - y0));
            vp_x = px;
            vp_y = py;
            vp_w = sw;
            vp_h = sh;
        }

        float anim_progress = 0.0f;
        monotonic_t eff_dur = cg->animation_end_duration < 0 ? OPT(cursor_stop_blinking_after) : cg->animation_end_duration;
        if ((cg->animation_start_events != 0 || cg->attached) && eff_dur > 0 && os_window->shader_group_anim[g].active) {
            monotonic_t started_at = os_window->shader_group_anim[g].started_at;
            bool cached = false;
            for (size_t c = 0; c < num_anim_cached; c++) {
                if (anim_cache[c].curve == cg->animation_curve && anim_cache[c].started_at == started_at && anim_cache[c].duration == eff_dur) {
                    anim_progress = anim_cache[c].progress;
                    cached = true;
                    break;
                }
            }
            if (!cached) {
                double elapsed = (double)(now - started_at);
                double t = elapsed / (double)eff_dur;
                if (t < 0.0) t = 0.0;
                if (t > 1.0) t = 1.0;
                anim_progress = (float)(cg->animation_curve ? apply_easing_curve(cg->animation_curve, t, eff_dur) : t);
                anim_cache[num_anim_cached++] = (struct AnimCacheEntry){cg->animation_curve, started_at, eff_dur, anim_progress};
            }
        }
        glUniform1i(group_loc, (GLint)g);
        glUniform4f(viewport_loc, vp_x, vp_y, vp_w, vp_h);
        glUniform1f(anim_progress_loc, anim_progress);
        glUniform1i(convert_to_srgb_loc, is_last ? 1 : 0);
        // debug_rendering("Custom shader draw group %u: anim_progress=%.4f viewport=(%.2f,%.2f,%.2f,%.2f)\n", g, anim_progress, vp_x, vp_y, vp_w, vp_h);
        draw_quad(false, 0);
    }
}
#endif

static void
stop_os_window_rendering(OSWindow *os_window, Tab *tab, Window *active_window, monotonic_t now) {
    if (OPT(cursor_trail) && tab->cursor_trail.needs_render && !(custom_shaders.end.active && custom_shaders.end.bypass_builtin_trail))
        draw_cursor_trail(&tab->cursor_trail, active_window);
    if (os_window->needs_layers) {
#ifdef KITTY_BACKEND_METAL
        // M1: resolve the working surface onto the drawable in the SAME pass
        // (in-shader linear->sRGB, replacing the BLIT pass) and end it.
        // restore_viewport balances the save in start_os_window_rendering;
        // draw_resizing_text (live resize only) then draws on the drawable in a
        // normal pass. Custom end shaders never activate on this backend (see
        // compile_program), so the resolve is unconditional.
        metal_resolve_layered_frame();
        restore_viewport();
        if (os_window->live_resize.in_progress) draw_resizing_text(os_window);
#else
        float sx = global_state.layers_render_texture.width > 0 ? (float)os_window->viewport_width / (float)global_state.layers_render_texture.width : 1.f;
        float sy = global_state.layers_render_texture.height > 0 ? (float)os_window->viewport_height / (float)global_state.layers_render_texture.height : 1.f;
        if (custom_shaders.end.active && os_window->has_active_custom_shaders) {
            restore_viewport();
            if (os_window->live_resize.in_progress)
                save_viewport_using_top_left_origin(0, 0, os_window->viewport_width, os_window->viewport_height, os_window->live_resize.height);
            run_custom_end_shader(os_window, sx, sy, now);
        } else {
            set_framebuffer_to_use_for_output(0);
            bind_framebuffer_for_output(0);
            bind_program(BLIT_PROGRAM);
            glActiveTexture(GL_TEXTURE0 + GRAPHICS_UNIT);
            glBindTexture(GL_TEXTURE_2D, global_state.layers_render_texture.texture_id);
            glUniform4f(program_uniform_location(BLIT_PROGRAM, "src_rect"), 0, sy, sx, 0);
            glUniform4f(program_uniform_location(BLIT_PROGRAM, "dest_rect"), -1, 1, 1, -1);
            restore_viewport();
            if (os_window->live_resize.in_progress)
                save_viewport_using_top_left_origin(0, 0, os_window->viewport_width, os_window->viewport_height, os_window->live_resize.height);
            draw_quad(false, 0);
        }
        if (os_window->live_resize.in_progress) {
            restore_viewport();
            draw_resizing_text(os_window);
        }
#endif
    }
    os_window->last_rendered_at = now;
    os_window->frame_counter++;
}

void
setup_os_window_for_rendering(OSWindow *os_window, Tab *tab, Window *active_window, bool start, monotonic_t now) {
    if (start) start_os_window_rendering(os_window, tab);
    else stop_os_window_rendering(os_window, tab, active_window, now);
}

// Take a screenshot of the OS Window, must be called immediately after
// the OSWindow is rendered into the back buffer and before the buffers
// are swapped. If thumb_w or thumb_h are zero the are set to the corresponding
// dimension of the source region (viewport or central region without tab bar).
// Takes a screenshot of a rectangular region of the OSWindow's framebuffer.
// The region parameter specifies which part of the framebuffer to capture.
// Scaling is performed on the GPU using the SCREENSHOT_PROGRAM shader for better performance.
// The shader properly handles sRGB color space conversion and downscaling.
// Setting the thumbnail dimensions to zero disables scaling.
// If no_scaling is true, thumb_w/thumb_h are ignored and the region is read
// back directly from the framebuffer with no GPU resampling, for a pixel
// perfect capture (the output is in GL's native bottom-up row order, unlike
// the scaled path below which flips to top-down).
void
take_screenshot_of_rectangular_region(OSWindow *os_window, Region region, unsigned char *dst_buf, unsigned *thumb_w, unsigned *thumb_h, bool no_scaling) {
    unsigned vh = os_window->viewport_height;

    // Calculate the source region dimensions
    unsigned src_height = region.bottom - region.top;
    unsigned src_width = region.right - region.left;

    if (no_scaling) {
        *thumb_w = src_width;
        *thumb_h = src_height;
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels((GLint)region.left, (GLint)(vh - region.bottom), (GLsizei)src_width, (GLsizei)src_height, GL_RGBA, GL_UNSIGNED_BYTE, dst_buf);
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        return;
    }

    unsigned vw = os_window->viewport_width;
    if (!*thumb_w) *thumb_w = src_width;
    if (!*thumb_h) *thumb_h = src_height;
    *thumb_w = MIN(src_width, *thumb_w);
    *thumb_h = MIN(src_height, *thumb_h);

    // Create a texture to hold the current framebuffer content
    GLuint src_texture = 0;
    glGenTextures(1, &src_texture);
    glBindTexture(GL_TEXTURE_2D, src_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    // Copy the current framebuffer to the texture
    glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 0, 0, vw, vh, 0);

    // Create a temporary framebuffer for GPU-based scaling
    GLuint temp_texture = 0, temp_framebuffer = 0;
    setup_texture_as_render_target(*thumb_w, *thumb_h, &temp_texture, &temp_framebuffer);

    // Save current state
    GLint current_framebuffer;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &current_framebuffer);

    // Bind our temporary framebuffer for rendering
    bind_framebuffer_for_output(temp_framebuffer);
    save_viewport_using_bottom_left_origin(0, 0, *thumb_w, *thumb_h);

    // Use the screenshot program to render the scaled framebuffer with proper color space handling
    bind_program(SCREENSHOT_PROGRAM);

    // Set source rectangle (normalized coordinates: 0 to 1)
    // Note: OpenGL texture origin is bottom-left, but Region uses top-left origin
    // Convert from screen coordinates (top-left origin) to OpenGL texture coordinates (bottom-left origin)
    float src_left_norm = (float)region.left / (float)vw;
    float src_right_norm = (float)region.right / (float)vw;
    float src_bottom_norm = (float)(vh - region.bottom) / (float)vh;
    float src_top_norm = (float)(vh - region.top) / (float)vh;
    glUniform4f(program_uniform_location(SCREENSHOT_PROGRAM, "src_rect"), src_left_norm, src_top_norm, src_right_norm, src_bottom_norm);

    // Set destination rectangle (NDC coordinates: -1 to 1)
    glUniform4f(program_uniform_location(SCREENSHOT_PROGRAM, "dest_rect"), -1.0f, -1.0f, 1.0f, 1.0f);

    // Set the source texture size for proper downscaling
    glUniform2f(program_uniform_location(SCREENSHOT_PROGRAM, "src_size"), (float)vw, (float)vh);

    // Bind the source texture
    glActiveTexture(GL_TEXTURE0 + GRAPHICS_UNIT);
    glBindTexture(GL_TEXTURE_2D, src_texture);

    // Draw the scaled quad
    draw_quad(false, 0);

    // Read the scaled result
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, *thumb_w, *thumb_h, GL_RGBA, GL_UNSIGNED_BYTE, dst_buf);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);

    // Restore previous state
    bind_framebuffer_for_output(current_framebuffer);
    restore_viewport();

    // Clean up temporary resources
    free_texture(&src_texture);
    free_texture(&temp_texture);
    free_framebuffer(&temp_framebuffer);
}
// }}}

// Python API {{{

static PyObject *
pygpu_driver_version_string(PyObject *self UNUSED, PyObject *args UNUSED) {
    return PyUnicode_FromString(global_state.gl_version ? gl_version_string() : "");
}

static void
free_custom_shader_pipeline(CustomShaderPipeline *p) {
    for (size_t i = 0; i < p->num_groups; i++) {
        if (p->groups[i].animation_curve_is_shared) p->groups[i].animation_curve = NULL;
        else p->groups[i].animation_curve = free_animation(p->groups[i].animation_curve);
    }
}

#ifndef KITTY_BACKEND_METAL
// The pipeline-definition parser feeds compile_program's GL-only custom-end
// arm; free_custom_shader_pipeline above stays common (the clear path runs on
// both backends).
static NamedTexture
named_texture_from_str(const char *s) {
    if (strcmp(s, "a") == 0) return CUSTOM_SHADER_TEXTURE_A;
    if (strcmp(s, "b") == 0) return CUSTOM_SHADER_TEXTURE_B;
    if (strcmp(s, "persist") == 0) return CUSTOM_SHADER_TEXTURE_PERSIST;
    return CUSTOM_SHADER_TEXTURE_DEFAULT;
}

static unsigned
shader_anim_event_bit(const char *s) {
    if (strcmp(s, "pointer-left-button-press") == 0) return 1u << SHADER_ANIM_EVENT_POINTER_LEFT_BUTTON_PRESS;
    if (strcmp(s, "os-window-focus-in") == 0) return 1u << SHADER_ANIM_EVENT_OS_WINDOW_FOCUS_IN;
    if (strcmp(s, "os-window-focus-out") == 0) return 1u << SHADER_ANIM_EVENT_OS_WINDOW_FOCUS_OUT;
    if (strcmp(s, "window-focus-in") == 0) return 1u << SHADER_ANIM_EVENT_WINDOW_FOCUS_IN;
    if (strcmp(s, "window-focus-out") == 0) return 1u << SHADER_ANIM_EVENT_WINDOW_FOCUS_OUT;
    if (strcmp(s, "tab-change") == 0) return 1u << SHADER_ANIM_EVENT_TAB_CHANGE;
    if (strcmp(s, "bell-in-window") == 0) return 1u << SHADER_ANIM_EVENT_BELL_IN_WINDOW;
    if (strcmp(s, "user-activity") == 0) return 1u << SHADER_ANIM_EVENT_USER_ACTIVITY;
    if (strcmp(s, "user-idle") == 0) return 1u << SHADER_ANIM_EVENT_USER_IDLE;
    if (strcmp(s, "cursor-trail-move") == 0) return 1u << SHADER_ANIM_EVENT_CURSOR_TRAIL_MOVE;
    if (strcmp(s, "cursor-trail-stop") == 0) return 1u << SHADER_ANIM_EVENT_CURSOR_TRAIL_STOP;
    return 0;
}

static unsigned
parse_anim_event_sequence(PyObject *seq) {
    unsigned mask = 0;
    for (Py_ssize_t i = 0; i < PySequence_Fast_GET_SIZE(seq); i++) {
        PyObject *item = PySequence_Fast_GET_ITEM(seq, i);
        if (PyUnicode_Check(item)) mask |= shader_anim_event_bit(PyUnicode_AsUTF8(item));
    }
    return mask;
}

static bool
transfer_pipeline_to_struct(PyObject *pg, CustomShaderPipeline *p) {
#define is_seq(x) (x && (PyList_Check(x) || PyTuple_Check(x)))
    PyObject *textures = PyDict_GetItemString(pg, "textures");
    if (is_seq(textures)) {
        for (Py_ssize_t i = 0; i < PySequence_Fast_GET_SIZE(textures); i++) {
            PyObject *t = PySequence_Fast_GET_ITEM(textures, i);
            if (!PyUnicode_Check(t)) {
                PyErr_SetString(PyExc_TypeError, "pipeline textures must be strings");
                return false;
            }
            p->textures |= (1u << named_texture_from_str(PyUnicode_AsUTF8(t)));
        }
    }
    PyObject *groups = PyDict_GetItemString(pg, "groups");
    if (!is_seq(groups)) {
        PyErr_SetString(PyExc_TypeError, "pipeline groups must be a sequence");
        return false;
    }
    Py_ssize_t num_groups = PySequence_Fast_GET_SIZE(groups);
    if ((size_t)num_groups > arraysz(p->groups)) {
        PyErr_SetString(PyExc_ValueError, "too many pipeline groups");
        return false;
    }
    p->num_groups = (size_t)num_groups;
    for (Py_ssize_t i = 0; i < num_groups; i++) {
        PyObject *g = PySequence_Fast_GET_ITEM(groups, i);
        if (!PyDict_Check(g)) {
            PyErr_SetString(PyExc_TypeError, "pipeline group must be a dict");
            return false;
        }
        CustomShaderGroup *cg = &p->groups[i];
        PyObject *vp = PyDict_GetItemString(g, "viewport_pos");
        if (is_seq(vp) && PySequence_Fast_GET_SIZE(vp) == 2) {
            cg->viewport_pos.x = (float)PyFloat_AsDouble(PySequence_Fast_GET_ITEM(vp, 0));
            cg->viewport_pos.y = (float)PyFloat_AsDouble(PySequence_Fast_GET_ITEM(vp, 1));
        }
        PyObject *vs = PyDict_GetItemString(g, "viewport_size");
        if (is_seq(vs) && PySequence_Fast_GET_SIZE(vs) == 2) {
            cg->viewport_size.w = (float)PyFloat_AsDouble(PySequence_Fast_GET_ITEM(vs, 0));
            cg->viewport_size.h = (float)PyFloat_AsDouble(PySequence_Fast_GET_ITEM(vs, 1));
        }
        PyObject *ot = PyDict_GetItemString(g, "output_texture");
        if (ot && PyUnicode_Check(ot)) { cg->output_texture = named_texture_from_str(PyUnicode_AsUTF8(ot)); }

        PyObject *astart = PyDict_GetItemString(g, "animation_start");
        if (is_seq(astart)) cg->animation_start_events = parse_anim_event_sequence(astart);

        PyObject *acurve = PyDict_GetItemString(g, "animation_curve");
        if (acurve && PyObject_IsTrue(acurve)) {
            if ((cg->animation_curve = alloc_animation()) != NULL) add_easing_function(cg->animation_curve, acurve, 0.0, 1.0);
            for (Py_ssize_t j = 0; j < i; j++) {
                if (animations_equal(p->groups[j].animation_curve, cg->animation_curve)) {
                    free_animation(cg->animation_curve);
                    cg->animation_curve = p->groups[j].animation_curve;
                    cg->animation_curve_is_shared = true;
                    break;
                }
            }
        }

        PyObject *astep = PyDict_GetItemString(g, "animation_step");
        cg->animation_step = (astep && PyLong_Check(astep)) ? (monotonic_t)PyLong_AsLong(astep) : ANIMATION_SAMPLE_WAIT;
        cg->animation_step = MAX(cg->animation_step, OPT(repaint_delay));

        PyObject *ae_events = PyDict_GetItemString(g, "animation_end_events");
        if (is_seq(ae_events)) cg->animation_end_events = parse_anim_event_sequence(ae_events);

        PyObject *ae_dur = PyDict_GetItemString(g, "animation_end_duration");
        if (ae_dur && PyLong_Check(ae_dur)) cg->animation_end_duration = (monotonic_t)PyLong_AsLong(ae_dur);

        PyObject *attached = PyDict_GetItemString(g, "attached");
        cg->attached = attached && PyObject_IsTrue(attached);
    }
    p->all_animation_start_events = 0;
    for (size_t i = 0; i < p->num_groups; i++) p->all_animation_start_events |= p->groups[i].animation_start_events;
    p->bypass_builtin_trail = (p->all_animation_start_events & (1u << SHADER_ANIM_EVENT_CURSOR_TRAIL_MOVE)) != 0;
#undef is_seq
    return true;
}

static bool
attach_shaders(PyObject *sources, GLuint program_id, GLenum shader_type) {
    RAII_ALLOC(const GLchar *, c_sources, calloc(PyTuple_GET_SIZE(sources), sizeof(GLchar *)));
    for (Py_ssize_t i = 0; i < PyTuple_GET_SIZE(sources); i++) {
        PyObject *temp = PyTuple_GET_ITEM(sources, i);
        if (!PyUnicode_Check(temp)) {
            PyErr_SetString(PyExc_TypeError, "shaders must be strings");
            return false;
        }
        c_sources[i] = PyUnicode_AsUTF8(temp);
    }
    GLuint shader_id = compile_shaders(shader_type, PyTuple_GET_SIZE(sources), c_sources);
    if (shader_id == 0) return false;
    glAttachShader(program_id, shader_id);
    glDeleteShader(shader_id);
    return true;
}
#endif

static PyObject *
compile_program(PyObject UNUSED *self, PyObject *args) {
    PyObject *vertex_shaders, *fragment_shaders, *metadata;
    int which, allow_recompile = 0;
    if (!PyArg_ParseTuple(
            args, "iO!O!O!|p", &which, &PyTuple_Type, &vertex_shaders, &PyTuple_Type, &fragment_shaders, &PyDict_Type, &metadata, &allow_recompile))
        return NULL;
    if (which == -1) {
        init_cell_program();
        Py_RETURN_NONE;
    }
    if (which == -2) {
        init_custom_programs();
        Py_RETURN_NONE;
    }
    if (which < 0 || which >= NUM_PROGRAMS) {
        PyErr_Format(PyExc_ValueError, "Unknown program: %d", which);
        return NULL;
    }
    Program *program = program_ptr(which);
    if (!PyTuple_GET_SIZE(vertex_shaders)) {
        if (which == CUSTOM_END_PROGRAM) {
            free_custom_shader_pipeline(&custom_shaders.end);
            zero_at_ptr(&custom_shaders.end);
        }
        if (program->id != 0) {
            glDeleteProgram(program->id);
            program->id = 0;
        }
        Py_RETURN_NONE;
    }
    if (program->id != 0) {
        if (allow_recompile) {
            glDeleteProgram(program->id);
            program->id = 0;
        } else {
            PyErr_SetString(PyExc_ValueError, "program already compiled");
            return NULL;
        }
    }
    program->id = glCreateProgram();
#ifndef KITTY_BACKEND_METAL
    // W27 GLSL freeze-out (stage 3): the Metal backend has nothing to
    // compile -- the MSL equivalents are pre-compiled into default.metallib
    // (see compile_shaders() in metal.m). The GLSL sources and layout
    // metadata Python passes are accepted for API parity and ignored;
    // set_program_layout() is a no-op there (layouts are compiled into the
    // pipelines) and custom end shaders never activate on this backend.
#define fail_compile() { glDeleteProgram(program->id); return NULL; }
    if (!attach_shaders(vertex_shaders, program->id, GL_VERTEX_SHADER)) fail_compile();
    if (!attach_shaders(fragment_shaders, program->id, GL_FRAGMENT_SHADER)) fail_compile();
    glLinkProgram(program->id);
    GLint ret = GL_FALSE;
    glGetProgramiv(program->id, GL_LINK_STATUS, &ret);
    if (ret != GL_TRUE) {
        GLsizei len;
        static char glbuf[4096];
        glGetProgramInfoLog(program->id, sizeof(glbuf), &len, glbuf);
        PyErr_Format(PyExc_ValueError, "Failed to link GLSL shaders:\n%s", glbuf);
        fail_compile();
    }
#undef fail_compile
    if (which == CUSTOM_END_PROGRAM) {
        free_custom_shader_pipeline(&custom_shaders.end);
        zero_at_ptr(&custom_shaders.end);
        PyObject *pg = PyDict_GetItemString(metadata, "pipeline");
        if (pg && !transfer_pipeline_to_struct(pg, &custom_shaders.end)) {
            glDeleteProgram(program->id);
            return NULL;
        }
        custom_shaders.end.active = true;
    }
#endif
    init_uniforms(which);
    set_program_layout(which, metadata);
    return Py_BuildValue("I", program->id);
}

// W27 P3.4 (chain 2). The cell-program options Python resolves from the config.
// The GL backend needs nothing here — cell_defines.glsl already carries them in
// the source Python is about to compile. The Metal backend takes them as
// pipeline function constants, so it is told directly instead of recovering
// them by scraping the preprocessed GLSL back apart (which made kitty/*.glsl
// load-bearing for Metal rendering config). Defined for both backends so the
// Python caller stays backend-agnostic.

// The EDR text-boost lever, a SEPARATE channel from the function constants
// documented above: this one is an ordinary per-draw uniform, not a
// specialization, so pushing it rebuilds no pipelines. Resolved on the Python
// side because kitty.conf's `env` dict lives there and never reaches this
// process's environment, then pushed here on startup and on every config
// reload. Defined for both backends so the Python caller stays
// backend-agnostic; the GL arm has no EDR pipeline to boost into, so it
// discards the value.
static PyObject*
set_text_edr_boost(PyObject UNUSED *self, PyObject *args) {
    float boost;
    if (!PyArg_ParseTuple(args, "f", &boost)) return NULL;
#ifdef KITTY_BACKEND_METAL
    metal_set_text_edr_boost(boost);
#else
    (void)boost;
#endif
    Py_RETURN_NONE;
}

static PyObject*
set_cell_shader_opts(PyObject UNUSED *self, PyObject *args) {
    int do_fg_override, fg_override_algo, text_new_gamma;
    float fg_override_threshold;
    if (!PyArg_ParseTuple(args, "pifp", &do_fg_override, &fg_override_algo,
                          &fg_override_threshold, &text_new_gamma)) return NULL;
#ifdef KITTY_BACKEND_METAL
    metal_set_cell_shader_opts(do_fg_override, fg_override_algo, fg_override_threshold, text_new_gamma);
#else
    (void)do_fg_override; (void)fg_override_algo; (void)fg_override_threshold; (void)text_new_gamma;
#endif
    Py_RETURN_NONE;
}

#define PYWRAP0(name) static PyObject* py##name(PYNOARG)
#define PYWRAP1(name) static PyObject* py##name(PyObject UNUSED *self, PyObject *args)
#define PA(fmt, ...) if(!PyArg_ParseTuple(args, fmt, __VA_ARGS__)) return NULL;
#define ONE_INT(name) PYWRAP1(name) { name(PyLong_AsSsize_t(args)); Py_RETURN_NONE; }
#define TWO_INT(name) PYWRAP1(name) { int a, b; PA("ii", &a, &b); name(a, b); Py_RETURN_NONE; }
#define NO_ARG(name) PYWRAP0(name) { name(); Py_RETURN_NONE; }
#define NO_ARG_INT(name) PYWRAP0(name) { return PyLong_FromSsize_t(name()); }

ONE_INT(bind_program)
NO_ARG(unbind_program)

PYWRAP0(create_vao) {
    int ans = create_vao();
    if (ans < 0) return NULL;
    return Py_BuildValue("i", ans);
}

ONE_INT(bind_vertex_array)
NO_ARG(unbind_vertex_array)
TWO_INT(unmap_vao_buffer)

static PyObject *
sprite_map_set_limits(PyObject UNUSED *self, PyObject *args) {
    unsigned int w, h;
    if (!PyArg_ParseTuple(args, "II", &w, &h)) return NULL;
    sprite_tracker_set_limits(w, h);
    max_texture_size = w;
    max_array_texture_layers = h;
    Py_RETURN_NONE;
}

#define M(name, arg_type) {#name, (PyCFunction)name, arg_type, NULL}
#define MW(name, arg_type) {#name, (PyCFunction)py##name, arg_type, NULL}
static PyMethodDef module_methods[] = {
    M(compile_program, METH_VARARGS),
    M(set_cell_shader_opts, METH_VARARGS),
    M(set_text_edr_boost, METH_VARARGS),
    M(sprite_map_set_limits, METH_VARARGS),
    MW(create_vao, METH_NOARGS),
    MW(gpu_driver_version_string, METH_NOARGS),
    MW(bind_vertex_array, METH_O),
    MW(unbind_vertex_array, METH_NOARGS),
    MW(unmap_vao_buffer, METH_VARARGS),
    MW(bind_program, METH_O),
    MW(unbind_program, METH_NOARGS),

    {NULL, NULL, 0, NULL} /* Sentinel */
};

void
initialize_gpu(void) {
    gl_init();
}

void
free_vao(ssize_t vao_idx) {
    remove_vao(vao_idx);
}

void
cleanup_shader_resources_on_terminate(void) {
    if (shader_globals_vao_idx != -1) {
        remove_vao(shader_globals_vao_idx);
        shader_globals_vao_idx = -1;
    }
}

static void
finalize(void) {
    default_visual_bell_animation = free_animation(default_visual_bell_animation);
    free_custom_shader_pipeline(&custom_shaders.end);
    free_program_layouts();
}

bool
init_shaders(PyObject *module) {
    // BACKEND_IS_METAL: the compile-time backend selector, exported so Python
    // can introspect which GPU backend this build renders with.
#ifdef KITTY_BACKEND_METAL
    if (PyModule_AddObject(module, "BACKEND_IS_METAL", Py_NewRef(Py_True)) != 0) { PyErr_NoMemory(); return false; }
#else
    if (PyModule_AddObject(module, "BACKEND_IS_METAL", Py_NewRef(Py_False)) != 0) { PyErr_NoMemory(); return false; }
#endif
#define C(x) if (PyModule_AddIntConstant(module, #x, x) != 0) { PyErr_NoMemory(); return false; }
    C(CELL_PROGRAM); C(CELL_FG_PROGRAM); C(CELL_BG_PROGRAM); C(BORDERS_PROGRAM);
    C(GRAPHICS_PROGRAM); C(GRAPHICS_PREMULT_PROGRAM); C(GRAPHICS_ALPHA_MASK_PROGRAM);
    C(BGIMAGE_PROGRAM); C(TINT_PROGRAM); C(TRAIL_PROGRAM); C(BLIT_PROGRAM); C(SCREENSHOT_PROGRAM); C(ROUNDED_RECT_PROGRAM);
    C(PADDING_PROGRAM); C(CUSTOM_END_PROGRAM); C(MAX_CUSTOM_SHADER_GROUPS);
    C(GLSL_VERSION);
    C(GL_VERSION);
    C(GL_VENDOR);
    C(GL_SHADING_LANGUAGE_VERSION);
    C(GL_RENDERER);
    C(GL_TRIANGLE_FAN);
    C(GL_TRIANGLE_STRIP);
    C(GL_TRIANGLES);
    C(GL_LINE_LOOP);
    C(GL_COLOR_BUFFER_BIT);
    C(GL_VERTEX_SHADER);
    C(GL_FRAGMENT_SHADER);
    C(GL_TRUE);
    C(GL_FALSE);
    C(GL_COMPILE_STATUS);
    C(GL_LINK_STATUS);
    C(GL_MAX_ARRAY_TEXTURE_LAYERS);
    C(GL_TEXTURE_BINDING_BUFFER);
    C(GL_MAX_TEXTURE_BUFFER_SIZE);
    C(GL_MAX_TEXTURE_SIZE);
    C(GL_TEXTURE_2D_ARRAY);
    C(GL_LINEAR);
    C(GL_CLAMP_TO_EDGE);
    C(GL_NEAREST);
    C(GL_TEXTURE_MIN_FILTER);
    C(GL_TEXTURE_MAG_FILTER);
    C(GL_TEXTURE_WRAP_S);
    C(GL_TEXTURE_WRAP_T);
    C(GL_UNPACK_ALIGNMENT);
    C(GL_R8);
    C(GL_RED);
    C(GL_UNSIGNED_BYTE);
    C(GL_UNSIGNED_SHORT);
    C(GL_R32UI);
    C(GL_RGB32UI);
    C(GL_RGBA);
    C(GL_TEXTURE_BUFFER);
    C(GL_STATIC_DRAW);
    C(GL_STREAM_DRAW);
    C(GL_DYNAMIC_DRAW);
    C(GL_SRC_ALPHA);
    C(GL_ONE_MINUS_SRC_ALPHA);
    C(GL_WRITE_ONLY);
    C(GL_READ_ONLY);
    C(GL_READ_WRITE);
    C(GL_BLEND);
    C(GL_FLOAT);
    C(GL_UNSIGNED_INT);
    C(GL_ARRAY_BUFFER);
    C(GL_UNIFORM_BUFFER);
    C(ANIMATION_SAMPLE_WAIT);

#undef C
    if (PyModule_AddFunctions(module, module_methods) != 0) return false;
    register_at_exit_cleanup_func(SHADERS_CLEANUP_FUNC, finalize);
    return true;
}
// }}}

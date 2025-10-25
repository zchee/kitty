#include <Python.h>

#include "state.h"
#include "opengl_renderer_priv.h"
#include "data-types.h"
#include "fonts.h"
#include "renderer_backend.h"

#ifdef KITTY_DISABLE_NSGL

void
gl_init(void) {}

void
remove_vao(ssize_t vao_idx) {
    (void)vao_idx;
}

ssize_t
create_cell_vao(void) {
    return -1;
}

ssize_t
create_graphics_vao(void) {
    return -1;
}

ssize_t
create_border_vao(void) {
    return -1;
}

bool
send_cell_data_to_gpu(ssize_t vao_idx, Screen *screen, OSWindow *os_window) {
    (void)vao_idx;
    (void)screen;
    (void)os_window;
    return false;
}

void
set_gpu_viewport(unsigned w, unsigned h) {
    (void)w;
    (void)h;
}

void
free_texture(uint32_t *tex_id) {
    if (tex_id) {
        *tex_id = 0;
    }
}

void
free_framebuffer(uint32_t *fb_id) {
    if (fb_id) {
        *fb_id = 0;
    }
}

void
send_image_to_gpu(
    uint32_t *texture_id,
    const void *pixels,
    int32_t width,
    int32_t height,
    bool is_opaque,
    bool is_4byte_aligned,
    bool linear_filter,
    RepeatStrategy repeat
) {
    (void)texture_id;
    (void)pixels;
    (void)width;
    (void)height;
    (void)is_opaque;
    (void)is_4byte_aligned;
    (void)linear_filter;
    (void)repeat;
}

void
send_sprite_to_gpu(FONTS_DATA_HANDLE fg, sprite_index idx, pixel *buf, sprite_index decoration_idx) {
    (void)fg;
    (void)idx;
    (void)buf;
    (void)decoration_idx;
}

void
send_prerendered_sprites_for_window(OSWindow *w, bool ensure_opengl_resources) {
    (void)w;
    (void)ensure_opengl_resources;
}

SPRITE_MAP_HANDLE
alloc_sprite_map(void) {
    return NULL;
}

void
free_sprite_data(FONTS_DATA_HANDLE fg) {
    (void)fg;
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
    OSWindow *w
) {
    (void)vao_idx;
    (void)num_border_rects;
    (void)rect_buf;
    (void)rect_data_is_dirty;
    (void)active_window_bg;
    (void)num_visible_windows;
    (void)all_windows_have_same_bg;
    (void)w;
}

void
draw_cells(
    const WindowRenderData *render_data,
    OSWindow *os_window,
    bool is_active_window,
    bool is_tab_bar,
    bool is_single_window,
    Window *window
) {
    (void)render_data;
    (void)os_window;
    (void)is_active_window;
    (void)is_tab_bar;
    (void)is_single_window;
    (void)window;
}

void
blank_canvas(float background_opacity, color_type color_in_srgb, bool for_final_output) {
    (void)background_opacity;
    (void)color_in_srgb;
    (void)for_final_output;
}

void
setup_os_window_for_rendering(OSWindow *os_window, Tab *tab, Window *active_window, bool start) {
    (void)os_window;
    (void)tab;
    (void)active_window;
    (void)start;
}

void
blank_os_window(OSWindow *os_window) {
    (void)os_window;
}

bool
init_shaders(PyObject *module) {
    (void)module;
    return true;
}

bool
screen_needs_rendering_in_layers(OSWindow *os_window, Window *window, Screen *screen) {
    (void)os_window;
    (void)window;
    (void)screen;
    return false;
}

#endif /* KITTY_DISABLE_NSGL */

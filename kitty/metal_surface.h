/*
 * metal_surface.h
 * Scaffolding for the macOS Metal renderer.
 *
 * Copyright (C) 2025
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#include <stdbool.h>

struct OSWindow;
struct Screen;
struct WindowRenderData;
struct Window;

#ifdef KITTY_ENABLE_METAL

bool metal_backend_available(void);
bool metal_backend_init(struct OSWindow *window);
void metal_backend_shutdown(void);
bool metal_begin_frame(struct OSWindow *window, float background_opacity, unsigned int color_in_srgb);
void metal_end_frame(struct OSWindow *window);
void metal_teardown_surface(struct OSWindow *window);
void metal_sprite_map_resize(FONTS_DATA_HANDLE fg, unsigned int cell_width, unsigned int cell_height_plus1, unsigned int xnum, unsigned int ynum, unsigned int layers);
void metal_sprite_decorations_resize(FONTS_DATA_HANDLE fg, unsigned int width, unsigned int height);
void metal_sprite_upload(FONTS_DATA_HANDLE fg, sprite_index idx, const pixel *buf, sprite_index decoration_idx);
void metal_sprite_free(FONTS_DATA_HANDLE fg);
bool metal_prepare_cell_buffers(struct Screen *screen, struct OSWindow *window);
void metal_draw_cells(const struct WindowRenderData *srd, struct OSWindow *os_window, bool is_active_window, bool is_tab_bar, bool is_single_window, struct Window *window);

#else

static inline bool
metal_backend_available(void) { return false; }

static inline bool
metal_backend_init(struct OSWindow *window) {
    (void)window;
    return false;
}

static inline void
metal_backend_shutdown(void) {}

static inline bool
metal_begin_frame(struct OSWindow *window, float background_opacity, unsigned int color_in_srgb) {
    (void)window;
    (void)background_opacity;
    (void)color_in_srgb;
    return false;
}

static inline void
metal_end_frame(struct OSWindow *window) {
    (void)window;
}

static inline void
metal_teardown_surface(struct OSWindow *window) {
    (void)window;
}

static inline void metal_sprite_map_resize(FONTS_DATA_HANDLE fg, unsigned int cell_width, unsigned int cell_height_plus1, unsigned int xnum, unsigned int ynum, unsigned int layers) {
    (void)fg; (void)cell_width; (void)cell_height_plus1; (void)xnum; (void)ynum; (void)layers;
}

static inline void metal_sprite_decorations_resize(FONTS_DATA_HANDLE fg, unsigned int width, unsigned int height) {
    (void)fg; (void)width; (void)height;
}

static inline void metal_sprite_upload(FONTS_DATA_HANDLE fg, sprite_index idx, const pixel *buf, sprite_index decoration_idx) {
    (void)fg; (void)idx; (void)buf; (void)decoration_idx;
}

static inline void metal_sprite_free(FONTS_DATA_HANDLE fg) { (void)fg; }

static inline bool metal_prepare_cell_buffers(struct Screen *screen, struct OSWindow *window) {
    (void)screen; (void)window;
    return false;
}

static inline void metal_draw_cells(const struct WindowRenderData *srd, struct OSWindow *os_window, bool is_active_window, bool is_tab_bar, bool is_single_window, struct Window *window) {
    (void)srd; (void)os_window; (void)is_active_window; (void)is_tab_bar; (void)is_single_window; (void)window;
}

#endif

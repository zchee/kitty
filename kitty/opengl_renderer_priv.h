#pragma once

#include "state.h"

// OpenGL backend-only drawing helpers. Keep these declarations out of the
// public headers so that new renderer backends are not coupled to GL logic.

void draw_borders(
    ssize_t vao_idx,
    unsigned int num_border_rects,
    BorderRect *rect_buf,
    bool rect_data_is_dirty,
    color_type active_window_bg,
    unsigned int num_visible_windows,
    bool all_windows_have_same_bg,
    OSWindow *w
);

void draw_cells(
    const WindowRenderData *render_data,
    OSWindow *os_window,
    bool is_active_window,
    bool is_tab_bar,
    bool is_single_window,
    Window *window
);

void blank_canvas(float background_opacity, color_type color_in_srgb, bool for_final_output);

void setup_os_window_for_rendering(OSWindow *os_window, Tab *tab, Window *active_window, bool start);

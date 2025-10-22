#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "color_type.h"
#include "compiler.h"
#include "screen.h"
#include "data-types.h"

#ifdef __cplusplus
extern "C" {
#endif

struct OSWindow;
struct Window;
struct WindowRenderData;
struct WindowBarData;
typedef struct _object PyObject;

typedef struct RendererCellUniformData {
    float use_cell_bg_for_selection_fg;
    float use_cell_fg_for_selection_color;
    float use_cell_for_selection_bg;

    unsigned int default_fg;
    unsigned int highlight_fg;
    unsigned int highlight_bg;
    unsigned int main_cursor_fg;
    unsigned int main_cursor_bg;
    unsigned int url_color;
    unsigned int url_style;
    unsigned int inverted;
    unsigned int extra_cursor_fg;
    unsigned int extra_cursor_bg;

    unsigned int columns;
    unsigned int lines;
    unsigned int sprites_xnum;
    unsigned int sprites_ynum;
    unsigned int cursor_shape;
    unsigned int cell_width;
    unsigned int cell_height;
    unsigned int cursor_x1;
    unsigned int cursor_x2;
    unsigned int cursor_y1;
    unsigned int cursor_y2;
    float cursor_opacity;
    float inactive_text_alpha;
    float dim_opacity;
    float blink_opacity;

    unsigned int bg_colors0;
    unsigned int bg_colors1;
    unsigned int bg_colors2;
    unsigned int bg_colors3;
    unsigned int bg_colors4;
    unsigned int bg_colors5;
    unsigned int bg_colors6;
    unsigned int bg_colors7;
    float bg_opacities0;
    float bg_opacities1;
    float bg_opacities2;
    float bg_opacities3;
    float bg_opacities4;
    float bg_opacities5;
    float bg_opacities6;
    float bg_opacities7;
    unsigned int color_table[];
} RendererCellUniformData;

typedef enum {
    RENDERER_SHARED_BUFFER_CELL_DATA = 0,
    RENDERER_SHARED_BUFFER_SELECTIONS,
    RENDERER_SHARED_BUFFER_UNIFORMS
} RendererSharedBufferType;

typedef struct RendererSharedBufferOps {
    void *(*map)(RendererSharedBufferType type, size_t size, void *user);
    void (*unmap)(RendererSharedBufferType type, void *ptr, size_t size, void *user);
} RendererSharedBufferOps;

typedef struct RendererSharedFrameParams {
    Screen *screen;
    struct OSWindow *os_window;
    bool cursor_has_moved;
} RendererSharedFrameParams;

typedef struct RendererSharedFrameResult {
    bool cell_data_changed;
    bool selection_data_changed;
    bool graphics_data_changed;
    color_type default_bg;
} RendererSharedFrameResult;

EXPORTED bool renderer_shared_prepare_frame(
    const RendererSharedFrameParams *params,
    const RendererSharedBufferOps *ops,
    void *ops_user,
    RendererSharedFrameResult *out_result
);

EXPORTED color_type renderer_shared_populate_uniform_data(
    Screen *screen,
    const CursorRenderInfo *cursor,
    struct OSWindow *os_window,
    float inactive_text_alpha,
    float bg_alpha,
    RendererCellUniformData *out_data,
    size_t color_table_offset,
    size_t color_table_stride
);

typedef struct RendererSharedScrollbarMetrics {
    bool visible;
    int left_px;
    int top_px;
    unsigned int width_px;
    unsigned int height_px;
    unsigned int thumb_top_px;
    unsigned int thumb_height_px;
    float thumb_top_fraction;
    float thumb_bottom_fraction;
    float thumb_height_fraction;
    float handle_opacity;
    float track_opacity;
    unsigned int corner_radius_px;
    color_type handle_color;
    color_type track_color;
} RendererSharedScrollbarMetrics;

typedef struct RendererSharedBarSurface {
    bool visible;
    bool along_bottom;
    unsigned int width_px;
    unsigned int height_px;
    unsigned int border_width_px;
    color_type foreground_color;
    color_type background_color;
    const uint8_t *pixels;
    size_t stride_bytes;
} RendererSharedBarSurface;

typedef struct RendererSharedWindowNumber {
    bool visible;
    unsigned int width_px;
    unsigned int height_px;
    unsigned int offset_x_px;
    unsigned int offset_y_px;
    color_type glyph_color;
    const uint8_t *pixels;
} RendererSharedWindowNumber;

EXPORTED bool renderer_shared_prepare_scrollbar_metrics(
    Screen *screen,
    struct Window *window,
    const struct WindowRenderData *render_data,
    unsigned int screen_left_px,
    unsigned int screen_top_px,
    unsigned int screen_width_px,
    unsigned int screen_height_px,
    unsigned int cell_width_px,
    unsigned int cell_height_px,
    unsigned int framebuffer_height_px,
    RendererSharedScrollbarMetrics *out_metrics
);

EXPORTED bool renderer_shared_prepare_bar_surface(
    Screen *screen,
    struct OSWindow *os_window,
    struct WindowBarData *bar,
    PyObject *title,
    unsigned int screen_width_px,
    unsigned int screen_height_px,
    unsigned int cell_height_px,
    bool along_bottom,
    RendererSharedBarSurface *out_surface
);

EXPORTED bool renderer_shared_prepare_window_number(
    Screen *screen,
    unsigned int screen_width_px,
    unsigned int screen_height_px,
    unsigned int screen_left_px,
    unsigned int screen_top_px,
    unsigned int full_framebuffer_height_px,
    unsigned int cell_width_px,
    unsigned int cell_height_px,
    unsigned int title_bar_height_px,
    RendererSharedWindowNumber *out_window_number
);

EXPORTED PyObject *renderer_shared_get_hyperlink_title(
    Screen *screen,
    struct Window *window,
    struct OSWindow *os_window,
    bool *out_along_bottom
);

EXPORTED bool renderer_shared_test_scrollbar_metrics(
    unsigned int screen_width_px,
    unsigned int screen_height_px,
    unsigned int cell_width_px,
    unsigned int cell_height_px,
    unsigned int padding_right_px,
    unsigned int padding_top_px,
    unsigned int padding_bottom_px,
    unsigned int framebuffer_height_px,
    unsigned int scrolled_by,
    unsigned int history_count,
    bool hovering,
    float hover_width_cells,
    float width_cells,
    float gap_cells,
    float handle_opacity,
    float track_opacity,
    float track_hover_opacity,
    float min_handle_height_cells,
    unsigned int radius_cells,
    unsigned int handle_color,
    unsigned int track_color,
    RendererSharedScrollbarMetrics *out_metrics
);

EXPORTED bool renderer_shared_test_prepare_bar_surface(
    unsigned int width_px,
    unsigned int height_px,
    unsigned int border_width_px,
    color_type fg,
    color_type bg,
    RendererSharedBarSurface *out_surface
);

EXPORTED bool renderer_shared_test_prepare_window_number(
    unsigned int glyph_width_px,
    unsigned int glyph_height_px,
    unsigned int offset_x_px,
    unsigned int offset_y_px,
    color_type glyph_color,
    RendererSharedWindowNumber *out_info
);

EXPORTED float renderer_shared_visual_bell_alpha_scale_for_tests(uint32_t flash_rgb, float intensity);

#ifdef __cplusplus
}
#endif

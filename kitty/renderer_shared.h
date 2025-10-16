#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "color_type.h"
#include "compiler.h"
#include "screen.h"
#include "data-types.h"

#ifdef __cplusplus
extern "C" {
#endif

struct OSWindow;

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

#ifdef __cplusplus
}
#endif

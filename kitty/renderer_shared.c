#include "Python.h"

#include "renderer_shared.h"

#include "colors.h"
#include "fonts.h"
#include "graphics.h"
#include "lineops.h"
#include "state.h"

#define IS_SPECIAL_COLOR(scr, name) ((scr)->color_profile->overridden.name.type == COLOR_IS_SPECIAL || ((scr)->color_profile->overridden.name.type == COLOR_NOT_SET && (scr)->color_profile->configured.name.type == COLOR_IS_SPECIAL))

static void
pick_cursor_color(
    color_type cell_fg,
    color_type cell_bg,
    color_type *cursor_fg,
    color_type *cursor_bg,
    color_type default_fg,
    color_type default_bg
) {
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

color_type
renderer_shared_populate_uniform_data(
    Screen *screen,
    const CursorRenderInfo *cursor,
    OSWindow *os_window,
    float inactive_text_alpha,
    float bg_alpha,
    RendererCellUniformData *out_data,
    size_t color_table_offset,
    size_t color_table_stride
) {
    if (!screen || !os_window || !os_window->fonts_data) {
        return 0;
    }

    ColorProfile *cp = screen->paused_rendering.expires_at ? &screen->paused_rendering.color_profile : screen->color_profile;
    RendererCellUniformData *rd = out_data;

    if (rd && (UNLIKELY(cp->dirty || screen->reload_all_gpu_data))) {
        copy_color_table_to_buffer(
            cp,
            (color_type *)rd,
            (int)(color_table_offset / sizeof(color_type)),
            color_table_stride / sizeof(color_type)
        );
    }

    color_type default_bg = colorprofile_to_color(cp, cp->overridden.default_bg, cp->configured.default_bg).rgb;
    color_type default_fg = colorprofile_to_color(cp, cp->overridden.default_fg, cp->configured.default_fg).rgb;

    if (!rd) {
        // No buffer provided; compute and return default background only.
        return default_bg;
    }

#define COLOR(name) colorprofile_to_color(cp, cp->overridden.name, cp->configured.name).rgb
    rd->default_fg = default_fg;
    rd->highlight_fg = COLOR(highlight_fg);
    rd->highlight_bg = COLOR(highlight_bg);
    rd->extra_cursor_fg = screen->extra_cursors.color.text.val;
    rd->extra_cursor_bg = screen->extra_cursors.color.cursor.val;
    rd->bg_colors0 = default_bg;
    rd->bg_opacities0 = bg_alpha;

#define SETBG(which) \
    colorprofile_to_transparent_color(cp, (which) - 1, &rd->bg_colors##which, &rd->bg_opacities##which)
    SETBG(1);
    SETBG(2);
    SETBG(3);
    SETBG(4);
    SETBG(5);
    SETBG(6);
    SETBG(7);
#undef SETBG

    if (IS_SPECIAL_COLOR(screen, highlight_fg)) {
        if (IS_SPECIAL_COLOR(screen, highlight_bg)) {
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
    rd->use_cell_for_selection_bg = IS_SPECIAL_COLOR(screen, highlight_bg) ? 1.f : 0.f;

    rd->cursor_opacity = MAX(0.f, MIN(cursor->cursor_opacity, 1.f));
    rd->blink_opacity = MAX(0.f, MIN(cursor->text_blink_opacity, 1.f));
    rd->cursor_shape = 0;
    rd->cursor_x1 = screen->columns + 1;
    rd->cursor_x2 = screen->columns;
    rd->cursor_y1 = screen->lines + 1;
    rd->cursor_y2 = screen->lines;
    rd->main_cursor_bg = default_bg;
    rd->main_cursor_fg = default_fg;

    if (rd->cursor_opacity != 0.f && cursor->is_visible) {
        rd->cursor_x1 = cursor->x;
        rd->cursor_y1 = cursor->y;
        rd->cursor_x2 = cursor->x;
        rd->cursor_y2 = cursor->y;

        CursorShape cs = (cursor->is_focused || OPT(cursor_shape_unfocused) == NO_CURSOR_SHAPE)
            ? cursor->shape : OPT(cursor_shape_unfocused);
        rd->cursor_shape = cs;

        color_type cell_fg = default_fg;
        color_type cell_bg = default_bg;
        index_type cell_color_x = cursor->x;
        bool reversed = false;

        Line *line_for_cursor = NULL;
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
            const CPUCell *cursor_cell = &line_for_cursor->cpu_cells[cursor->x];
            const bool large_cursor = cursor_cell->is_multicell && cursor_cell->x == 0 && cursor_cell->y == 0;
            if (large_cursor) {
                switch (cs) {
                    case CURSOR_BEAM:
                        rd->cursor_y2 += cursor_cell->scale - 1;
                        break;
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
                    case NO_CURSOR_SHAPE:
                        break;
                }
            }
        }

        if (IS_SPECIAL_COLOR(screen, cursor_color)) {
            if (line_for_cursor) {
                pick_cursor_color(cell_fg, cell_bg, &rd->main_cursor_fg, &rd->main_cursor_bg, default_fg, default_bg);
            } else {
                rd->main_cursor_fg = default_bg;
                rd->main_cursor_bg = default_fg;
            }
            if (cell_bg == cell_fg) {
                rd->main_cursor_fg = default_bg;
                rd->main_cursor_bg = default_fg;
            } else {
                rd->main_cursor_fg = cell_bg;
                rd->main_cursor_bg = cell_fg;
            }
        } else {
            rd->main_cursor_bg = COLOR(cursor_color);
            if (IS_SPECIAL_COLOR(screen, cursor_text_color)) {
                rd->main_cursor_fg = cell_bg;
            } else {
                rd->main_cursor_fg = COLOR(cursor_text_color);
            }
        }
        screen->last_rendered.cursor_bg = rd->main_cursor_bg;
    }

    rd->columns = screen->columns;
    rd->lines = screen->lines;

    unsigned int sprite_x = 0, sprite_y = 0, sprite_z = 0;
    sprite_tracker_current_layout(os_window->fonts_data, &sprite_x, &sprite_y, &sprite_z);
    rd->sprites_xnum = sprite_x;
    rd->sprites_ynum = sprite_y;
    rd->inverted = screen_invert_colors(screen) ? 1u : 0u;
    rd->cell_width = os_window->fonts_data->fcm.cell_width;
    rd->cell_height = os_window->fonts_data->fcm.cell_height;
    rd->inactive_text_alpha = inactive_text_alpha;
    rd->dim_opacity = OPT(dim_opacity);
    rd->main_cursor_fg = rd->main_cursor_fg;
    rd->url_color = OPT(url_color);
    rd->url_style = OPT(url_style);

#undef COLOR

    return default_bg;
}

bool
renderer_shared_prepare_frame(
    const RendererSharedFrameParams *params,
    const RendererSharedBufferOps *ops,
    void *ops_user,
    RendererSharedFrameResult *out_result
) {
    if (!params || !out_result) {
        PyErr_SetString(PyExc_ValueError, "renderer_shared_prepare_frame received null arguments");
        return false;
    }

    Screen *screen = params->screen;
    OSWindow *os_window = params->os_window;
    if (!screen || !os_window || !os_window->fonts_data) {
        *out_result = (RendererSharedFrameResult){0};
        return true;
    }

    if (!ops || !ops->map || !ops->unmap) {
        PyErr_SetString(PyExc_RuntimeError, "renderer_shared_prepare_frame missing buffer callbacks");
        return false;
    }

    RendererSharedFrameResult result = {0};
    FONTS_DATA_HANDLE fonts_data = os_window->fonts_data;
    const Cursor *cursor = screen->paused_rendering.expires_at ? &screen->paused_rendering.cursor : screen->cursor;

    bool cursor_pos_changed = cursor->x != screen->last_rendered.cursor.x || cursor->y != screen->last_rendered.cursor.y;
    bool disable_ligatures = screen->disable_ligatures == DISABLE_LIGATURES_CURSOR;
    bool screen_resized = screen->last_rendered.columns != screen->columns || screen->last_rendered.lines != screen->lines;

    size_t cell_buffer_size = (size_t)screen->lines * screen->columns * sizeof(GPUCell);
    size_t selection_buffer_size = (size_t)screen->lines * screen->columns;

    bool need_cell_update = false;
    if (screen->paused_rendering.expires_at) {
        need_cell_update = !screen->paused_rendering.cell_data_updated;
    } else {
        need_cell_update = screen->reload_all_gpu_data || screen->scroll_changed ||
            screen->is_dirty || screen_resized || (disable_ligatures && cursor_pos_changed);
    }

    if (need_cell_update && cell_buffer_size) {
        void *cell_ptr = ops->map(RENDERER_SHARED_BUFFER_CELL_DATA, cell_buffer_size, ops_user);
        if (!cell_ptr) {
            PyErr_NoMemory();
            return false;
        }
        screen_update_cell_data(screen, cell_ptr, fonts_data, disable_ligatures && cursor_pos_changed);
        ops->unmap(RENDERER_SHARED_BUFFER_CELL_DATA, cell_ptr, cell_buffer_size, ops_user);
        result.cell_data_changed = true;
    }

    bool need_selection_update = false;
    if (screen->paused_rendering.expires_at) {
        need_selection_update = !screen->paused_rendering.cell_data_updated;
    } else {
        need_selection_update = screen->reload_all_gpu_data || screen_resized || screen_is_selection_dirty(screen);
    }

    if (need_selection_update && selection_buffer_size) {
        void *selection_ptr = ops->map(RENDERER_SHARED_BUFFER_SELECTIONS, selection_buffer_size, ops_user);
        if (!selection_ptr) {
            PyErr_NoMemory();
            return false;
        }
        screen_apply_selection(screen, selection_ptr, selection_buffer_size);
        ops->unmap(RENDERER_SHARED_BUFFER_SELECTIONS, selection_ptr, selection_buffer_size, ops_user);
        result.selection_data_changed = true;
    }

    bool graphics_changed = false;
    GraphicsManager *grman = screen->paused_rendering.expires_at && screen->paused_rendering.grman
        ? screen->paused_rendering.grman : screen->grman;
    unsigned int scrolled_by = screen->paused_rendering.expires_at ? screen->paused_rendering.scrolled_by : screen->scrolled_by;

    if (screen->paused_rendering.expires_at) {
        if (!screen->paused_rendering.cell_data_updated) {
            if (grman_update_layers(
                    grman,
                    scrolled_by,
                    -1.f,
                    1.f,
                    2.f / screen->columns,
                    2.f / screen->lines,
                    screen->columns,
                    screen->lines,
                    screen->cell_size)) {
                graphics_changed = true;
            }
        }
        screen->paused_rendering.cell_data_updated = true;
    } else {
        if (grman_update_layers(
                grman,
                scrolled_by,
                -1.f,
                1.f,
                2.f / screen->columns,
                2.f / screen->lines,
                screen->columns,
                screen->lines,
                screen->cell_size)) {
            graphics_changed = true;
        }
    }

    if (graphics_changed) {
        result.graphics_data_changed = true;
    }

    screen->last_rendered.columns = screen->columns;
    screen->last_rendered.lines = screen->lines;
    screen->last_rendered.cursor = screen->cursor_render_info;
    screen->last_rendered.scrolled_by = scrolled_by;

    float bg_alpha = effective_os_window_alpha(os_window);
    result.default_bg = renderer_shared_populate_uniform_data(
        screen,
        &screen->cursor_render_info,
        os_window,
        1.0f,
        bg_alpha,
        NULL,
        0,
        0
    );

    *out_result = result;
    return true;
}

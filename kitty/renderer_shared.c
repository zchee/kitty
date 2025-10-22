#include "Python.h"

#include "renderer_shared.h"

#include "colors.h"
#include "fonts.h"
#include "graphics.h"
#include "lineops.h"
#include "state.h"

#include <math.h>

#define IS_SPECIAL_COLOR(scr, name) ((scr)->color_profile->overridden.name.type == COLOR_IS_SPECIAL || ((scr)->color_profile->overridden.name.type == COLOR_NOT_SET && (scr)->color_profile->configured.name.type == COLOR_IS_SPECIAL))

EXPORTED float
renderer_shared_visual_bell_alpha_scale_for_tests(uint32_t flash_rgb, float intensity) {
    if (intensity < 0.0f) intensity = 0.0f;
    if (intensity > 1.0f) intensity = 1.0f;
    ARGB32 flash = {.rgb = flash_rgb};
    const double luminance = rgb_luminance(flash);
    const float base = luminance >= 128.0 ? 0.6f : 0.4f;
    return intensity * base;
}

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

static bool
renderer_shared_has_scrollbar(const Window *window, const Screen *screen) {
    if (!window || !screen || !screen->historybuf || screen->historybuf->count == 0u) {
        return false;
    }
    if (screen->linebuf != screen->main_linebuf) {
        return false;
    }
    switch (OPT(scrollbar)) {
        case SCROLLBAR_NEVER: return false;
        case SCROLLBAR_ALWAYS: return true;
        case SCROLLBAR_ON_SCROLLED: return screen->scrolled_by > 0u;
        case SCROLLBAR_ON_HOVERED: return window->scrollbar.is_hovering;
        case SCROLLBAR_ON_SCROLL_AND_HOVER: return screen->scrolled_by > 0u && window->scrollbar.is_hovering;
    }
    return false;
}

static color_type
renderer_shared_scrollbar_color(Screen *screen, unsigned int val) {
    switch (val & 0xffu) {
#define COLOR_FROM_PROFILE(which) colorprofile_to_color(screen->color_profile, screen->color_profile->overridden.which, screen->color_profile->configured.which).rgb
        case 0: return COLOR_FROM_PROFILE(default_fg);
        case 1: return COLOR_FROM_PROFILE(highlight_bg);
#undef COLOR_FROM_PROFILE
        default: return val >> 8u;
    }
}

static double
renderer_shared_border_thickness(const OSWindow *os_window, unsigned int level) {
    if (!os_window || !os_window->fonts_data) {
        return 0.0;
    }
    level = MIN(level, arraysz(OPT(box_drawing_scale)));
    double pts = OPT(box_drawing_scale)[level];
    double dpi = (os_window->fonts_data->logical_dpi_x + os_window->fonts_data->logical_dpi_y) / 2.0;
    return pts * dpi / 72.0;
}

bool
renderer_shared_prepare_scrollbar_metrics(
    Screen *screen,
    Window *window,
    const WindowRenderData *render_data,
    unsigned int screen_left_px,
    unsigned int screen_top_px,
    unsigned int screen_width_px,
    unsigned int screen_height_px,
    unsigned int cell_width_px,
    unsigned int cell_height_px,
    unsigned int framebuffer_height_px,
    RendererSharedScrollbarMetrics *out_metrics
) {
    if (!out_metrics) {
        PyErr_SetString(PyExc_ValueError, "renderer_shared_prepare_scrollbar_metrics requires output metrics");
        return false;
    }
    memset(out_metrics, 0, sizeof(*out_metrics));
    if (!screen || !window || !render_data) {
        return false;
    }
    if (!renderer_shared_has_scrollbar(window, screen)) {
        return true;
    }
    if (!screen_width_px || !screen_height_px || !cell_width_px || !cell_height_px) {
        return true;
    }
    const unsigned int history_count = screen->historybuf ? screen->historybuf->count : 0u;
    if (history_count == 0u) {
        return true;
    }

    const bool hovering = window->scrollbar.is_hovering;
    const double handle_width_cells = hovering ? OPT(scrollbar_hover_width) : OPT(scrollbar_width);
    const unsigned int scrollbar_width_px = (unsigned int)llround(handle_width_cells * (double)cell_width_px);
    const unsigned int scrollbar_gap_px = (unsigned int)llround(OPT(scrollbar_gap) * (double)cell_width_px);
    const unsigned int scrollbar_radius_px = (unsigned int)llround(OPT(scrollbar_radius) * (double)cell_width_px);

    unsigned int window_right_edge = screen_left_px + screen_width_px + render_data->geometry.spaces.right;
    unsigned int window_top_edge = screen_top_px - render_data->geometry.spaces.top;
    unsigned int window_height = screen_height_px + render_data->geometry.spaces.top + render_data->geometry.spaces.bottom;

    if (window_height <= 2u * scrollbar_gap_px || window_right_edge < scrollbar_width_px + scrollbar_gap_px) {
        return true;
    }

    unsigned int scrollbar_left = window_right_edge - scrollbar_width_px - scrollbar_gap_px;
    unsigned int scrollbar_top = window_top_edge + scrollbar_gap_px;
    unsigned int scrollbar_height = window_height - 2u * scrollbar_gap_px;

    if (scrollbar_height == 0u) {
        return true;
    }

    float bar_fraction = history_count ? (float)screen->scrolled_by / (float)history_count : 0.f;
    float visible_fraction = (float)screen->lines / (float)(screen->lines + history_count);
    float min_thumb_height_fraction = (float)(OPT(scrollbar_min_handle_height) * (double)cell_height_px) / (float)window_height;
    float thumb_height_fraction = fmaxf(min_thumb_height_fraction, visible_fraction);
    thumb_height_fraction = fminf(thumb_height_fraction, 1.f);

    const float gl_span = 2.0f;
    float thumb_height_gl = thumb_height_fraction * gl_span;
    float available_gl_space = gl_span - thumb_height_gl;
    float thumb_bottom_gl = -1.0f + available_gl_space * bar_fraction;
    float thumb_top_gl = thumb_bottom_gl + thumb_height_gl;
    float thumb_top_fraction = (1.0f - thumb_top_gl) * 0.5f;
    float thumb_bottom_fraction = (1.0f - thumb_bottom_gl) * 0.5f;

    unsigned int thumb_height_px = (unsigned int)llround((double)thumb_height_fraction * (double)scrollbar_height);
    thumb_height_px = MAX(thumb_height_px, 1u);
    unsigned int thumb_top_px = scrollbar_top + (unsigned int)llround((double)thumb_top_fraction * (double)scrollbar_height);
    if (thumb_top_px + thumb_height_px > scrollbar_top + scrollbar_height) {
        if (thumb_height_px > scrollbar_height) {
            thumb_height_px = scrollbar_height;
        }
        if (thumb_top_px + thumb_height_px > scrollbar_top + scrollbar_height) {
            thumb_top_px = scrollbar_top + scrollbar_height - thumb_height_px;
        }
    }

    color_type handle_color = renderer_shared_scrollbar_color(screen, OPT(scrollbar_handle_color));
    color_type track_color = renderer_shared_scrollbar_color(screen, OPT(scrollbar_track_color));
    float handle_opacity = OPT(scrollbar_handle_opacity);
    float track_opacity = hovering ? OPT(scrollbar_track_hover_opacity) : OPT(scrollbar_track_opacity);

    out_metrics->visible = true;
    out_metrics->left_px = (int)scrollbar_left;
    out_metrics->top_px = (int)scrollbar_top;
    out_metrics->width_px = scrollbar_width_px;
    out_metrics->height_px = scrollbar_height;
    out_metrics->thumb_top_px = thumb_top_px;
    out_metrics->thumb_height_px = thumb_height_px;
    out_metrics->thumb_top_fraction = thumb_top_fraction;
    out_metrics->thumb_bottom_fraction = thumb_bottom_fraction;
    out_metrics->thumb_height_fraction = thumb_height_fraction;
    out_metrics->handle_opacity = handle_opacity;
    out_metrics->track_opacity = track_opacity;
    out_metrics->corner_radius_px = scrollbar_radius_px;
    out_metrics->handle_color = handle_color;
    out_metrics->track_color = track_color;

    if (framebuffer_height_px > 0u) {
        float scrollbar_top_in_window = (float)(window_top_edge + scrollbar_gap_px) / (float)framebuffer_height_px;
        float scrollbar_height_in_window = (float)(window_height - 2u * scrollbar_gap_px) / (float)framebuffer_height_px;
        window->scrollbar.thumb_top = scrollbar_top_in_window + thumb_top_fraction * scrollbar_height_in_window;
        window->scrollbar.thumb_bottom = scrollbar_top_in_window + thumb_bottom_fraction * scrollbar_height_in_window;
    }

    return true;
}

bool
renderer_shared_prepare_bar_surface(
    Screen *screen,
    OSWindow *os_window,
    WindowBarData *bar,
    PyObject *title,
    unsigned int screen_width_px,
    unsigned int screen_height_px UNUSED,
    unsigned int cell_height_px,
    bool along_bottom,
    RendererSharedBarSurface *out_surface
) {
    if (!out_surface) {
        PyErr_SetString(PyExc_ValueError, "renderer_shared_prepare_bar_surface requires output surface");
        return false;
    }
    memset(out_surface, 0, sizeof(*out_surface));
    if (!screen || !os_window || !os_window->fonts_data || !bar) {
        return false;
    }
    const unsigned int border_width_px = (unsigned int)ceil(renderer_shared_border_thickness(os_window, 1));
    const unsigned int bar_height_px = cell_height_px + 2u;
    if (screen_width_px <= 2u * border_width_px || bar_height_px == 0u) {
        return true;
    }
    const unsigned int bar_width_px = screen_width_px - 2u * border_width_px;
    const size_t required_bytes = (size_t)4 * bar_width_px * bar_height_px;
    if (!bar->buf || bar->width != bar_width_px || bar->height != bar_height_px) {
        free(bar->buf);
        bar->buf = required_bytes ? malloc(required_bytes) : NULL;
        if (!bar->buf) {
            bar->width = 0;
            bar->height = 0;
            PyErr_NoMemory();
            return false;
        }
        bar->width = bar_width_px;
        bar->height = bar_height_px;
        bar->needs_render = true;
    }

    if (title && (bar->last_drawn_title_object_id != title || bar->needs_render)) {
        static char titlebuf[2048] = {0};
        if (!PyUnicode_Check(title)) {
            PyErr_SetString(PyExc_TypeError, "renderer_shared_prepare_bar_surface expects title to be unicode");
            return false;
        }
        const char *utf8 = PyUnicode_AsUTF8(title);
        if (!utf8) {
            return false;
        }
        snprintf(titlebuf, arraysz(titlebuf), " %s", utf8);
#define RGBCOL(which, fallback) (0xff000000u | colorprofile_to_color_with_fallback(screen->color_profile, screen->color_profile->overridden.which, screen->color_profile->configured.which, screen->color_profile->overridden.fallback, screen->color_profile->configured.fallback))
        color_type fg = RGBCOL(default_fg, default_fg);
        color_type bg = RGBCOL(default_bg, default_bg);
#undef RGBCOL
        if (!draw_window_title(os_window->fonts_data->font_sz_in_pts,
                               os_window->fonts_data->logical_dpi_y,
                               titlebuf,
                               fg,
                               bg,
                               bar->buf,
                               bar_width_px,
                               bar_height_px)) {
            PyErr_SetString(PyExc_RuntimeError, "draw_window_title failed");
            return false;
        }
        Py_CLEAR(bar->last_drawn_title_object_id);
        bar->last_drawn_title_object_id = Py_NewRef(title);
        bar->needs_render = false;
    }

#define RGBCOL(which, fallback) (0xff000000u | colorprofile_to_color_with_fallback(screen->color_profile, screen->color_profile->overridden.which, screen->color_profile->configured.which, screen->color_profile->overridden.fallback, screen->color_profile->configured.fallback))
    color_type fg = RGBCOL(default_fg, default_fg);
    color_type bg = RGBCOL(default_bg, default_bg);
#undef RGBCOL

    out_surface->visible = bar->buf != NULL;
    out_surface->along_bottom = along_bottom;
    out_surface->width_px = bar_width_px;
    out_surface->height_px = bar_height_px;
    out_surface->border_width_px = border_width_px;
    out_surface->foreground_color = fg;
    out_surface->background_color = bg;
    out_surface->pixels = bar->buf;
    out_surface->stride_bytes = bar_width_px * 4u;
    return true;
}

bool
renderer_shared_prepare_window_number(
    Screen *screen,
    unsigned int screen_width_px,
    unsigned int screen_height_px,
    unsigned int screen_left_px,
    unsigned int screen_top_px,
    unsigned int framebuffer_height_px UNUSED,
    unsigned int cell_width_px,
    unsigned int cell_height_px,
    unsigned int title_bar_height_px,
    RendererSharedWindowNumber *out_window_number
) {
    if (!out_window_number) {
        PyErr_SetString(PyExc_ValueError, "renderer_shared_prepare_window_number requires output struct");
        return false;
    }
    memset(out_window_number, 0, sizeof(*out_window_number));
    if (!screen || screen->display_window_char == 0) {
        return true;
    }

    unsigned int available_height = 0;
    if (screen_height_px > title_bar_height_px) {
        available_height = screen_height_px - title_bar_height_px;
    }
    if (available_height <= cell_height_px) {
        return true;
    }
    unsigned int height_for_letter = available_height - cell_height_px;
    unsigned int width_for_letter = screen_width_px > cell_width_px ? screen_width_px - cell_width_px : 0u;
    unsigned int requested_height = MIN(12u * cell_height_px, MIN(height_for_letter, width_for_letter));
    if (requested_height < 4u) {
        return true;
    }

#define lr screen->last_rendered_window_char
    if (!lr.canvas || lr.ch != screen->display_window_char || lr.requested_height != requested_height) {
        free(lr.canvas);
        lr.canvas = NULL;
        lr.width_px = 0;
        lr.height_px = requested_height;
        lr.requested_height = requested_height;
        lr.ch = 0;
        lr.canvas = draw_single_ascii_char(screen->display_window_char, &lr.width_px, &lr.height_px);
        if (!lr.canvas || lr.height_px < 4 || lr.width_px < 4) {
            lr.ch = 0;
            return true;
        }
        lr.ch = screen->display_window_char;
    }
#undef lr

    unsigned int letter_x = 0, letter_y = title_bar_height_px;
    if (screen->last_rendered_window_char.width_px < screen_width_px) {
        letter_x = (screen_width_px - (unsigned int)screen->last_rendered_window_char.width_px) / 2u;
    }
    if (screen->last_rendered_window_char.height_px + title_bar_height_px < screen_height_px) {
        letter_y += (screen_height_px - (unsigned int)screen->last_rendered_window_char.height_px - title_bar_height_px) / 2u;
    }

    color_type glyph_color = colorprofile_to_color_with_fallback(
        screen->color_profile,
        screen->color_profile->overridden.highlight_bg,
        screen->color_profile->configured.highlight_bg,
        screen->color_profile->overridden.default_fg,
        screen->color_profile->configured.default_fg
    );

    out_window_number->visible = true;
    out_window_number->width_px = (unsigned int)screen->last_rendered_window_char.width_px;
    out_window_number->height_px = (unsigned int)screen->last_rendered_window_char.height_px;
    out_window_number->offset_x_px = screen_left_px + letter_x;
    out_window_number->offset_y_px = screen_top_px + letter_y;
    out_window_number->glyph_color = glyph_color;
    out_window_number->pixels = screen->last_rendered_window_char.canvas;
    return true;
}

PyObject *
renderer_shared_get_hyperlink_title(
    Screen *screen,
    Window *window,
    OSWindow *os_window,
    bool *out_along_bottom
) {
    if (!screen || !window || !os_window || !out_along_bottom) {
        return NULL;
    }
    if (!OPT(show_hyperlink_targets) || !screen->current_hyperlink_under_mouse.id || is_mouse_hidden(os_window)) {
        return NULL;
    }
    if (global_state.mouse_hover_in_window != window->id) {
        return NULL;
    }

    WindowBarData *bd = &window->url_target_bar_data;
    const bool along_bottom = screen->current_hyperlink_under_mouse.y < 3;

    if (bd->hyperlink_id_for_title_object != screen->current_hyperlink_under_mouse.id) {
        bd->hyperlink_id_for_title_object = screen->current_hyperlink_under_mouse.id;
        Py_CLEAR(bd->last_drawn_title_object_id);
        const char *url = get_hyperlink_for_id(screen->hyperlink_pool, bd->hyperlink_id_for_title_object, true);
        if (!url) {
            url = "";
        }
        bd->last_drawn_title_object_id = PyObject_CallMethod(
            global_state.boss,
            "sanitize_url_for_display_to_user",
            "s",
            url
        );
        if (!bd->last_drawn_title_object_id) {
            PyErr_Print();
            return NULL;
        }
        bd->needs_render = true;
    }

    if (!bd->last_drawn_title_object_id) {
        return NULL;
    }

    *out_along_bottom = along_bottom;
    return Py_NewRef(bd->last_drawn_title_object_id);
}

bool
renderer_shared_test_scrollbar_metrics(
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
) {
    if (!out_metrics) {
        PyErr_SetString(PyExc_ValueError, "renderer_shared_test_scrollbar_metrics requires output metrics");
        return false;
    }

    Screen screen = {0};
    Window window = {0};
    WindowRenderData render_data = {0};
    HistoryBuf history = {0};
    LineBuf linebuf = {0};

    history.count = history_count;
    screen.historybuf = &history;
    screen.scrolled_by = scrolled_by;
    screen.lines = (unsigned int)((double)screen_height_px / (double)MAX(cell_height_px, 1u));
    screen.columns = (unsigned int)((double)screen_width_px / (double)MAX(cell_width_px, 1u));
    linebuf.cpu_cell_buf = NULL;
    linebuf.gpu_cell_buf = NULL;
    screen.linebuf = &linebuf;
    screen.main_linebuf = &linebuf;

    render_data.geometry.left = 0;
    render_data.geometry.top = 0;
    render_data.geometry.right = screen_width_px;
    render_data.geometry.bottom = screen_height_px;
    render_data.geometry.spaces.right = padding_right_px;
    render_data.geometry.spaces.top = padding_top_px;
    render_data.geometry.spaces.bottom = padding_bottom_px;

    window.scrollbar.is_hovering = hovering;

    RendererSharedScrollbarMetrics metrics = {0};

    float saved_hover_width = OPT(scrollbar_hover_width);
    float saved_width = OPT(scrollbar_width);
    float saved_gap = OPT(scrollbar_gap);
    float saved_handle_opacity = OPT(scrollbar_handle_opacity);
    float saved_track_opacity = OPT(scrollbar_track_opacity);
    float saved_track_hover_opacity = OPT(scrollbar_track_hover_opacity);
    float saved_min_handle = OPT(scrollbar_min_handle_height);
    float saved_radius = OPT(scrollbar_radius);
    unsigned int saved_handle_color = OPT(scrollbar_handle_color);
    unsigned int saved_track_color = OPT(scrollbar_track_color);
    ScrollbarVisibilityPolicy saved_policy = OPT(scrollbar);

    OPT(scrollbar_hover_width) = hover_width_cells;
    OPT(scrollbar_width) = width_cells;
    OPT(scrollbar_gap) = gap_cells;
    OPT(scrollbar_handle_opacity) = handle_opacity;
    OPT(scrollbar_track_opacity) = track_opacity;
    OPT(scrollbar_track_hover_opacity) = track_hover_opacity;
    OPT(scrollbar_min_handle_height) = min_handle_height_cells;
    OPT(scrollbar_radius) = (float)radius_cells;
    OPT(scrollbar_handle_color) = handle_color;
    OPT(scrollbar_track_color) = track_color;
    OPT(scrollbar) = SCROLLBAR_ALWAYS;

    bool ok = renderer_shared_prepare_scrollbar_metrics(
        &screen,
        &window,
        &render_data,
        0,
        0,
        screen_width_px,
        screen_height_px,
        cell_width_px,
        cell_height_px,
        framebuffer_height_px,
        &metrics
    );

    OPT(scrollbar_hover_width) = saved_hover_width;
    OPT(scrollbar_width) = saved_width;
    OPT(scrollbar_gap) = saved_gap;
    OPT(scrollbar_handle_opacity) = saved_handle_opacity;
    OPT(scrollbar_track_opacity) = saved_track_opacity;
    OPT(scrollbar_track_hover_opacity) = saved_track_hover_opacity;
    OPT(scrollbar_min_handle_height) = saved_min_handle;
    OPT(scrollbar_radius) = saved_radius;
    OPT(scrollbar_handle_color) = saved_handle_color;
    OPT(scrollbar_track_color) = saved_track_color;
    OPT(scrollbar) = saved_policy;

    if (!ok) {
        return false;
    }
    *out_metrics = metrics;
    return true;
}

bool
renderer_shared_test_prepare_bar_surface(
    unsigned int width_px,
    unsigned int height_px,
    unsigned int border_width_px,
    color_type fg,
    color_type bg,
    RendererSharedBarSurface *out_surface
) {
    if (!out_surface) {
        PyErr_SetString(PyExc_ValueError, "renderer_shared_test_prepare_bar_surface requires output surface");
        return false;
    }
    memset(out_surface, 0, sizeof(*out_surface));
    static uint8_t dummy_pixels[4] = {0};
    out_surface->visible = true;
    out_surface->along_bottom = false;
    out_surface->width_px = width_px;
    out_surface->height_px = height_px;
    out_surface->border_width_px = border_width_px;
    out_surface->foreground_color = fg;
    out_surface->background_color = bg;
    out_surface->pixels = dummy_pixels;
    out_surface->stride_bytes = width_px ? width_px * 4u : 0u;
    return true;
}

bool
renderer_shared_test_prepare_window_number(
    unsigned int glyph_width_px,
    unsigned int glyph_height_px,
    unsigned int offset_x_px,
    unsigned int offset_y_px,
    color_type glyph_color,
    RendererSharedWindowNumber *out_info
) {
    if (!out_info) {
        PyErr_SetString(PyExc_ValueError, "renderer_shared_test_prepare_window_number requires output struct");
        return false;
    }
    memset(out_info, 0, sizeof(*out_info));
    out_info->visible = true;
    out_info->width_px = glyph_width_px;
    out_info->height_px = glyph_height_px;
    out_info->offset_x_px = offset_x_px;
    out_info->offset_y_px = offset_y_px;
    out_info->glyph_color = glyph_color;
    out_info->pixels = NULL;
    return true;
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

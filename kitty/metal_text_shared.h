/*
 * Shared data structures/constants for the Metal text renderer.
 *
 * This header is included by both C/Objective-C code and Metal shaders.
 *
 * Copyright (C) 2025
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#include <stdint.h>

#define KITTY_NUM_COLORS              256u
#define KITTY_MARK_MASK               3u
#define KITTY_COLOR_TABLE_SIZE        (KITTY_NUM_COLORS + 2u * KITTY_MARK_MASK + 2u)
#define KITTY_GAMMA_LUT_SIZE          256u

#define KITTY_DECORATION_SHIFT        0u
#define KITTY_REVERSE_SHIFT           5u
#define KITTY_STRIKE_SHIFT            6u
#define KITTY_DIM_SHIFT               7u
#define KITTY_BLINK_SHIFT             8u
#define KITTY_MARK_SHIFT              9u

#define KITTY_BIT_MASK                1u
#define KITTY_SPRITE_INDEX_MASK       0x7fffffffu
#define KITTY_SPRITE_COLORED_MASK     0x80000000u
#define KITTY_SPRITE_COLORED_SHIFT    31u

#define KITTY_NUM_BG_SLOTS            8u

#define KITTY_COLOR_NOT_SET           0u
#define KITTY_COLOR_IS_SPECIAL        1u
#define KITTY_COLOR_IS_INDEX          2u
#define KITTY_COLOR_IS_RGB            3u

#ifdef __cplusplus
extern "C" {
#endif

#ifndef __METAL_VERSION__

#include "line.h"

typedef GPUCell KittyGPUCell;

typedef struct KittyCellUniforms {
    float use_cell_bg_for_selection_fg;
    float use_cell_fg_for_selection_color;
    float use_cell_for_selection_bg;
    float _pad0;

    uint32_t default_fg;
    uint32_t highlight_fg;
    uint32_t highlight_bg;
    uint32_t main_cursor_fg;
    uint32_t main_cursor_bg;
    uint32_t url_color;
    uint32_t url_style;
    uint32_t inverted;
    uint32_t extra_cursor_fg;
    uint32_t extra_cursor_bg;

    uint32_t draw_bg_bitfield;
    uint32_t columns;
    uint32_t lines;
    uint32_t sprites_xnum;
    uint32_t sprites_ynum;
    uint32_t cursor_shape;
    uint32_t cell_width;
    uint32_t cell_height;
    uint32_t cursor_x1;
    uint32_t cursor_x2;
    uint32_t cursor_y1;
    uint32_t cursor_y2;

    float cursor_opacity;
    float inactive_text_alpha;
    float dim_opacity;
    float blink_opacity;

    uint32_t bg_colors[KITTY_NUM_BG_SLOTS];
    float bg_opacities[KITTY_NUM_BG_SLOTS];

    uint32_t color_table[KITTY_COLOR_TABLE_SIZE];
    float gamma_lut[KITTY_GAMMA_LUT_SIZE];
} KittyCellUniforms;

static_assert(sizeof(KittyCellUniforms) % 16u == 0u, "KittyCellUniforms must be 16-byte aligned");

#else /* __METAL_VERSION__ */

struct KittyGPUCell {
    uint fg;
    uint bg;
    uint decoration_fg;
    uint sprite_idx;
    uint attrs;
};

struct KittyCellUniforms {
    float use_cell_bg_for_selection_fg;
    float use_cell_fg_for_selection_color;
    float use_cell_for_selection_bg;
    float _pad0;

    uint default_fg;
    uint highlight_fg;
    uint highlight_bg;
    uint main_cursor_fg;
    uint main_cursor_bg;
    uint url_color;
    uint url_style;
    uint inverted;
    uint extra_cursor_fg;
    uint extra_cursor_bg;

    uint draw_bg_bitfield;
    uint columns;
    uint lines;
    uint sprites_xnum;
    uint sprites_ynum;
    uint cursor_shape;
    uint cell_width;
    uint cell_height;
    uint cursor_x1;
    uint cursor_x2;
    uint cursor_y1;
    uint cursor_y2;

    float cursor_opacity;
    float inactive_text_alpha;
    float dim_opacity;
    float blink_opacity;

    uint bg_colors[KITTY_NUM_BG_SLOTS];
    float bg_opacities[KITTY_NUM_BG_SLOTS];

    uint color_table[KITTY_COLOR_TABLE_SIZE];
    float gamma_lut[KITTY_GAMMA_LUT_SIZE];
};

#endif /* __METAL_VERSION__ */

#ifdef __cplusplus
}
#endif

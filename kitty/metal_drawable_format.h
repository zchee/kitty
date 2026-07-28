/*
 * metal_drawable_format.h
 * Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// W27 P3.2 drawable-format probe (plan
// .omc/plans/plan-2026-07-28-w27-metal-2026-fastest-displayp3.md, P3.2 + the
// P3.3 format<->colourspace<->transfer coupling table). KITTY_METAL_DRAWABLE_
// FORMAT selects one candidate for the CAMetalLayer drawable.
//
// A candidate is a COHERENT TRIPLE: the layer's pixel format, the CGColorSpace
// Core Animation composites it through, and *who* applies the sRGB transfer.
// All three must move together or the frame is double-encoded (gamma-sized
// error) or never encoded at all:
//
//   value            layer.pixelFormat   layer.colorspace                  transfer applied by
//   ---------------  ------------------  --------------------------------  -------------------------------
//   bgra8 (default)  BGRA8Unorm          nil (not colour-matched)          the shaders (SRGB_ENCODE_OUTPUT)
//   bgra10_xr_srgb   BGRA10_XR_sRGB      kCGColorSpaceExtendedSRGB         the ROP (sRGB encode on store)
//   bgra10_xr        BGRA10_XR           kCGColorSpaceExtendedLinearSRGB   nobody (linear stored; XR mapping
//                                                                          shader_float = (xr10 - 384)/510)
//   rgba16f          RGBA16Float         kCGColorSpaceExtendedLinearSRGB   nobody (linear float end to end)
//
// So for every candidate except bgra8 the render pipeline emits LINEAR values:
// the in-shader encode is off, the layered resolve's encode is off, and the
// deferred clear colour (which kitty hands over sRGB-encoded, blank_canvas() in
// kitty/shaders.c) is linearized before it reaches MTLClearColor.
//
// The tags are the sRGB-primaries members of the extended families, not the
// Display-P3 members the plan's P3.3 table pins: at P3.2 the shaders still emit
// sRGB primaries, so a P3 tag would reinterpret every colour and make the P3.1
// gates measure the missing primaries conversion instead of the format. The P3
// tags land with that conversion in P3.4/P3.5.
//
// bgra8 is byte-for-byte the pre-probe behaviour: same format, no colourspace,
// same in-shader encode. Every other value is opt-in via the environment.
//
// CAMetalLayer.pixelFormat accepts all four (apple-docs, quartzcore/
// cametallayer/pixelformat); the XR formats are macOS 11.0+, the build floor is
// 15.3, so no availability guard is needed.

typedef enum {
    DRAWABLE_FORMAT_BGRA8 = 0,
    DRAWABLE_FORMAT_BGRA10_XR_SRGB,
    DRAWABLE_FORMAT_BGRA10_XR,
    DRAWABLE_FORMAT_RGBA16F,
} KittyDrawableFormatId;

// The selected candidate. Read from the environment once, cached: the drawable
// format is fixed for the process lifetime (PSOs and the layer are built
// against it), so a mid-run change must not be observable.
static inline KittyDrawableFormatId
kitty_drawable_format_id(void) {
    static bool checked = false;
    static KittyDrawableFormatId id = DRAWABLE_FORMAT_BGRA8;
    if (!checked) {
        checked = true;
        const char *s = getenv("KITTY_METAL_DRAWABLE_FORMAT");
        if (s && s[0]) {
            if (strcmp(s, "bgra8") == 0) id = DRAWABLE_FORMAT_BGRA8;
            else if (strcmp(s, "bgra10_xr_srgb") == 0) id = DRAWABLE_FORMAT_BGRA10_XR_SRGB;
            else if (strcmp(s, "bgra10_xr") == 0) id = DRAWABLE_FORMAT_BGRA10_XR;
            else if (strcmp(s, "rgba16f") == 0) id = DRAWABLE_FORMAT_RGBA16F;
            else fprintf(stderr, "[kitty] unknown KITTY_METAL_DRAWABLE_FORMAT=%s"
                                 " (expected one of: bgra8 bgra10_xr_srgb bgra10_xr rgba16f);"
                                 " using bgra8\n", s);
        }
    }
    return id;
}

static inline MTLPixelFormat
kitty_drawable_pixel_format(void) {
    switch (kitty_drawable_format_id()) {
        case DRAWABLE_FORMAT_BGRA10_XR_SRGB: return MTLPixelFormatBGRA10_XR_sRGB;
        case DRAWABLE_FORMAT_BGRA10_XR:      return MTLPixelFormatBGRA10_XR;
        case DRAWABLE_FORMAT_RGBA16F:        return MTLPixelFormatRGBA16Float;
        case DRAWABLE_FORMAT_BGRA8:          break;
    }
    return MTLPixelFormatBGRA8Unorm;
}

// The colourspace to tag the layer with, or NULL to leave layer.colorspace at
// its default nil (the bgra8 control arm's uncolour-matched fast path).
static inline CFStringRef
kitty_drawable_colorspace_name(void) {
    switch (kitty_drawable_format_id()) {
        // Extended-range, sRGB-like transfer: the ROP hands Core Animation
        // already-encoded values.
        case DRAWABLE_FORMAT_BGRA10_XR_SRGB: return kCGColorSpaceExtendedSRGB;
        // Extended-range LINEAR: the drawable stores what the shaders emit.
        case DRAWABLE_FORMAT_BGRA10_XR:
        case DRAWABLE_FORMAT_RGBA16F:        return kCGColorSpaceExtendedLinearSRGB;
        case DRAWABLE_FORMAT_BGRA8:          break;
    }
    return NULL;
}

// True for the wide candidates, i.e. exactly the drawable formats whose render
// pipeline must emit LINEAR values. Deliberately an explicit allowlist rather
// than "!= BGRA8Unorm": every other attachment format in the backend (the
// RGBA16Unorm layered working surface, the BGRA8 dump offscreen, FBO targets)
// keeps its pre-probe encode behaviour by construction.
static inline bool
kitty_drawable_format_is_wide(MTLPixelFormat fmt) {
    return fmt == MTLPixelFormatBGRA10_XR_sRGB || fmt == MTLPixelFormatBGRA10_XR ||
           fmt == MTLPixelFormatRGBA16Float;
}

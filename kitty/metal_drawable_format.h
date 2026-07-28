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
//   value            layer.pixelFormat   layer.colorspace                     transfer applied by
//   ---------------  ------------------  -----------------------------------  -------------------------------
//   bgra8 (default)  BGRA8Unorm          nil (not colour-matched)             the shaders (TARGET_COLOR_SPACE)
//   bgra10_xr_srgb   BGRA10_XR_sRGB      kCGColorSpaceExtendedDisplayP3       the ROP (sRGB encode on store)
//   bgra10_xr        BGRA10_XR           kCGColorSpaceExtendedLinearDisplayP3 nobody (linear stored; XR mapping
//                                                                             shader_float = (xr10 - 384)/510)
//   rgba16f          RGBA16Float         kCGColorSpaceExtendedLinearDisplayP3 nobody (linear float end to end)
//
// So for every candidate except bgra8 the render pipeline emits LINEAR values:
// the in-shader encode is off, the layered resolve's encode is off, and the
// deferred clear colour (which kitty hands over sRGB-encoded, blank_canvas() in
// kitty/shaders.c) is linearized before it reaches MTLClearColor.
//
// W27 P3.5: the tags are now the Display-P3 members the plan's P3.3 coupling
// table pins, and they move together with the primaries conversion the
// fragments apply at the attachment exit (TARGET_PRIMARIES_IS_P3, resolved by
// target_primaries_is_p3_for() in kitty/metal.m from the same format the
// transfer is resolved from): the pipeline still works in linear sRGB
// primaries end to end, converts once at the exit, and the tag tells Core
// Animation what the converted values mean. Tag and matrix compose to the
// same light as the P3.2-era sRGB tags — CA colour-matched sRGB content then,
// the shader-side matrix plus the P3 tag produce identical XYZ now — but P3
// tagging makes out-of-sRGB values expressible, which is what the P3.5b wide
// colour carrier and the P4 EDR wiring stand on. (At P3.2 the tags were the
// sRGB-primaries members so the gates priced the format flip alone.)
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
        // Extended-range, sRGB-like transfer, P3 primaries: the ROP hands Core
        // Animation already-encoded values (macOS 11.0+, floor is 15.3).
        case DRAWABLE_FORMAT_BGRA10_XR_SRGB: return kCGColorSpaceExtendedDisplayP3;
        // Extended-range LINEAR, P3 primaries: the drawable stores what the
        // shaders emit (post primaries conversion).
        case DRAWABLE_FORMAT_BGRA10_XR:
        case DRAWABLE_FORMAT_RGBA16F:        return kCGColorSpaceExtendedLinearDisplayP3;
        case DRAWABLE_FORMAT_BGRA8:          break;
    }
    return NULL;
}

// NOTE (W27 P3.4): the "which formats want linear values" question used to be
// answered by a kitty_drawable_format_is_wide() predicate here. It is now
// target_color_space_for() in kitty/metal.m, which has to distinguish
// BGRA10_XR_sRGB (the ROP encodes) from the linear-stored formats anyway and is
// the single classifier for BOTH consumers — the shader function constants and
// the deferred clear colour. Keeping a second format allowlist here would be a
// place for the two to disagree.

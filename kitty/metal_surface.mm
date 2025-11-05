/*
 * metal_surface.mm
 * Prototype scaffolding for the macOS Metal renderer.
 *
 * Copyright (C) 2025
 *
 * Distributed under terms of the GPL3 license.
 */

#include "metal_surface.h"

#ifdef __APPLE__

#include "state.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

static id<MTLDevice> metal_device = nil;

bool
metal_backend_available(void) {
    @autoreleasepool {
        return MTLCreateSystemDefaultDevice() != nil;
    }
}

bool
metal_backend_init(OSWindow *window) {
    (void)window;
    @autoreleasepool {
        metal_device = MTLCreateSystemDefaultDevice();
        if (metal_device == nil) {
            log_error("Metal backend unavailable: failed to acquire default Metal device.");
            return false;
        }
        log_error("Metal backend scaffolding initialized (no rendering yet, falling back to OpenGL).");
    }
    return false;
}

void
metal_backend_shutdown(void) {
    metal_device = nil;
}

bool
metal_begin_frame(OSWindow *window) {
    (void)window;
    return false;
}

void
metal_end_frame(OSWindow *window) {
    (void)window;
}

#else

bool
metal_backend_available(void) { return false; }

bool
metal_backend_init(OSWindow *window) {
    (void)window;
    return false;
}

void
metal_backend_shutdown(void) {}

bool
metal_begin_frame(OSWindow *window) {
    (void)window;
    return false;
}

void
metal_end_frame(OSWindow *window) {
    (void)window;
}

#endif


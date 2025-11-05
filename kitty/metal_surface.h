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

#ifdef KITTY_ENABLE_METAL

bool metal_backend_available(void);
bool metal_backend_init(struct OSWindow *window);
void metal_backend_shutdown(void);
bool metal_begin_frame(struct OSWindow *window);
void metal_end_frame(struct OSWindow *window);

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
metal_begin_frame(struct OSWindow *window) {
    (void)window;
    return false;
}

static inline void
metal_end_frame(struct OSWindow *window) {
    (void)window;
}

#endif

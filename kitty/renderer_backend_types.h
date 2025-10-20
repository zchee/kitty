#pragma once

#include <stdbool.h>

#include "color_type.h"
#include "monotonic.h"

typedef enum {
    RENDERER_BACKEND_OPENGL = 0,
    RENDERER_BACKEND_METAL,
    RENDERER_BACKEND_COUNT
} RendererBackendType;

typedef enum {
    RENDERER_BACKEND_PREFERENCE_AUTO = 0,
    RENDERER_BACKEND_PREFERENCE_METAL,
    RENDERER_BACKEND_PREFERENCE_OPENGL
} RendererBackendPreference;

typedef enum {
    REPEAT_MIRROR,
    REPEAT_CLAMP,
    REPEAT_DEFAULT
} RepeatStrategy;

typedef struct RendererInitConfig {
    bool prefer_low_latency;
    bool enable_debug_labels;
} RendererInitConfig;

typedef struct RendererFrameParams {
    monotonic_t frame_start_time;
    bool vsync_enabled;
} RendererFrameParams;

typedef struct RendererPresentParams {
    bool blocking;
    bool capture_framebuffer;
} RendererPresentParams;

typedef struct RendererResizeParams {
    int framebuffer_width;
    int framebuffer_height;
    float framebuffer_scale;
} RendererResizeParams;

struct OSWindow;

typedef struct RendererRenderParams {
    struct OSWindow *os_window;
    unsigned int active_window_id;
    color_type active_window_bg;
    unsigned int num_visible_windows;
    bool all_windows_have_same_bg;
} RendererRenderParams;

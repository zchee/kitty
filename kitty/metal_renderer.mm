#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "metal_renderer.h"
#include "renderer_backend.h"
#include "data-types.h"

static bool preflight_attempted = false;
static bool preflight_success = false;
static const char *preflight_failure_reason = NULL;

static void
set_preflight_failure(const char *reason) {
    preflight_success = false;
    preflight_failure_reason = reason;
}

bool
metal_renderer_preflight(const char **failure_reason) {
    if (!preflight_attempted) {
        preflight_attempted = true;
        if (@available(macOS 13.0, *)) {
            set_preflight_failure("Metal renderer bootstrap is in progress; continuing with OpenGL.");
        } else {
            set_preflight_failure("Metal renderer requires macOS 13 or newer.");
        }
    }
    if (failure_reason && !preflight_success) {
        *failure_reason = preflight_failure_reason;
    }
    return preflight_success;
}

static bool
metal_backend_ensure_initialized(const RendererInitConfig *cfg UNUSED) {
    const char *reason = NULL;
    if (!metal_renderer_preflight(&reason)) {
        PyErr_SetString(PyExc_RuntimeError, reason ? reason : "Metal renderer disabled");
        return false;
    }
    PyErr_SetString(PyExc_RuntimeError, "Metal renderer initialization has not been implemented yet");
    return false;
}

static void
metal_backend_shutdown(void) {
}

static void*
metal_backend_make_context_current(GLFWwindow *window UNUSED) {
    return NULL;
}

static void
metal_backend_restore_context(void *token UNUSED) {
}

static bool
metal_backend_attach_window(GLFWwindow *window UNUSED, const RendererWindowConfig *config UNUSED) {
    PyErr_SetString(PyExc_RuntimeError, "Metal renderer window attachment is not available");
    return false;
}

static void
metal_backend_apply_swap_interval(int val UNUSED) {
}

static void
metal_backend_swap_buffers(GLFWwindow *window UNUSED) {
}

static bool
metal_backend_begin_frame(GLFWwindow *window UNUSED, const RendererFrameParams *params UNUSED) {
    PyErr_SetString(PyExc_RuntimeError, "Metal renderer begin_frame is not available");
    return false;
}

static bool
metal_backend_render(GLFWwindow *window UNUSED, const RendererRenderParams *params UNUSED) {
    PyErr_SetString(PyExc_RuntimeError, "Metal renderer render is not available");
    return false;
}

static bool
metal_backend_present(GLFWwindow *window UNUSED, const RendererPresentParams *params UNUSED) {
    return false;
}

static void
metal_backend_on_resize(GLFWwindow *window UNUSED, const RendererResizeParams *params UNUSED) {
}

static void
metal_backend_on_suspend(void) {
}

static void
metal_backend_on_resume(void) {
}

bool
register_metal_renderer_backend(void) {
    static const RendererBackendOps metal_ops = {
        .name = "metal",
        .ensure_initialized = metal_backend_ensure_initialized,
        .shutdown = metal_backend_shutdown,
        .make_context_current = metal_backend_make_context_current,
        .restore_context = metal_backend_restore_context,
        .attach_window = metal_backend_attach_window,
        .apply_swap_interval = metal_backend_apply_swap_interval,
        .begin_frame = metal_backend_begin_frame,
        .render = metal_backend_render,
        .present = metal_backend_present,
        .on_resize = metal_backend_on_resize,
        .on_suspend = metal_backend_on_suspend,
        .on_resume = metal_backend_on_resume,
    };
    return renderer_backend_register(RENDERER_BACKEND_METAL, &metal_ops);
}

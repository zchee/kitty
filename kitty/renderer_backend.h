#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "Python.h"
#include "compiler.h"
#include "glfw-wrapper.h"
#include "renderer_backend_types.h"

struct TextureRef;

typedef struct RendererWindowConfig {
    bool is_first_window;
    bool wants_transparency;
    float background_opacity;
    color_type background_color;
} RendererWindowConfig;

typedef struct RendererGraphicsImageUpload {
    const void *pixels;
    int32_t width;
    int32_t height;
    bool is_opaque;
    bool is_4byte_aligned;
    bool linear_filter;
    RepeatStrategy repeat;
} RendererGraphicsImageUpload;

typedef struct RendererBackendOps {
    const char *name;
    bool  (*ensure_initialized)(const RendererInitConfig *cfg);
    void  (*shutdown)(void);
    bool  (*attach_window)(GLFWwindow *window, const RendererWindowConfig *config);
    void* (*make_context_current)(GLFWwindow *window);
    void  (*restore_context)(void *token);
    void  (*apply_swap_interval)(int val);
    bool  (*begin_frame)(GLFWwindow *window, const RendererFrameParams *params);
    bool  (*render)(GLFWwindow *window, const RendererRenderParams *params);
    bool  (*present)(GLFWwindow *window, const RendererPresentParams *params);
    void  (*on_resize)(GLFWwindow *window, const RendererResizeParams *params);
    void  (*on_suspend)(void);
    void  (*on_resume)(void);
    bool  (*upload_graphics_image)(struct TextureRef *ref, const RendererGraphicsImageUpload *upload);
    void  (*destroy_graphics_image)(struct TextureRef *ref);
} RendererBackendOps;

EXPORTED bool renderer_backend_register(RendererBackendType type, const RendererBackendOps *ops);
EXPORTED bool renderer_backend_select(RendererBackendType type);
EXPORTED RendererBackendType renderer_backend_current_type(void);
EXPORTED const char* renderer_backend_type_name(RendererBackendType type);
EXPORTED RendererBackendType renderer_backend_type_from_name(const char *name);
EXPORTED bool renderer_backend_attach_window(GLFWwindow *window, const RendererWindowConfig *config);
EXPORTED void* renderer_backend_make_context_current(GLFWwindow *window);
EXPORTED void renderer_backend_restore_context(void *token);
EXPORTED void renderer_backend_apply_swap_interval(int val);
EXPORTED bool renderer_backend_begin_frame(GLFWwindow *window, const RendererFrameParams *params);
EXPORTED bool renderer_backend_render(GLFWwindow *window, const RendererRenderParams *params);
EXPORTED bool renderer_backend_present(GLFWwindow *window, const RendererPresentParams *params);
EXPORTED void renderer_backend_on_resize(GLFWwindow *window, const RendererResizeParams *params);
EXPORTED void renderer_backend_on_suspend(void);
EXPORTED void renderer_backend_on_resume(void);
EXPORTED void renderer_backend_swap_buffers(GLFWwindow *window);
EXPORTED bool renderer_backend_upload_graphics_image(struct TextureRef *ref, const RendererGraphicsImageUpload *upload);
EXPORTED void renderer_backend_destroy_graphics_image(struct TextureRef *ref);
EXPORTED void renderer_backend_shutdown_active(void);
EXPORTED void renderer_backend_reset_for_tests(void);
EXPORTED bool renderer_backend_register_stub_for_tests(
    RendererBackendType type,
    const char *name,
    bool provide_render,
    bool provide_present
);
EXPORTED bool renderer_backend_render_for_tests(const RendererRenderParams *params);
EXPORTED bool renderer_backend_present_for_tests(const RendererPresentParams *params);

PyObject *py_renderer_backend_register_stub_for_tests(PyObject *self, PyObject *args);
PyObject *py_renderer_backend_render_for_tests(PyObject *self, PyObject *args, PyObject *kwargs);
PyObject *py_renderer_backend_present_for_tests(PyObject *self, PyObject *args, PyObject *kwargs);
PyObject *py_renderer_backend_current(PyObject *self, PyObject *noargs);
PyObject *py_renderer_backend_select(PyObject *self, PyObject *args);
PyObject *py_renderer_backends_available(PyObject *self, PyObject *noargs);

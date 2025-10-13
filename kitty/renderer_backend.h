#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "Python.h"
#include "data-types.h"
#include "glfw-wrapper.h"
#include "renderer_backend_types.h"

typedef struct RendererWindowConfig {
    bool is_first_window;
    bool wants_transparency;
    float background_opacity;
    color_type background_color;
} RendererWindowConfig;

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
} RendererBackendOps;

bool renderer_backend_register(RendererBackendType type, const RendererBackendOps *ops);
bool renderer_backend_select(RendererBackendType type);
RendererBackendType renderer_backend_current_type(void);
const char* renderer_backend_type_name(RendererBackendType type);
RendererBackendType renderer_backend_type_from_name(const char *name);
bool renderer_backend_attach_window(GLFWwindow *window, const RendererWindowConfig *config);
void* renderer_backend_make_context_current(GLFWwindow *window);
void renderer_backend_restore_context(void *token);
void renderer_backend_apply_swap_interval(int val);
bool renderer_backend_begin_frame(GLFWwindow *window, const RendererFrameParams *params);
bool renderer_backend_render(GLFWwindow *window, const RendererRenderParams *params);
bool renderer_backend_present(GLFWwindow *window, const RendererPresentParams *params);
void renderer_backend_on_resize(GLFWwindow *window, const RendererResizeParams *params);
void renderer_backend_on_suspend(void);
void renderer_backend_on_resume(void);
void renderer_backend_swap_buffers(GLFWwindow *window);
void renderer_backend_shutdown_active(void);
void renderer_backend_reset_for_tests(void);

PyObject *py_renderer_backend_current(PyObject *self, PyObject *noargs);
PyObject *py_renderer_backend_select(PyObject *self, PyObject *args);
PyObject *py_renderer_backends_available(PyObject *self, PyObject *noargs);

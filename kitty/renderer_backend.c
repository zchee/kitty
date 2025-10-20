#include "renderer_backend.h"

#include <stdlib.h>
#include <string.h>

#include "state.h"

typedef struct {
    const RendererBackendOps *ops;
    bool registered;
    bool initialized;
    bool have_init_cfg;
    RendererInitConfig init_cfg;
    char *label;
} RegisteredBackend;

static RegisteredBackend registered_backends[RENDERER_BACKEND_COUNT];
static RendererBackendType selected_backend = RENDERER_BACKEND_OPENGL;
static bool backend_selected = false;
static const char *const renderer_backend_names[RENDERER_BACKEND_COUNT] = {
    [RENDERER_BACKEND_OPENGL] = "opengl",
    [RENDERER_BACKEND_METAL] = "metal",
};

static inline const char*
backend_label(const RegisteredBackend *entry) {
    if (!entry || !entry->ops) {
        return "renderer backend";
    }
    if (entry->label) {
        return entry->label;
    }
    ptrdiff_t idx = entry - registered_backends;
    if (idx >= 0 && idx < RENDERER_BACKEND_COUNT) {
        const char *name = renderer_backend_names[idx];
        if (name) {
            return name;
        }
    }
    return "renderer backend";
}

static bool
validate_backend_type(RendererBackendType type) {
    return type >= 0 && type < RENDERER_BACKEND_COUNT;
}

static RegisteredBackend*
current_backend_entry(void) {
    if (!validate_backend_type(selected_backend)) {
        return NULL;
    }
    RegisteredBackend *entry = &registered_backends[selected_backend];
    return entry->registered ? entry : NULL;
}

static bool
stub_ensure_initialized(const RendererInitConfig *cfg UNUSED) {
    return true;
}

static void
stub_shutdown(void) {}

static bool
stub_attach_window(GLFWwindow *window UNUSED, const RendererWindowConfig *config UNUSED) {
    return true;
}

static void*
stub_make_context_current(GLFWwindow *window UNUSED) {
    return NULL;
}

static void
stub_restore_context(void *token UNUSED) {}

static void
stub_apply_swap_interval(int val UNUSED) {}

static bool
stub_begin_frame(GLFWwindow *window UNUSED, const RendererFrameParams *params UNUSED) {
    return true;
}

static bool
stub_render_true(GLFWwindow *window UNUSED, const RendererRenderParams *params UNUSED) {
    return true;
}

static bool
stub_present_true(GLFWwindow *window UNUSED, const RendererPresentParams *params UNUSED) {
    return true;
}

static void
stub_on_resize(GLFWwindow *window UNUSED, const RendererResizeParams *params UNUSED) {}

static void
stub_on_suspend(void) {}

static void
stub_on_resume(void) {}

static bool
stub_upload_graphics_image(struct TextureRef *ref UNUSED, const RendererGraphicsImageUpload *upload UNUSED) {
    return true;
}

static void
stub_destroy_graphics_image(struct TextureRef *ref) {
    if (!ref) {
        return;
    }
    ref->id = 0;
    ref->backend_handle = NULL;
}

bool
renderer_backend_register(RendererBackendType type, const RendererBackendOps *ops) {
    if (!validate_backend_type(type) || !ops || !ops->name) {
        PyErr_SetString(PyExc_ValueError, "renderer_backend_register received invalid arguments");
        return false;
    }
    char *label = NULL;
    size_t name_len = strlen(ops->name);
    label = malloc(name_len + 1);
    if (!label) {
        PyErr_NoMemory();
        return false;
    }
    memcpy(label, ops->name, name_len + 1);
    if (registered_backends[type].label) {
        free(registered_backends[type].label);
    }
    registered_backends[type].ops = ops;
    registered_backends[type].registered = true;
    registered_backends[type].initialized = false;
    registered_backends[type].have_init_cfg = false;
    registered_backends[type].label = label;
    if (!backend_selected) {
        selected_backend = type;
        backend_selected = true;
    }
    return true;
}

bool
renderer_backend_register_stub_for_tests(
    RendererBackendType type,
    const char *name,
    bool provide_render,
    bool provide_present
) {
    static RendererBackendOps ops = {
        .ensure_initialized = stub_ensure_initialized,
        .shutdown = stub_shutdown,
        .attach_window = stub_attach_window,
        .make_context_current = stub_make_context_current,
        .restore_context = stub_restore_context,
        .apply_swap_interval = stub_apply_swap_interval,
        .begin_frame = stub_begin_frame,
        .render = stub_render_true,
        .present = stub_present_true,
        .on_resize = stub_on_resize,
        .on_suspend = stub_on_suspend,
        .on_resume = stub_on_resume,
        .upload_graphics_image = stub_upload_graphics_image,
        .destroy_graphics_image = stub_destroy_graphics_image,
    };
    ops.name = name;
    ops.render = provide_render ? stub_render_true : NULL;
    ops.present = provide_present ? stub_present_true : NULL;
    return renderer_backend_register(type, &ops);
}

bool
renderer_backend_select(RendererBackendType type) {
    if (!validate_backend_type(type) || !registered_backends[type].registered) {
        PyErr_SetString(PyExc_ValueError, "renderer backend is not registered");
        return false;
    }
    selected_backend = type;
    backend_selected = true;
    return true;
}

RendererBackendType
renderer_backend_current_type(void) {
    if (!backend_selected) {
        return RENDERER_BACKEND_OPENGL;
    }
    return selected_backend;
}

const char*
renderer_backend_type_name(RendererBackendType type) {
    if (!validate_backend_type(type) || !registered_backends[type].registered) {
        return NULL;
    }
    return renderer_backend_names[type];
}

RendererBackendType
renderer_backend_type_from_name(const char *name) {
    if (!name) {
        return (RendererBackendType)-1;
    }
    for (RendererBackendType t = 0; t < RENDERER_BACKEND_COUNT; t++) {
        if (registered_backends[t].registered) {
            const char *candidate = renderer_backend_names[t];
            if (candidate && strcmp(candidate, name) == 0) {
                return t;
            }
            const char *alt = registered_backends[t].ops->name;
            if (alt && strcmp(alt, name) == 0) {
                return t;
            }
        }
    }
    return (RendererBackendType)-1;
}

static RendererInitConfig
current_init_config(void) {
    RendererInitConfig cfg = {
        .prefer_low_latency = !OPT(sync_to_monitor),
        .enable_debug_labels = global_state.debug_rendering,
    };
    return cfg;
}

static bool
ensure_backend_ready(RegisteredBackend *entry, const RendererInitConfig *cfg) {
    if (!entry) {
        PyErr_SetString(PyExc_RuntimeError, "Renderer backend not selected");
        return false;
    }
    if (!entry->ops) {
        PyErr_SetString(PyExc_RuntimeError, "Renderer backend has no registered operations");
        return false;
    }
    if (!entry->ops->ensure_initialized) {
        entry->initialized = true;
        entry->init_cfg = *cfg;
        entry->have_init_cfg = true;
        return true;
    }
    if (!entry->initialized || !entry->have_init_cfg || memcmp(&entry->init_cfg, cfg, sizeof(RendererInitConfig)) != 0) {
        if (!entry->ops->ensure_initialized(cfg)) {
            return false;
        }
        entry->initialized = true;
        entry->init_cfg = *cfg;
        entry->have_init_cfg = true;
    }
    return true;
}

bool
renderer_backend_attach_window(GLFWwindow *window, const RendererWindowConfig *config) {
    RegisteredBackend *entry = current_backend_entry();
    RendererInitConfig init_cfg = current_init_config();
    void *ctx_token = NULL;
    if (entry && entry->ops && entry->ops->make_context_current) {
        ctx_token = entry->ops->make_context_current(window);
    }
    bool restore_context = entry && entry->ops && entry->ops->restore_context && ctx_token;
    bool ok = ensure_backend_ready(entry, &init_cfg);
    if (ok && entry->ops->attach_window) {
        ok = entry->ops->attach_window(window, config);
    }
    if (restore_context) {
        entry->ops->restore_context(ctx_token);
    }
    return ok;
}

void*
renderer_backend_make_context_current(GLFWwindow *window) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops || !entry->ops->make_context_current) {
        return NULL;
    }
    return entry->ops->make_context_current(window);
}

void
renderer_backend_restore_context(void *token) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops || !entry->ops->restore_context) {
        return;
    }
    entry->ops->restore_context(token);
}

void
renderer_backend_apply_swap_interval(int val) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops || !entry->ops->apply_swap_interval) {
        return;
    }
    entry->ops->apply_swap_interval(val);
}

bool
renderer_backend_begin_frame(GLFWwindow *window, const RendererFrameParams *params) {
    RegisteredBackend *entry = current_backend_entry();
    RendererInitConfig init_cfg = current_init_config();
    if (!ensure_backend_ready(entry, &init_cfg)) {
        return false;
    }
    if (!entry->ops) {
        PyErr_SetString(PyExc_RuntimeError, "Renderer backend has no registered operations");
        return false;
    }
    if (entry->ops->begin_frame) {
        return entry->ops->begin_frame(window, params);
    }
    return true;
}

bool
renderer_backend_render(GLFWwindow *window, const RendererRenderParams *params) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops) {
        PyErr_SetString(PyExc_RuntimeError, "Renderer backend not selected");
        return false;
    }
    if (!entry->ops->render) {
        PyErr_Format(PyExc_RuntimeError, "%s backend does not implement render()", backend_label(entry));
        return false;
    }
    return entry->ops->render(window, params);
}

bool
renderer_backend_present(GLFWwindow *window, const RendererPresentParams *params) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops) {
        PyErr_SetString(PyExc_RuntimeError, "Renderer backend not selected");
        return false;
    }
    if (!entry->ops->present) {
        PyErr_Format(PyExc_RuntimeError, "%s backend does not implement present()", backend_label(entry));
        return false;
    }
    return entry->ops->present(window, params);
}

bool
renderer_backend_render_for_tests(const RendererRenderParams *params) {
    return renderer_backend_render(NULL, params);
}

bool
renderer_backend_present_for_tests(const RendererPresentParams *params) {
    return renderer_backend_present(NULL, params);
}

void
renderer_backend_on_resize(GLFWwindow *window, const RendererResizeParams *params) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops || !entry->ops->on_resize) {
        return;
    }
    entry->ops->on_resize(window, params);
}

void
renderer_backend_on_suspend(void) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops || !entry->ops->on_suspend) {
        return;
    }
    entry->ops->on_suspend();
}

void
renderer_backend_on_resume(void) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops || !entry->ops->on_resume) {
        return;
    }
    entry->ops->on_resume();
}

void
renderer_backend_swap_buffers(GLFWwindow *window) {
    RendererPresentParams params = {
        .blocking = true,
        .capture_framebuffer = false,
    };
    (void)renderer_backend_present(window, &params);
}

bool
renderer_backend_upload_graphics_image(struct TextureRef *ref, const RendererGraphicsImageUpload *upload) {
    if (!ref || !upload) {
        PyErr_SetString(PyExc_RuntimeError, "Invalid arguments to renderer_backend_upload_graphics_image");
        return false;
    }
    RegisteredBackend *entry = current_backend_entry();
    RendererInitConfig init_cfg = current_init_config();
    if (!ensure_backend_ready(entry, &init_cfg)) {
        return false;
    }
    if (!entry->ops || !entry->ops->upload_graphics_image) {
        PyErr_Format(PyExc_RuntimeError, "%s backend does not implement graphics image upload", backend_label(entry));
        return false;
    }
    if (!entry->ops->upload_graphics_image(ref, upload)) {
        return false;
    }
    return true;
}

void
renderer_backend_destroy_graphics_image(struct TextureRef *ref) {
    if (!ref) {
        return;
    }
    RegisteredBackend *entry = current_backend_entry();
    if (entry && entry->ops && entry->ops->destroy_graphics_image) {
        entry->ops->destroy_graphics_image(ref);
    } else {
        ref->id = 0;
        ref->backend_handle = NULL;
    }
}

void
renderer_backend_shutdown_active(void) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry) {
        return;
    }
    if (entry->ops && entry->ops->shutdown) {
        entry->ops->shutdown();
    }
    entry->initialized = false;
    entry->have_init_cfg = false;
}

void
renderer_backend_reset_for_tests(void) {
    for (RendererBackendType t = 0; t < RENDERER_BACKEND_COUNT; t++) {
        registered_backends[t].initialized = false;
        registered_backends[t].have_init_cfg = false;
        if (registered_backends[t].label) {
            free(registered_backends[t].label);
            registered_backends[t].label = NULL;
        }
    }
    backend_selected = false;
    selected_backend = RENDERER_BACKEND_OPENGL;
}

PyObject*
py_renderer_backend_register_stub_for_tests(PyObject *self UNUSED, PyObject *args) {
    const char *name = NULL;
    int type_int = RENDERER_BACKEND_METAL;
    int provide_render = 1;
    int provide_present = 1;
    if (!PyArg_ParseTuple(args, "s|ipp", &name, &type_int, &provide_render, &provide_present)) {
        return NULL;
    }
    RendererBackendType type = (RendererBackendType)type_int;
    if (!validate_backend_type(type)) {
        PyErr_SetString(PyExc_ValueError, "renderer_backend_register_stub_for_tests received invalid backend type");
        return NULL;
    }
    if (!renderer_backend_register_stub_for_tests(type, name, provide_render != 0, provide_present != 0)) {
        return NULL;
    }
    Py_RETURN_NONE;
}

PyObject*
py_renderer_backend_render_for_tests(PyObject *self UNUSED, PyObject *args, PyObject *kwargs) {
    static char *kwlist[] = {
        "active_window_id",
        "active_window_bg",
        "num_visible_windows",
        "all_windows_have_same_bg",
        NULL
    };
    unsigned int active_window_id = 0;
    unsigned int active_window_bg = 0;
    unsigned int num_visible_windows = 0;
    int all_same_bg = 0;
    if (!PyArg_ParseTupleAndKeywords(
            args,
            kwargs,
            "|IIIp",
            kwlist,
            &active_window_id,
            &active_window_bg,
            &num_visible_windows,
            &all_same_bg)) {
        return NULL;
    }
    RendererRenderParams params = {
        .os_window = NULL,
        .active_window_id = active_window_id,
        .active_window_bg = active_window_bg,
        .num_visible_windows = num_visible_windows,
        .all_windows_have_same_bg = all_same_bg != 0,
    };
    if (!renderer_backend_render_for_tests(&params)) {
        if (PyErr_Occurred()) {
            return NULL;
        }
        Py_RETURN_FALSE;
    }
    Py_RETURN_TRUE;
}

PyObject*
py_renderer_backend_present_for_tests(PyObject *self UNUSED, PyObject *args, PyObject *kwargs) {
    static char *kwlist[] = {
        "blocking",
        "capture_framebuffer",
        NULL
    };
    int blocking = 1;
    int capture_framebuffer = 0;
    if (!PyArg_ParseTupleAndKeywords(
            args,
            kwargs,
            "|pp",
            kwlist,
            &blocking,
            &capture_framebuffer)) {
        return NULL;
    }
    RendererPresentParams params = {
        .blocking = blocking != 0,
        .capture_framebuffer = capture_framebuffer != 0,
    };
    if (!renderer_backend_present_for_tests(&params)) {
        if (PyErr_Occurred()) {
            return NULL;
        }
        Py_RETURN_FALSE;
    }
    Py_RETURN_TRUE;
}

PyObject*
py_renderer_backend_current(PyObject *self UNUSED, PyObject *noargs UNUSED) {
    const char *name = renderer_backend_type_name(renderer_backend_current_type());
    if (!name) {
        Py_RETURN_NONE;
    }
    return PyUnicode_FromString(name);
}

PyObject*
py_renderer_backend_select(PyObject *self UNUSED, PyObject *args) {
    const char *name = NULL;
    if (!PyArg_ParseTuple(args, "s", &name)) {
        return NULL;
    }
    RendererBackendType type = renderer_backend_type_from_name(name);
    if (type == (RendererBackendType)-1) {
        PyErr_Format(PyExc_ValueError, "Unknown renderer backend: %s", name);
        return NULL;
    }
    if (!renderer_backend_select(type)) {
        return NULL;
    }
    Py_RETURN_NONE;
}

PyObject*
py_renderer_backends_available(PyObject *self UNUSED, PyObject *noargs UNUSED) {
    PyObject *list = PyList_New(0);
    if (!list) {
        return NULL;
    }
    for (RendererBackendType t = 0; t < RENDERER_BACKEND_COUNT; t++) {
        if (registered_backends[t].registered) {
            const char *name = renderer_backend_type_name(t);
            if (!name) {
                name = registered_backends[t].ops ? registered_backends[t].ops->name : NULL;
            }
            if (!name) continue;
            PyObject *py_name = PyUnicode_FromString(name);
            if (!py_name) {
                Py_DECREF(list);
                return NULL;
            }
            if (PyList_Append(list, py_name) != 0) {
                Py_DECREF(py_name);
                Py_DECREF(list);
                return NULL;
            }
            Py_DECREF(py_name);
        }
    }
    return list;
}

#include "renderer_backend.h"

#include <string.h>

#include "state.h"

typedef struct {
    const RendererBackendOps *ops;
    bool registered;
    bool initialized;
    bool have_init_cfg;
    RendererInitConfig init_cfg;
} RegisteredBackend;

static RegisteredBackend registered_backends[RENDERER_BACKEND_COUNT];
static RendererBackendType selected_backend = RENDERER_BACKEND_OPENGL;
static bool backend_selected = false;

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

bool
renderer_backend_register(RendererBackendType type, const RendererBackendOps *ops) {
    if (!validate_backend_type(type) || !ops || !ops->name) {
        PyErr_SetString(PyExc_ValueError, "renderer_backend_register received invalid arguments");
        return false;
    }
    registered_backends[type].ops = ops;
    registered_backends[type].registered = true;
    registered_backends[type].initialized = false;
    registered_backends[type].have_init_cfg = false;
    if (!backend_selected) {
        selected_backend = type;
        backend_selected = true;
    }
    return true;
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
    return registered_backends[type].ops->name;
}

RendererBackendType
renderer_backend_type_from_name(const char *name) {
    if (!name) {
        return (RendererBackendType)-1;
    }
    for (RendererBackendType t = 0; t < RENDERER_BACKEND_COUNT; t++) {
        if (registered_backends[t].registered) {
            const char *candidate = registered_backends[t].ops->name;
            if (candidate && strcmp(candidate, name) == 0) {
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
    if (entry && entry->ops->make_context_current) {
        ctx_token = entry->ops->make_context_current(window);
    }
    bool restore_context = entry && entry->ops->restore_context && ctx_token;
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
    if (!entry || !entry->ops->make_context_current) {
        return NULL;
    }
    return entry->ops->make_context_current(window);
}

void
renderer_backend_restore_context(void *token) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops->restore_context) {
        return;
    }
    entry->ops->restore_context(token);
}

void
renderer_backend_apply_swap_interval(int val) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops->apply_swap_interval) {
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
    if (entry->ops->begin_frame) {
        return entry->ops->begin_frame(window, params);
    }
    return true;
}

bool
renderer_backend_render(GLFWwindow *window, const RendererRenderParams *params) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops->render) {
        PyErr_SetString(PyExc_RuntimeError, "Renderer backend does not implement render()");
        return false;
    }
    return entry->ops->render(window, params);
}

bool
renderer_backend_present(GLFWwindow *window, const RendererPresentParams *params) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry) {
        return false;
    }
    if (!entry->ops->present) {
        PyErr_SetString(PyExc_RuntimeError, "Renderer backend does not implement present()");
        return false;
    }
    return entry->ops->present(window, params);
}

void
renderer_backend_on_resize(GLFWwindow *window, const RendererResizeParams *params) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops->on_resize) {
        return;
    }
    entry->ops->on_resize(window, params);
}

void
renderer_backend_on_suspend(void) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops->on_suspend) {
        return;
    }
    entry->ops->on_suspend();
}

void
renderer_backend_on_resume(void) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry || !entry->ops->on_resume) {
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

void
renderer_backend_shutdown_active(void) {
    RegisteredBackend *entry = current_backend_entry();
    if (!entry) {
        return;
    }
    if (entry->ops->shutdown) {
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
    }
    backend_selected = false;
    selected_backend = RENDERER_BACKEND_OPENGL;
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
            const char *name = registered_backends[t].ops->name;
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

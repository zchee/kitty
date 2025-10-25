#include "opengl_renderer.h"

#include "glfw-wrapper.h"
#include "renderer_backend.h"
#include "state.h"
#include "gl.h"
#include "opengl_renderer_priv.h"

#ifdef KITTY_DISABLE_NSGL

bool
register_opengl_renderer_backend(void) {
    PyErr_SetString(PyExc_RuntimeError, "OpenGL renderer backend is not supported on macOS");
    return false;
}

#else
#ifndef __APPLE__
static bool gl_backend_initialized = false;

static bool
opengl_backend_ensure_initialized(const RendererInitConfig *cfg UNUSED) {
    if (!gl_backend_initialized) {
        gl_init();
        gl_backend_initialized = true;
    }
    return true;
}

static void
opengl_backend_shutdown(void) {
    gl_backend_initialized = false;
}

static void*
opengl_backend_make_context_current(GLFWwindow *window) {
    GLFWwindow *current = glfwGetCurrentContext();
    if (current != window) {
        glfwMakeContextCurrent(window);
        return current;
    }
    return NULL;
}

static void
opengl_backend_restore_context(void *token) {
    GLFWwindow *previous = (GLFWwindow *)token;
    if (previous || glfwGetCurrentContext() != NULL) {
        glfwMakeContextCurrent(previous);
    }
}

static bool
opengl_backend_attach_window(GLFWwindow *window, const RendererWindowConfig *config) {
    const bool is_transparent = glfwGetWindowAttrib(window, GLFW_TRANSPARENT_FRAMEBUFFER);
    const float clear_alpha = is_transparent ? config->background_opacity : 1.0f;
    blank_canvas(clear_alpha, config->background_color, true);
    return true;
}

static void
opengl_backend_apply_swap_interval(int val) {
#ifndef __APPLE__
    if (val < 0) {
        val = OPT(sync_to_monitor) && !global_state.is_wayland ? 1 : 0;
    }
    glfwSwapInterval(val);
#else
    (void)val;
#endif
}

static void
opengl_backend_swap_buffers(GLFWwindow *window) {
    glfwSwapBuffers(window);
}

static bool
opengl_backend_begin_frame(GLFWwindow *window UNUSED, const RendererFrameParams *params UNUSED) {
    return true;
}

static bool
opengl_backend_render(GLFWwindow *window UNUSED, const RendererRenderParams *params) {
    if (!params || !params->os_window) {
        PyErr_SetString(PyExc_RuntimeError, "OpenGL backend render requires a valid OSWindow");
        return false;
    }
    OSWindow *os_window = params->os_window;
    Tab *tab = os_window->tabs + os_window->active_tab;

#define TD os_window->tab_bar_render_data
    setup_os_window_for_rendering(os_window, tab, NULL, true);
    BorderRects *br = &tab->border_rects;
    draw_borders(
        br->vao_idx,
        br->num_border_rects,
        br->rect_buf,
        br->is_dirty,
        params->active_window_bg,
        params->num_visible_windows,
        params->all_windows_have_same_bg,
        os_window
    );
    br->is_dirty = false;

    if (TD.screen && os_window->num_tabs >= OPT(tab_bar_min_tabs)) {
        draw_cells(&TD, os_window, true, true, false, NULL);
    }

    unsigned int computed_visible = 0;
    for (unsigned int i = 0; i < tab->num_windows; i++) {
        Window *w = tab->windows + i;
        if (w->visible && w->render_data.screen) {
            computed_visible++;
        }
    }
    const unsigned int visible_windows =
        params->num_visible_windows ? params->num_visible_windows : computed_visible;

    Window *active_window = NULL;
    for (unsigned int i = 0; i < tab->num_windows; i++) {
        Window *w = tab->windows + i;
#define WD w->render_data
        if (w->visible && WD.screen) {
            const bool is_active_window = i == tab->active_window;
            if (is_active_window) {
                active_window = w;
            }
            draw_cells(
                &WD,
                os_window,
                is_active_window,
                false,
                visible_windows == 1,
                w
            );
        }
#undef WD
    }

    setup_os_window_for_rendering(os_window, tab, active_window, false);
#undef TD
    return true;
}

static bool
opengl_backend_present(GLFWwindow *window, const RendererPresentParams *params UNUSED) {
    opengl_backend_swap_buffers(window);
    return true;
}

static void
opengl_backend_on_resize(GLFWwindow *window UNUSED, const RendererResizeParams *params) {
    set_gpu_viewport((unsigned)params->framebuffer_width, (unsigned)params->framebuffer_height);
}

static void
opengl_backend_on_suspend(void) {
}

static void
opengl_backend_on_resume(void) {
}

static bool
opengl_backend_upload_graphics_image(TextureRef *ref, const RendererGraphicsImageUpload *upload) {
    if (!ref || !upload) {
        PyErr_SetString(PyExc_RuntimeError, "OpenGL graphics upload received invalid arguments");
        return false;
    }
    GLuint texture = ref->id;
    send_image_to_gpu(&texture,
                      upload->pixels,
                      upload->width,
                      upload->height,
                      upload->is_opaque,
                      upload->is_4byte_aligned,
                      upload->linear_filter,
                      upload->repeat);
    ref->id = texture;
    ref->backend_handle = NULL;
    return true;
}

static void
opengl_backend_destroy_graphics_image(TextureRef *ref) {
    if (!ref) {
        return;
    }
    if (ref->id) {
        free_texture(&ref->id);
    }
    ref->backend_handle = NULL;
}

#endif /* __APPLE__ */

bool
register_opengl_renderer_backend(void) {
    static const RendererBackendOps opengl_ops = {
        .name = "opengl",
        .ensure_initialized = opengl_backend_ensure_initialized,
        .shutdown = opengl_backend_shutdown,
        .attach_window = opengl_backend_attach_window,
        .make_context_current = opengl_backend_make_context_current,
        .restore_context = opengl_backend_restore_context,
        .apply_swap_interval = opengl_backend_apply_swap_interval,
        .begin_frame = opengl_backend_begin_frame,
        .render = opengl_backend_render,
        .present = opengl_backend_present,
        .on_resize = opengl_backend_on_resize,
        .on_suspend = opengl_backend_on_suspend,
        .on_resume = opengl_backend_on_resume,
        .upload_graphics_image = opengl_backend_upload_graphics_image,
        .destroy_graphics_image = opengl_backend_destroy_graphics_image,
    };
    return renderer_backend_register(RENDERER_BACKEND_OPENGL, &opengl_ops);
}

#endif /* KITTY_DISABLE_NSGL */

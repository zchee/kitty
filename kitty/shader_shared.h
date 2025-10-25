#pragma once

#include <Python.h>

/*
 * Shared shader metadata to keep the OpenGL shim and the Metal backend stubs
 * aligned. The OpenGL implementation in shaders.c and the Metal build stubs in
 * opengl_disabled.c both consume these definitions to avoid diverging enums or
 * exported symbol lists while the project migrates away from OpenGL.
 */

enum RendererShaderProgramId {
    CELL_PROGRAM,
    CELL_FG_PROGRAM,
    CELL_BG_PROGRAM,
    BORDERS_PROGRAM,
    GRAPHICS_PROGRAM,
    GRAPHICS_PREMULT_PROGRAM,
    GRAPHICS_ALPHA_MASK_PROGRAM,
    BGIMAGE_PROGRAM,
    TINT_PROGRAM,
    TRAIL_PROGRAM,
    BLIT_PROGRAM,
    ROUNDED_RECT_PROGRAM,
    NUM_PROGRAMS
};

enum RendererShaderBindingUnit {
    SPRITE_MAP_UNIT,
    GRAPHICS_UNIT,
    SPRITE_DECORATIONS_MAP_UNIT
};

#define RENDERER_SHADER_MODULE_METHODS(M, MW) \
    M(compile_program, METH_VARARGS)         \
    M(sprite_map_set_limits, METH_VARARGS)   \
    MW(create_vao, METH_NOARGS)              \
    MW(gpu_driver_version_string, METH_NOARGS) \
    MW(bind_vertex_array, METH_O)            \
    MW(unbind_vertex_array, METH_NOARGS)     \
    MW(unmap_vao_buffer, METH_VARARGS)       \
    MW(bind_program, METH_O)                 \
    MW(unbind_program, METH_NOARGS)          \
    MW(init_borders_program, METH_NOARGS)    \
    MW(init_cell_program, METH_NOARGS)

#define RENDERER_SHADER_PROGRAM_CONSTANTS(X)      \
    X(CELL_PROGRAM)                               \
    X(CELL_FG_PROGRAM)                            \
    X(CELL_BG_PROGRAM)                            \
    X(BORDERS_PROGRAM)                            \
    X(GRAPHICS_PROGRAM)                           \
    X(GRAPHICS_PREMULT_PROGRAM)                   \
    X(GRAPHICS_ALPHA_MASK_PROGRAM)                \
    X(BGIMAGE_PROGRAM)                            \
    X(TINT_PROGRAM)                               \
    X(TRAIL_PROGRAM)                              \
    X(BLIT_PROGRAM)                               \
    X(ROUNDED_RECT_PROGRAM)

#define RENDERER_GL_COMPAT_CONSTANTS(X)           \
    X(GLSL_VERSION)                               \
    X(GL_VERSION)                                 \
    X(GL_VENDOR)                                  \
    X(GL_SHADING_LANGUAGE_VERSION)                \
    X(GL_RENDERER)                                \
    X(GL_TRIANGLE_FAN)                            \
    X(GL_TRIANGLE_STRIP)                          \
    X(GL_TRIANGLES)                               \
    X(GL_LINE_LOOP)                               \
    X(GL_COLOR_BUFFER_BIT)                        \
    X(GL_VERTEX_SHADER)                           \
    X(GL_FRAGMENT_SHADER)                         \
    X(GL_TRUE)                                    \
    X(GL_FALSE)                                   \
    X(GL_COMPILE_STATUS)                          \
    X(GL_LINK_STATUS)                             \
    X(GL_MAX_ARRAY_TEXTURE_LAYERS)                \
    X(GL_TEXTURE_BINDING_BUFFER)                  \
    X(GL_MAX_TEXTURE_BUFFER_SIZE)                 \
    X(GL_MAX_TEXTURE_SIZE)                        \
    X(GL_TEXTURE_2D_ARRAY)                        \
    X(GL_LINEAR)                                  \
    X(GL_CLAMP_TO_EDGE)                           \
    X(GL_NEAREST)                                 \
    X(GL_TEXTURE_MIN_FILTER)                      \
    X(GL_TEXTURE_MAG_FILTER)                      \
    X(GL_TEXTURE_WRAP_S)                          \
    X(GL_TEXTURE_WRAP_T)                          \
    X(GL_UNPACK_ALIGNMENT)                        \
    X(GL_R8)                                      \
    X(GL_RED)                                     \
    X(GL_UNSIGNED_BYTE)                           \
    X(GL_UNSIGNED_SHORT)                          \
    X(GL_R32UI)                                   \
    X(GL_RGB32UI)                                 \
    X(GL_RGBA)                                    \
    X(GL_TEXTURE_BUFFER)                          \
    X(GL_STATIC_DRAW)                             \
    X(GL_STREAM_DRAW)                             \
    X(GL_DYNAMIC_DRAW)                            \
    X(GL_SRC_ALPHA)                               \
    X(GL_ONE_MINUS_SRC_ALPHA)                     \
    X(GL_WRITE_ONLY)                              \
    X(GL_READ_ONLY)                               \
    X(GL_READ_WRITE)                              \
    X(GL_BLEND)                                   \
    X(GL_FLOAT)                                   \
    X(GL_UNSIGNED_INT)                            \
    X(GL_ARRAY_BUFFER)                            \
    X(GL_UNIFORM_BUFFER)

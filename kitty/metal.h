/*
 * metal.h
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#include "data-types.h"
#include "metal_uniforms.h"

// Type aliases to replace OpenGL types in shared code
typedef uint32_t GLuint;
typedef int32_t GLint;
typedef int32_t GLsizei;
typedef intptr_t GLsizeiptr;
typedef unsigned int GLenum;
typedef float GLfloat;

// Stub GL constants needed by shared code
#define GL_ARRAY_BUFFER     0x8892
#define GL_UNIFORM_BUFFER   0x8A11
#define GL_STREAM_DRAW      0x88E0
#define GL_STATIC_DRAW      0x88E4
#define GL_DYNAMIC_DRAW     0x88E8
#define GL_UNSIGNED_BYTE    0x1401
#define GL_UNSIGNED_SHORT   0x1403
#define GL_UNSIGNED_INT     0x1405
#define GL_FLOAT            0x1406
#define GL_INT              0x1404
#define GL_BYTE             0x1400
#define GL_SHORT            0x1402
#define GL_WRITE_ONLY       0x88B9
#define GL_READ_ONLY        0x88B8
#define GL_READ_WRITE       0x88BA
#define GL_TEXTURE_2D       0x0DE1
#define GL_TEXTURE_2D_ARRAY 0x8C1A
#define GL_BLEND            0x0BE2
#define GL_RGBA             0x1908
#define GL_RGB              0x1907
#define GL_RED              0x1903
#define GL_RED_INTEGER      0x8D94
#define GL_R8               0x8229
#define GL_R32UI            0x8236
#define GL_RGB32UI          0x8D71
#define GL_SRGB_ALPHA       0x8C42
#define GL_SRGB8_ALPHA8     0x8C43
#define GL_RGBA16           0x805B
// W27 P4.2: the internal format for an f=3232 (float RGBA) graphics image --
// MTLPixelFormatRGBA32Float. The only image storage in this pipeline that can
// carry the >1.0 components EDR content is made of.
#define GL_RGBA32F          0x8814
#define GL_NEAREST          0x2600
#define GL_LINEAR           0x2601
#define GL_CLAMP_TO_EDGE    0x812F
#define GL_CLAMP_TO_BORDER  0x812D
#define GL_REPEAT           0x2901
#define GL_MIRRORED_REPEAT  0x8370
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_WRAP_S   0x2802
#define GL_TEXTURE_WRAP_T   0x2803
#define GL_UNPACK_ALIGNMENT 0x0CF5
#define GL_PACK_ALIGNMENT   0x0D05
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_VERTEX_SHADER    0x8B31
#define GL_FRAGMENT_SHADER  0x8B30
#define GL_TRUE             1
#define GL_FALSE            0
#define GL_COMPILE_STATUS   0x8B81
#define GL_LINK_STATUS      0x8B82
#define GL_MAX_ARRAY_TEXTURE_LAYERS 0x88FF
#define GL_MAX_TEXTURE_SIZE 0x0D33
#define GL_TEXTURE_BINDING_BUFFER 0x8C2C
#define GL_MAX_TEXTURE_BUFFER_SIZE 0x8C2B
#define GL_TEXTURE_BUFFER   0x8C2A
#define GL_FRAMEBUFFER      0x8D40
#define GL_FRAMEBUFFER_SRGB 0x8DB9
#define GL_SCISSOR_TEST     0x0C11
#define GL_TRIANGLE_FAN     0x0006
#define GL_TRIANGLE_STRIP   0x0005
#define GL_TRIANGLES        0x0004
#define GL_LINE_LOOP        0x0002
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_SRC_ALPHA        0x0302
#define GL_ONE_MINUS_SRC_ALPHA 0x0303
#define GL_ONE              1     // F1: R8-atlas swizzle source (RGB<-ONE)
#define GL_NO_ERROR         0
#define GL_VIEWPORT         0x0BA2
#define GL_INVALID_INDEX    0xFFFFFFFF
#define GL_TEXTURE_DEPTH    0x8071
#define GL_TEXTURE_WIDTH    0x1000
#define GL_TEXTURE_HEIGHT   0x1001
#define GL_TEXTURE_INTERNAL_FORMAT 0x1003
#define GL_TEXTURE_BORDER_COLOR 0x1004
#define GL_UNIFORM_SIZE     0x8A38
#define GL_UNIFORM_OFFSET   0x8A3C
#define GL_UNIFORM_ARRAY_STRIDE 0x8A3D
#define GL_UNIFORM_BLOCK_DATA_SIZE 0x8A40
#define GL_DRAW_FRAMEBUFFER_BINDING 0x8CA6
#define GL_MAP_WRITE_BIT    0x0002
#define GL_MAP_INVALIDATE_RANGE_BIT 0x0004
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_TEXTURE_BINDING_2D 0x8069
#define GL_UNSIGNED_INT_8_8_8_8 0x8035
#define GL_R8UI             0x8232
#define GL_R8I              0x8231
#define GL_R16UI            0x8234
#define GL_R16I             0x8233
#define GL_R32I             0x8235
#define GL_RG8UI            0x8238
#define GL_RG8I             0x8237
#define GL_RG16UI           0x823A
#define GL_RG16I            0x8239
#define GL_RG32UI           0x823C
#define GL_RG32I            0x823B
#define GL_RGB8UI           0x8D7D
#define GL_RGB8I            0x8D8F
#define GL_RGB16UI          0x8D77
#define GL_RGB16I           0x8D89
#define GL_RGB32I           0x8D83
#define GL_RGBA8UI          0x8D7C
#define GL_RGBA8I           0x8D8E
#define GL_RGBA16UI         0x8D76
#define GL_RGBA16I          0x8D88
#define GL_RGBA32UI         0x8D70
#define GL_RGBA32I          0x8D82
#define GL_VERSION          0x1F02
#define GL_VENDOR           0x1F00
#define GL_RENDERER         0x1F01
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C

// GLchar/GLbitfield typedefs — needed before function declarations below
typedef char GLchar;
typedef unsigned int GLbitfield;

// GL_TEXTURE0 base and related
#define GL_TEXTURE0 0x84C0
#define GL_ACTIVE_UNIFORMS 0x8B86

// Uniform block info (same struct name as GL for compatibility)
typedef struct {
    GLint size, index;
} UniformBlock;

typedef struct {
    GLint offset, stride, size;
} ArrayInformation;

typedef struct {
    char name[256];
    GLint size, location, idx;
    GLenum type;
} Uniform;

typedef struct {
    GLuint id;
    Uniform uniforms[256];
    GLint num_of_uniforms;
} Program;

typedef struct Viewport { unsigned left, top, width, height; } Viewport;

// Metal backend public API — mirrors gl.h signatures
void gl_init(void);
const char* gl_version_string(void);
void set_gpu_viewport(unsigned w, unsigned h);
Viewport get_gpu_viewport(void);
void draw_quad(bool blend, unsigned instance_count);
void save_texture_as_png(uint32_t texture_id, const char *filename);
void free_texture(GLuint *tex_id);
void free_framebuffer(GLuint *fb_id);
void remove_vao(ssize_t vao_idx);
void init_uniforms(int program);
GLuint program_id(int program);
Program* program_ptr(int program);
GLuint block_index(int program, const char *name);
GLint block_size(int program, GLuint block_index);
GLint get_uniform_location(int program, const char *name);
GLint get_uniform_information(int program, const char *name, GLenum information_type);
GLint attrib_location(int program, const char *name);
ssize_t create_vao(void);
size_t add_buffer_to_vao(ssize_t vao_idx, GLenum usage);
void add_attribute_to_vao(int p, ssize_t vao_idx, const char *name, GLint size, GLenum data_type, GLsizei stride, void *offset, GLuint divisor);
ssize_t alloc_vao_buffer(ssize_t vao_idx, GLsizeiptr size, size_t bufnum, GLenum usage);
void* alloc_and_map_vao_buffer(ssize_t vao_idx, GLsizeiptr size, size_t bufnum, bool frequently_updated);
void unmap_vao_buffer(ssize_t vao_idx, size_t bufnum);
void* map_vao_buffer(ssize_t vao_idx, size_t bufnum, GLenum access);
void* map_vao_buffer_for_write_only(ssize_t vao_idx, size_t bufnum, int offset, unsigned size);
bool metal_cell_ring_take_fresh(ssize_t vao_idx, size_t bufnum); // D2: was the current cell ring slot just (re)allocated?
void metal_note_upload_bytes(uint64_t n);                        // D2: accumulate this frame's VAO-buffer upload bytes
void bind_program(int program);
void bind_vertex_array(ssize_t vao_idx);
void bind_vao_uniform_buffer(ssize_t vao_idx, size_t bufnum, GLuint block_index);
void unbind_vertex_array(void);
void unbind_program(void);
GLuint compile_shaders(GLenum shader_type, GLsizei count, const GLchar * const * string);
void save_viewport_using_top_left_origin(GLsizei x, GLsizei y, GLsizei width, GLsizei height, GLsizei full_framebuffer_height);
void save_viewport_using_bottom_left_origin(GLsizei x, GLsizei y, GLsizei width, GLsizei height);
const char* check_framebuffer_status(void);
void restore_viewport(void);
void bind_framebuffer_for_output(unsigned fbid);
void set_framebuffer_to_use_for_output(unsigned fbid);
void enable_scissor_using_top_left_origin(Viewport, unsigned);
void disable_scissor(void);

// Metal-specific functions not in gl.h
void metal_end_frame(void);
void metal_set_current_layer(void *layer);
void* metal_get_device(void);

// Phase 4 (L1): hand the CAMetalDisplayLink-delivered drawable (id<CAMetalDrawable>
// as void*) to the renderer for the current frame. When set, ensure_drawable()
// uses it instead of blocking in nextDrawable, so drawable_wait_ms is structurally
// 0 (the wait is absorbed by the link scheduling its callback). Pass NULL to clear
// after the frame; non-link paths (golden dump, live resize) leave it NULL and
// keep the nextDrawable path.
void metal_set_link_drawable(void *drawable);

bool metal_immediate_encode_enabled(void);  // true under timer pace (L2 intrinsic once no link owns the drawable pool)
bool metal_timer_pace_enabled(void);        // W27 P2.4a: drive the drawable arm with the plain pace timer (no CAMetalDisplayLink)
void metal_forget_layer(void *layer);       // window teardown: free the per-window state slot

// M1: single-pass layered rendering. metal_begin_layered_frame opens ONE render
// pass whose color attachment 0 is a memoryless RGBA16Unorm working surface
// (tile-only, never DRAM) and attachment 1 is the drawable; all subsequent
// layered compositing draws render linear-premultiplied into att0 through the
// existing shaders/blend. metal_resolve_layered_frame issues the in-pass resolve
// (att0 -> att1: unpremultiply, linear->sRGB, premultiply) and ends the pass,
// replacing the old RGBA16 DRAM FBO + separate BLIT pass. Called only from the
// KITTY_BACKEND_METAL branch of start/stop_os_window_rendering; the GL backend
// keeps the FBO+blit path.
void metal_begin_layered_frame(void);
void metal_resolve_layered_frame(void);
// W27 P4.2: publish the OS window's EDR state for the frame about to be encoded.
// Selects the layered working-surface format (RGBA16Float while engaged, so
// >1.0 components survive to the drawable; RGBA16Unorm otherwise).
void metal_set_edr_frame_state(bool engaged, float headroom);

// H3 (W28.4a): run one render tick's per-window loop inside a single
// autorelease pool, with the drain barrier as the pool's last statement. The
// caller hands the loop over as a callback because @autoreleasepool is
// lexically scoped and child-monitor.c is plain C.
void metal_render_tick(void (*body)(void *), void *ctx);

// W27 P3.4 (chain 2): the cell-program options Python resolves from the config
// (text_composition_strategy, text_fg_override_threshold). GL bakes them into
// the GLSL via cell_defines.glsl; Metal takes them as function constants, so
// they are handed over directly instead of being scraped back out of the
// preprocessed shader source. Rebuilds the cell pipeline states iff a value
// actually changed. Routed from set_cell_shader_opts() in kitty/shaders.c.
void metal_set_cell_shader_opts(bool do_fg_override, int fg_override_algo, float fg_override_threshold, bool text_new_gamma);

// Stub GL functions called directly in shaders.c — these become no-ops or
// map to Metal equivalents in metal.m
// Note: glUniform* calls are used extensively in shaders.c; in Metal these
// become setVertexBytes/setFragmentBytes. We provide inline stubs here that
// store values to be picked up during draw calls.
#define glEnable(cap) metal_gl_enable(cap)
#define glDisable(cap) metal_gl_disable(cap)
#define glClearColor(r, g, b, a) metal_gl_clear_color(r, g, b, a)
#define glClear(mask) metal_gl_clear(mask)
#define glGetIntegerv(pname, params) metal_gl_get_integerv(pname, params)
#define glPixelStorei(pname, param) ((void)(pname), (void)(param))  // no-op for Metal
#define glActiveTexture(unit) metal_gl_active_texture(unit)
#define glBindTexture(target, id) metal_gl_bind_texture(target, id)
#define glGenTextures(n, ids) metal_gl_gen_textures(n, ids)
#define glTexParameteri(target, pname, param) metal_gl_tex_parameteri(target, pname, param)
// Only ever called for GL_TEXTURE_BORDER_COLOR with a zero border (shaders.c),
// which the sampler cache maps to clamp_to_border_color's transparent black, so
// the values themselves need no recording.
#define glTexParameterfv(target, pname, params) ((void)(target), (void)(pname), (void)(params))
void metal_gl_tex_parameteri(GLenum target, GLenum pname, GLint param);
#define glTexImage2D(...) metal_gl_tex_image_2d(__VA_ARGS__)
#define glTexSubImage2D(...) metal_gl_tex_sub_image_2d(__VA_ARGS__)
#define glTexSubImage3D(...) metal_gl_tex_sub_image_3d(__VA_ARGS__)
#define glTexStorage3D(...) metal_gl_tex_storage_3d(__VA_ARGS__)
#define glGetTexLevelParameteriv(...) metal_gl_get_tex_level_parameteriv(__VA_ARGS__)
#define glGetTexImage(...) metal_gl_get_tex_image(__VA_ARGS__)
#define glCopyTexImage2D(...) metal_gl_copy_tex_image_2d(__VA_ARGS__)
#define glCopyImageSubData(...) metal_gl_copy_image_sub_data(__VA_ARGS__)
#define glGenFramebuffers(n, ids) metal_gl_gen_framebuffers(n, ids)
#define glFramebufferTexture2D(...) metal_gl_framebuffer_texture_2d(__VA_ARGS__)
#define glReadPixels(...) metal_gl_read_pixels(__VA_ARGS__)
static inline void metal_gl_uniform_block_binding(GLuint program, GLuint uniformBlockIndex, GLuint uniformBlockBinding) { (void)program; (void)uniformBlockIndex; (void)uniformBlockBinding; }
#define glUniformBlockBinding metal_gl_uniform_block_binding
#define glUniform1i(loc, v) metal_gl_uniform1i(loc, v)
#define glUniform1f(loc, v) metal_gl_uniform1f(loc, v)
#define glUniform2f(loc, x, y) metal_gl_uniform2f(loc, x, y)
#define glUniform3f(loc, x, y, z) metal_gl_uniform3f(loc, x, y, z)
#define glUniform4f(loc, x, y, z, w) metal_gl_uniform4f(loc, x, y, z, w)
#define glUniform1ui(loc, v) metal_gl_uniform1ui(loc, v)
#define glUniform1fv(loc, count, v) metal_gl_uniform1fv(loc, count, v)
#define glUniform1uiv(loc, count, v) metal_gl_uniform1uiv(loc, count, v)
#define glUniform2fv(loc, count, v) metal_gl_uniform2fv(loc, count, v)
#define glUniform4fv(loc, count, v) metal_gl_uniform4fv(loc, count, v)
#define glBlendFunc(sfactor, dfactor) ((void)(sfactor), (void)(dfactor)) // configured in pipeline state

// Metal GL-compat function declarations (implemented in metal.m)
void metal_gl_enable(GLenum cap);
void metal_gl_disable(GLenum cap);
void metal_gl_clear_color(float r, float g, float b, float a);
void metal_gl_clear(unsigned mask);
void metal_gl_get_integerv(GLenum pname, GLint *params);
void metal_gl_active_texture(GLenum unit);
void metal_gl_bind_texture(GLenum target, GLuint id);
void metal_gl_gen_textures(int n, GLuint *ids);
void metal_gl_tex_image_2d(GLenum target, int level, int internalformat, int width, int height, int border, GLenum format, GLenum type, const void *data);
void metal_gl_tex_sub_image_2d(GLenum target, int level, int x, int y, int width, int height, GLenum format, GLenum type, const void *data);
void metal_gl_tex_sub_image_3d(GLenum target, int level, int x, int y, int z, int width, int height, int depth, GLenum format, GLenum type, const void *data);
void metal_gl_tex_storage_3d(GLenum target, int levels, GLenum internalformat, int width, int height, int depth);
void metal_gl_get_tex_level_parameteriv(GLenum target, int level, GLenum pname, GLint *params);
void metal_gl_get_tex_image(GLenum target, int level, GLenum format, GLenum type, void *pixels);
void metal_gl_copy_tex_image_2d(GLenum target, int level, GLenum internalformat, int x, int y, int width, int height, int border);
void metal_gl_copy_image_sub_data(GLuint src, GLenum srcTarget, int srcLevel, int srcX, int srcY, int srcZ, GLuint dst, GLenum dstTarget, int dstLevel, int dstX, int dstY, int dstZ, int width, int height, int depth);
void metal_gl_gen_framebuffers(int n, GLuint *ids);
void metal_gl_framebuffer_texture_2d(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, int level);
void metal_gl_read_pixels(int x, int y, int width, int height, GLenum format, GLenum type, void *data);
void metal_gl_uniform1i(GLint loc, int v);
void metal_gl_uniform1f(GLint loc, float v);
void metal_gl_uniform2f(GLint loc, float x, float y);
void metal_gl_uniform3f(GLint loc, float x, float y, float z);
void metal_gl_uniform4f(GLint loc, float x, float y, float z, float w);
void metal_gl_uniform1ui(GLint loc, unsigned v);
void metal_gl_uniform1fv(GLint loc, int count, const float *v);
void metal_gl_uniform1uiv(GLint loc, int count, const unsigned *v);
void metal_gl_uniform2fv(GLint loc, int count, const float *v);
void metal_gl_uniform4fv(GLint loc, int count, const float *v);

// GLAD compat stubs — used in gl_init() and version checking
#define GLAD_VERSION_MAJOR(v) ((v) >> 16)
#define GLAD_VERSION_MINOR(v) ((v) & 0xFFFF)
#define GLAD_GL_ARB_texture_storage 1
#define GLAD_GL_ARB_copy_image 1
#define GLAD_GL_ARB_framebuffer_sRGB 1
#define GLAD_GL_EXT_framebuffer_sRGB 0
#define gladLoadGL(proc) ((3 << 16) | 3)  // report 3.3 (unused, Metal is always available)
#define gladUninstallGLDebug() ((void)0)
#define gladSetGLPostCallback(cb) ((void)0)
typedef void* GLADapiproc;
#undef glfwGetProcAddress
#define glfwGetProcAddress(name) NULL

// Additional GL function stubs used in shaders.c that need no-op or mapping
#define glShaderSource(id, count, src, len) ((void)(id), (void)(count), (void)(src), (void)(len))
#define glCompileShader(id) ((void)(id))
#define glGetShaderInfoLog(id, bufsize, len, buf) ((void)(id), (void)(bufsize), (void)(len), (void)(buf))
#define glDeleteShader(id) ((void)(id))
#define glCreateProgram() metal_gl_create_program()
#define glAttachShader(prog, shader) ((void)(prog), (void)(shader))
#define glLinkProgram(prog) ((void)(prog))
#define glGetProgramiv(prog, pname, params) metal_gl_get_programiv(prog, pname, params)
#define glGetProgramInfoLog(prog, bufsize, len, buf) ((void)(prog), (void)(bufsize), (void)(len), (void)(buf))
#define glDeleteProgram(prog) metal_gl_delete_program(prog)
#define glGetActiveUniform(prog, idx, bufsize, len, size, type, name) ((void)(prog), (void)(idx), (void)(bufsize), (void)(len), (void)(size), (void)(type), (void)(name))
#define glGetUniformLocation(prog, name) 0
#define glGetUniformIndices(prog, count, names, indices) ((void)(prog), (void)(count), (void)(names), (void)(indices))
#define glGetActiveUniformsiv(prog, count, indices, pname, params) ((void)(prog), (void)(count), (void)(indices), (void)(pname), (void)(params))
#define glGetAttribLocation(prog, name) 0
#define glGetUniformBlockIndex(prog, name) 0
#define glGetActiveUniformBlockiv(prog, block, pname, params) ((void)(prog), (void)(block), (void)(pname), (void)(params))
#define glMapBufferRange(target, offset, length, access) metal_gl_map_buffer_range(target, offset, length, access)
#define glEnableVertexAttribArray(idx) ((void)(idx))
#define glVertexAttribIPointer(idx, size, type, stride, offset) ((void)(idx), (void)(size), (void)(type), (void)(stride), (void)(offset))
#define glVertexAttribPointer(idx, size, type, normalized, stride, offset) ((void)(idx), (void)(size), (void)(type), (void)(normalized), (void)(stride), (void)(offset))
#define glVertexAttribDivisorARB(idx, divisor) ((void)(idx), (void)(divisor))

// Additional GL compat function declarations
GLuint metal_gl_create_program(void);
void metal_gl_get_programiv(GLuint prog, GLenum pname, GLint *params);
void metal_gl_delete_program(GLuint prog);
void* metal_gl_map_buffer_range(GLenum target, int offset, unsigned length, unsigned access);


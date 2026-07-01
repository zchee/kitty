/*
 * metal_context.h
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#ifdef KITTY_USE_METAL

// Metal-specific per-context data (replaces _GLFWcontextNSGL)
typedef struct _GLFWcontextMetal
{
    id              layer;      // CAMetalLayer*
    id              device;     // id<MTLDevice>
} _GLFWcontextMetal;

// Metal-specific global data (replaces _GLFWlibraryNSGL)
typedef struct _GLFWlibraryMetal
{
    id              device;     // id<MTLDevice> (shared across windows)
} _GLFWlibraryMetal;

#define _GLFW_PLATFORM_CONTEXT_STATE            _GLFWcontextMetal metal;
#define _GLFW_PLATFORM_LIBRARY_CONTEXT_STATE    _GLFWlibraryMetal metal;

bool _glfwInitMetal(void);
void _glfwTerminateMetal(void);
bool _glfwCreateContextMetal(_GLFWwindow* window);
void _glfwDestroyContextMetal(_GLFWwindow* window);

#endif // KITTY_USE_METAL

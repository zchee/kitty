/*
 * metal_context.m
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#ifdef KITTY_USE_METAL

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <Cocoa/Cocoa.h>

// Undefine system MAX/MIN before internal.h redefines them
#undef MAX
#undef MIN

#include "internal.h"

bool _glfwInitMetal(void)
{
    _glfw.metal.device = MTLCreateSystemDefaultDevice();
    if (!_glfw.metal.device)
    {
        _glfwInputError(GLFW_API_UNAVAILABLE,
                        "Metal: No supported Metal device found");
        return false;
    }
    return true;
}

void _glfwTerminateMetal(void)
{
    _glfw.metal.device = nil;
}

// Metal context callbacks — registered as function pointers on _GLFWwindow.context

static void makeContextCurrentMetal(_GLFWwindow* window)
{
    // Metal doesn't have a "current context" concept like OpenGL.
    // The device and command queue are process-global.
    // We just track which window is "current" in the TLS slot.
    if (window)
        _glfwPlatformSetTls(&_glfw.contextSlot, window);
    else
        _glfwPlatformSetTls(&_glfw.contextSlot, NULL);
}

static void swapBuffersMetal(_GLFWwindow* window)
{
    // Metal presents via [commandBuffer presentDrawable:] which is called
    // from metal_end_frame() in kitty's render loop. This callback exists
    // for GLFW API compatibility but doesn't need to do anything extra.
    (void)window;
}

static void swapIntervalMetal(int interval UNUSED)
{
    // Metal's CAMetalLayer handles vsync via displaySyncEnabled property.
    // This is set during layer creation, not per-frame.
}

static int extensionSupportedMetal(const char* extension UNUSED)
{
    // Metal doesn't have GL extensions
    return false;
}

static GLFWglproc getProcAddressMetal(const char* procname UNUSED)
{
    // Metal doesn't have a getProcAddress equivalent
    return NULL;
}

// Create a Metal rendering context (CAMetalLayer) for a window.
// Modeled on the Vulkan surface creation code in cocoa_window.m
bool _glfwCreateContextMetal(_GLFWwindow* window)
{
    // Create the CAMetalLayer
    CAMetalLayer *layer = [CAMetalLayer layer];
    if (!layer)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Metal: Failed to create CAMetalLayer");
        return false;
    }

    // Configure the layer
    layer.device = (id<MTLDevice>)_glfw.metal.device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    layer.framebufferOnly = NO;  // Allow read-back for screenshots
    layer.presentsWithTransaction = NO;
    // Allow nextDrawable to return nil instead of blocking indefinitely
    // when all drawables are in-flight. This prevents deadlock when
    // the main thread blocks in nextDrawable while the GPU needs the
    // run loop to process drawable release callbacks.
    if (@available(macOS 12.3, *)) {
        layer.allowsNextDrawableTimeout = YES;
    }

    // Handle Retina displays
    if (window->ns.retina)
        layer.contentsScale = [window->ns.object backingScaleFactor];


    // Set the layer on the NSView (same order as Vulkan surface creation)
    window->ns.layer = layer;
    [window->ns.view setLayer:layer];
    [window->ns.view setWantsLayer:YES];

    // Store context references
    window->context.metal.layer = layer;
    window->context.metal.device = _glfw.metal.device;

    // Register GLFW context callbacks
    window->context.makeCurrent = makeContextCurrentMetal;
    window->context.swapBuffers = swapBuffersMetal;
    window->context.swapInterval = swapIntervalMetal;
    window->context.extensionSupported = extensionSupportedMetal;
    window->context.getProcAddress = getProcAddressMetal;

    // Set client to NATIVE so GLFW functions like glfwMakeContextCurrent don't
    // reject this window with "no OpenGL context" error.
    // GLFW_NO_API causes glfwMakeContextCurrent/glfwSwapBuffers to early-return.
    window->context.client = GLFW_OPENGL_API;
    window->context.source = GLFW_NATIVE_CONTEXT_API;

    return true;
}

void _glfwDestroyContextMetal(_GLFWwindow* window)
{
    window->context.metal.layer = nil;
    window->context.metal.device = nil;
}

#endif // KITTY_USE_METAL

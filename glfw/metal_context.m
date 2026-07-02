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
    // Non-sRGB base format: GL_FRAMEBUFFER_SRGB parity is implemented with an
    // sRGB texture view of the drawable, selected per render pass in metal.m.
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;  // Allow read-back for screenshots
    layer.presentsWithTransaction = NO;
    // Allow nextDrawable to return nil instead of blocking indefinitely
    // when all drawables are in-flight. This prevents deadlock when
    // the main thread blocks in nextDrawable while the GPU needs the
    // run loop to process drawable release callbacks.
    if (@available(macOS 12.3, *)) {
        layer.allowsNextDrawableTimeout = YES;
    }

    // Match the layer's scale to the backing store. The drawable size is
    // driven explicitly from kitty's viewport (set_gpu_viewport), which uses
    // the backing-pixel framebuffer size, so contentsScale mainly keeps Core
    // Animation's point<->pixel mapping consistent across display moves.
    layer.contentsScale = window->ns.retina ? [window->ns.object backingScaleFactor] : 1.0;


    // Install as the view's backing layer. window->ns.layer must be set
    // BEFORE wantsLayer: GLFWContentView's makeBackingLayer override returns
    // it, and keeps returning it whenever AppKit re-backs the view (screen
    // change, full-screen transition), so the render target is never
    // silently replaced by a plain CALayer.
    window->ns.layer = layer;
    [window->ns.view setWantsLayer:YES];
    if ([(NSView*)window->ns.view layer] != (CALayer*)layer)
        [(NSView*)window->ns.view setLayer:(CALayer*)layer];

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

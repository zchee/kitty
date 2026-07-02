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
    // Plain (non-sRGB) BGRA8Unorm base. C1: sRGB is now encoded in-shader — the
    // opaque cell/border fragments via the SRGB_ENCODE_OUTPUT function constant,
    // and layered content in the single-pass resolve draw (kitty/metal.m) — so
    // no per-frame sRGB texture view of the drawable is created any more.
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // C4a: framebufferOnly=YES lets Core Animation optimize the drawable for
    // display (lossless framebuffer compression). Safe now that nothing creates a
    // texture view of the drawable (that per-frame view creation was the Wave-1
    // blocker that forced this to NO). Read-back paths — the KITTY_METAL_DUMP_FRAME
    // golden harness and take_screenshot_of_rectangular_region — render to a
    // readable offscreen instead (metal_capture_to_offscreen in metal.m), never
    // the drawable.
    layer.framebufferOnly = YES;
    layer.presentsWithTransaction = NO;
    // CAMetalLayer.maximumDrawableCount accepts only 2 or 3 (any other value
    // raises an exception, Apple docs); default is 3. Two trades one frame of
    // drawable-acquisition queue depth for up to one frame less presentation
    // latency: once both drawables are in flight, nextDrawable blocks
    // (bounded below by allowsNextDrawableTimeout) instead of the CPU
    // racing three frames ahead of what's on screen.
    layer.maximumDrawableCount = 2;
    // layer.colorspace is intentionally left at its default, nil. Per Apple
    // docs a nil colorspace means the drawable's content "isn't
    // color-matched" -- Core Animation performs no colorspace transform at
    // composite time, which is the fast, GL-parity path. kitty already does
    // its own sRGB handling in the render pipeline (texture views selected
    // per pass in metal.m), so a CA-side conversion would be redundant work
    // at best and a double-conversion bug at worst. Never set a colorspace
    // here.
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

    // Opaque lets Core Animation drop the alpha channel from the drawable's
    // backing store and skip compositing this layer against whatever sits
    // behind it (CALayer.isOpaque, default NO -- Apple docs). Seed it from
    // the NSWindow's own opacity, which createNativeWindow (cocoa_window.m)
    // already resolved from the GLFW_TRANSPARENT_FRAMEBUFFER hint before this
    // function runs. glfwCocoaSetWindowChrome (cocoa_window.m) keeps this in
    // sync with the live background_opacity for the rest of the window's
    // life -- it must stay NO whenever background_opacity < 1.
    layer.opaque = [window->ns.object isOpaque];

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

/*
 * metal_context.h
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#ifdef KITTY_USE_METAL

#if defined(__OBJC__)
// Full CAMetalLayer type for the .m files that toggle presentation
// properties on window->ns.layer (live resize, backing changes).
#import <QuartzCore/CAMetalLayer.h>
#endif

// Metal-specific per-context data (replaces _GLFWcontextNSGL)
typedef struct _GLFWcontextMetal
{
    id              layer;            // CAMetalLayer*
    id              device;           // id<MTLDevice>
    // Phase 4 (L1): CAMetalDisplayLink render driver. One link per window
    // (per CAMetalLayer) — it follows the layer's display automatically, so no
    // per-display registry is needed (unlike the CVDisplayLink path that stays
    // for the GL backend). The link is created UNPAUSED and added to the runloop;
    // the idle pause/resume toggles runloop membership, and live-resize DESTROYS +
    // recreates it. Its delegate (strong ref, since link.delegate is weak) drives
    // one render + present per vsync-timed callback on the main runloop.
    id              display_link;         // CAMetalDisplayLink* (strong)
    id              display_link_delegate; // KittyMetalDisplayLinkDelegate* (strong)
    // The link-delivered drawable + its target presentation time, valid ONLY for
    // the duration of the current metalDisplayLink:needsUpdate: callback (kitty's
    // render callback pulls the drawable synchronously and presents it).
    id              pending_drawable;     // id<CAMetalDrawable> (unretained; owned by the Update)
    double          pending_present_time; // CAMetalDisplayLinkUpdate.targetPresentationTimestamp
    // Phase 4 (L3): whether the link is currently in the main runloop. An attached
    // link (even paused) owns the layer's drawable pool and starves nextDrawable,
    // so sync_to_monitor=no (which renders inline via nextDrawable + immediate
    // present) REMOVES the link from the runloop; sync_to_monitor=yes keeps it.
    bool            link_in_runloop;
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

// Phase 4 (L1): pause/resume this window's CAMetalDisplayLink. Defined in
// metal_context.m (keeps the CAMetalDisplayLink type localized there); called
// from cocoa_window.m (requestRenderFrame resume, live-resize pause) and via the
// glfwCocoaSetRenderLinkPaused() public shim. A no-op if the window has no link.
void _glfwCocoaSetMetalLinkPaused(_GLFWwindow* window, bool paused);

// Phase 4 (L3): add/remove this window's CAMetalDisplayLink from the main runloop.
// Removed when sync_to_monitor=no so nextDrawable works (inline immediate present);
// added when =yes. Defined in metal_context.m; called via glfwCocoaSetRenderLinkEnabled.
void _glfwCocoaSetMetalLinkEnabled(_GLFWwindow* window, bool enabled);

// Wave-14 confirm accessor: is this window's pace link currently a member of the
// main runloop? Arbitrates H1 (link in-runloop but starved) vs H2 (link removed)
// at a stall. Main/render-thread only, no lock; false when the window has no link.
bool _glfwCocoaIsMetalLinkInRunloop(_GLFWwindow* window);

#endif // KITTY_USE_METAL

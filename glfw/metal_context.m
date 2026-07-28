/*
 * metal_context.m
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#ifdef KITTY_USE_METAL

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <Cocoa/Cocoa.h>

// Undefine system MAX/MIN before internal.h redefines them
#undef MAX
#undef MIN

#include "internal.h"
#include <stdio.h>
#include <string.h>

// --- Wave-4 task #4 link-stall diagnostic (KITTY_METAL_LINKTRACE_FILE) -------
// Appends CAMetalDisplayLink lifecycle events tagged with the window's
// activation/visibility state, so a BROKEN run's trace can be diffed against a
// HEALTHY one to decide whether a frozen window is non-key/occluded (activation)
// or key-but-not-ticking (a deeper stall). No-op unless the env var is set;
// temporary diagnostic, removed once the fix lands.
static FILE *link_trace_fp = NULL;
static bool link_trace_checked = false;
static FILE *
link_trace_file(void) {
    if (!link_trace_checked) {
        link_trace_checked = true;
        const char *p = getenv("KITTY_METAL_LINKTRACE_FILE");
        if (p && p[0]) link_trace_fp = fopen(p, "a");
    }
    return link_trace_fp;
}
void
link_trace(const char *event, _GLFWwindow *w, double extra) {
    FILE *fp = link_trace_file();
    if (!fp || !w) return;
    NSWindow *nw = (NSWindow*)w->ns.object;
    int is_key = nw ? (int)[nw isKeyWindow] : -1;
    int is_main = nw ? (int)[nw isMainWindow] : -1;
    int is_visible = nw ? (int)[nw isVisible] : -1;
    int occluded = nw ? ((([nw occlusionState] & NSWindowOcclusionStateVisible) == 0) ? 1 : 0) : -1;
    int app_active = (int)[NSApp isActive];
    fprintf(fp, "%.6f %s win=%p key=%d main=%d vis=%d occl=%d app=%d x=%.2f\n",
            CACurrentMediaTime(), event, (void*)w, is_key, is_main, is_visible,
            occluded, app_active, extra);
    fflush(fp);
}

// Phase 4 (L1): CAMetalDisplayLink delegate. One instance per window, holding a
// back-pointer (unretained — the window owns the delegate, not vice versa) to
// the _GLFWwindow whose layer drives it. The link delivers a vsync-timed
// drawable on the main runloop; we hand it to kitty's render callback for this
// one frame and let kitty render + present it synchronously inside the callback.
@interface KittyMetalDisplayLinkDelegate : NSObject <CAMetalDisplayLinkDelegate>
{
    @public
    _GLFWwindow *window;
    uint64_t tick_count;
}
@end

@implementation KittyMetalDisplayLinkDelegate
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    (void)link;
    _GLFWwindow *w = window;
    if (!w || !w->ns.renderFrameCallback) return;
    tick_count++;
    if (tick_count == 1) link_trace("FIRST_TICK", w, 0);
    else if (tick_count % 60 == 0) link_trace("TICK", w, (double)tick_count);
    // Wave-4 task #4 DETERMINISTIC repro (KITTY_METAL_FORCE_STUCK_RESIZE). Mirror
    // EXACTLY what macOS does when it emits a spurious viewWillStartLiveResize with
    // no viewDidEndLiveResize: presentsWithTransaction=YES, live_resize latched, link
    // DESTROYED. dispatch_async onto the main queue so it runs on a LATER turn,
    // serialized after this delegate call — like the real AppKit event — instead of
    // destroying the link from inside its own tick. The kill switch / linktrace /
    // this hook are the only levers for a quirk we cannot otherwise trigger; kept.
    {
        static bool forced_stuck_resize = false;
        if (!forced_stuck_resize && tick_count == 3) {
            const char *v = getenv("KITTY_METAL_FORCE_STUCK_RESIZE");
            if (v && v[0] && strcmp(v, "0") != 0) {
                forced_stuck_resize = true;
                _GLFWwindow *fw = w;
                dispatch_async(dispatch_get_main_queue(), ^{
                    fw->ns.live_resize_in_progress = true;
                    if (fw->ns.layer) ((CAMetalLayer*)fw->ns.layer).presentsWithTransaction = YES;
                    _glfwCocoaSetMetalLinkEnabled(fw, false);  // DESTROY, exactly as viewWillStartLiveResize
                    link_trace("FORCE_STUCK_RESIZE", fw, 0);
                    _glfwInputLiveResize(fw, true);
                });
            }
        }
    }
    // NOTE: do NOT guard on w->ns.live_resize_in_progress here. During a real resize
    // the link is DESTROYED (viewWillStartLiveResize / change_live_resize_state ENTER),
    // so this delegate does not run at all; the ONLY resize guard that matters is the
    // kitty-side w->live_resize.in_progress check in cocoa_metal_frame_callback, which
    // every resize-exit path (viewDidEndLiveResize, the debounce in
    // process_pending_resizes, and the render()-loop backstop) clears. The GLFW-side
    // ns.live_resize_in_progress is only reliably cleared by viewDidEndLiveResize and
    // the backstop's glfwCocoaResetLiveResizeGuards — the debounce path leaves it
    // latched, and guarding on it here froze a freshly-recreated link (it ticked but
    // never invoked the callback). Publishing an unused drawable on a resize tick is
    // harmless; the callback's kitty-flag guard drops it.
    // Publish the drawable for glfwGetCocoaPendingMetalDrawable(); valid ONLY for
    // this synchronous callback (kitty presents with a plain present — a timed
    // present asserts under CAMetalDisplayLink, per Apple docs).
    w->context.metal.pending_drawable = update.drawable;
    w->context.metal.pending_present_time = update.targetPresentationTimestamp;
    w->ns.renderFrameRequested = false;
    w->ns.renderFrameCallback((GLFWwindow*)w);
    w->context.metal.pending_drawable = nil;
    w->context.metal.pending_present_time = 0;
}
@end

// Wave-5 default: IOSurface presentation. KITTY_METAL_IOSURFACE=0 is the kill
// switch back to the legacy CAMetalDisplayLink + drawable path. Must agree
// with metal_iosurface_enabled() in kitty/metal.m (same env var, same default).
static bool
iosurface_present_mode(void) {
    // W27 (ADR-0021): default flipped — the CAMetalLayer arm won the
    // consolidation (EDR eligibility). =1 is the transition-period kill switch
    // back to the IOSurface host; the host is deleted at P2.4b completion.
    static int state = -1;
    if (state < 0) { const char *v = getenv("KITTY_METAL_IOSURFACE"); state = (v && v[0] && strcmp(v, "1") == 0) ? 1 : 0; }
    return state == 1;
}

// W27 P2.4a (ADR-0021): timer-paced drawable arm — drive the CAMetalLayer arm
// with the plain-CADisplayLink pace timer (KittyIOSurfacePaceLinkTarget) so no
// CAMetalDisplayLink owns the drawable pool and kitty's L2 immediate-encode is
// safe there. Must agree with metal_timer_pace_enabled() in kitty/metal.m
// (same env var, same default).
static bool
timer_paced_mode(void) {
    // W27 (ADR-0021): default ON — the winner arm ships timer-paced (the
    // echo-immediate port). =0 restores the CAMetalDisplayLink driver.
    static int state = -1;
    if (state < 0) { const char *v = getenv("KITTY_METAL_TIMER_PACE"); state = (v && v[0] && v[0] == '0') ? 0 : 1; }
    return state == 1;
}

// W27 (ADR-0021 addendum): displaySync policy for the winner arm. Windowed/
// composited presents immediately — operator-verified tear-free (whole-surface
// composition cannot shear) and the fastest photon ever measured here (typing
// p50 20.0 ms vs 42.4 vsync-queued). Fullscreen keeps vsync: direct scanout
// can genuinely tear; P5 owns any scanout-mode work. sync_to_monitor still
// wins downward: interval 0 forces immediate everywhere.
static void
apply_display_sync_policy(_GLFWwindow *window) {
    if (!window || !window->context.metal.layer) return;
    if (iosurface_present_mode()) return;  // mirror-flag arm keeps its own path
    NSWindow *nswin = (NSWindow*)window->ns.object;
    const bool fullscreen = window->monitor != NULL
        || window->ns.in_traditional_fullscreen
        || (nswin && ([nswin styleMask] & NSWindowStyleMaskFullScreen) != 0);
    const bool sync = window->context.metal.sync_interval != 0 && fullscreen;
    ((CAMetalLayer*)window->context.metal.layer).displaySyncEnabled = sync ? YES : NO;
}

void _glfwCocoaApplyMetalDisplaySyncPolicy(_GLFWwindow* window) {
    apply_display_sync_policy(window);
}

// Wave-5 governor: under the IOSurface model the render driver is a plain
// CADisplayLink — the same per-window vsync-timed callback cadence as
// CAMetalDisplayLink, but a pure timer: it owns NO drawable pool, so the
// kitty-side input fast path (immediate encode) can render at any instant
// without corrupting anything, and glfwGetCocoaPendingMetalDrawable() simply
// returns NULL during its ticks (kitty's ensure_drawable takes the IOSurface
// ring instead). This link IS the flood pacing governor: the render gate
// defers sustained damage to these ticks, so flood encodes at the refresh
// rate instead of the parse rate. Same lifecycle as the CAMetalDisplayLink it
// replaces: created unpaused, idle pause = runloop removal, destroyed for
// live resize and sync_to_monitor=no.
@interface KittyIOSurfacePaceLinkTarget : NSObject
{
    @public
    _GLFWwindow *window;
    uint64_t tick_count;
}
- (void)tick:(CADisplayLink *)link;
@end

@implementation KittyIOSurfacePaceLinkTarget
- (void)tick:(CADisplayLink *)link {
    (void)link;
    _GLFWwindow *w = window;
    if (!w || !w->ns.renderFrameCallback) return;
    tick_count++;
    if (tick_count == 1) link_trace("FIRST_TICK", w, 0);
    else if (tick_count % 60 == 0) link_trace("TICK", w, (double)tick_count);
    // Same resize non-guard as the CAMetalDisplayLink delegate: the kitty-side
    // live_resize check in cocoa_metal_frame_callback is the only guard that
    // matters (see the NOTE in metalDisplayLink:needsUpdate: above).
    w->ns.renderFrameRequested = false;
    w->ns.renderFrameCallback((GLFWwindow*)w);
}
@end

// Phase 4 (L1/L3): create/destroy this window's CAMetalDisplayLink. Factored so
// sync_to_monitor can toggle it AND so live-resize can DESTROY it (an attached link
// — even removed from the runloop — owns the layer's drawable pool and makes
// nextDrawable return nil, so both sync_to_monitor=no and the resize's inline
// nextDrawable path need the link fully gone). The link is created UNPAUSED and
// added to the runloop; the idle pause/resume toggles runloop membership.
static void create_metal_display_link(_GLFWwindow *window)
{
    if (window->context.metal.display_link || !window->context.metal.layer) return;
    CAMetalLayer *layer = (CAMetalLayer*)window->context.metal.layer;
    // A link means normal (non-resize) rendering, so clear a stale
    // presentsWithTransaction=YES left by the debounce path (process_pending_resizes),
    // which — unlike the backstop's glfwCocoaResetLiveResizeGuards — does not reset it,
    // else the fresh link's frames would present through the synchronous transaction
    // path (pace=resize). BUT only when NO drag is in progress: process_pending_resizes
    // recreates the link mid-drag on a >100ms pause, and dropping presentsWithTransaction
    // then would detach the content from the window chrome for the rest of the drag
    // (the DEFECT-1 flicker). [NSEvent pressedMouseButtons] is AppKit ground truth;
    // a genuine drag keeps the transaction, a stuck/programmatic resize clears it.
    if (!([NSEvent pressedMouseButtons] & 1)) layer.presentsWithTransaction = NO;
    if (iosurface_present_mode() || timer_paced_mode()) {
        // IOSurface default: a plain CADisplayLink paces render frames (see
        // KittyIOSurfacePaceLinkTarget above). NSWindow-vended so it tracks
        // the display the window is actually on (macOS 14+; build floor 15.3).
        NSWindow *nswin = (NSWindow*)window->ns.object;
        if (!nswin) return;
        KittyIOSurfacePaceLinkTarget *tgt = [[KittyIOSurfacePaceLinkTarget alloc] init];
        tgt->window = window;
        CADisplayLink *dl = [nswin displayLinkWithTarget:tgt selector:@selector(tick:)];
        if (!dl) { [tgt release]; return; }
        [dl retain];  // MRC: vended autoreleased; released in destroy_metal_display_link
        dl.preferredFrameRateRange = CAFrameRateRangeDefault;  // ProMotion; system-driven cadence
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        window->context.metal.display_link = dl;
        window->context.metal.display_link_delegate = tgt;
        window->context.metal.link_in_runloop = true;
        link_trace("CREATE_PACE", window, 0);
        return;
    }
    KittyMetalDisplayLinkDelegate *dlDelegate = [[KittyMetalDisplayLinkDelegate alloc] init];
    dlDelegate->window = window;
    CAMetalDisplayLink *dl = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
    dl.delegate = dlDelegate;  // link.delegate is weak; the strong ref is in the context
    // Only 1.0/2.0 valid (1.0 = documented floor). Measured no-op for our cold
    // latency (1.0==2.0 within noise; frames complete in <1ms so completion slack
    // is irrelevant) — see metal-pipeline-design.md. 1.0 = least requested latency.
    dl.preferredFrameLatency = 1.0f;
    dl.preferredFrameRateRange = CAFrameRateRangeDefault;  // ProMotion; a 0-minimum range throws
    // Add to the runloop UNPAUSED at creation. The link delivers reliably once in
    // the runloop, and the idle pause/resume (removeFromRunLoop on a no-damage tick,
    // addToRunLoop on fresh damage via request_frame_render) is reliable too — a
    // healthy session performs hundreds of these. The once-then-freeze defect was
    // NOT the idle resume but the resize->normal handoff: a live resize removed the
    // link from the runloop and it was never recreated, so render_state stuck at
    // READY and the main loop spun on inline nextDrawable (nil while the link owns
    // the pool). That is fixed in change_live_resize_state (kitty/glfw.c), which
    // recreates the link when a resize ends. The link is removed for live-resize and
    // destroyed/recreated for sync_to_monitor toggles; paused stays NO throughout.
    dl.paused = NO;
    [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    window->context.metal.display_link = dl;
    window->context.metal.display_link_delegate = dlDelegate;
    window->context.metal.link_in_runloop = true;
    link_trace("CREATE", window, 0);
}

static void destroy_metal_display_link(_GLFWwindow *window)
{
    if (window->context.metal.display_link) link_trace("DESTROY", window, 0);
    if (window->context.metal.display_link) {
        if (iosurface_present_mode() || timer_paced_mode()) {
            CADisplayLink *dl = (CADisplayLink*)window->context.metal.display_link;
            [dl invalidate];  // removes it from all runloops (and drops its own target retain)
            [dl release];
        } else {
            CAMetalDisplayLink *dl = (CAMetalDisplayLink*)window->context.metal.display_link;
            dl.delegate = nil;
            [dl invalidate];
            [dl release];
        }
        window->context.metal.display_link = nil;
    }
    if (window->context.metal.display_link_delegate) {
        [(NSObject*)window->context.metal.display_link_delegate release];
        window->context.metal.display_link_delegate = nil;
    }
    window->context.metal.link_in_runloop = false;
}

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

static void swapIntervalMetal(int interval)
{
    // Phase 4 (L3): map kitty's swap interval (driven by sync_to_monitor via
    // apply_swap_interval) onto the layer's displaySyncEnabled. interval 0
    // (sync_to_monitor=no) => NO: present immediately, tearing accepted — the
    // documented swap-interval-0 GL semantic. Otherwise YES: vsync-clean (default).
    // Runs on the CURRENT context's window (glfwMakeContextCurrent set the TLS).
    _GLFWwindow *window = _glfwPlatformGetTls(&_glfw.contextSlot);
    if (window && window->context.metal.layer) {
        window->context.metal.sync_interval = interval;
        if (iosurface_present_mode()) {
            // Mirror-flag arm (transition-period only): direct mapping as before.
            ((CAMetalLayer*)window->context.metal.layer).displaySyncEnabled = interval != 0 ? YES : NO;
        } else {
            // W27 winner arm: interval feeds the windowed-immediate /
            // fullscreen-vsync policy instead of mapping 1:1.
            apply_display_sync_policy(window);
        }
    }
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

// IOSurface presentation mode's backing layer: a plain CALayer, not a
// CAMetalLayer. Manually assigning IOSurfaces to `contents` is a fully
// supported CALayer operation, which silences Core Animation's per-present
// "changing `contents' on CAMetalLayer may result in undefined behavior"
// error log and removes the standing UB exposure of bypassing the drawable
// pool (same shape as Ghostty's IOSurfaceLayer). presentsWithTransaction /
// displaySyncEnabled / drawableSize are MIRROR properties: plain stored
// state with CAMetalLayer's exact selector names and types, because every
// shared read/write site (the glfw resize signals here and in
// cocoa_window.m, kitty/metal.m's present decisions and ring sizing)
// accesses them through a CAMetalLayer* static type and resolves at runtime
// via selector dispatch. In IOSurface mode there are no drawable presents,
// so the flags carry no CA-side behavior — the sync swap already happens
// inside an explicit CATransaction (iosurface_swap_contents, kitty/metal.m).
// Selector names and types MUST stay exactly aligned with CAMetalLayer's;
// metal_set_current_layer (kitty/metal.m) fatals if the layer class ever
// disagrees with metal_iosurface_enabled().
@interface KittyIOSurfaceLayer : CALayer
@property (nonatomic) BOOL presentsWithTransaction;
@property (nonatomic) BOOL displaySyncEnabled;
@property (nonatomic) CGSize drawableSize;
@end

@implementation KittyIOSurfaceLayer
// Kill ALL implicit animations (the 0.25 s contents crossfade, bounds moves
// during AppKit-driven live resize). The contents swap itself already runs
// under setDisableActions:YES, but AppKit's geometry changes land outside
// that transaction.
- (id<CAAction>)actionForKey:(NSString *)event { (void)event; return (id<CAAction>)[NSNull null]; }
@end

// Create a Metal rendering context for a window: the view's backing layer —
// a plain KittyIOSurfaceLayer in IOSurface presentation mode (the default),
// a CAMetalLayer on the legacy drawable path (KITTY_METAL_IOSURFACE=0).
// Modeled on the Vulkan surface creation code in cocoa_window.m
bool _glfwCreateContextMetal(_GLFWwindow* window)
{
    CAMetalLayer *layer;
    if (iosurface_present_mode()) {
        // The static type stays CAMetalLayer* so the shared property sites
        // below and across kitty compile unchanged; only the mirror
        // selectors and the inherited CALayer surface are ever used on it.
        // None of the legacy branch's drawable-pool configuration applies
        // (device/pixelFormat/framebufferOnly/maximumDrawableCount/
        // allowsNextDrawableTimeout): this layer has no drawable pool. The
        // frame format lives in the IOSurface ring (kitty/metal.m), and no
        // colorspace is attached anywhere (nil-colorspace parity, see the
        // legacy branch's colorspace comment below).
        layer = (CAMetalLayer*)[KittyIOSurfaceLayer layer];
        if (!layer)
        {
            _glfwInputError(GLFW_PLATFORM_ERROR,
                            "Metal: Failed to create KittyIOSurfaceLayer");
            return false;
        }
        // Mirror-flag seeds, matching the legacy branch: no resize
        // transaction in progress; vsync on (CAMetalLayer's default —
        // swapIntervalMetal overwrites this from the swap interval).
        // drawableSize starts zero = "unset"; set_gpu_viewport
        // (kitty/metal.m) drives it, and the ring sizing falls back to
        // mtl_viewport while it is zero.
        layer.presentsWithTransaction = NO;
        layer.displaySyncEnabled = YES;
    } else {
        // Legacy drawable path: a real CAMetalLayer.
        layer = [CAMetalLayer layer];
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
        // raises an exception, Apple docs); default is 3. Wave-4 measured 2 vs 3
        // under the CAMetalDisplayLink driver (flood + typing): the link delivers a
        // vsync-timed drawable to each delegate callback, so there is no CPU-side
        // nextDrawable race and a 2-deep pool already yields a perfectly steady
        // present cadence (16.667 ms p50==p99==max at 60 Hz) with drawable_wait_ms
        // structurally 0. Count 3 gave BYTE-IDENTICAL cadence and zero tail stalls
        // (no smoothness gain) while adding ~2 ms of PTY-write->present latency (one
        // more frame of queue depth). The old 2-pass-era "60 ms tail stall at 2" is
        // gone. So 2 is optimal: shallowest presentation queue == lowest latency.
        layer.maximumDrawableCount = 2;
        // W27: seed the sync policy (windowed at creation => immediate). The
        // stored interval defaults to 1 (sync_to_monitor default yes) until
        // kitty applies the real option via swapIntervalMetal.
        window->context.metal.sync_interval = 1;
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

    // Phase 4 (L1): create this window's CAMetalDisplayLink render driver (created
    // paused; requestRenderFrame() resumes it). kitty destroys it after creation
    // when sync_to_monitor=no (glfwCocoaSetRenderLinkEnabled) so that mode can
    // render inline via nextDrawable. Build floor is macOS 15.3 so CAMetalDisplayLink
    // (14.0+) is unconditional.
    window->context.metal.pending_drawable = nil;
    window->context.metal.pending_present_time = 0;
    create_metal_display_link(window);

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
    // Phase 4 (L1): tear down the CAMetalDisplayLink (invalidate + release, MRC).
    destroy_metal_display_link(window);
    window->context.metal.pending_drawable = nil;
    window->context.metal.pending_present_time = 0;
    window->context.metal.layer = nil;
    window->context.metal.device = nil;
}

void _glfwCocoaSetMetalLinkPaused(_GLFWwindow* window, bool paused)
{
    // IDLE pause/resume ONLY (live-resize destroys the link instead — see
    // _glfwCocoaSetMetalLinkEnabled / viewWillStartLiveResize). Toggle runloop
    // membership: a healthy session performs hundreds of these idle cycles
    // reliably. The once-then-freeze defect was never here — it was the resize
    // handoff. Idempotent via link_in_runloop; safe to toggle from the delegate.
    if (!window || !window->context.metal.display_link) return;
    // id, not a concrete cast: the link is a CADisplayLink under the IOSurface
    // default and a CAMetalDisplayLink on the legacy path; both implement the
    // runloop add/remove selectors used below.
    id dl = window->context.metal.display_link;
    if (paused) {
        if (window->context.metal.link_in_runloop) {
            [dl removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            window->context.metal.link_in_runloop = false;
            link_trace("PAUSE", window, 0);
        }
    } else {
        if (!window->context.metal.link_in_runloop) {
            [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            window->context.metal.link_in_runloop = true;
            link_trace("RESUME", window, 0);
        }
    }
}

bool _glfwCocoaIsMetalLinkInRunloop(_GLFWwindow* window)
{
    // Wave-14 §5 confirm accessor: report the runloop-membership bookkeeping that
    // _glfwCocoaSetMetalLinkPaused / addToRunLoop / removeFromRunLoop maintain
    // above. Read on the same main/render thread that mutates it, so no lock is
    // needed. false when the window has no link (nothing can be in the runloop).
    if (!window || !window->context.metal.display_link) return false;
    return window->context.metal.link_in_runloop;
}

void _glfwCocoaSetMetalLinkEnabled(_GLFWwindow* window, bool enabled)
{
    // Phase 4 (L3): fully create or DESTROY the link. Removing it from the runloop
    // is not enough — the link object, init'd with the layer, owns the drawable
    // pool and makes nextDrawable return nil even when paused/removed. So
    // sync_to_monitor=no destroys it (freeing nextDrawable for inline rendering);
    // sync_to_monitor=yes (re)creates it. Idempotent.
    if (!window) return;
    if (enabled) create_metal_display_link(window);
    else destroy_metal_display_link(window);
}

#endif // KITTY_USE_METAL

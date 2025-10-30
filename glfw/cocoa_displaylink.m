/*
 * cocoa_displaylink.m
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

// CVDisplayLink is deprecated replace with CADisplayLink via [NSScreen displayLink] once base macOS version is 14
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "internal.h"
#include <CoreVideo/CVDisplayLink.h>
#include <os/lock.h>

#if __has_include(<QuartzCore/CADisplayLink.h>)
#  include <QuartzCore/CADisplayLink.h>
#  define GLFW_HAS_CADISPLAYLINK 1
#else
#  define GLFW_HAS_CADISPLAYLINK 0
#endif

#if GLFW_HAS_CADISPLAYLINK && defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED < 140000
@interface NSScreen (KittyDisplayLinkCompatibility)
- (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector;
@end
#endif

#if GLFW_HAS_CADISPLAYLINK
@class GLFWCADisplayLinkTarget;
#endif

#define DISPLAY_LINK_SHUTDOWN_CHECK_INTERVAL s_to_monotonic_t(30ll)
#define MAX_NUM_OF_DISPLAYS 256

typedef struct _GLFWDisplayLinkNS
{
#if GLFW_HAS_CADISPLAYLINK
    CADisplayLink *caDisplayLink;
    GLFWCADisplayLinkTarget *target;
#endif
    CVDisplayLinkRef displayLink;
    CGDirectDisplayID displayID;
    monotonic_t lastRenderFrameRequestedAt, first_unserviced_render_frame_request_at;
    bool pending_dispatch;
    bool useCADisplayLink;
} _GLFWDisplayLinkNS;

static struct {
    _GLFWDisplayLinkNS entries[MAX_NUM_OF_DISPLAYS];
    os_unfair_lock locks[MAX_NUM_OF_DISPLAYS];
    bool locks_initialized[MAX_NUM_OF_DISPLAYS];
    size_t count;
} displayLinks = {0};

static void _glfwHandleDisplayLinkTick(_GLFWDisplayLinkNS *entry);
static void _glfwDispatchRenderFrame(void *passed_in_data);

static inline size_t
index_for_entry(_GLFWDisplayLinkNS *entry) {
    return (size_t)(entry - displayLinks.entries);
}

static inline os_unfair_lock*
lock_for_entry(_GLFWDisplayLinkNS *entry) {
    return &displayLinks.locks[index_for_entry(entry)];
}

#if GLFW_HAS_CADISPLAYLINK
static NSScreen*
screenForDisplayID(CGDirectDisplayID displayID) {
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number && number.unsignedIntValue == displayID)
            return screen;
    }
    return nil;
}

@interface GLFWCADisplayLinkTarget : NSObject {
    _GLFWDisplayLinkNS *entry;
}
- (instancetype)initWithEntry:(_GLFWDisplayLinkNS *)entry;
- (void)detach;
- (void)displayLinkDidFire:(CADisplayLink *)link;
@end

@implementation GLFWCADisplayLinkTarget

- (instancetype)initWithEntry:(_GLFWDisplayLinkNS *)e {
    self = [super init];
    if (self) entry = e;
    return self;
}

- (void)detach {
    entry = NULL;
}

- (void)displayLinkDidFire:(CADisplayLink *)link {
    (void)link;
    if (entry) _glfwHandleDisplayLinkTick(entry);
}

- (void)dealloc {
    entry = NULL;
    [super dealloc];
}

@end
#endif

static CGDirectDisplayID
displayIDForWindow(_GLFWwindow *w) {
    NSWindow *nw = w->ns.object;
    NSDictionary *dict = [nw.screen deviceDescription];
    NSNumber *displayIDns = dict[@"NSScreenNumber"];
    if (displayIDns) return [displayIDns unsignedIntValue];
    return (CGDirectDisplayID)-1;
}

static void
_glfwHandleDisplayLinkTick(_GLFWDisplayLinkNS *entry) {
    os_unfair_lock *lock = lock_for_entry(entry);
    os_unfair_lock_lock(lock);
    const bool should_dispatch = entry->first_unserviced_render_frame_request_at && !entry->pending_dispatch;
    CGDirectDisplayID displayID = entry->displayID;
    if (should_dispatch) entry->pending_dispatch = true;
    os_unfair_lock_unlock(lock);
    if (should_dispatch) dispatch_async_f(dispatch_get_main_queue(), (void*)(uintptr_t)displayID, _glfwDispatchRenderFrame);
}

void
_glfwClearDisplayLinks(void) {
    for (size_t i = 0; i < displayLinks.count; i++) {
        _GLFWDisplayLinkNS *entry = &displayLinks.entries[i];
        os_unfair_lock *lock = &displayLinks.locks[i];
#if GLFW_HAS_CADISPLAYLINK
        CADisplayLink *caLink = NULL;
        GLFWCADisplayLinkTarget *target = NULL;
#endif
        CVDisplayLinkRef link = NULL;

        os_unfair_lock_lock(lock);
        const bool wasCADisplayLink = entry->useCADisplayLink;
#if GLFW_HAS_CADISPLAYLINK
        if (wasCADisplayLink) {
            caLink = entry->caDisplayLink;
            target = entry->target;
            if (target) {
                [target detach];
            }
            entry->caDisplayLink = NULL;
            entry->target = NULL;
        }
#endif
        if (!wasCADisplayLink) link = entry->displayLink;
        entry->displayLink = NULL;
        entry->displayID = (CGDirectDisplayID)0;
        entry->lastRenderFrameRequestedAt = 0;
        entry->first_unserviced_render_frame_request_at = 0;
        entry->pending_dispatch = false;
        entry->useCADisplayLink = false;
        os_unfair_lock_unlock(lock);
#if GLFW_HAS_CADISPLAYLINK
        if (wasCADisplayLink && caLink) {
            [caLink setPaused:YES];
            [caLink invalidate];
            [caLink release];
        }
        if (wasCADisplayLink && target) [target release];
#endif
        if (!wasCADisplayLink && link) {
            CVDisplayLinkStop(link);
            CVDisplayLinkRelease(link);
        }
    }
    displayLinks.count = 0;
}

#if GLFW_HAS_CADISPLAYLINK
static bool
_glfw_create_ca_display_link(_GLFWDisplayLinkNS *entry) {
    if (@available(macOS 14.0, *)) {
        NSScreen *screen = screenForDisplayID(entry->displayID);
        if (!screen)
            return false;

        GLFWCADisplayLinkTarget *target = [[GLFWCADisplayLinkTarget alloc] initWithEntry:entry];
        if (!target)
            return false;

        CADisplayLink *link = [screen displayLinkWithTarget:target selector:@selector(displayLinkDidFire:)];
        if (!link) {
            [target release];
            return false;
        }
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        link.paused = YES;
        entry->caDisplayLink = [link retain];
        entry->target = target;
        entry->useCADisplayLink = true;
        entry->displayLink = NULL;
        return true;
    }

    return false;
}
#endif

static CVReturn
displayLinkCallback(
        CVDisplayLinkRef displayLink UNUSED,
        const CVTimeStamp* now UNUSED, const CVTimeStamp* outputTime UNUSED,
        CVOptionFlags flagsIn UNUSED, CVOptionFlags* flagsOut UNUSED, void* userInfo) {
    _GLFWDisplayLinkNS *entry = (_GLFWDisplayLinkNS *)userInfo;
    if (entry) _glfwHandleDisplayLinkTick(entry);
    return kCVReturnSuccess;
}

static void
_glfw_create_cv_display_link(_GLFWDisplayLinkNS *entry) {
    CVDisplayLinkCreateWithCGDisplay(entry->displayID, &entry->displayLink);
    if (entry->displayLink) CVDisplayLinkSetOutputCallback(entry->displayLink, &displayLinkCallback, entry);
#if GLFW_HAS_CADISPLAYLINK
    if (entry->target) {
        [entry->target detach];
        [entry->target release];
        entry->target = NULL;
    }
    if (entry->caDisplayLink) {
        [entry->caDisplayLink setPaused:YES];
        [entry->caDisplayLink invalidate];
        [entry->caDisplayLink release];
        entry->caDisplayLink = NULL;
    }
#endif
    entry->useCADisplayLink = false;
}

unsigned
_glfwCreateDisplayLink(CGDirectDisplayID displayID) {
    for (unsigned i = 0; i < displayLinks.count; i++) {
        os_unfair_lock *existing_lock = &displayLinks.locks[i];
        os_unfair_lock_lock(existing_lock);
        const bool already_created = displayLinks.entries[i].displayID == displayID;
        os_unfair_lock_unlock(existing_lock);
        if (already_created) return i;
    }
    if (displayLinks.count >= MAX_NUM_OF_DISPLAYS) {
        _glfwInputError(GLFW_PLATFORM_ERROR, "Too many monitors cannot create display link");
        return displayLinks.count;
    }
    unsigned idx = displayLinks.count;
    _GLFWDisplayLinkNS *entry = &displayLinks.entries[idx];
    if (!displayLinks.locks_initialized[idx]) {
        displayLinks.locks[idx] = OS_UNFAIR_LOCK_INIT;
        displayLinks.locks_initialized[idx] = true;
    }
    os_unfair_lock *lock = &displayLinks.locks[idx];
    os_unfair_lock_lock(lock);
    memset(entry, 0, sizeof(entry[0]));
    entry->displayID = displayID;
    displayLinks.count++;
#if GLFW_HAS_CADISPLAYLINK
    bool created = _glfw_create_ca_display_link(entry);
    if (!created)
#endif
        _glfw_create_cv_display_link(entry);
    os_unfair_lock_unlock(lock);
    return idx;
}

static unsigned long long display_link_shutdown_timer = 0;

static void
_glfwShutdownCVDisplayLink(unsigned long long timer_id UNUSED, void *user_data UNUSED) {
    display_link_shutdown_timer = 0;
    for (size_t i = 0; i < displayLinks.count; i++) {
        _GLFWDisplayLinkNS *dl = &displayLinks.entries[i];
        os_unfair_lock *lock = &displayLinks.locks[i];
        os_unfair_lock_lock(lock);
        const bool wasCADisplayLink = dl->useCADisplayLink;
#if GLFW_HAS_CADISPLAYLINK
        CADisplayLink *caLink = NULL;
        if (wasCADisplayLink) {
            caLink = dl->caDisplayLink;
            if (caLink) [caLink retain];
        }
#endif
        CVDisplayLinkRef link = wasCADisplayLink ? NULL : dl->displayLink;
        if (link) CVDisplayLinkRetain(link);
        dl->lastRenderFrameRequestedAt = 0;
        dl->first_unserviced_render_frame_request_at = 0;
        dl->pending_dispatch = false;
        os_unfair_lock_unlock(lock);
#if GLFW_HAS_CADISPLAYLINK
        if (wasCADisplayLink && caLink) {
            [caLink setPaused:YES];
            [caLink release];
        }
#endif
        if (!wasCADisplayLink && link) {
            CVDisplayLinkStop(link);
            CVDisplayLinkRelease(link);
        }
    }
}

void
_glfwRequestRenderFrame(_GLFWwindow *w) {
    CGDirectDisplayID displayID = displayIDForWindow(w);
    if (display_link_shutdown_timer) {
        _glfwPlatformUpdateTimer(display_link_shutdown_timer, DISPLAY_LINK_SHUTDOWN_CHECK_INTERVAL, true);
    } else {
        display_link_shutdown_timer = _glfwPlatformAddTimer(DISPLAY_LINK_SHUTDOWN_CHECK_INTERVAL, false, _glfwShutdownCVDisplayLink, NULL, NULL);
    }
    monotonic_t now = glfwGetTime();
    bool found_display_link = false;
    _GLFWDisplayLinkNS *dl = NULL;
    for (size_t i = 0; i < displayLinks.count; i++) {
        dl = &displayLinks.entries[i];
        bool need_start = false, need_stop = false, need_recreate = false;
        bool retain_link = false;
#if GLFW_HAS_CADISPLAYLINK
        CADisplayLink *caLink = NULL;
#endif
        CVDisplayLinkRef link = NULL;
        os_unfair_lock *lock = &displayLinks.locks[i];
        os_unfair_lock_lock(lock);
#if GLFW_HAS_CADISPLAYLINK
        const bool usesCA = dl->useCADisplayLink;
        caLink = usesCA ? dl->caDisplayLink : NULL;
#else
        const bool usesCA = false;
#endif
        link = usesCA ? NULL : dl->displayLink;
        if (dl->displayID == displayID) {
            found_display_link = true;
            monotonic_t first_unserviced = dl->first_unserviced_render_frame_request_at;
            dl->lastRenderFrameRequestedAt = now;
            if (!first_unserviced) {
                dl->first_unserviced_render_frame_request_at = now;
                first_unserviced = now;
            }
            dl->pending_dispatch = false;
#if GLFW_HAS_CADISPLAYLINK
            if (usesCA) {
                if (caLink && caLink.isPaused) {
                    need_start = true;
                    retain_link = true;
                }
            } else
#endif
            if (link) {
                if (!CVDisplayLinkIsRunning(link)) {
                    need_start = true;
                    retain_link = true;
                } else if (now - first_unserviced > s_to_monotonic_t(1ll)) {
                    need_recreate = true;
                    dl->first_unserviced_render_frame_request_at = now;
                    dl->displayLink = NULL;
                }
            }
        } else if (dl->lastRenderFrameRequestedAt && now - dl->lastRenderFrameRequestedAt >= DISPLAY_LINK_SHUTDOWN_CHECK_INTERVAL) {
#if GLFW_HAS_CADISPLAYLINK
            if (usesCA && caLink) {
                need_stop = true;
                retain_link = true;
                dl->lastRenderFrameRequestedAt = 0;
                dl->first_unserviced_render_frame_request_at = 0;
                dl->pending_dispatch = false;
            } else
#endif
            if (!usesCA && link) {
                need_stop = true;
                retain_link = true;
                dl->lastRenderFrameRequestedAt = 0;
                dl->first_unserviced_render_frame_request_at = 0;
                dl->pending_dispatch = false;
            }
        }
#if GLFW_HAS_CADISPLAYLINK
        if (retain_link && usesCA && caLink) [caLink retain];
#endif
        if (retain_link && !usesCA && link) CVDisplayLinkRetain(link);
        os_unfair_lock_unlock(lock);
#if GLFW_HAS_CADISPLAYLINK
        if (usesCA) {
            if (need_start && caLink) {
                caLink.paused = NO;
                [caLink release];
            } else if (need_stop && caLink) {
                caLink.paused = YES;
                [caLink release];
            } else if (retain_link && caLink) {
                [caLink release];
            }
        } else
#endif
        {
            CVDisplayLinkRef new_link = NULL;
            bool new_link_retained = false;
            if (need_recreate && link) {
                CVDisplayLinkStop(link);
                CVDisplayLinkRelease(link);
                os_unfair_lock_lock(lock);
                _glfw_create_cv_display_link(dl);
                new_link = dl->displayLink;
                if (new_link) {
                    CVDisplayLinkRetain(new_link);
                    new_link_retained = true;
                }
                dl->pending_dispatch = false;
                os_unfair_lock_unlock(lock);
                if (new_link) {
                    if (!CVDisplayLinkIsRunning(new_link)) CVDisplayLinkStart(new_link);
                    if (new_link_retained) CVDisplayLinkRelease(new_link);
                }
                _glfwInputError(GLFW_PLATFORM_ERROR,
                    "CVDisplayLink stuck possibly because of sleep/screensaver + Apple's incompetence, recreating.");
            } else {
                if (need_start && link) CVDisplayLinkStart(link);
                else if (need_stop && link) CVDisplayLinkStop(link);
                if (retain_link && link) CVDisplayLinkRelease(link);
            }
        }
    }
    if (!found_display_link) {
        unsigned idx = _glfwCreateDisplayLink(displayID);
        if (idx < displayLinks.count) {
            dl = &displayLinks.entries[idx];
            os_unfair_lock *lock = &displayLinks.locks[idx];
            os_unfair_lock_lock(lock);
            dl->lastRenderFrameRequestedAt = now;
            dl->first_unserviced_render_frame_request_at = now;
            dl->pending_dispatch = false;
#if GLFW_HAS_CADISPLAYLINK
            if (dl->useCADisplayLink) {
                CADisplayLink *caLink = dl->caDisplayLink;
                if (caLink && caLink.isPaused) caLink.paused = NO;
            } else
#endif
            {
                CVDisplayLinkRef link = dl->displayLink;
                if (link && !CVDisplayLinkIsRunning(link)) CVDisplayLinkStart(link);
            }
            os_unfair_lock_unlock(lock);
        }
    }
}

static void
_glfwDispatchRenderFrame(void *passed_in_data) {
    CGDirectDisplayID displayID = (uintptr_t)passed_in_data;
    _GLFWwindow *w = _glfw.windowListHead;
    while (w) {
        if (w->ns.renderFrameRequested && displayID == displayIDForWindow(w)) {
            w->ns.renderFrameRequested = false;
            w->ns.renderFrameCallback((GLFWwindow*)w);
        }
        w = w->next;
    }
    for (size_t i = 0; i < displayLinks.count; i++) {
        _GLFWDisplayLinkNS *dl = &displayLinks.entries[i];
        bool need_stop = false;
#if GLFW_HAS_CADISPLAYLINK
        CADisplayLink *caLink = NULL;
#endif
        CVDisplayLinkRef link = NULL;
        os_unfair_lock *lock = &displayLinks.locks[i];
        os_unfair_lock_lock(lock);
#if GLFW_HAS_CADISPLAYLINK
        const bool usesCA = dl->useCADisplayLink;
        if (usesCA) caLink = dl->caDisplayLink;
#else
        const bool usesCA = false;
#endif
        if (dl->displayID == displayID) {
            dl->first_unserviced_render_frame_request_at = 0;
            dl->pending_dispatch = false;
            bool any_pending_request = false;
            _GLFWwindow *window = _glfw.windowListHead;
            while (window) {
                if (window->ns.renderFrameRequested && displayID == displayIDForWindow(window)) {
                    any_pending_request = true;
                    break;
                }
                window = window->next;
            }
#if GLFW_HAS_CADISPLAYLINK
            if (usesCA) {
                if (!any_pending_request && caLink && !caLink.isPaused) {
                    need_stop = true;
                    [caLink retain];
                }
            } else
#endif
            {
                link = dl->displayLink;
                if (!any_pending_request && link && CVDisplayLinkIsRunning(link)) {
                    need_stop = true;
                    CVDisplayLinkRetain(link);
                }
            }
            if (need_stop) dl->lastRenderFrameRequestedAt = 0;
        }
        os_unfair_lock_unlock(lock);
#if GLFW_HAS_CADISPLAYLINK
        if (usesCA) {
            if (need_stop && caLink) {
                caLink.paused = YES;
                [caLink release];
            }
        } else
#endif
        if (need_stop && link) {
            CVDisplayLinkStop(link);
            CVDisplayLinkRelease(link);
        }
    }
}

GLFWAPI int glfwCocoaPreferredDisplayLinkBackend(void) {
#if GLFW_HAS_CADISPLAYLINK
    if (@available(macOS 14.0, *))
        return 1;
#endif
    return 0;
}

#pragma once

#include <stdbool.h>

#include "renderer_backend_types.h"

#ifdef __cplusplus
extern "C" {
#endif

bool register_metal_renderer_backend(void);
bool metal_renderer_preflight(const char **failure_reason);

#ifdef __cplusplus
}
#endif


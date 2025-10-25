#pragma once

#include <stdbool.h>
#include "compiler.h"

EXPORTED bool register_opengl_renderer_backend(void);
EXPORTED const char *opengl_renderer_disabled_reason(void);

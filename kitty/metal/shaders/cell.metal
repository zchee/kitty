#include "cell_variant_impl.metal"

#define CELL_VARIANT_SUFFIX full
#include "cell_variant_impl.metal"
#undef CELL_VARIANT_SUFFIX

#define CELL_VARIANT_SUFFIX background
#define ONLY_BACKGROUND 1
#include "cell_variant_impl.metal"
#undef ONLY_BACKGROUND
#undef CELL_VARIANT_SUFFIX

#define CELL_VARIANT_SUFFIX foreground
#define ONLY_FOREGROUND 1
#include "cell_variant_impl.metal"
#undef ONLY_FOREGROUND
#undef CELL_VARIANT_SUFFIX


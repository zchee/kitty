// G2: instanced image draws. One instance == one image ref; its src/dest rects
// come from per-draw uniform arrays indexed by gl_InstanceID, so a whole
// same-texture group is drawn in a single instanced draw call. Decoupled from
// blit_common.glsl (still used by blit/screenshot with scalar src_rect/dest_rect).
// MAX_IMAGE_INSTANCES must match kitty/shaders.c and graphics_shaders.metal.
#define MAX_IMAGE_INSTANCES 16
uniform vec4 src_rects[MAX_IMAGE_INSTANCES];
uniform vec4 dest_rects[MAX_IMAGE_INSTANCES];

out vec2 texcoord;

// Same corner LUT as blit_common (index into a rect's {left,top,right,bottom}).
const ivec2 vertex_pos_map[4] = ivec2[4](
    ivec2(2, 1),  // right, top
    ivec2(2, 3),  // right, bottom
    ivec2(0, 3),  // left, bottom
    ivec2(0, 1)   // left, top
);

void main() {
    ivec2 pos = vertex_pos_map[gl_VertexID];
    vec4 src_rect = src_rects[gl_InstanceID];
    vec4 dest_rect = dest_rects[gl_InstanceID];
    texcoord = vec2(src_rect[pos.x], src_rect[pos.y]);
    gl_Position = vec4(dest_rect[pos.x], dest_rect[pos.y], 0, 1);
}

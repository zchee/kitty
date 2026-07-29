#pragma kitty_include_shader <alpha_blend.glsl>
#pragma kitty_include_shader <utils.glsl>
#define ALPHA_TYPE

uniform sampler2D image;
#ifdef ALPHA_MASK
uniform vec3 amask_fg;
uniform vec4 amask_bg_premult;
#else
uniform float extra_alpha;
// W27 P4.2 tone-map inputs, mirroring kitty/graphics_shaders.metal so the two
// shader sources stay readable as one algorithm. On the GL backend these are
// only ever set to (>=1, 0, 0) for an SDR image, so the branch below is dead and
// GL rendering is bit-for-bit what it was; a declared-but-unused uniform
// resolves to location -1 and glUniform on -1 is silently ignored.
uniform float edr_headroom;
uniform float src_is_hdr;
uniform float src_max_component;

// See the MSL twin (kitty/graphics_shaders.metal tone_map_hdr) for the full
// rationale: soft knee hinged at 0.8*headroom iff the source overshoots the
// headroom, hard clamp otherwise, ceiling applied in both cases.
vec3 tone_map_hdr(vec3 c, float hr, float src_max) {
    if (src_max > hr) {
        float k = 0.8 * hr;
        float denom = src_max - k;
        if (denom > 0.0) {
            float slope = (hr - k) / denom;
            // step(k, c) selects the shoulder for components at or above the
            // knee. At exactly k both expressions evaluate to k, so which side
            // the boundary falls on does not matter.
            c = mix(c, k + (c - k) * slope, step(vec3(k), c));
        }
    }
    return min(c, vec3(hr));
}
#endif

in vec2 texcoord;
out vec4 output_color;

void main() {
    vec4 color = texture(image, texcoord);
#ifdef ALPHA_MASK
    color = vec4(amask_fg, color.r);
    color = vec4_premul(color);
    color = alpha_blend_premul(color, amask_bg_premult);
#else
    color.a *= extra_alpha;
    if (src_is_hdr > 0.5) {
        color.rgb = tone_map_hdr(color.rgb, edr_headroom, src_max_component);
    }
#if TEXTURE_IS_NOT_PREMULTIPLIED
    color = vec4_premul(color);
#endif
#endif
    output_color = color;
}

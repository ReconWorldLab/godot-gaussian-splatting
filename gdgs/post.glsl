#[compute]
#version 450

layout(
    local_size_x = 16,
    local_size_y = 16,
    local_size_z = 1
) in;

layout(rgba16f, binding = 0, set = 0) uniform image2D scene_tex;
layout(rgba32f, binding = 1, set = 0) uniform readonly image2D gsplat_tex;
layout(r32f, binding = 2, set = 0) uniform readonly image2D gsplat_depth_tex;
layout(set = 0, binding = 3) uniform sampler2D scene_depth_tex;

layout(push_constant, std430) uniform Params {
    vec2 screen_size;
    float alpha_cutoff;
    float depth_bias;
    float depth_test_min_alpha;
    float debug_view;
    vec2 _pad0;
    mat4 inv_projection;
} p;

const float INVALID_DEPTH = 1e19;

vec3 visualize_depth(float depth) {
    float normalized = clamp(depth / 20.0, 0.0, 1.0);
    return vec3(normalized);
}

vec3 unpremultiply_color(vec3 color, float alpha) {
    if (alpha <= 1e-5) {
        return vec3(0.0);
    }
    return color / alpha;
}

vec3 srgb_to_linear(vec3 color) {
    bvec3 cutoff = lessThanEqual(color, vec3(0.04045));
    vec3 lower = color / 12.92;
    vec3 higher = pow((color + 0.055) / 1.055, vec3(2.4));
    return mix(higher, lower, cutoff);
}

float get_scene_view_depth(ivec2 pixel, out bool has_scene_depth) {
    float raw_depth = texelFetch(scene_depth_tex, pixel, 0).r;
    if (raw_depth <= 0.0) {
        has_scene_depth = false;
        return 0.0;
    }

    vec2 uv = (vec2(pixel) + vec2(0.5)) / p.screen_size;
    vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);
    vec4 view = p.inv_projection * vec4(ndc, 1.0);
    view.xyz /= view.w;
    has_scene_depth = true;
    return -view.z;
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    vec2 size = p.screen_size;
    if (pixel.x >= int(size.x) || pixel.y >= int(size.y)) {
        return;
    }

    vec4 scene_color = imageLoad(scene_tex, pixel);
    vec4 gsplat_color = imageLoad(gsplat_tex, pixel);
    float gsplat_alpha = gsplat_color.a;
    float gsplat_view_depth = imageLoad(gsplat_depth_tex, pixel).r;
    bool has_gsplat_depth = gsplat_view_depth < INVALID_DEPTH;

    bool has_scene_depth = false;
    float scene_view_depth = get_scene_view_depth(pixel, has_scene_depth);
    bool depth_rejected = has_scene_depth && has_gsplat_depth && gsplat_alpha >= p.depth_test_min_alpha && gsplat_view_depth > scene_view_depth + p.depth_bias;

    int debug_view = int(p.debug_view + 0.5);
    if (debug_view == 1) {
        imageStore(scene_tex, pixel, vec4(vec3(gsplat_alpha), 1.0));
        return;
    }
    if (debug_view == 2) {
        vec3 gsplat_straight = unpremultiply_color(gsplat_color.rgb, gsplat_alpha);
        imageStore(scene_tex, pixel, vec4(srgb_to_linear(gsplat_straight), 1.0));
        return;
    }
    if (debug_view == 3) {
        imageStore(scene_tex, pixel, vec4(gsplat_view_depth >= INVALID_DEPTH ? vec3(0.0) : visualize_depth(gsplat_view_depth), 1.0));
        return;
    }
    if (debug_view == 4) {
        imageStore(scene_tex, pixel, vec4(has_scene_depth ? visualize_depth(scene_view_depth) : vec3(0.0), 1.0));
        return;
    }
    if (debug_view == 5) {
        imageStore(scene_tex, pixel, depth_rejected ? vec4(1.0, 0.0, 0.0, 1.0) : vec4(0.0, 1.0, 0.0, 1.0));
        return;
    }

    if (gsplat_alpha <= p.alpha_cutoff) {
        return;
    }

    if (has_scene_depth && !has_gsplat_depth) {
        return;
    }

    if (depth_rejected) {
        return;
    }

    vec3 gsplat_straight = unpremultiply_color(gsplat_color.rgb, gsplat_alpha);
    vec3 gsplat_linear = srgb_to_linear(gsplat_straight) * gsplat_alpha;
    vec3 composited_color = gsplat_linear + scene_color.rgb * (1.0 - gsplat_alpha);
    imageStore(scene_tex, pixel, vec4(composited_color, scene_color.a));
}

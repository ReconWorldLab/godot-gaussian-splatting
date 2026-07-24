// Raster ("sticker") backend: sorted-quad hardware rasterizer.
//
// One instanced quad per splat. vertex() reads the splat's position, 3D
// covariance, opacity and DC colour from the index-addressed data texture,
// projects the covariance to a 2D screen-space ellipse, and expands the quad
// along the ellipse's eigen-axes by writing POSITION directly in clip space.
// fragment() evaluates the Gaussian falloff and blends through the standard
// transparent pass with the hardware depth test (no depth-bias params).
//
// The covariance-projection math is a deliberate re-expression of the Compute
// backend's GLSL (render/shaders/compute/gsplat_projection.glsl). The two MUST
// stay in parity; keep this comment in both when either changes.

shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled, specular_disabled, ambient_light_disabled;

// Index-addressed data texture: 15 RGBA32F texels per splat, laid out as the
// frozen 60-float AoS struct (see CLAUDE.md / gaussian_resource.gd).
uniform sampler2D splat_data : filter_nearest, repeat_disable;
uniform int splat_data_width = 1;
uniform int point_count = 0;
// Optional sorted-order indirection (Phase 3): order_data[sorted_pos] = splat
// index, back-to-front. When use_order is false the order is the identity
// (resource order), which is what the static Phase 2 path renders.
uniform sampler2D order_data : filter_nearest, repeat_disable;
uniform int order_width = 1;
uniform bool use_order = false;
// Quad half-size in standard deviations; splats fade to ~exp(-0.5 k^2) at the edge.
uniform float quad_extent = 3.0;
uniform float alpha_cutoff = 0.00392; // ~1/255

const float SH_C0 = 0.28209479177387814;
const int SPLATS_PER_INSTANCE = 128;
const int TEXELS_PER_SPLAT = 15;

varying flat vec4 v_color; // rgb + opacity
varying vec2 v_t;          // ellipse-local coordinate in std-dev units

vec4 fetch_texel(int texel) {
	int x = texel % splat_data_width;
	int y = texel / splat_data_width;
	return texelFetch(splat_data, ivec2(x, y), 0);
}

void vertex() {
	// Start culled: NDC (2,2,2) is outside the clip volume, so an unmodified
	// quad is clipped away. The success path at the bottom overwrites POSITION
	// and the varyings; any splat that fails a guard stays culled. (Godot forbids
	// both `return` in vertex() and writing POSITION from a helper, so this is a
	// single nested-guard path.)
	POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	v_color = vec4(0.0);
	v_t = vec2(0.0);

	int local = int(UV.x + 0.5);
	int corner = int(UV.y + 0.5);
	int sorted_pos = INSTANCE_ID * SPLATS_PER_INSTANCE + local;

	if (sorted_pos < point_count) {
		int sidx = sorted_pos;
		if (use_order) {
			int ox = sorted_pos % order_width;
			int oy = sorted_pos / order_width;
			sidx = int(texelFetch(order_data, ivec2(ox, oy), 0).r + 0.5);
		}
		int base = sidx * TEXELS_PER_SPLAT;
		vec4 t0 = fetch_texel(base + 0); // position.xyz, (pad)
		vec4 t1 = fetch_texel(base + 1); // cov xx, xy, xz, yy
		vec4 t2 = fetch_texel(base + 2); // cov yz, zz, opacity, (pad)
		vec4 t3 = fetch_texel(base + 3); // SH DC rgb, (basis1.r)

		vec3 splat_pos = t0.xyz;
		float opacity = clamp(t2.z, 0.0, 1.0);
		mat3 cov3d = mat3(
			vec3(t1.x, t1.y, t1.z),
			vec3(t1.y, t1.w, t2.x),
			vec3(t1.z, t2.x, t2.y));

		vec4 world_pos = MODEL_MATRIX * vec4(splat_pos, 1.0);
		vec4 view_pos = VIEW_MATRIX * world_pos;
		vec4 clip_pos = PROJECTION_MATRIX * view_pos;

		// Godot cameras look down -Z; only splats in front of the camera project.
		bool in_front = (view_pos.z < -0.0001) && (clip_pos.w > 0.0);
		if (in_front) {
			mat3 object_linear = mat3(MODEL_MATRIX[0].xyz, MODEL_MATRIX[1].xyz, MODEL_MATRIX[2].xyz);
			mat3 world_cov = object_linear * cov3d * transpose(object_linear);

			// --- project 3D covariance to a 2D pixel-space ellipse (parity with compute) ---
			vec2 tan_fov_inv = vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]);
			vec2 focal = (VIEWPORT_SIZE - 1.0) * 0.5 * tan_fov_inv;
			vec2 tan_fov = 1.0 / abs(tan_fov_inv);
			float depth_inv = -1.0 / view_pos.z;
			focal *= depth_inv;
			vec2 m = clamp(view_pos.xy * depth_inv, -tan_fov * 1.3, tan_fov * 1.3);
			mat3 view_linear = mat3(VIEW_MATRIX[0].xyz, VIEW_MATRIX[1].xyz, VIEW_MATRIX[2].xyz);
			mat3 jacobian = mat3(
				vec3(focal.x, 0.0, 0.0),
				vec3(0.0, focal.y, 0.0),
				vec3(focal.x * m.x, focal.y * m.y, 0.0));
			mat3 screen_transform = jacobian * view_linear;
			mat3 cov2d_m = screen_transform * world_cov * transpose(screen_transform);
			vec3 cov2d = vec3(cov2d_m[0][0] + 0.3, cov2d_m[0][1], cov2d_m[1][1] + 0.3);

			float det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
			if (det > 0.0) {
				// eigenvalues of the symmetric 2x2 [[x, y], [y, z]]
				float mid = 0.5 * (cov2d.x + cov2d.z);
				float disc = sqrt(max(0.0, mid * mid - det));
				float lambda1 = mid + disc;
				float lambda2 = max(mid - disc, 0.0);

				// eigenvector for lambda1 (major axis); e2 is perpendicular
				vec2 e1;
				if (abs(cov2d.y) < 1e-6) {
					e1 = (cov2d.x >= cov2d.z) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
				} else {
					e1 = normalize(vec2(cov2d.y, lambda1 - cov2d.x));
				}
				vec2 e2 = vec2(-e1.y, e1.x);

				float r1 = quad_extent * sqrt(lambda1);
				float r2 = quad_extent * sqrt(lambda2);

				// corner ids: 0=(-,-) 1=(+,-) 2=(+,+) 3=(-,+)
				vec2 corner_sign = vec2(
					(corner == 1 || corner == 2) ? 1.0 : -1.0,
					(corner >= 2) ? 1.0 : -1.0);

				vec2 pixel_offset = corner_sign.x * r1 * e1 + corner_sign.y * r2 * e2;
				vec2 ndc_offset = pixel_offset * 2.0 / VIEWPORT_SIZE;

				vec4 pos = clip_pos;
				pos.xy += ndc_offset * clip_pos.w;
				POSITION = pos;

				// std-dev coordinate at this corner; interpolates across the quad
				v_t = corner_sign * quad_extent;

				vec3 color = max(vec3(0.0), 0.5 + SH_C0 * t3.xyz);
				v_color = vec4(color, opacity);
			}
		}
	}
}

void fragment() {
	float power = -0.5 * dot(v_t, v_t);
	float a = v_color.a * exp(power);
	if (a < alpha_cutoff) {
		discard;
	}
	ALBEDO = v_color.rgb;
	ALPHA = clamp(a, 0.0, 1.0);
}

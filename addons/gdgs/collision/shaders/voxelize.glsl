#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ParamsBuffer {
    float values[];
} params_buffer;

// 16 floats per splat:
// position.xyz, opacity; extent.xyz, pad;
// inv_xx, inv_xy, inv_xz, inv_yy; inv_yz, inv_zz, pad, pad.
layout(set = 0, binding = 1, std430) restrict readonly buffer SplatBuffer {
    float values[];
} splat_buffer;

// 5 uints per workgroup: block xyz, candidate offset, candidate count.
layout(set = 0, binding = 2, std430) restrict readonly buffer BlockBuffer {
    uint values[];
} block_buffer;

layout(set = 0, binding = 3, std430) restrict readonly buffer CandidateBuffer {
    uint values[];
} candidate_buffer;

// Two uint32 words per workgroup form the 64-bit block occupancy mask.
layout(set = 0, binding = 4, std430) restrict writeonly buffer ResultBuffer {
    uint values[];
} result_buffer;

shared uint block_mask[2];

void main() {
    uint bit_index = gl_LocalInvocationID.x;
    uint groups_x = uint(params_buffer.values[5]);
    uint group_index = gl_WorkGroupID.x + gl_WorkGroupID.y * groups_x;
    if (group_index >= uint(params_buffer.values[6])) {
        return;
    }
    if (bit_index < 2u) {
        block_mask[bit_index] = 0u;
    }
    barrier();

    uint block_base = group_index * 5u;
    uvec3 block_coord = uvec3(
        block_buffer.values[block_base],
        block_buffer.values[block_base + 1u],
        block_buffer.values[block_base + 2u]
    );
    uint candidate_offset = block_buffer.values[block_base + 3u];
    uint candidate_count = block_buffer.values[block_base + 4u];
    uvec3 local_coord = uvec3(bit_index & 3u, (bit_index >> 2u) & 3u, bit_index >> 4u);
    uvec3 voxel_coord = block_coord * 4u + local_coord;
    vec3 origin = vec3(params_buffer.values[0], params_buffer.values[1], params_buffer.values[2]);
    float voxel_size = params_buffer.values[3];
    float sigma_threshold = params_buffer.values[4];
    vec3 voxel_min = origin + vec3(voxel_coord) * voxel_size;
    vec3 voxel_max = voxel_min + vec3(voxel_size);
    float sigma = 0.0;

    for (uint candidate = 0u; candidate < candidate_count && sigma < 7.0; ++candidate) {
        uint splat_index = candidate_buffer.values[candidate_offset + candidate];
        uint base = splat_index * 16u;
        vec3 center = vec3(
            splat_buffer.values[base],
            splat_buffer.values[base + 1u],
            splat_buffer.values[base + 2u]
        );
        float opacity = splat_buffer.values[base + 3u];
        vec3 extent = vec3(
            splat_buffer.values[base + 4u],
            splat_buffer.values[base + 5u],
            splat_buffer.values[base + 6u]
        );
        if (any(lessThan(voxel_max, center - extent)) || any(greaterThan(voxel_min, center + extent))) {
            continue;
        }
        vec3 closest = clamp(center, voxel_min, voxel_max);
        vec3 delta = closest - center;
        float inv_xx = splat_buffer.values[base + 8u];
        float inv_xy = splat_buffer.values[base + 9u];
        float inv_xz = splat_buffer.values[base + 10u];
        float inv_yy = splat_buffer.values[base + 11u];
        float inv_yz = splat_buffer.values[base + 12u];
        float inv_zz = splat_buffer.values[base + 13u];
        float distance_squared =
            inv_xx * delta.x * delta.x + inv_yy * delta.y * delta.y + inv_zz * delta.z * delta.z +
            2.0 * (inv_xy * delta.x * delta.y + inv_xz * delta.x * delta.z + inv_yz * delta.y * delta.z);
        if (distance_squared >= -0.00001 && !isnan(distance_squared) && !isinf(distance_squared)) {
            sigma += opacity * exp(-0.5 * max(distance_squared, 0.0));
        }
    }

    if (sigma >= sigma_threshold) {
        atomicOr(block_mask[bit_index >> 5u], 1u << (bit_index & 31u));
    }
    barrier();
    if (bit_index < 2u) {
        result_buffer.values[group_index * 2u + bit_index] = block_mask[bit_index];
    }
}

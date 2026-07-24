#[compute]
#version 460 core

#extension GL_KHR_shader_subgroup_basic: enable

/**
 * vulkan_radix_sort, modified under the MIT license.
 * Source: https://github.com/jaesung-cs/vulkan_radix_sort/tree/master
 */

#define RADIX              (256)
#define WORKGROUP_SIZE     (512)
#define PARTITION_DIVISION (8)
#define PARTITION_SIZE     (PARTITION_DIVISION * WORKGROUP_SIZE)

layout (local_size_x = WORKGROUP_SIZE) in;

layout (std430, set = 0, binding = 0) restrict buffer Histogram {
    uint element_count;
    uint global_histogram[4*RADIX];                 // (4, RADIX)
    uint partition_histogram[PARTITION_SIZE*RADIX]; // (PARTITION_SIZE, RADIX)
};

layout (std430, set = 0, binding = 1) restrict readonly buffer KeysBuffer {
    uint keys[]; // (NUM_ELEMENTS)
};

layout (push_constant) uniform PushConstant {
    int pass;
    uint in_offset;
    float _pad0;
    float _pad1;
};

shared uint local_histogram[RADIX];

void main() {
    uint thread_index = gl_SubgroupInvocationID; // 0..31
    uint subgroup_index = gl_SubgroupID;         // 0..31
    uint index = subgroup_index * gl_SubgroupSize + thread_index;

    uint element_count = element_count;
    uint partition_index = gl_WorkGroupID.x;
    uint partition_start = partition_index * PARTITION_SIZE;

    // Discard all workgroup invocations
    if (partition_start >= element_count) return;

    if (index < RADIX) local_histogram[index] = 0;
    barrier();

    // Local histogram
    for (int i = 0; i < PARTITION_DIVISION; ++i) {
        uint key_index = partition_start + WORKGROUP_SIZE * i + index;
        uint key = key_index < element_count ? keys[key_index + in_offset] : 0xffffffff;
        uint radix = bitfieldExtract(key, 8 * pass, 8);
        atomicAdd(local_histogram[radix], 1);
    }
    barrier();

    if (index < RADIX) {
        // Set to partition histogram
        partition_histogram[RADIX * partition_index + index] = local_histogram[index];
        // Add to global histogram
        atomicAdd(global_histogram[RADIX * pass + index], local_histogram[index]);
    }
}

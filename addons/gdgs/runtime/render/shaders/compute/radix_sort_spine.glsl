#[compute]
#version 460 core

#extension GL_KHR_shader_subgroup_basic: enable
#extension GL_KHR_shader_subgroup_arithmetic: enable
#extension GL_KHR_shader_subgroup_ballot: enable

/**
 * vulkan_radix_sort, modified under the MIT license.
 * Source: https://github.com/jaesung-cs/vulkan_radix_sort/tree/master
 */

#define RADIX              (256)
#define SUBGROUP_SIZE      (32)
#define WORKGROUP_SIZE     (512)
#define PARTITION_DIVISION (8)
#define PARTITION_SIZE     (PARTITION_DIVISION * WORKGROUP_SIZE)

// Dispatch this shader (RADIX, 1, 1), so that gl_WorkGroupID.x is radix
layout (local_size_x = WORKGROUP_SIZE) in;

layout (std430, set = 0, binding = 0) restrict buffer Histogram {
    uint element_count;
    uint global_histogram[4*RADIX];                // (4, RADIX)
    uint parition_histogram[PARTITION_SIZE*RADIX]; // (PARTITION_SIZE, RADIX)
};

layout (push_constant) uniform PushConstant {
    int pass;
    float _pad0;
    float _pad1;
    float _pad2;
};

shared uint reduction;
shared uint intermediate[SUBGROUP_SIZE];

void main() {
    uint thread_index = gl_SubgroupInvocationID; // 0..31
    uint subgroup_index = gl_SubgroupID;         // 0..15
    uint index = subgroup_index * gl_SubgroupSize + thread_index;
    uint radix = gl_WorkGroupID.x;

    uint element_count = element_count;
    uint partition_count = (element_count + PARTITION_SIZE - 1) / PARTITION_SIZE;

    if (index == 0) reduction = 0;
    barrier();

    for (uint i = 0; WORKGROUP_SIZE * i < partition_count; ++i) {
        uint partition_index = WORKGROUP_SIZE * i + index;
        uint value = partition_index < partition_count ? parition_histogram[RADIX * partition_index + radix] : 0;
        uint excl = subgroupExclusiveAdd(value) + reduction;
        uint sum = subgroupAdd(value);

        if (subgroupElect()) intermediate[subgroup_index] = sum;
        barrier();

        if (index < gl_NumSubgroups) {
            uint excl = subgroupExclusiveAdd(intermediate[index]);
            uint sum = subgroupAdd(intermediate[index]);
            intermediate[index] = excl;

            if (index == 0) reduction += sum;
        }
        barrier();

        if (partition_index < partition_count) {
            excl += intermediate[subgroup_index];
            parition_histogram[RADIX * partition_index + radix] = excl;
        }
        barrier();
    }

    if (gl_WorkGroupID.x == 0) {
        // One workgroup is responsible for global histogram prefix sum
        if (index < RADIX) {
            uint value = global_histogram[RADIX * pass + index];
            uint excl = subgroupExclusiveAdd(value);
            uint sum = subgroupAdd(value);

            if (subgroupElect()) intermediate[subgroup_index] = sum;
            barrier();

            if (index < RADIX / gl_SubgroupSize) {
                uint excl = subgroupExclusiveAdd(intermediate[index]);
                intermediate[index] = excl;
            }
            barrier();

            excl += intermediate[subgroup_index];
            global_histogram[RADIX * pass + index] = excl;
        }
    }
}

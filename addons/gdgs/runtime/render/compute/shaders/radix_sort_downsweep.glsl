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
#define WORKGROUP_SIZE     (512)
#define PARTITION_DIVISION (8)
#define PARTITION_SIZE     (PARTITION_DIVISION * WORKGROUP_SIZE)

layout (local_size_x = WORKGROUP_SIZE) in;

layout (std430, set = 0, binding = 0) restrict readonly buffer Histogram {
    uint element_count;
    uint global_histogram[4*RADIX];                 // (4, RADIX)
    uint partition_histogram[PARTITION_SIZE*RADIX]; // (PARTITION_SIZE, RADIX)
};

layout (std430, set = 0, binding = 1) restrict buffer KeysBuffer {
    uint keys[]; // (NUM_ELEMENTS)
};

layout (std430, set = 0, binding = 2) restrict buffer ValuesBuffer {
    uint values[]; // (NUM_ELEMENTS)
};

layout (push_constant) uniform PushConstant {
    int pass;
    uint in_offset;
    uint out_offset;
    float _pad;
};

const uint SHMEM_SIZE = PARTITION_SIZE;
shared uint local_histogram[SHMEM_SIZE]; // (R, S=16)=4096, (P) for alias. take maximum.
shared uint local_histogram_sum[RADIX];

void main() {
    uint thread_index = gl_SubgroupInvocationID; // 0..31
    uint subgroup_index = gl_SubgroupID;         // 0..15
    uint index = subgroup_index * gl_SubgroupSize + thread_index;

    uint partition_index = gl_WorkGroupID.x;
    uint partition_start = partition_index * PARTITION_SIZE;
    uint element_count = element_count;

    if (partition_start >= element_count) return;

    if (index < RADIX) {
        for (int i = 0; i < gl_NumSubgroups; ++i) {
            local_histogram[gl_NumSubgroups * index + i] = 0;
        }
    }
    barrier();

    // Load from global memory, local histogram and offset
    uint local_keys[PARTITION_DIVISION];
    uint local_radix[PARTITION_DIVISION];
    uint local_offsets[PARTITION_DIVISION];
    uint subgroup_histogram[PARTITION_DIVISION];

    uint local_values[PARTITION_DIVISION];
    for (int i = 0; i < PARTITION_DIVISION; ++i) {
        uint key_index = partition_start + (PARTITION_DIVISION * gl_SubgroupSize) * subgroup_index + i * gl_SubgroupSize + thread_index;
        uint key = key_index < element_count ? keys[key_index + in_offset] : 0xffffffff;
        local_keys[i] = key;
        local_values[i] = key_index < element_count ? values[key_index + in_offset] : 0;

        uint radix = bitfieldExtract(key, pass * 8, 8);
        local_radix[i] = radix;

        // Mask per digit
        uvec4 mask = subgroupBallot(true);
        #pragma unroll
        for (int j = 0; j < 8; ++j) {
            uint digit = (radix >> j) & 1;
            uvec4 ballot = subgroupBallot(digit == 1);
            // digit - 1 is 0 or 0xffffffff. xor to flip.
            mask &= uvec4(digit - 1) ^ ballot;
        }

        // Subgroup level offset for radix
        uint subgroup_offset = subgroupBallotExclusiveBitCount(mask);
        uint radix_count = subgroupBallotBitCount(mask);

        // Elect a representative per radix, add to histogram
        if (subgroup_offset == 0) {
            // accumulate to local histogram
            atomicAdd(local_histogram[gl_NumSubgroups * radix + subgroup_index], radix_count);
            subgroup_histogram[i] = radix_count;
        } else {
            subgroup_histogram[i] = 0;
        }

        local_offsets[i] = subgroup_offset;
    }
    barrier();

    // Local histogram reduce 4096
    for (uint i = index; i < RADIX * gl_NumSubgroups; i += WORKGROUP_SIZE) {
        uint v = local_histogram[i];
        uint sum = subgroupAdd(v);
        uint excl = subgroupExclusiveAdd(v);
        local_histogram[i] = excl;

        if (thread_index == 0) local_histogram_sum[i / gl_SubgroupSize] = sum;
    }
    barrier();

    // Local histogram reduce 128
    uint intermediate_offset = RADIX * gl_NumSubgroups / gl_SubgroupSize;
    if (index < intermediate_offset) {
        uint v = local_histogram_sum[index];
        uint sum = subgroupAdd(v);
        uint excl = subgroupExclusiveAdd(v);
        local_histogram_sum[index] = excl;
        
        if (thread_index == 0) local_histogram_sum[intermediate_offset + index / gl_SubgroupSize] = sum;
    }
    barrier();

    // Local histogram reduce 4 or 1
    uint intermediate_size = max(RADIX * gl_NumSubgroups / gl_SubgroupSize / gl_SubgroupSize, 1u);
    if (index < intermediate_size) {
        uint v = local_histogram_sum[intermediate_offset + index];
        uint excl = subgroupExclusiveAdd(v);
        local_histogram_sum[intermediate_offset + index] = excl;
    }
    barrier();

    // Local histogram add 128
    if (index < intermediate_offset) {
        local_histogram_sum[index] += local_histogram_sum[intermediate_offset + index / gl_SubgroupSize];
    }
    barrier();

    // Local histogram add 4096
    for (uint i = index; i < RADIX * gl_NumSubgroups; i += WORKGROUP_SIZE) {
        local_histogram[i] += local_histogram_sum[i / gl_SubgroupSize];
    }
    barrier();

    // Post-scan stage
    for (int i = 0; i < PARTITION_DIVISION; ++i) {
        uint radix = local_radix[i];
        local_offsets[i] += local_histogram[gl_NumSubgroups * radix + subgroup_index];

        barrier();
        if (subgroup_histogram[i] > 0) {
            atomicAdd(local_histogram[gl_NumSubgroups * radix + subgroup_index], subgroup_histogram[i]);
        }
        barrier();
    }

    // After atomicAdd, local_histogram contains inclusive sum
    if (index < RADIX) {
        uint v = index == 0 ? 0 : local_histogram[gl_NumSubgroups * index - 1];
        local_histogram_sum[index] = global_histogram[RADIX * pass + index] + partition_histogram[RADIX * partition_index + index] - v;
    }
    barrier();

    // Rearrange keys. grouping keys together makes dst_offset to be almost sequential, grants huge speed boost.
    // Now local_histogram is unused, so alias memory.
    for (int i = 0; i < PARTITION_DIVISION; ++i) {
        local_histogram[local_offsets[i]] = local_keys[i];
    }
    barrier();

    // --- Binning ---
    for (uint i = index; i < PARTITION_SIZE; i += WORKGROUP_SIZE) {
        uint key = local_histogram[i];
        uint radix = bitfieldExtract(key, pass * 8, 8);
        uint dst_offset = local_histogram_sum[radix] + i;
        if (dst_offset < element_count) {
            keys[dst_offset + out_offset] = key;
        }

        local_keys[i / WORKGROUP_SIZE] = dst_offset;
    }

    barrier();

    for (int i = 0; i < PARTITION_DIVISION; ++i) {
        local_histogram[local_offsets[i]] = local_values[i];
    }
    barrier();

    for (uint i = index; i < PARTITION_SIZE; i += WORKGROUP_SIZE) {
        uint value = local_histogram[i];
        uint dst_offset = local_keys[i / WORKGROUP_SIZE];
        if (dst_offset < element_count) {
            values[dst_offset + out_offset] = value;
        }
    }
}

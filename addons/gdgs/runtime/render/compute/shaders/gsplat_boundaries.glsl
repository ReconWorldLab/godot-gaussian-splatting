#[compute]
#version 460

#define BLOCK_SIZE (256)

layout (local_size_x = BLOCK_SIZE, local_size_y = 1, local_size_z = 1) in;

layout (std430, set = 0, binding = 0) restrict readonly buffer Histograms {
    uint sort_buffer_size;
    uint histogram[];
};

layout (std430, set = 0, binding = 1) restrict readonly buffer SortBuffer {
    uint sort_buffer[];
};

layout (std430, set = 0, binding = 2) restrict writeonly buffer BoundsBuffer {
    uvec2 bounds_buffer[];
};

void main() {
    const uint id = gl_GlobalInvocationID.x;
    const uint count = sort_buffer_size;
    if (id >= count) return;

    const uint tile_id = sort_buffer[id] >> 16;

    if (id == 0) {
        bounds_buffer[tile_id].x = 0;
    } else {
        const uint prev_tile_id = sort_buffer[id - 1] >> 16;
        if (prev_tile_id != tile_id) {
            bounds_buffer[prev_tile_id].y = id;
            bounds_buffer[tile_id].x = id;
        }
    }

    if (id == count - 1) {
        // End index is exclusive to match num_splats = bounds.y - bounds.x
        bounds_buffer[tile_id].y = count;
    }
}

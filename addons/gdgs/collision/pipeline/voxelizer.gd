extends RefCounted

const COMMON := preload("res://addons/gdgs/collision/pipeline/pipeline_common.gd")
const CANDIDATE_INDEX_SCRIPT := preload("res://addons/gdgs/collision/pipeline/candidate_index.gd")

const MAX_SIGMA := 7.0
const NEIGHBORS := [
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(0, -1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, -1), Vector3i(0, 0, 1),
]


static func voxelize(
	source: Dictionary,
	grid: RefCounted,
	opacity_cutoff: float,
	max_candidate_references: int,
	control: RefCounted = null
) -> Dictionary:
	var index_result: Dictionary = CANDIDATE_INDEX_SCRIPT.build(source, grid, max_candidate_references, control)
	if not index_result.get("ok", false):
		return index_result
	var positions: PackedVector3Array = source["positions"]
	var inverse_covariances: PackedFloat32Array = source["inverse_covariances"]
	var opacities: PackedFloat32Array = source["opacities"]
	var voxel_ranges: PackedInt32Array = index_result["voxel_ranges"]
	var blocks: PackedInt32Array = index_result["blocks"]
	var starts: PackedInt32Array = index_result["starts"]
	var counts: PackedInt32Array = index_result["counts"]
	var candidates: PackedInt32Array = index_result["candidates"]
	var candidate_references: int = index_result["candidate_references"]

	# Hot loop: everything the per-voxel math needs lives in locals.
	var origin_x: float = grid.origin.x
	var origin_y: float = grid.origin.y
	var origin_z: float = grid.origin.z
	var voxel_size: float = grid.voxel_size

	var sigma_threshold := -log(1.0 - opacity_cutoff)
	var occupied_blocks := 0
	var block_count := blocks.size()
	var sigma := PackedFloat32Array()
	sigma.resize(64)
	for block_offset in block_count:
		if block_offset % 32 == 0:
			if COMMON.is_cancelled(control):
				return COMMON.cancelled_result()
			COMMON.phase_progress(control, "Voxelizing Gaussian density", &"voxelize", float(block_offset) / maxf(block_count, 1))
		var block_index := blocks[block_offset]
		var block_coordinate: Vector3i = grid.decode_block_index(block_index)
		var block_voxel_min := block_coordinate * 4
		var block_voxel_max := block_voxel_min + Vector3i(3, 3, 3)
		sigma.fill(0.0)
		var saturated_bits := 0
		var candidate_start := starts[block_offset]
		var candidate_end := candidate_start + counts[block_offset]
		for candidate_offset in range(candidate_start, candidate_end):
			if saturated_bits == 64:
				break
			var splat_index := candidates[candidate_offset]
			var range_base := splat_index * 6
			var voxel_min_x := maxi(voxel_ranges[range_base + 0], block_voxel_min.x)
			var voxel_min_y := maxi(voxel_ranges[range_base + 1], block_voxel_min.y)
			var voxel_min_z := maxi(voxel_ranges[range_base + 2], block_voxel_min.z)
			var voxel_max_x := mini(voxel_ranges[range_base + 3], block_voxel_max.x)
			var voxel_max_y := mini(voxel_ranges[range_base + 4], block_voxel_max.y)
			var voxel_max_z := mini(voxel_ranges[range_base + 5], block_voxel_max.z)
			var center := positions[splat_index]
			var inverse_base := splat_index * 6
			var inv_xx := inverse_covariances[inverse_base + 0]
			var inv_xy := inverse_covariances[inverse_base + 1]
			var inv_xz := inverse_covariances[inverse_base + 2]
			var inv_yy := inverse_covariances[inverse_base + 3]
			var inv_yz := inverse_covariances[inverse_base + 4]
			var inv_zz := inverse_covariances[inverse_base + 5]
			var opacity := opacities[splat_index]
			for iz in range(voxel_min_z, voxel_max_z + 1):
				var voxel_z_min := origin_z + iz * voxel_size
				var delta_z := clampf(center.z, voxel_z_min, voxel_z_min + voxel_size) - center.z
				for iy in range(voxel_min_y, voxel_max_y + 1):
					var voxel_y_min := origin_y + iy * voxel_size
					var delta_y := clampf(center.y, voxel_y_min, voxel_y_min + voxel_size) - center.y
					for ix in range(voxel_min_x, voxel_max_x + 1):
						var local_bit := (ix & 3) + ((iy & 3) << 2) + ((iz & 3) << 4)
						var accumulated := sigma[local_bit]
						if accumulated >= MAX_SIGMA:
							continue
						var voxel_x_min := origin_x + ix * voxel_size
						var delta_x := clampf(center.x, voxel_x_min, voxel_x_min + voxel_size) - center.x
						var distance_squared := (
							inv_xx * delta_x * delta_x + inv_yy * delta_y * delta_y + inv_zz * delta_z * delta_z +
							2.0 * (inv_xy * delta_x * delta_y + inv_xz * delta_x * delta_z + inv_yz * delta_y * delta_z)
						)
						if distance_squared < 0.0 and distance_squared > -1.0e-5:
							distance_squared = 0.0
						if distance_squared >= 0.0 and is_finite(distance_squared):
							accumulated += opacity * exp(-0.5 * distance_squared)
							sigma[local_bit] = accumulated
							if accumulated >= MAX_SIGMA:
								saturated_bits += 1

		var mask := 0
		for bit_index in 64:
			if sigma[bit_index] >= sigma_threshold:
				mask |= 1 << bit_index
		if mask != 0:
			grid.set_block_mask(block_index, mask)
			occupied_blocks += 1

	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"mesh": null,
		"stats": {
			"candidate_references": candidate_references,
			"candidate_blocks": block_count,
			"occupied_blocks_before_cleanup": occupied_blocks,
			"compute_backend": "cpu",
			"private_rendering_device": false,
		},
		"candidate_references": candidate_references,
		"candidate_blocks": block_count,
		"occupied_blocks_before_cleanup": occupied_blocks,
	}


static func cleanup(grid: RefCounted, control: RefCounted = null) -> Dictionary:
	var original: Dictionary = grid.get_blocks_snapshot()
	var cleaned: Dictionary = {}
	var removed := 0
	var filled := 0
	var block_keys: Array = original.keys()
	var block_count := block_keys.size()
	for block_offset in block_count:
		if block_offset % 64 == 0:
			if COMMON.is_cancelled(control):
				return COMMON.cancelled_result()
			COMMON.phase_progress(control, "Cleaning isolated voxels", &"cleanup", float(block_offset) / maxf(block_count, 1))
		var block_index_value: Variant = block_keys[block_offset]
		var block_index := int(block_index_value)
		var original_mask := int(original[block_index])
		if original_mask == -1:
			cleaned[block_index] = original_mask
			continue
		var coordinate: Vector3i = grid.decode_block_index(block_index)
		var voxel_base := coordinate * 4
		var cleaned_mask := 0
		for bit_index in 64:
			var local_x := bit_index & 3
			var local_y := (bit_index >> 2) & 3
			var local_z := (bit_index >> 4) & 3
			var voxel := voxel_base + Vector3i(local_x, local_y, local_z)
			var was_solid := (original_mask & (1 << bit_index)) != 0
			var any_neighbor := false
			var all_neighbors := true
			for offset: Vector3i in NEIGHBORS:
				var neighbor_solid: bool = grid.is_voxel_solid_in(original, voxel.x + offset.x, voxel.y + offset.y, voxel.z + offset.z)
				any_neighbor = any_neighbor or neighbor_solid
				all_neighbors = all_neighbors and neighbor_solid
			var is_solid := (was_solid and any_neighbor) or (not was_solid and all_neighbors)
			if is_solid:
				cleaned_mask |= 1 << bit_index
			if was_solid and not is_solid:
				removed += 1
			elif not was_solid and is_solid:
				filled += 1
		if cleaned_mask != 0:
			cleaned[block_index] = cleaned_mask
	grid.replace_blocks(cleaned)
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"mesh": null,
		"stats": {"removed_voxels": removed, "filled_voxels": filled},
	}

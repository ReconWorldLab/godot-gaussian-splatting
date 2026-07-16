extends RefCounted

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
	var positions: PackedVector3Array = source["positions"]
	var inverse_covariances: PackedFloat32Array = source["inverse_covariances"]
	var extents: PackedVector3Array = source["extents"]
	var opacities: PackedFloat32Array = source["opacities"]
	var splat_count := positions.size()
	var voxel_ranges := PackedInt32Array()
	voxel_ranges.resize(splat_count * 6)
	var candidates: Dictionary = {}
	var candidate_references := 0

	for splat_index in splat_count:
		if splat_index % 1024 == 0:
			if _is_cancelled(control):
				return _cancelled_result()
			_report_progress(control, "Indexing splats into voxel blocks", 0.18 + 0.17 * float(splat_index) / maxf(splat_count, 1))
		var min_voxel: Vector3i = grid.world_to_voxel_floor(positions[splat_index] - extents[splat_index])
		var max_voxel: Vector3i = grid.world_to_voxel_floor(positions[splat_index] + extents[splat_index])
		min_voxel = min_voxel.max(Vector3i.ZERO)
		max_voxel = max_voxel.min(Vector3i(grid.nx - 1, grid.ny - 1, grid.nz - 1))
		var range_base := splat_index * 6
		voxel_ranges[range_base + 0] = min_voxel.x
		voxel_ranges[range_base + 1] = min_voxel.y
		voxel_ranges[range_base + 2] = min_voxel.z
		voxel_ranges[range_base + 3] = max_voxel.x
		voxel_ranges[range_base + 4] = max_voxel.y
		voxel_ranges[range_base + 5] = max_voxel.z
		for bz in range(min_voxel.z >> 2, (max_voxel.z >> 2) + 1):
			for by in range(min_voxel.y >> 2, (max_voxel.y >> 2) + 1):
				for bx in range(min_voxel.x >> 2, (max_voxel.x >> 2) + 1):
					candidate_references += 1
					if candidate_references > max_candidate_references:
						return _failure(
							"Gaussian-to-block candidate references exceed the safety limit (%d). Increase voxel_size." % max_candidate_references
						)
					var block_index: int = grid.block_index(bx, by, bz)
					var block_candidates: Array = candidates.get(block_index, [])
					block_candidates.append(splat_index)
					candidates[block_index] = block_candidates

	var sigma_threshold := -log(1.0 - opacity_cutoff)
	var occupied_blocks := 0
	var candidate_keys: Array = candidates.keys()
	var candidate_block_count := candidate_keys.size()
	for candidate_offset in candidate_block_count:
		if candidate_offset % 32 == 0:
			if _is_cancelled(control):
				return _cancelled_result()
			_report_progress(control, "Voxelizing Gaussian density", 0.35 + 0.38 * float(candidate_offset) / maxf(candidate_block_count, 1))
		var block_index_value: Variant = candidate_keys[candidate_offset]
		var block_index := int(block_index_value)
		var block_coordinate: Vector3i = grid.decode_block_index(block_index)
		var block_voxel_min := block_coordinate * 4
		var block_voxel_max := block_voxel_min + Vector3i(3, 3, 3)
		var sigma := PackedFloat32Array()
		sigma.resize(64)
		var block_candidates: Array = candidates[block_index]
		for splat_index_value: Variant in block_candidates:
			var splat_index := int(splat_index_value)
			var range_base := splat_index * 6
			var voxel_min := Vector3i(
				maxi(voxel_ranges[range_base + 0], block_voxel_min.x),
				maxi(voxel_ranges[range_base + 1], block_voxel_min.y),
				maxi(voxel_ranges[range_base + 2], block_voxel_min.z)
			)
			var voxel_max := Vector3i(
				mini(voxel_ranges[range_base + 3], block_voxel_max.x),
				mini(voxel_ranges[range_base + 4], block_voxel_max.y),
				mini(voxel_ranges[range_base + 5], block_voxel_max.z)
			)
			var center := positions[splat_index]
			var inverse_base := splat_index * 6
			var inv_xx := inverse_covariances[inverse_base + 0]
			var inv_xy := inverse_covariances[inverse_base + 1]
			var inv_xz := inverse_covariances[inverse_base + 2]
			var inv_yy := inverse_covariances[inverse_base + 3]
			var inv_yz := inverse_covariances[inverse_base + 4]
			var inv_zz := inverse_covariances[inverse_base + 5]
			var opacity := opacities[splat_index]
			for iz in range(voxel_min.z, voxel_max.z + 1):
				for iy in range(voxel_min.y, voxel_max.y + 1):
					for ix in range(voxel_min.x, voxel_max.x + 1):
						var local_bit := (ix & 3) + ((iy & 3) << 2) + ((iz & 3) << 4)
						if sigma[local_bit] >= MAX_SIGMA:
							continue
						var voxel_world_min: Vector3 = grid.origin + Vector3(ix, iy, iz) * grid.voxel_size
						var voxel_world_max: Vector3 = voxel_world_min + Vector3.ONE * grid.voxel_size
						var closest := Vector3(
							clampf(center.x, voxel_world_min.x, voxel_world_max.x),
							clampf(center.y, voxel_world_min.y, voxel_world_max.y),
							clampf(center.z, voxel_world_min.z, voxel_world_max.z)
						)
						var delta := closest - center
						var distance_squared := (
							inv_xx * delta.x * delta.x + inv_yy * delta.y * delta.y + inv_zz * delta.z * delta.z +
							2.0 * (inv_xy * delta.x * delta.y + inv_xz * delta.x * delta.z + inv_yz * delta.y * delta.z)
						)
						if distance_squared < 0.0 and distance_squared > -1.0e-5:
							distance_squared = 0.0
						if distance_squared >= 0.0 and is_finite(distance_squared):
							sigma[local_bit] += opacity * exp(-0.5 * distance_squared)

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
			"candidate_blocks": candidates.size(),
			"occupied_blocks_before_cleanup": occupied_blocks,
			"compute_backend": "cpu",
			"private_rendering_device": false,
		},
		"candidate_references": candidate_references,
		"candidate_blocks": candidates.size(),
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
			if _is_cancelled(control):
				return _cancelled_result()
			_report_progress(control, "Cleaning isolated voxels", 0.74 + 0.05 * float(block_offset) / maxf(block_count, 1))
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


static func _report_progress(control: RefCounted, stage: String, progress: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(progress, 0.0, 1.0))


static func _is_cancelled(control: RefCounted) -> bool:
	return control != null and control.is_cancel_requested()


static func _cancelled_result() -> Dictionary:
	return {"ok": false, "error": "Generation cancelled.", "cancelled": true, "mesh": null, "stats": {}}


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "cancelled": false, "mesh": null, "stats": {}}

extends RefCounted

const COMMON := preload("res://addons/gdgs/collision/pipeline/pipeline_common.gd")

# Builds the splat → 4³-voxel-block candidate index shared by the CPU and
# private-GPU voxelizers. The index is a CSR layout over packed int arrays
# (two counting passes) instead of a Dictionary of Arrays: at the 12M-reference
# safety limit that is ~48 MB of PackedInt32Array instead of hundreds of MB of
# Variants, and the arrays upload to the GPU without conversion.
#
# Result on success:
#   voxel_ranges: 6 ints per splat — clamped min/max voxel of its 3σ box.
#   blocks:      block index per non-empty block, ascending.
#   starts:      offset into `candidates` per entry of `blocks`.
#   counts:      candidate count per entry of `blocks`.
#   candidates:  splat indices, grouped by block.


static func build(
	source: Dictionary,
	grid: RefCounted,
	max_candidate_references: int,
	control: RefCounted = null
) -> Dictionary:
	var positions: PackedVector3Array = source["positions"]
	var extents: PackedVector3Array = source["extents"]
	var splat_count := positions.size()
	var total_blocks: int = grid.nbx * grid.nby * grid.nbz

	var voxel_ranges := PackedInt32Array()
	voxel_ranges.resize(splat_count * 6)
	var block_counts := PackedInt32Array()
	block_counts.resize(total_blocks)

	var max_voxel_bound := Vector3i(grid.nx - 1, grid.ny - 1, grid.nz - 1)
	var candidate_references := 0
	for splat_index in splat_count:
		if splat_index % 1024 == 0:
			if COMMON.is_cancelled(control):
				return COMMON.cancelled_result()
			COMMON.phase_progress(control, "Indexing splats into voxel blocks", &"index", 0.5 * float(splat_index) / maxf(splat_count, 1))
		var min_voxel: Vector3i = grid.world_to_voxel_floor(positions[splat_index] - extents[splat_index])
		var max_voxel: Vector3i = grid.world_to_voxel_floor(positions[splat_index] + extents[splat_index])
		min_voxel = min_voxel.max(Vector3i.ZERO)
		max_voxel = max_voxel.min(max_voxel_bound)
		var range_base := splat_index * 6
		voxel_ranges[range_base + 0] = min_voxel.x
		voxel_ranges[range_base + 1] = min_voxel.y
		voxel_ranges[range_base + 2] = min_voxel.z
		voxel_ranges[range_base + 3] = max_voxel.x
		voxel_ranges[range_base + 4] = max_voxel.y
		voxel_ranges[range_base + 5] = max_voxel.z
		var touched := (
			((max_voxel.x >> 2) - (min_voxel.x >> 2) + 1)
			* ((max_voxel.y >> 2) - (min_voxel.y >> 2) + 1)
			* ((max_voxel.z >> 2) - (min_voxel.z >> 2) + 1)
		)
		candidate_references += touched
		if candidate_references > max_candidate_references:
			return COMMON.failure(
				"Gaussian-to-block candidate references exceed the safety limit (%d). Increase voxel_size." % max_candidate_references
			)
		for bz in range(min_voxel.z >> 2, (max_voxel.z >> 2) + 1):
			for by in range(min_voxel.y >> 2, (max_voxel.y >> 2) + 1):
				for bx in range(min_voxel.x >> 2, (max_voxel.x >> 2) + 1):
					block_counts[grid.block_index(bx, by, bz)] += 1

	if candidate_references == 0:
		return COMMON.failure("No Gaussian splats overlap the voxel grid.")

	# Compact the non-empty blocks and lay out CSR offsets (ascending block order).
	var blocks := PackedInt32Array()
	var starts := PackedInt32Array()
	var counts := PackedInt32Array()
	var cursors := PackedInt32Array()
	cursors.resize(total_blocks)
	var running := 0
	for block_id in total_blocks:
		var count := block_counts[block_id]
		if count == 0:
			continue
		blocks.append(block_id)
		starts.append(running)
		counts.append(count)
		cursors[block_id] = running
		running += count

	var candidates := PackedInt32Array()
	candidates.resize(candidate_references)
	for splat_index in splat_count:
		if splat_index % 1024 == 0:
			if COMMON.is_cancelled(control):
				return COMMON.cancelled_result()
			COMMON.phase_progress(control, "Grouping splats by voxel block", &"index", 0.5 + 0.5 * float(splat_index) / maxf(splat_count, 1))
		var range_base := splat_index * 6
		for bz in range(voxel_ranges[range_base + 2] >> 2, (voxel_ranges[range_base + 5] >> 2) + 1):
			for by in range(voxel_ranges[range_base + 1] >> 2, (voxel_ranges[range_base + 4] >> 2) + 1):
				for bx in range(voxel_ranges[range_base + 0] >> 2, (voxel_ranges[range_base + 3] >> 2) + 1):
					var block_id: int = grid.block_index(bx, by, bz)
					candidates[cursors[block_id]] = splat_index
					cursors[block_id] += 1

	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"voxel_ranges": voxel_ranges,
		"blocks": blocks,
		"starts": starts,
		"counts": counts,
		"candidates": candidates,
		"candidate_references": candidate_references,
	}

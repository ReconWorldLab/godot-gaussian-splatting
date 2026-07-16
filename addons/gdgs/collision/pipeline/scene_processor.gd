extends RefCounted

const VOXEL_GRID_SCRIPT := preload("res://addons/gdgs/collision/pipeline/voxel_grid.gd")
const NEIGHBORS := [
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(0, -1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, -1), Vector3i(0, 0, 1),
]


static func process(grid: RefCounted, settings: Dictionary, control: RefCounted = null) -> Dictionary:
	var scene_mode: String = settings.get("scene_mode", "object")
	var do_carve: bool = settings.get("carve", false)
	if scene_mode == "object" and not do_carve:
		return _success(grid, {"scene_mode": scene_mode, "scene_filled_voxels": 0, "carve_applied": false})
	var dense := _to_dense(grid, control)
	if dense.is_empty():
		return _cancelled_result() if _is_cancelled(control) else _failure("Could not prepare the scene-mode voxel field.")
	var original := dense.duplicate()
	var dilation_world: float = settings.get("dilation", 1.6)
	var dilation_radius := ceili(dilation_world / grid.voxel_size)
	var seed: Vector3 = settings.get("seed", Vector3.ZERO)
	var stats := {
		"scene_mode": scene_mode,
		"scene_filled_voxels": 0,
		"scene_fill_skipped": false,
		"carve_applied": false,
		"carve_skipped": false,
	}

	if scene_mode == "interior":
		var fill_result := _fill_exterior(grid, dense, original, dilation_radius, seed, control)
		if not fill_result.get("ok", false):
			return fill_result
		grid = fill_result["grid"]
		dense = fill_result["dense"]
		original = dense.duplicate()
		stats.merge(fill_result["stats"], true)
	elif scene_mode == "outdoor":
		var floor_result := _fill_floor(grid, dense, original, dilation_radius, control)
		if not floor_result.get("ok", false):
			return floor_result
		dense = floor_result["dense"]
		original = dense.duplicate()
		stats.merge(floor_result["stats"], true)

	if do_carve:
		var capsule_height: float = settings.get("capsule_height", 1.6)
		var capsule_radius: float = settings.get("capsule_radius", 0.2)
		var carve_result := _carve(
			grid, dense,
			ceili(capsule_radius / grid.voxel_size),
			ceili(capsule_height / (2.0 * grid.voxel_size)),
			seed, control
		)
		if not carve_result.get("ok", false):
			return carve_result
		grid = carve_result["grid"]
		dense = carve_result["dense"]
		stats.merge(carve_result["stats"], true)

	_from_dense(grid, dense, control)
	if _is_cancelled(control):
		return _cancelled_result()
	return _success(grid, stats)


static func _fill_exterior(
	grid: RefCounted,
	dense: PackedByteArray,
	original: PackedByteArray,
	radius: int,
	seed: Vector3,
	control: RefCounted
) -> Dictionary:
	_report_progress(control, "Dilating walls for interior fill", 0.66)
	var blocked := _dilate(dense, grid.nx, grid.ny, grid.nz, radius, radius, radius, control)
	if blocked.is_empty():
		return _cancelled_result()
	_report_progress(control, "Flood-filling exterior space", 0.69)
	var visited := _flood_from_boundary(blocked, grid.nx, grid.ny, grid.nz, control)
	if visited.is_empty():
		return _cancelled_result()
	var seed_voxel: Vector3i = grid.world_to_voxel_floor(seed)
	if not _inside(seed_voxel, grid.nx, grid.ny, grid.nz):
		return {"ok": true, "grid": grid, "dense": original, "stats": {
			"scene_filled_voxels": 0, "scene_fill_skipped": true,
			"scene_fill_message": "Seed is outside the voxel grid; exterior fill was skipped.",
		}}
	var seed_index := _index(seed_voxel.x, seed_voxel.y, seed_voxel.z, grid.nx, grid.ny)
	if visited[seed_index] != 0:
		return {"ok": true, "grid": grid, "dense": original, "stats": {
			"scene_filled_voxels": 0, "scene_fill_skipped": true,
			"scene_fill_message": "Seed is reachable from outside; exterior fill was skipped.",
		}}
	_report_progress(control, "Closing interior shell", 0.72)
	var dilated_visited := _dilate(visited, grid.nx, grid.ny, grid.nz, radius, radius, radius, control)
	if dilated_visited.is_empty():
		return _cancelled_result()
	var filled := 0
	for index in dense.size():
		if original[index] == 0 and dilated_visited[index] != 0:
			filled += 1
		dense[index] = 1 if original[index] != 0 or dilated_visited[index] != 0 else 0
	var crop_result := _crop_dense(grid, dense, false, true, control)
	if not crop_result.get("ok", false):
		return crop_result
	return {"ok": true, "grid": crop_result["grid"], "dense": crop_result["dense"], "stats": {
		"scene_filled_voxels": filled, "scene_fill_skipped": false,
	}}


static func _fill_floor(
	grid: RefCounted,
	dense: PackedByteArray,
	original: PackedByteArray,
	radius: int,
	control: RefCounted
) -> Dictionary:
	_report_progress(control, "Dilating outdoor floor in XZ", 0.66)
	var dilated := _dilate(dense, grid.nx, grid.ny, grid.nz, radius, 0, radius, control)
	if dilated.is_empty():
		return _cancelled_result()
	var found := PackedByteArray()
	found.resize(dense.size())
	for z in grid.nz:
		if z % 8 == 0 and _is_cancelled(control):
			return _cancelled_result()
		for x in grid.nx:
			for y in grid.ny:
				var index := _index(x, y, z, grid.nx, grid.ny)
				if dilated[index] != 0:
					break
				found[index] = 1
	_report_progress(control, "Sealing the underside of the outdoor floor", 0.72)
	var dilated_found := _dilate(found, grid.nx, grid.ny, grid.nz, radius, 0, radius, control)
	if dilated_found.is_empty():
		return _cancelled_result()
	var filled := 0
	for index in dense.size():
		if original[index] == 0 and dilated_found[index] != 0:
			filled += 1
		dense[index] = 1 if original[index] != 0 or dilated_found[index] != 0 else 0
	return {"ok": true, "dense": dense, "stats": {
		"scene_filled_voxels": filled, "scene_fill_skipped": false,
	}}


static func _carve(
	grid: RefCounted,
	dense: PackedByteArray,
	radius_xz: int,
	radius_y: int,
	seed: Vector3,
	control: RefCounted
) -> Dictionary:
	var seed_voxel: Vector3i = grid.world_to_voxel_floor(seed)
	if not _inside(seed_voxel, grid.nx, grid.ny, grid.nz):
		return {"ok": true, "grid": grid, "dense": dense, "stats": {
			"carve_applied": false, "carve_skipped": true,
			"carve_message": "Seed is outside the voxel grid; carve was skipped.",
		}}
	_report_progress(control, "Dilating obstacles for the navigation capsule", 0.75)
	var blocked := _dilate(dense, grid.nx, grid.ny, grid.nz, radius_xz, radius_y, radius_xz, control)
	if blocked.is_empty():
		return _cancelled_result()
	var seed_index := _index(seed_voxel.x, seed_voxel.y, seed_voxel.z, grid.nx, grid.ny)
	if blocked[seed_index] != 0:
		seed_voxel = _find_nearest_free(blocked, seed_voxel, maxi(radius_xz, radius_y) * 2, grid.nx, grid.ny, grid.nz)
		if seed_voxel.x < 0:
			return {"ok": true, "grid": grid, "dense": dense, "stats": {
				"carve_applied": false, "carve_skipped": true,
				"carve_message": "Seed is blocked and no nearby free capsule position exists; carve was skipped.",
			}}
	_report_progress(control, "Flood-filling capsule-reachable space", 0.78)
	var reachable := _flood_from_seed(blocked, seed_voxel, grid.nx, grid.ny, grid.nz, control)
	if reachable.is_empty():
		return _cancelled_result()
	_report_progress(control, "Building carved navigation complement", 0.82)
	var nav_region := _dilate(reachable, grid.nx, grid.ny, grid.nz, radius_xz, radius_y, radius_xz, control)
	if nav_region.is_empty():
		return _cancelled_result()
	var crop_result := _crop_dense(grid, nav_region, true, false, control)
	if not crop_result.get("ok", false):
		return crop_result
	return {"ok": true, "grid": crop_result["grid"], "dense": crop_result["dense"], "stats": {
		"carve_applied": true, "carve_skipped": false,
	}}


static func _to_dense(grid: RefCounted, control: RefCounted) -> PackedByteArray:
	var dense := PackedByteArray()
	dense.resize(grid.nx * grid.ny * grid.nz)
	var keys: Array = grid.get_occupied_block_indices()
	for key_offset in keys.size():
		if key_offset % 128 == 0 and _is_cancelled(control):
			return PackedByteArray()
		var block_index := int(keys[key_offset])
		var mask: int = grid.get_block_mask(block_index)
		var base: Vector3i = grid.decode_block_index(block_index) * 4
		for bit in 64:
			if mask != -1 and (mask & (1 << bit)) == 0:
				continue
			var x := base.x + (bit & 3)
			var y := base.y + ((bit >> 2) & 3)
			var z := base.z + ((bit >> 4) & 3)
			dense[_index(x, y, z, grid.nx, grid.ny)] = 1
	return dense


static func _from_dense(grid: RefCounted, dense: PackedByteArray, control: RefCounted) -> void:
	var blocks: Dictionary = {}
	for bz in grid.nbz:
		if bz % 8 == 0 and _is_cancelled(control):
			return
		for by in grid.nby:
			for bx in grid.nbx:
				var mask := 0
				for lz in 4:
					for ly in 4:
						for lx in 4:
							var bit := lx + (ly << 2) + (lz << 4)
							if dense[_index(bx * 4 + lx, by * 4 + ly, bz * 4 + lz, grid.nx, grid.ny)] != 0:
								mask |= 1 << bit
				if mask != 0:
					blocks[grid.block_index(bx, by, bz)] = mask
	grid.replace_blocks(blocks)


static func _dilate(
	source: PackedByteArray,
	nx: int, ny: int, nz: int,
	rx: int, ry: int, rz: int,
	control: RefCounted
) -> PackedByteArray:
	var current := source
	if rx > 0:
		current = _dilate_x(current, nx, ny, nz, rx, control)
	if not current.is_empty() and ry > 0:
		current = _dilate_y(current, nx, ny, nz, ry, control)
	if not current.is_empty() and rz > 0:
		current = _dilate_z(current, nx, ny, nz, rz, control)
	return current


static func _dilate_x(source: PackedByteArray, nx: int, ny: int, nz: int, radius: int, control: RefCounted) -> PackedByteArray:
	var output := PackedByteArray()
	output.resize(source.size())
	for z in nz:
		if z % 8 == 0 and _is_cancelled(control):
			return PackedByteArray()
		for y in ny:
			var count := 0
			for initial_x in range(0, mini(nx, radius + 1)):
				if source[_index(initial_x, y, z, nx, ny)] != 0:
					count += 1
			for x in nx:
				output[_index(x, y, z, nx, ny)] = 1 if count > 0 else 0
				var remove_x := x - radius
				if remove_x >= 0 and source[_index(remove_x, y, z, nx, ny)] != 0:
					count -= 1
				var add_x := x + radius + 1
				if add_x < nx and source[_index(add_x, y, z, nx, ny)] != 0:
					count += 1
	return output


static func _dilate_y(source: PackedByteArray, nx: int, ny: int, nz: int, radius: int, control: RefCounted) -> PackedByteArray:
	var output := PackedByteArray()
	output.resize(source.size())
	for z in nz:
		if z % 8 == 0 and _is_cancelled(control):
			return PackedByteArray()
		for x in nx:
			var count := 0
			for initial_y in range(0, mini(ny, radius + 1)):
				if source[_index(x, initial_y, z, nx, ny)] != 0:
					count += 1
			for y in ny:
				output[_index(x, y, z, nx, ny)] = 1 if count > 0 else 0
				var remove_y := y - radius
				if remove_y >= 0 and source[_index(x, remove_y, z, nx, ny)] != 0:
					count -= 1
				var add_y := y + radius + 1
				if add_y < ny and source[_index(x, add_y, z, nx, ny)] != 0:
					count += 1
	return output


static func _dilate_z(source: PackedByteArray, nx: int, ny: int, nz: int, radius: int, control: RefCounted) -> PackedByteArray:
	var output := PackedByteArray()
	output.resize(source.size())
	for y in ny:
		if y % 8 == 0 and _is_cancelled(control):
			return PackedByteArray()
		for x in nx:
			var count := 0
			for initial_z in range(0, mini(nz, radius + 1)):
				if source[_index(x, y, initial_z, nx, ny)] != 0:
					count += 1
			for z in nz:
				output[_index(x, y, z, nx, ny)] = 1 if count > 0 else 0
				var remove_z := z - radius
				if remove_z >= 0 and source[_index(x, y, remove_z, nx, ny)] != 0:
					count -= 1
				var add_z := z + radius + 1
				if add_z < nz and source[_index(x, y, add_z, nx, ny)] != 0:
					count += 1
	return output


static func _flood_from_boundary(blocked: PackedByteArray, nx: int, ny: int, nz: int, control: RefCounted) -> PackedByteArray:
	var visited := PackedByteArray()
	visited.resize(blocked.size())
	var queue := PackedInt32Array()
	for z in nz:
		for y in ny:
			_seed_free(0, y, z, blocked, visited, queue, nx, ny)
			_seed_free(nx - 1, y, z, blocked, visited, queue, nx, ny)
	for z in nz:
		for x in nx:
			_seed_free(x, 0, z, blocked, visited, queue, nx, ny)
			_seed_free(x, ny - 1, z, blocked, visited, queue, nx, ny)
	for y in ny:
		for x in nx:
			_seed_free(x, y, 0, blocked, visited, queue, nx, ny)
			_seed_free(x, y, nz - 1, blocked, visited, queue, nx, ny)
	return _run_flood(blocked, visited, queue, nx, ny, nz, control)


static func _flood_from_seed(
	blocked: PackedByteArray,
	seed: Vector3i,
	nx: int, ny: int, nz: int,
	control: RefCounted
) -> PackedByteArray:
	var visited := PackedByteArray()
	visited.resize(blocked.size())
	var queue := PackedInt32Array()
	_seed_free(seed.x, seed.y, seed.z, blocked, visited, queue, nx, ny)
	return _run_flood(blocked, visited, queue, nx, ny, nz, control)


static func _run_flood(
	blocked: PackedByteArray,
	visited: PackedByteArray,
	queue: PackedInt32Array,
	nx: int, ny: int, nz: int,
	control: RefCounted
) -> PackedByteArray:
	var head := 0
	while head < queue.size():
		if head % 8192 == 0 and _is_cancelled(control):
			return PackedByteArray()
		var index := queue[head]
		head += 1
		var z := index / (nx * ny)
		var remainder := index - z * nx * ny
		var y := remainder / nx
		var x := remainder % nx
		for offset: Vector3i in NEIGHBORS:
			var neighbor := Vector3i(x, y, z) + offset
			if _inside(neighbor, nx, ny, nz):
				_seed_free(neighbor.x, neighbor.y, neighbor.z, blocked, visited, queue, nx, ny)
	return visited


static func _seed_free(
	x: int, y: int, z: int,
	blocked: PackedByteArray,
	visited: PackedByteArray,
	queue: PackedInt32Array,
	nx: int, ny: int
) -> void:
	var index := _index(x, y, z, nx, ny)
	if blocked[index] == 0 and visited[index] == 0:
		visited[index] = 1
		queue.append(index)


static func _find_nearest_free(
	blocked: PackedByteArray,
	seed: Vector3i,
	max_radius: int,
	nx: int, ny: int, nz: int
) -> Vector3i:
	for radius in range(1, max_radius + 1):
		for z in range(seed.z - radius, seed.z + radius + 1):
			for y in range(seed.y - radius, seed.y + radius + 1):
				for x in range(seed.x - radius, seed.x + radius + 1):
					if maxi(abs(x - seed.x), maxi(abs(y - seed.y), abs(z - seed.z))) != radius:
						continue
					var candidate := Vector3i(x, y, z)
					if _inside(candidate, nx, ny, nz) and blocked[_index(x, y, z, nx, ny)] == 0:
						return candidate
	return Vector3i(-1, -1, -1)


# Crop to one block beyond the selected region. When select_free is true the
# bounds follow zero voxels (interior fill); otherwise they follow one voxels
# (the navigable region). invert emits the selected crop's complement.
static func _crop_dense(
	grid: RefCounted,
	dense: PackedByteArray,
	invert: bool,
	select_free: bool,
	control: RefCounted
) -> Dictionary:
	var minimum := Vector3i(grid.nx, grid.ny, grid.nz)
	var maximum := Vector3i(-1, -1, -1)
	for z in grid.nz:
		if z % 8 == 0 and _is_cancelled(control):
			return _cancelled_result()
		for y in grid.ny:
			for x in grid.nx:
				var occupied := dense[_index(x, y, z, grid.nx, grid.ny)] != 0
				if occupied == select_free:
					continue
				minimum = minimum.min(Vector3i(x, y, z))
				maximum = maximum.max(Vector3i(x, y, z))
	if maximum.x < 0:
		return _failure("No navigable scene cells remain after fill/carve.")
	var min_block := Vector3i(minimum.x >> 2, minimum.y >> 2, minimum.z >> 2) - Vector3i.ONE
	var max_block := Vector3i(maximum.x >> 2, maximum.y >> 2, maximum.z >> 2) + Vector3i.ONE
	min_block = min_block.max(Vector3i.ZERO)
	max_block = max_block.min(Vector3i(grid.nbx - 1, grid.nby - 1, grid.nbz - 1))
	var dimensions := (max_block - min_block + Vector3i.ONE) * 4
	var cropped := PackedByteArray()
	cropped.resize(dimensions.x * dimensions.y * dimensions.z)
	for z in dimensions.z:
		for y in dimensions.y:
			for x in dimensions.x:
				var source_x := min_block.x * 4 + x
				var source_y := min_block.y * 4 + y
				var source_z := min_block.z * 4 + z
				var value := dense[_index(source_x, source_y, source_z, grid.nx, grid.ny)]
				cropped[_index(x, y, z, dimensions.x, dimensions.y)] = (1 - value) if invert else value
	var origin: Vector3 = grid.origin + Vector3(min_block * 4) * grid.voxel_size
	var cropped_grid = VOXEL_GRID_SCRIPT.new(origin, grid.voxel_size, dimensions.x, dimensions.y, dimensions.z)
	return {"ok": true, "grid": cropped_grid, "dense": cropped}


static func _index(x: int, y: int, z: int, nx: int, ny: int) -> int:
	return x + y * nx + z * nx * ny


static func _inside(voxel: Vector3i, nx: int, ny: int, nz: int) -> bool:
	return voxel.x >= 0 and voxel.y >= 0 and voxel.z >= 0 and voxel.x < nx and voxel.y < ny and voxel.z < nz


static func _success(grid: RefCounted, stats: Dictionary) -> Dictionary:
	return {"ok": true, "error": "", "cancelled": false, "grid": grid, "stats": stats}


static func _report_progress(control: RefCounted, stage: String, progress: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(progress, 0.0, 1.0))


static func _is_cancelled(control: RefCounted) -> bool:
	return control != null and control.is_cancel_requested()


static func _cancelled_result() -> Dictionary:
	return {"ok": false, "error": "Generation cancelled.", "cancelled": true, "grid": null, "stats": {}}


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "cancelled": false, "grid": null, "stats": {}}

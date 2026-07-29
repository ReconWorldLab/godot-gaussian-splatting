extends RefCounted

## Builds the scalar fields the per-splat lighting transfer samples.
##
## Both are separable box blurs of the binary occupancy grid, kept as dense u8
## arrays over the grid dimensions:
##
##   - `surface` (radius 1): the *smoothed* occupancy. Its central-difference
##     gradient points toward solid, so the outward normal is `-∇surface`, and
##     the gradient magnitude is a natural confidence: it peaks on the surface
##     and vanishes both in open space and deep inside a volume — exactly the
##     two places where "the surface normal here" is meaningless. That is why
##     there is no distance transform; the gradient already answers the
##     question and costs nothing extra.
##   - `open` (radius `ao_radius`): occupancy over a wider neighbourhood,
##     sampled just outside the surface to get ambient occlusion.
##
## Everything here is worker-safe: plain packed arrays and ints, no Resource,
## Node or editor access, cancellable between rows. It also deliberately avoids
## importing anything from `collision/`, so the headless tests can exercise it
## against a hand-built VoxelGrid.
##
## Cost is O(voxels) per pass, six passes total. At the pipeline's default
## resolution (128 voxels on the longest axis, ~1-2M voxels) that is a couple
## of seconds in GDScript; at the 16.7M-voxel safety cap it is minutes, which
## is why the caller runs it on WorkerThreadPool behind a cancellable dialog.

const SURFACE_BLUR_RADIUS := 1
## Central difference across a blurred binary step is ~170/255 for a wall
## facing an axis and less for oblique surfaces; this maps a solidly-defined
## surface to confidence 1 while leaving oblique faces well above zero.
const CONFIDENCE_GRADIENT_SCALE := 96.0


## Returns {ok, dims, origin, voxel_size, surface, open} or {ok=false, error}.
static func build(grid: RefCounted, settings: Dictionary, control: RefCounted = null) -> Dictionary:
	if grid == null:
		return {"ok": false, "error": "Lighting field build received no voxel grid.", "cancelled": false}
	var nx: int = grid.nx
	var ny: int = grid.ny
	var nz: int = grid.nz
	var total := nx * ny * nz
	if total <= 0:
		return {"ok": false, "error": "Voxel grid is empty.", "cancelled": false}

	_progress(control, "Reading occupancy field", 0.0)
	var occupancy := to_dense(grid, control)
	if occupancy.is_empty():
		return _cancelled_result()

	_progress(control, "Smoothing the surface field", 0.15)
	var surface := box_blur(occupancy, nx, ny, nz, SURFACE_BLUR_RADIUS, control)
	if surface.is_empty():
		return _cancelled_result()

	var ao_radius := maxi(0, int(settings.get("ao_radius", 3)))
	var open := PackedByteArray()
	if ao_radius > 0:
		_progress(control, "Sampling openness for ambient occlusion", 0.55)
		open = box_blur(occupancy, nx, ny, nz, ao_radius, control)
		if open.is_empty():
			return _cancelled_result()

	_progress(control, "Lighting field ready", 1.0)
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"dims": Vector3i(nx, ny, nz),
		"origin": grid.origin,
		"voxel_size": grid.voxel_size,
		"surface": surface,
		"open": open,
	}


## Expands a VoxelGrid's sparse 4×4×4 block masks into a dense 0/1 array.
## Mirrors scene_processor's `_to_dense`; duplicated rather than imported so
## this module stays independent of `collision/`.
static func to_dense(grid: RefCounted, control: RefCounted = null) -> PackedByteArray:
	var nx: int = grid.nx
	var ny: int = grid.ny
	var dense := PackedByteArray()
	dense.resize(nx * ny * grid.nz)
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
			dense[x + y * nx + z * nx * ny] = 255
	return dense


## Separable box blur over a dense u8 field. Out-of-grid samples count as
## empty, so the blur fades toward the border, which is what an occupancy field
## should do. Returns an empty array when cancelled.
static func box_blur(
	source: PackedByteArray,
	nx: int, ny: int, nz: int,
	radius: int,
	control: RefCounted = null
) -> PackedByteArray:
	if radius <= 0:
		return source.duplicate()
	var pass_x := _blur_x(source, nx, ny, nz, radius, control)
	if pass_x.is_empty():
		return pass_x
	var pass_y := _blur_y(pass_x, nx, ny, nz, radius, control)
	if pass_y.is_empty():
		return pass_y
	return _blur_z(pass_y, nx, ny, nz, radius, control)


static func _blur_x(source: PackedByteArray, nx: int, ny: int, nz: int, radius: int, control: RefCounted) -> PackedByteArray:
	var output := PackedByteArray()
	output.resize(source.size())
	var window := 2 * radius + 1
	var half := window / 2
	for z in nz:
		if z % 8 == 0 and _is_cancelled(control):
			return PackedByteArray()
		for y in ny:
			var base := y * nx + z * nx * ny
			var accumulator := 0
			for initial_x in range(0, mini(nx, radius + 1)):
				accumulator += source[base + initial_x]
			for x in nx:
				output[base + x] = (accumulator + half) / window
				var remove_x := x - radius
				if remove_x >= 0:
					accumulator -= source[base + remove_x]
				var add_x := x + radius + 1
				if add_x < nx:
					accumulator += source[base + add_x]
	return output


static func _blur_y(source: PackedByteArray, nx: int, ny: int, nz: int, radius: int, control: RefCounted) -> PackedByteArray:
	var output := PackedByteArray()
	output.resize(source.size())
	var window := 2 * radius + 1
	var half := window / 2
	for z in nz:
		if z % 8 == 0 and _is_cancelled(control):
			return PackedByteArray()
		for x in nx:
			var base := x + z * nx * ny
			var accumulator := 0
			for initial_y in range(0, mini(ny, radius + 1)):
				accumulator += source[base + initial_y * nx]
			for y in ny:
				output[base + y * nx] = (accumulator + half) / window
				var remove_y := y - radius
				if remove_y >= 0:
					accumulator -= source[base + remove_y * nx]
				var add_y := y + radius + 1
				if add_y < ny:
					accumulator += source[base + add_y * nx]
	return output


static func _blur_z(source: PackedByteArray, nx: int, ny: int, nz: int, radius: int, control: RefCounted) -> PackedByteArray:
	var output := PackedByteArray()
	output.resize(source.size())
	var window := 2 * radius + 1
	var half := window / 2
	var slice_stride := nx * ny
	for y in ny:
		if y % 8 == 0 and _is_cancelled(control):
			return PackedByteArray()
		for x in nx:
			var base := x + y * nx
			var accumulator := 0
			for initial_z in range(0, mini(nz, radius + 1)):
				accumulator += source[base + initial_z * slice_stride]
			for z in nz:
				output[base + z * slice_stride] = (accumulator + half) / window
				var remove_z := z - radius
				if remove_z >= 0:
					accumulator -= source[base + remove_z * slice_stride]
				var add_z := z + radius + 1
				if add_z < nz:
					accumulator += source[base + add_z * slice_stride]
	return output


static func _progress(control: RefCounted, stage: String, fraction: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(fraction, 0.0, 1.0))


static func _is_cancelled(control: RefCounted) -> bool:
	return control != null and control.is_cancel_requested()


static func _cancelled_result() -> Dictionary:
	return {"ok": false, "error": "Bake cancelled.", "cancelled": true}

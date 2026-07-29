extends RefCounted

## Worker-safe orchestrator for a lighting-proxy bake.
##
##   1. Run the collision pipeline in `smooth` mesh mode, forced to `object`
##      scene mode with no carve, asking it to keep the voxel grid. The proxy
##      must be the actual surface — an interior fill or a capsule carve would
##      describe navigable space, not something to light.
##   2. Give the contoured mesh area-weighted vertex normals (marching cubes
##      emits positions and indices only), optionally Laplacian-smoothed, since
##      normals straight off a binary field at 5 cm voxels are visibly faceted.
##   3. Build the surface/openness fields from the same grid.
##   4. Transfer them onto every splat as 4-byte records.
##
## The dependency on `collision/` is deliberate and bake-time only: nothing in
## `runtime/` imports this module, so a shipped game can relight from a baked
## resource with `addons/gdgs/collision/` deleted. `lighting_feature.gd` checks
## for the collision module up front and reports a precise reason when it is
## missing, rather than letting a preload chain fail with a generic message.

const PIPELINE_SCRIPT := preload("res://addons/gdgs/collision/pipeline/collision_pipeline.gd")
const FIELD_SCRIPT := preload("res://addons/gdgs/lighting/bake/normal_field.gd")
const TRANSFER_SCRIPT := preload("res://addons/gdgs/lighting/bake/splat_transfer.gd")

# Progress budget. Voxelization dominates, so the collision pipeline owns most
# of the bar and the lighting-specific stages share the tail.
const SPAN_PIPELINE := Vector2(0.0, 0.55)
const SPAN_NORMALS := Vector2(0.55, 0.62)
const SPAN_FIELD := Vector2(0.62, 0.82)
const SPAN_TRANSFER := Vector2(0.82, 1.0)


## Rescales a nested stage's 0..1 progress into a slice of the overall bar,
## and forwards cancellation. Lets the collision pipeline report progress
## without knowing it is only part of a larger job.
class ScaledControl:
	extends RefCounted

	var _control: RefCounted
	var _low: float
	var _high: float

	func _init(control: RefCounted, low: float, high: float) -> void:
		_control = control
		_low = low
		_high = high

	func report_progress(stage: String, progress: float) -> void:
		if _control != null:
			_control.report_progress(stage, _low + (_high - _low) * clampf(progress, 0.0, 1.0))

	func is_cancel_requested() -> bool:
		return _control != null and _control.is_cancel_requested()


static func default_settings() -> Dictionary:
	return {
		"auto_voxel": true,
		"voxel_size": 0.05,
		"opacity_cutoff": 0.1,
		"compute_backend": "auto",
		"normal_smoothing": 1,
		"ao_radius": 3,
		"ao_strength": 1.0,
	}


## Worker entry point. `data_snapshot` is `collision_pipeline.create_snapshot`'s
## output (duplicated packed arrays only). Returns
## {ok, proxy:{positions, normals, indices}, splat_data, voxel_size, stats}.
static func bake(data_snapshot: Dictionary, raw_settings: Dictionary, control: RefCounted = null) -> Dictionary:
	var settings := default_settings()
	settings.merge(raw_settings, true)

	var pipeline_settings := {
		"voxel_size": 0.0 if bool(settings["auto_voxel"]) else float(settings["voxel_size"]),
		"opacity_cutoff": float(settings["opacity_cutoff"]),
		"compute_backend": String(settings["compute_backend"]),
		"mesh_mode": "smooth",
		"scene_mode": "object",
		"carve": false,
		"keep_grid": true,
	}
	var pipeline_result: Dictionary = PIPELINE_SCRIPT.generate_from_snapshot_settings(
		data_snapshot, pipeline_settings, ScaledControl.new(control, SPAN_PIPELINE.x, SPAN_PIPELINE.y)
	)
	if not pipeline_result.get("ok", false):
		return pipeline_result
	var grid: RefCounted = pipeline_result.get("grid", null)
	if grid == null:
		return _failure("The collision pipeline did not return a voxel grid.")
	var geometry: Dictionary = pipeline_result.get("geometry", {})
	var positions: PackedVector3Array = geometry.get("positions", PackedVector3Array())
	var indices: PackedInt32Array = geometry.get("indices", PackedInt32Array())
	if positions.is_empty() or indices.is_empty():
		return _failure("The lighting proxy mesh came out empty.")

	_progress(control, "Computing proxy vertex normals", SPAN_NORMALS.x)
	var normals := vertex_normals(positions, indices, int(settings["normal_smoothing"]))
	if _is_cancelled(control):
		return _cancelled()

	var field: Dictionary = FIELD_SCRIPT.build(
		grid, settings, ScaledControl.new(control, SPAN_FIELD.x, SPAN_FIELD.y)
	)
	if not field.get("ok", false):
		return field

	var transferred: Dictionary = TRANSFER_SCRIPT.transfer(
		data_snapshot.get("xyz", PackedVector3Array()), field, settings,
		ScaledControl.new(control, SPAN_TRANSFER.x, SPAN_TRANSFER.y)
	)
	if not transferred.get("ok", false):
		return transferred

	var stats: Dictionary = pipeline_result.get("stats", {}).duplicate(true)
	stats.merge(transferred.get("stats", {}), true)
	stats["proxy_vertices"] = positions.size()
	stats["proxy_triangles"] = indices.size() / 3
	stats["normal_smoothing"] = int(settings["normal_smoothing"])
	stats["ao_radius"] = int(settings["ao_radius"])

	_progress(control, "Lighting proxy ready", 1.0)
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"proxy": {"positions": positions, "normals": normals, "indices": indices},
		"splat_data": transferred["splat_data"],
		"voxel_size": grid.voxel_size,
		"settings": settings,
		"stats": stats,
	}


## Area-weighted vertex normals, then `smoothing_iterations` rounds of
## neighbour averaging over the triangle adjacency. The cross product is left
## unnormalised on purpose so larger triangles weigh more; smoothing then takes
## the faceting off the marching-cubes surface without moving any vertex.
static func vertex_normals(
	positions: PackedVector3Array,
	indices: PackedInt32Array,
	smoothing_iterations: int = 0
) -> PackedVector3Array:
	var count := positions.size()
	var normals := PackedVector3Array()
	normals.resize(count)
	for triangle_offset in range(0, indices.size() - 2, 3):
		var ia := indices[triangle_offset]
		var ib := indices[triangle_offset + 1]
		var ic := indices[triangle_offset + 2]
		if ia < 0 or ib < 0 or ic < 0 or ia >= count or ib >= count or ic >= count:
			continue
		var pa := positions[ia]
		var face := (positions[ib] - pa).cross(positions[ic] - pa)
		normals[ia] += face
		normals[ib] += face
		normals[ic] += face

	for _iteration in maxi(0, smoothing_iterations):
		var smoothed := PackedVector3Array()
		smoothed.resize(count)
		for triangle_offset in range(0, indices.size() - 2, 3):
			var ia := indices[triangle_offset]
			var ib := indices[triangle_offset + 1]
			var ic := indices[triangle_offset + 2]
			if ia < 0 or ib < 0 or ic < 0 or ia >= count or ib >= count or ic >= count:
				continue
			var na := normals[ia]
			var nb := normals[ib]
			var nc := normals[ic]
			smoothed[ia] += nb + nc
			smoothed[ib] += na + nc
			smoothed[ic] += na + nb
		# Re-normalising every round keeps the accumulation from being dominated
		# by high-valence vertices.
		for index in count:
			var blended := normals[index] + smoothed[index]
			if blended.length_squared() > 0.0:
				normals[index] = blended.normalized()

	for index in count:
		if normals[index].length_squared() > 0.0:
			normals[index] = normals[index].normalized()
		else:
			# Isolated or degenerate vertex (the coplanar merge can leave some
			# unreferenced); any unit vector is as good as another here.
			normals[index] = Vector3(0.0, 1.0, 0.0)
	return normals


static func _progress(control: RefCounted, stage: String, fraction: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(fraction, 0.0, 1.0))


static func _is_cancelled(control: RefCounted) -> bool:
	return control != null and control.is_cancel_requested()


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "cancelled": false, "stats": {}}


static func _cancelled() -> Dictionary:
	return {"ok": false, "error": "Bake cancelled.", "cancelled": true, "stats": {}}

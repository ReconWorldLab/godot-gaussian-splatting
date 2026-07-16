extends RefCounted

const SPLAT_SOURCE_SCRIPT := preload("res://addons/gdgs/collision/pipeline/splat_source.gd")
const VOXEL_GRID_SCRIPT := preload("res://addons/gdgs/collision/pipeline/voxel_grid.gd")
const VOXELIZER_SCRIPT := preload("res://addons/gdgs/collision/pipeline/voxelizer.gd")
const GPU_VOXELIZER_SCRIPT := preload("res://addons/gdgs/collision/pipeline/gpu_voxelizer.gd")
const MESHER_SCRIPT := preload("res://addons/gdgs/collision/pipeline/mesher.gd")
const SMOOTH_MESHER_SCRIPT := preload("res://addons/gdgs/collision/pipeline/smooth_mesher.gd")
const SCENE_PROCESSOR_SCRIPT := preload("res://addons/gdgs/collision/pipeline/scene_processor.gd")

const AUTO_VOXELS_ON_LONGEST_AXIS := 128.0
const MIN_VOXEL_SIZE := 0.01
const MAX_VOXEL_SIZE := 0.5
const MAX_GRID_VOXELS := 16_777_216
const MAX_GRID_AXIS := 4096
const MAX_CANDIDATE_REFERENCES := 12_000_000
const MAX_EXPOSED_FACES := 2_000_000
const GPU_SHADER_PATH := "res://addons/gdgs/collision/shaders/voxelize.glsl"


# Synchronous convenience API. Editor callers should snapshot on the main
# thread, run generate_from_snapshot() in WorkerThreadPool, then finalize_result()
# back on the main thread.
static func generate(resource: Object, requested_voxel_size: float = 0.0, opacity_cutoff: float = 0.1) -> Dictionary:
	var snapshot_result := create_snapshot(resource)
	if not snapshot_result.get("ok", false):
		return snapshot_result
	return finalize_result(generate_from_snapshot(snapshot_result["snapshot"], requested_voxel_size, opacity_cutoff))


static func generate_with_settings(resource: Object, settings: Dictionary) -> Dictionary:
	var snapshot_result := create_snapshot(resource)
	if not snapshot_result.get("ok", false):
		return snapshot_result
	return finalize_result(generate_from_snapshot_settings(snapshot_result["snapshot"], settings))


static func create_snapshot(resource: Object) -> Dictionary:
	var result: Dictionary = SPLAT_SOURCE_SCRIPT.snapshot(resource)
	if result.get("ok", false):
		# FileAccess returns a plain String. The worker therefore never touches
		# an imported shader Resource or GDGS/global rendering state.
		result["snapshot"]["gpu_shader_source"] = FileAccess.get_file_as_string(GPU_SHADER_PATH)
	return result


# Worker-safe. data_snapshot contains only duplicated PackedArrays and values;
# this function never reads a Resource, UI object, editor object, or scene node.
static func generate_from_snapshot(
	data_snapshot: Dictionary,
	requested_voxel_size: float = 0.0,
	opacity_cutoff: float = 0.1,
	control: RefCounted = null
) -> Dictionary:
	return generate_from_snapshot_settings(data_snapshot, {
		"voxel_size": requested_voxel_size,
		"opacity_cutoff": opacity_cutoff,
	}, control)


# Worker-safe settings API used by stage-three editor jobs. Unknown settings
# are ignored so stored metadata remains forward-compatible.
static func generate_from_snapshot_settings(
	data_snapshot: Dictionary,
	raw_settings: Dictionary,
	control: RefCounted = null
) -> Dictionary:
	var started_msec := Time.get_ticks_msec()
	var settings_result := normalize_settings(raw_settings)
	if not settings_result.get("ok", false):
		return settings_result
	var settings: Dictionary = settings_result["settings"]
	var mesh_mode: String = settings["mesh_mode"]
	var scene_mode: String = settings["scene_mode"]
	if _is_cancelled(control):
		return _cancelled_result()

	_report_progress(control, "Preparing Gaussian data", 0.01)
	var phase_started := Time.get_ticks_msec()
	var extract_result: Dictionary = SPLAT_SOURCE_SCRIPT.prepare(data_snapshot, control)
	var prepare_msec := Time.get_ticks_msec() - phase_started
	if not extract_result.get("ok", false):
		return _forward_failure(extract_result, "Failed to prepare Gaussian data.")
	var source: Dictionary = extract_result["source"]
	var input_splats := int(source["input_splats"])
	var valid_splats := int(source["valid_splats"])
	var skipped_splats := int(source["skipped_splats"])
	var source_bounds: AABB = source["bounds"]
	var longest_axis := maxf(source_bounds.size.x, maxf(source_bounds.size.y, source_bounds.size.z))
	if longest_axis <= 0.0 or not is_finite(longest_axis):
		return _failure("Gaussian 3σ bounds are empty or invalid.")
	var voxel_size := _resolve_voxel_size(settings["voxel_size"], longest_axis)
	if voxel_size <= 0.0:
		return _failure("voxel_size must be positive.")
	source_bounds = _grow_bounds_for_scene_modes(source_bounds, settings, voxel_size)

	_report_progress(control, "Creating aligned voxel grid", 0.16)
	var grid_result := _create_aligned_grid(source_bounds, voxel_size)
	if not grid_result.get("ok", false):
		return grid_result
	if _is_cancelled(control):
		return _cancelled_result()
	var grid: RefCounted = grid_result["grid"]
	var dimensions := Vector3i(grid.nx, grid.ny, grid.nz)
	var total_voxels := dimensions.x * dimensions.y * dimensions.z

	phase_started = Time.get_ticks_msec()
	var voxelize_result := _voxelize_with_backend(
		source, grid, settings, String(data_snapshot.get("gpu_shader_source", "")), control
	)
	var voxelize_msec := Time.get_ticks_msec() - phase_started
	if not voxelize_result.get("ok", false):
		return _forward_failure(voxelize_result, "Voxelization failed.")
	var gpu_fallback_reason := String(voxelize_result.get("gpu_fallback_reason", ""))
	source.clear()
	if grid.get_occupied_block_indices().is_empty():
		return _failure("Voxelization produced no solid voxels. Lower opacity_cutoff or voxel_size.")

	phase_started = Time.get_ticks_msec()
	var cleanup_result: Dictionary = VOXELIZER_SCRIPT.cleanup(grid, control)
	var cleanup_msec := Time.get_ticks_msec() - phase_started
	if not cleanup_result.get("ok", false):
		return _forward_failure(cleanup_result, "Voxel cleanup failed.")
	var object_occupied_voxels: int = grid.occupied_voxel_count()
	if object_occupied_voxels == 0:
		return _failure("All solid voxels were removed as isolated noise.")
	if _is_cancelled(control):
		return _cancelled_result()

	phase_started = Time.get_ticks_msec()
	var scene_result: Dictionary = SCENE_PROCESSOR_SCRIPT.process(grid, settings, control)
	var scene_msec := Time.get_ticks_msec() - phase_started
	if not scene_result.get("ok", false):
		return _forward_failure(scene_result, "Scene fill/carve failed.")
	grid = scene_result["grid"]
	var scene_stats: Dictionary = scene_result["stats"]
	var occupied_voxels: int = grid.occupied_voxel_count()
	if occupied_voxels == 0:
		return _failure("Scene fill/carve produced no solid voxels.")

	phase_started = Time.get_ticks_msec()
	var mesh_result: Dictionary
	if mesh_mode == "smooth":
		mesh_result = SMOOTH_MESHER_SCRIPT.build_geometry(grid, MAX_EXPOSED_FACES, control)
	else:
		mesh_result = MESHER_SCRIPT.build_geometry(grid, MAX_EXPOSED_FACES, control)
	var mesher_msec := Time.get_ticks_msec() - phase_started
	if not mesh_result.get("ok", false):
		return _forward_failure(mesh_result, "Mesh extraction failed.")
	var exposed_faces := int(mesh_result.get("exposed_faces", 0))
	var triangles := int(mesh_result["triangles"])
	var baseline_triangles := exposed_faces * 2
	var triangle_reduction_percent := 0.0
	if baseline_triangles > 0:
		triangle_reduction_percent = 100.0 * (1.0 - float(triangles) / baseline_triangles)

	var stats := {
		"compute_backend_requested": settings["compute_backend"],
		"compute_backend": voxelize_result.get("stats", {}).get("compute_backend", "cpu"),
		"private_rendering_device": voxelize_result.get("stats", {}).get("private_rendering_device", false),
		"gpu_fallback_reason": gpu_fallback_reason,
		"mesh_mode": mesh_mode,
		"scene_mode": scene_mode,
		"carve": settings["carve"],
		"input_splats": input_splats,
		"valid_splats": valid_splats,
		"skipped_splats": skipped_splats,
		"voxel_size": voxel_size,
		"grid_dimensions": dimensions,
		"grid_voxels": total_voxels,
		"output_grid_dimensions": Vector3i(grid.nx, grid.ny, grid.nz),
		"output_grid_voxels": grid.nx * grid.ny * grid.nz,
		"candidate_references": voxelize_result["candidate_references"],
		"occupied_voxels": occupied_voxels,
		"object_occupied_voxels": object_occupied_voxels,
		"removed_voxels": cleanup_result["stats"]["removed_voxels"],
		"filled_voxels": cleanup_result["stats"]["filled_voxels"],
		"exposed_faces": exposed_faces,
		"rectangles": mesh_result.get("rectangles", 0),
		"surface_cells": mesh_result.get("surface_cells", 0),
		"contour_loops": mesh_result.get("contour_loops", 0),
		"coplanar_polygons": mesh_result.get("coplanar_polygons", 0),
		"triangles_before_coplanar_merge": mesh_result.get("triangles_before_coplanar_merge", triangles),
		"coplanar_removed_vertices": mesh_result.get("coplanar_removed_vertices", 0),
		"coplanar_removed_triangles": mesh_result.get("coplanar_removed_triangles", 0),
		"vertices": mesh_result["vertices"],
		"triangles": triangles,
		"triangle_reduction_percent": triangle_reduction_percent,
		"prepare_msec": prepare_msec,
		"voxelize_msec": voxelize_msec,
		"cleanup_msec": cleanup_msec,
		"scene_msec": scene_msec,
		"mesher_msec": mesher_msec,
		"elapsed_msec": Time.get_ticks_msec() - started_msec,
	}
	stats.merge(scene_stats, true)
	_report_progress(control, "Collision geometry ready", 1.0)
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"mesh": null,
		"geometry": mesh_result["geometry"],
		"stats": stats,
	}


static func _resolve_voxel_size(requested: float, longest_axis: float) -> float:
	if is_zero_approx(requested):
		return clampf(longest_axis / AUTO_VOXELS_ON_LONGEST_AXIS, MIN_VOXEL_SIZE, MAX_VOXEL_SIZE)
	return requested


# Interior/outdoor fill and carve sample space beyond the splats, so the grid
# needs padding for the dilation radius, the capsule, and a 4-voxel margin.
static func _grow_bounds_for_scene_modes(bounds: AABB, settings: Dictionary, voxel_size: float) -> AABB:
	var scene_mode: String = settings["scene_mode"]
	if scene_mode == "object" and not settings["carve"]:
		return bounds
	var padding := float(settings["dilation"]) if scene_mode != "object" else 0.0
	if settings["carve"]:
		padding = maxf(padding, maxf(float(settings["capsule_radius"]), float(settings["capsule_height"]) * 0.5))
	return bounds.grow(padding + voxel_size * 4.0)


# Grid origin/end snap to 4-voxel block boundaries so VoxelGrid's block masks
# tile the volume exactly; axis and voxel-count caps guard runaway grids.
static func _create_aligned_grid(bounds: AABB, voxel_size: float) -> Dictionary:
	var block_world_size := voxel_size * 4.0
	var bounds_end := bounds.position + bounds.size
	var grid_origin := Vector3(
		floor(bounds.position.x / block_world_size) * block_world_size,
		floor(bounds.position.y / block_world_size) * block_world_size,
		floor(bounds.position.z / block_world_size) * block_world_size
	)
	var grid_end := Vector3(
		ceil(bounds_end.x / block_world_size) * block_world_size,
		ceil(bounds_end.y / block_world_size) * block_world_size,
		ceil(bounds_end.z / block_world_size) * block_world_size
	)
	var dimensions := Vector3i(
		maxi(4, roundi((grid_end.x - grid_origin.x) / voxel_size)),
		maxi(4, roundi((grid_end.y - grid_origin.y) / voxel_size)),
		maxi(4, roundi((grid_end.z - grid_origin.z) / voxel_size))
	)
	var total_voxels := dimensions.x * dimensions.y * dimensions.z
	if dimensions.x > MAX_GRID_AXIS or dimensions.y > MAX_GRID_AXIS or dimensions.z > MAX_GRID_AXIS:
		return _failure("Voxel grid axis %s exceeds the safety limit (%d). Increase voxel_size." % [dimensions, MAX_GRID_AXIS])
	if total_voxels <= 0 or total_voxels > MAX_GRID_VOXELS:
		return _failure(
			"Voxel grid %s contains %d voxels; the safety limit is %d. Increase voxel_size." %
			[dimensions, total_voxels, MAX_GRID_VOXELS]
		)
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"grid": VOXEL_GRID_SCRIPT.new(grid_origin, voxel_size, dimensions.x, dimensions.y, dimensions.z),
	}


# Runs the requested compute backend. "auto" tries the private GPU first and
# falls back to the CPU voxelizer, recording why under "gpu_fallback_reason".
static func _voxelize_with_backend(
	source: Dictionary,
	grid: RefCounted,
	settings: Dictionary,
	gpu_shader_source: String,
	control: RefCounted
) -> Dictionary:
	var backend: String = settings["compute_backend"]
	var opacity_cutoff: float = settings["opacity_cutoff"]
	if backend in ["auto", "gpu"]:
		var gpu_result: Dictionary = GPU_VOXELIZER_SCRIPT.voxelize(
			source, grid, opacity_cutoff, MAX_CANDIDATE_REFERENCES, gpu_shader_source, control
		)
		if gpu_result.get("ok", false) or gpu_result.get("cancelled", false):
			return gpu_result
		if backend == "gpu":
			return _forward_failure(gpu_result, "Private GPU voxelization failed.")
		grid.replace_blocks({})
		var cpu_result: Dictionary = VOXELIZER_SCRIPT.voxelize(
			source, grid, opacity_cutoff, MAX_CANDIDATE_REFERENCES, control
		)
		cpu_result["gpu_fallback_reason"] = gpu_result.get("error", "Private GPU unavailable.")
		return cpu_result
	return VOXELIZER_SCRIPT.voxelize(source, grid, opacity_cutoff, MAX_CANDIDATE_REFERENCES, control)


static func normalize_settings(raw_settings: Dictionary) -> Dictionary:
	var voxel_size := float(raw_settings.get("voxel_size", 0.0))
	var opacity_cutoff := float(raw_settings.get("opacity_cutoff", 0.1))
	var mesh_mode := String(raw_settings.get("mesh_mode", "faces")).to_lower()
	var scene_mode := String(raw_settings.get("scene_mode", "object")).to_lower()
	var compute_backend := String(raw_settings.get("compute_backend", "auto")).to_lower()
	var dilation := float(raw_settings.get("dilation", 1.6))
	var carve := bool(raw_settings.get("carve", false))
	var capsule_height := float(raw_settings.get("capsule_height", 1.6))
	var capsule_radius := float(raw_settings.get("capsule_radius", 0.2))
	var seed_value: Variant = raw_settings.get("seed", Vector3.ZERO)
	if not is_finite(voxel_size) or voxel_size < 0.0:
		return _failure("voxel_size must be zero (auto) or a finite positive number.")
	if not is_finite(opacity_cutoff) or opacity_cutoff <= 0.0 or opacity_cutoff >= 1.0:
		return _failure("opacity_cutoff must be greater than 0 and less than 1.")
	if mesh_mode not in ["faces", "smooth"]:
		return _failure("mesh_mode must be 'faces' or 'smooth'.")
	if scene_mode not in ["object", "interior", "outdoor"]:
		return _failure("scene_mode must be 'object', 'interior', or 'outdoor'.")
	if compute_backend not in ["auto", "cpu", "gpu"]:
		return _failure("compute_backend must be 'auto', 'cpu', or 'gpu'.")
	if not is_finite(dilation) or dilation <= 0.0:
		return _failure("dilation must be finite and greater than zero.")
	if not is_finite(capsule_height) or capsule_height <= 0.0:
		return _failure("capsule_height must be finite and greater than zero.")
	if not is_finite(capsule_radius) or capsule_radius < 0.0:
		return _failure("capsule_radius must be finite and non-negative.")
	if not seed_value is Vector3 or not (seed_value as Vector3).is_finite():
		return _failure("seed must be a finite local-space Vector3.")
	return {
		"ok": true,
		"error": "",
		"settings": {
			"voxel_size": voxel_size,
			"opacity_cutoff": opacity_cutoff,
			"mesh_mode": mesh_mode,
			"scene_mode": scene_mode,
			"compute_backend": compute_backend,
			"dilation": dilation,
			"carve": carve,
			"capsule_height": capsule_height,
			"capsule_radius": capsule_radius,
			"seed": seed_value,
		},
	}


# Must run on the main thread because ArrayMesh is an engine Resource.
static func finalize_result(worker_result: Dictionary) -> Dictionary:
	if not worker_result.get("ok", false):
		return worker_result
	return MESHER_SCRIPT.create_mesh(worker_result)


# Single construction point for the physics shape, shared by the editor plugin
# and tests. The trimesh is a hollow shell, so thin regions are only one voxel
# thick; backface_collision keeps contacts alive when a fast body's center
# crosses a face plane within one physics tick instead of letting it pop
# through. Returns null when the mesh has no usable triangles.
static func create_collision_shape(mesh: ArrayMesh) -> ConcavePolygonShape3D:
	if mesh == null:
		return null
	var faces := mesh.get_faces()
	if faces.is_empty():
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	if shape.get_faces().is_empty():
		return null
	return shape


static func _report_progress(control: RefCounted, stage: String, progress: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(progress, 0.0, 1.0))


static func _is_cancelled(control: RefCounted) -> bool:
	return control != null and control.is_cancel_requested()


static func _forward_failure(result: Dictionary, fallback: String) -> Dictionary:
	return _failure(result.get("error", fallback), result.get("cancelled", false))


static func _cancelled_result() -> Dictionary:
	return _failure("Generation cancelled.", true)


static func _failure(message: String, cancelled: bool = false) -> Dictionary:
	return {"ok": false, "error": message, "cancelled": cancelled, "mesh": null, "stats": {}}

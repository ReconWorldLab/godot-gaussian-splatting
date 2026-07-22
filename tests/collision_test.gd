extends SceneTree

## Regression tests for the collision pipeline, using synthetic Gaussian
## snapshots (no imported resource needed — the pipeline consumes plain
## dictionaries). CPU backend only, so this runs headless in CI:
##   godot --headless --path . --script tests/collision_test.gd

const PIPELINE := preload("res://addons/gdgs/collision/pipeline/collision_pipeline.gd")
const SPLAT_SOURCE := preload("res://addons/gdgs/collision/pipeline/splat_source.gd")
const VOXEL_SIZE := 0.05

var _failures: PackedStringArray = []


func _initialize() -> void:
	_test_object_faces()
	_test_object_smooth()
	_test_outdoor_fill_direction()
	_test_subsampling()

	if _failures.is_empty():
		print("collision tests passed")
		quit(0)
	else:
		for failure in _failures:
			push_error("collision test: %s" % failure)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


# --- Synthetic assets -------------------------------------------------------


static func _make_snapshot(points: PackedVector3Array, sigma: float, opacity: float) -> Dictionary:
	var data := PackedFloat32Array()
	var cov := sigma * sigma
	for point in points:
		var block := PackedFloat32Array()
		block.resize(SPLAT_SOURCE.STRUCT_SIZE)
		block[SPLAT_SOURCE.COVARIANCE_OFFSET + 0] = cov
		block[SPLAT_SOURCE.COVARIANCE_OFFSET + 3] = cov
		block[SPLAT_SOURCE.COVARIANCE_OFFSET + 5] = cov
		block[SPLAT_SOURCE.OPACITY_OFFSET] = opacity
		data.append_array(block)
	var bounds := AABB(points[0], Vector3.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	return {
		"point_count": points.size(),
		"xyz": points,
		"point_data_float": data,
		"aabb": bounds.grow(3.0 * sigma),
	}


static func _box_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	for ix in 5:
		for iy in 5:
			for iz in 5:
				points.append(Vector3(ix - 2, iy - 2, iz - 2) * 0.1)
	return points


static func _slab_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	for ix in 21:
		for iz in 21:
			points.append(Vector3((ix - 10) * 0.1, 0.0, (iz - 10) * 0.1))
	return points


# --- Tests ------------------------------------------------------------------


func _test_object_faces() -> void:
	var result: Dictionary = PIPELINE.generate_from_snapshot_settings(
		_make_snapshot(_box_points(), 0.05, 0.9),
		{"voxel_size": VOXEL_SIZE, "compute_backend": "cpu", "mesh_mode": "faces"}
	)
	_check(result.get("ok", false), "object/faces failed: %s" % result.get("error", ""))
	if not result.get("ok", false):
		return
	var stats: Dictionary = result["stats"]
	_check(int(stats["triangles"]) > 0, "object/faces produced no triangles")
	var bounds := _geometry_bounds(result["geometry"])
	_check(bounds.size.x > 0.4 and bounds.size.x < 1.2, "object/faces bounds look wrong: %s" % bounds)
	var finalized: Dictionary = PIPELINE.finalize_result(result)
	_check(finalized.get("ok", false) and finalized["mesh"] is ArrayMesh, "object/faces mesh finalize failed")
	var shape: ConcavePolygonShape3D = PIPELINE.create_collision_shape(finalized.get("mesh"))
	_check(shape != null and shape.backface_collision, "object/faces collision shape invalid")


func _test_object_smooth() -> void:
	var result: Dictionary = PIPELINE.generate_from_snapshot_settings(
		_make_snapshot(_box_points(), 0.05, 0.9),
		{"voxel_size": VOXEL_SIZE, "compute_backend": "cpu", "mesh_mode": "smooth"}
	)
	_check(result.get("ok", false), "object/smooth failed: %s" % result.get("error", ""))
	if not result.get("ok", false):
		return
	_check(int(result["stats"]["triangles"]) > 0, "object/smooth produced no triangles")


func _test_outdoor_fill_direction() -> void:
	# A flat slab on the y=0 plane. The exposed walkable face must sit on the
	# air side: sealing the +y side leaves the -y face exposed and vice versa.
	for sign_value in [1.0, -1.0]:
		var result: Dictionary = PIPELINE.generate_from_snapshot_settings(
			_make_snapshot(_slab_points(), 0.05, 0.9),
			{
				"voxel_size": VOXEL_SIZE, "compute_backend": "cpu", "scene_mode": "outdoor",
				"dilation": 0.2, "floor_y_sign": sign_value,
			}
		)
		_check(result.get("ok", false), "outdoor(sign=%.0f) failed: %s" % [sign_value, result.get("error", "")])
		if not result.get("ok", false):
			continue
		var exposed_area := _horizontal_area_near(result["geometry"], -0.15 * sign_value, 0.05)
		var buried_area := _horizontal_area_near(result["geometry"], 0.15 * sign_value, 0.05)
		_check(
			exposed_area > 2.0,
			"outdoor(sign=%.0f): expected exposed ground face near y=%.2f, area=%.2f" % [sign_value, -0.15 * sign_value, exposed_area]
		)
		_check(
			buried_area < 0.5,
			"outdoor(sign=%.0f): surface at y=%.2f should be buried, area=%.2f" % [sign_value, 0.15 * sign_value, buried_area]
		)


func _test_subsampling() -> void:
	var snapshot := _make_snapshot(_slab_points(), 0.05, 0.9)
	var prepared: Dictionary = SPLAT_SOURCE.prepare(snapshot, null, 100)
	_check(prepared.get("ok", false), "subsampled prepare failed: %s" % prepared.get("error", ""))
	if not prepared.get("ok", false):
		return
	var source: Dictionary = prepared["source"]
	_check(int(source["sample_stride"]) == 5, "expected stride 5, got %d" % int(source["sample_stride"]))
	_check(int(source["valid_splats"]) <= 100, "subsample kept too many splats: %d" % int(source["valid_splats"]))
	var opacities: PackedFloat32Array = source["opacities"]
	_check(absf(opacities[0] - 0.9 * 5.0) < 1.0e-4, "opacity not density-compensated: %f" % opacities[0])


# --- Geometry helpers -------------------------------------------------------


static func _geometry_bounds(geometry: Dictionary) -> AABB:
	var positions: PackedVector3Array = geometry["positions"]
	var bounds := AABB(positions[0], Vector3.ZERO)
	for position in positions:
		bounds = bounds.expand(position)
	return bounds


# Total area of horizontal triangles whose plane lies within tolerance of
# plane_y. Robust against greedy merging because it sums areas instead of
# looking for specific vertices.
static func _horizontal_area_near(geometry: Dictionary, plane_y: float, tolerance: float) -> float:
	var positions: PackedVector3Array = geometry["positions"]
	var indices: PackedInt32Array = geometry["indices"]
	var area := 0.0
	for triangle_offset in range(0, indices.size(), 3):
		var a := positions[indices[triangle_offset]]
		var b := positions[indices[triangle_offset + 1]]
		var c := positions[indices[triangle_offset + 2]]
		if absf(a.y - plane_y) > tolerance or absf(b.y - plane_y) > tolerance or absf(c.y - plane_y) > tolerance:
			continue
		if absf(a.y - b.y) > 1.0e-4 or absf(a.y - c.y) > 1.0e-4:
			continue
		area += (b - a).cross(c - a).length() * 0.5
	return area

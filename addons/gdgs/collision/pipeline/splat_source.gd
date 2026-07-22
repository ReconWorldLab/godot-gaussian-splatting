extends RefCounted

const COMMON := preload("res://addons/gdgs/collision/pipeline/pipeline_common.gd")

const STRUCT_SIZE := 60
const COVARIANCE_OFFSET := 4
const OPACITY_OFFSET := 10
# Above MAX_SPLATS the prepare pass subsamples with a uniform stride and
# compensates density; HARD_MAX_SPLATS only guards against absurd input.
const MAX_SPLATS := 2_000_000
const HARD_MAX_SPLATS := 20_000_000
const REGULARIZATION_RELATIVE := 1.0e-6
const REGULARIZATION_ABSOLUTE := 1.0e-12


# Must run on the main thread. This is the only pipeline entry point that reads
# the imported resource; the worker receives only duplicated PackedArrays.
static func snapshot(resource: Object) -> Dictionary:
	if resource == null or not is_instance_valid(resource):
		return COMMON.failure("Gaussian resource is empty.")
	for property_name in [&"point_count", &"xyz", &"point_data_float", &"aabb"]:
		if not _has_property(resource, property_name):
			return COMMON.failure("Gaussian resource is missing the '%s' property." % property_name)

	var point_count_value: Variant = resource.get("point_count")
	var xyz_value: Variant = resource.get("xyz")
	var point_data_value: Variant = resource.get("point_data_float")
	var aabb_value: Variant = resource.get("aabb")
	if typeof(point_count_value) != TYPE_INT:
		return COMMON.failure("Gaussian point_count must be an integer.")
	if typeof(xyz_value) != TYPE_PACKED_VECTOR3_ARRAY:
		return COMMON.failure("Gaussian xyz must be a PackedVector3Array.")
	if typeof(point_data_value) != TYPE_PACKED_FLOAT32_ARRAY:
		return COMMON.failure("Gaussian point_data_float must be a PackedFloat32Array.")
	if typeof(aabb_value) != TYPE_AABB:
		return COMMON.failure("Gaussian aabb must be an AABB.")

	var point_count: int = point_count_value
	var xyz: PackedVector3Array = xyz_value
	var point_data: PackedFloat32Array = point_data_value
	var resource_aabb: AABB = aabb_value
	if point_count <= 0:
		return COMMON.failure("Gaussian resource contains no splats.")
	if point_count > HARD_MAX_SPLATS:
		return COMMON.failure("Gaussian resource has %d splats; the safety limit is %d." % [point_count, HARD_MAX_SPLATS])
	if xyz.size() != point_count:
		return COMMON.failure("Gaussian xyz length (%d) does not match point_count (%d)." % [xyz.size(), point_count])
	if point_data.size() != point_count * STRUCT_SIZE:
		return COMMON.failure(
			"Gaussian point_data_float length (%d) does not match point_count × %d (%d)." %
			[point_data.size(), STRUCT_SIZE, point_count * STRUCT_SIZE]
		)
	if not _is_finite_aabb(resource_aabb):
		return COMMON.failure("Gaussian resource AABB contains a non-finite value.")

	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"mesh": null,
		"stats": {},
		"snapshot": {
			"point_count": point_count,
			"xyz": xyz.duplicate(),
			"point_data_float": point_data.duplicate(),
			"aabb": resource_aabb,
		},
	}


# Convenience wrapper for synchronous callers and tests.
static func extract(resource: Object, control: RefCounted = null) -> Dictionary:
	var snapshot_result := snapshot(resource)
	if not snapshot_result.get("ok", false):
		return snapshot_result
	return prepare(snapshot_result["snapshot"], control)


# Worker-safe: consumes only the value snapshot created on the main thread.
# Resources above max_splats are subsampled with a uniform stride; each kept
# splat's opacity is multiplied by the stride so the accumulated density the
# voxelizer thresholds against stays approximately unchanged.
static func prepare(data_snapshot: Dictionary, control: RefCounted = null, max_splats: int = MAX_SPLATS) -> Dictionary:
	var point_count := int(data_snapshot.get("point_count", 0))
	var xyz: PackedVector3Array = data_snapshot.get("xyz", PackedVector3Array())
	var point_data: PackedFloat32Array = data_snapshot.get("point_data_float", PackedFloat32Array())
	if point_count <= 0 or xyz.size() != point_count or point_data.size() != point_count * STRUCT_SIZE:
		return COMMON.failure("Gaussian data snapshot is empty or inconsistent.")

	var sample_stride := 1
	if max_splats > 0 and point_count > max_splats:
		sample_stride = ceili(float(point_count) / float(max_splats))
	var sampled_count := (point_count + sample_stride - 1) / sample_stride
	var opacity_scale := float(sample_stride)

	var positions := PackedVector3Array()
	var inverse_covariances := PackedFloat32Array()
	var extents := PackedVector3Array()
	var opacities := PackedFloat32Array()
	positions.resize(sampled_count)
	inverse_covariances.resize(sampled_count * 6)
	extents.resize(sampled_count)
	opacities.resize(sampled_count)

	var valid_count := 0
	var skipped_count := 0
	var iteration := 0
	var bounds_min := Vector3(INF, INF, INF)
	var bounds_max := Vector3(-INF, -INF, -INF)
	for source_index in range(0, point_count, sample_stride):
		iteration += 1
		if iteration % 2048 == 0:
			if COMMON.is_cancelled(control):
				return COMMON.cancelled_result()
			COMMON.phase_progress(control, "Preparing Gaussian covariance data", &"prepare", float(iteration) / sampled_count)
		var position := xyz[source_index]
		var base := source_index * STRUCT_SIZE
		var xx := float(point_data[base + COVARIANCE_OFFSET + 0])
		var xy := float(point_data[base + COVARIANCE_OFFSET + 1])
		var xz := float(point_data[base + COVARIANCE_OFFSET + 2])
		var yy := float(point_data[base + COVARIANCE_OFFSET + 3])
		var yz := float(point_data[base + COVARIANCE_OFFSET + 4])
		var zz := float(point_data[base + COVARIANCE_OFFSET + 5])
		var opacity := float(point_data[base + OPACITY_OFFSET])
		if not _is_finite_vector(position) or not _all_finite([xx, xy, xz, yy, yz, zz, opacity]):
			skipped_count += 1
			continue
		if xx < 0.0 or yy < 0.0 or zz < 0.0 or opacity <= 0.0:
			skipped_count += 1
			continue

		var extent := 3.0 * Vector3(sqrt(xx), sqrt(yy), sqrt(zz))
		var covariance_scale := maxf(maxf(xx, yy), maxf(zz, REGULARIZATION_ABSOLUTE))
		var epsilon := covariance_scale * REGULARIZATION_RELATIVE + REGULARIZATION_ABSOLUTE
		var a := xx + epsilon
		var d := yy + epsilon
		var f := zz + epsilon
		var determinant := a * (d * f - yz * yz) - xy * (xy * f - xz * yz) + xz * (xy * yz - xz * d)
		var determinant_scale := maxf(covariance_scale * covariance_scale * covariance_scale, 1.0e-36)
		if a * d - xy * xy <= 0.0 or not is_finite(determinant) or determinant <= determinant_scale * 1.0e-12:
			skipped_count += 1
			continue

		var inverse_base := valid_count * 6
		var inverse_values := [
			(d * f - yz * yz) / determinant,
			(xz * yz - xy * f) / determinant,
			(xy * yz - xz * d) / determinant,
			(a * f - xz * xz) / determinant,
			(xy * xz - a * yz) / determinant,
			(a * d - xy * xy) / determinant,
		]
		if not _all_finite(inverse_values):
			skipped_count += 1
			continue
		for inverse_index in 6:
			inverse_covariances[inverse_base + inverse_index] = inverse_values[inverse_index]
		positions[valid_count] = position
		extents[valid_count] = extent
		opacities[valid_count] = clampf(opacity, 0.0, 1.0) * opacity_scale
		bounds_min = bounds_min.min(position - extent)
		bounds_max = bounds_max.max(position + extent)
		valid_count += 1

	if COMMON.is_cancelled(control):
		return COMMON.cancelled_result()
	if valid_count == 0:
		return COMMON.failure("No usable splats remain after covariance and opacity validation.")
	positions.resize(valid_count)
	inverse_covariances.resize(valid_count * 6)
	extents.resize(valid_count)
	opacities.resize(valid_count)

	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"mesh": null,
		"stats": {
			"input_splats": point_count,
			"sample_stride": sample_stride,
			"sampled_splats": sampled_count,
			"valid_splats": valid_count,
			"skipped_splats": skipped_count,
		},
		"source": {
			"positions": positions,
			"inverse_covariances": inverse_covariances,
			"extents": extents,
			"opacities": opacities,
			"bounds": AABB(bounds_min, bounds_max - bounds_min),
			"input_splats": point_count,
			"sample_stride": sample_stride,
			"sampled_splats": sampled_count,
			"valid_splats": valid_count,
			"skipped_splats": skipped_count,
		},
	}


static func _has_property(object: Object, property_name: StringName) -> bool:
	for property: Dictionary in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			return true
	return false


static func _all_finite(values: Array) -> bool:
	for value: float in values:
		if not is_finite(value):
			return false
	return true


static func _is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _is_finite_aabb(value: AABB) -> bool:
	return _is_finite_vector(value.position) and _is_finite_vector(value.size) and value.size.x >= 0.0 and value.size.y >= 0.0 and value.size.z >= 0.0

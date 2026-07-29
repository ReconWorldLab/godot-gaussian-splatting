extends SceneTree

## Headless tests for the relighting bake (Phase R1): the per-splat record
## codec, the surface/openness field, the splat transfer, and the proxy mesh's
## vertex normals. All CPU-side, no GPU and no collision voxelizer required —
## the fields are built against a hand-made VoxelGrid.
##
##   godot --headless --path . --script tests/lighting_test.gd

const LightingResource := preload("res://addons/gdgs/runtime/resources/gaussian_lighting_resource.gd")
const VoxelGrid := preload("res://addons/gdgs/collision/pipeline/voxel_grid.gd")
const NormalField := preload("res://addons/gdgs/lighting/bake/normal_field.gd")
const SplatTransfer := preload("res://addons/gdgs/lighting/bake/splat_transfer.gd")
const ProxyBuilder := preload("res://addons/gdgs/lighting/bake/proxy_builder.gd")

# A 32³ grid at 0.1 m voxels whose lower half in Y is solid, so the surface is
# the plane y = 16 and the outward normal is +Y everywhere on it.
const GRID_DIM := 32
const VOXEL_SIZE := 0.1
const SURFACE_VOXEL_Y := 16

var _failures: PackedStringArray = []


func _initialize() -> void:
	_test_oct_round_trip()
	_test_byte_codecs()
	_test_field_dimensions_and_smoothing()
	_test_transfer_normal_points_outward()
	_test_transfer_marks_floaters_unconfident()
	_test_transfer_ambient_occlusion_range()
	_test_flat_openness_reference()
	_test_ao_darkens_a_concave_corner()
	_test_vertex_normals_point_outward()
	_test_resource_validation()

	if _failures.is_empty():
		print("lighting tests passed")
		quit(0)
	else:
		for failure in _failures:
			push_error("lighting test: %s" % failure)
		quit(1)


# --- codec ------------------------------------------------------------------


func _test_oct_round_trip() -> void:
	# Sweep the sphere; oct + 8-bit quantisation must stay within ~2°.
	var worst := 0.0
	for yaw_step in 24:
		for pitch_step in 13:
			var yaw := TAU * float(yaw_step) / 24.0
			var pitch := -PI / 2.0 + PI * float(pitch_step) / 12.0
			var normal := Vector3(
				cos(pitch) * cos(yaw), sin(pitch), cos(pitch) * sin(yaw)
			).normalized()
			var encoded: Vector2 = LightingResource.oct_encode(normal)
			var quantized := Vector2(
				LightingResource.decode_signed_byte(LightingResource.encode_signed_byte(encoded.x)),
				LightingResource.decode_signed_byte(LightingResource.encode_signed_byte(encoded.y))
			)
			var decoded: Vector3 = LightingResource.oct_decode(quantized)
			worst = maxf(worst, rad_to_deg(normal.angle_to(decoded)))
	if worst > 2.0:
		_fail("oct round-trip error %.3f° exceeds 2°" % worst)


func _test_byte_codecs() -> void:
	for value in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var decoded: float = LightingResource.decode_unit_byte(LightingResource.encode_unit_byte(value))
		if absf(decoded - value) > 0.005:
			_fail("unit byte round-trip %f -> %f" % [value, decoded])
	# Out-of-range input must clamp rather than wrap.
	if LightingResource.encode_unit_byte(4.0) != 255:
		_fail("unit byte did not clamp above 1.0")
	if LightingResource.encode_signed_byte(-4.0) != 0:
		_fail("signed byte did not clamp below -1.0")


# --- field ------------------------------------------------------------------


func _test_field_dimensions_and_smoothing() -> void:
	var field := _build_field()
	if not field.get("ok", false):
		_fail("field build failed: %s" % field.get("error", ""))
		return
	var surface: PackedByteArray = field["surface"]
	if surface.size() != GRID_DIM * GRID_DIM * GRID_DIM:
		_fail("surface field has %d entries, expected %d" % [surface.size(), GRID_DIM ** 3])
		return
	# Deep inside solid the blur saturates, deep outside it vanishes, and the
	# surface layer sits in between — that ordering is what the gradient reads.
	var deep_solid := _sample(surface, 16, 4, 16)
	var deep_empty := _sample(surface, 16, 28, 16)
	var at_surface := _sample(surface, 16, SURFACE_VOXEL_Y, 16)
	if deep_solid < 250:
		_fail("blurred occupancy deep inside solid is %d, expected ~255" % deep_solid)
	if deep_empty != 0:
		_fail("blurred occupancy deep outside is %d, expected 0" % deep_empty)
	if at_surface <= deep_empty or at_surface >= deep_solid:
		_fail("surface sample %d is not between %d and %d" % [at_surface, deep_empty, deep_solid])


# --- transfer ---------------------------------------------------------------


func _test_transfer_normal_points_outward() -> void:
	var field := _build_field()
	var positions := PackedVector3Array()
	# Splats sitting on the surface plane, spread across X/Z.
	for offset in 8:
		positions.append(_voxel_center(8 + offset, SURFACE_VOXEL_Y - 1, 8 + offset))
	var result: Dictionary = SplatTransfer.transfer(positions, field, ProxyBuilder.default_settings())
	if not result.get("ok", false):
		_fail("transfer failed: %s" % result.get("error", ""))
		return
	var resource: Resource = _resource_from(positions.size(), result["splat_data"])
	for index in positions.size():
		var record: Dictionary = resource.read_splat(index)
		var normal: Vector3 = record["normal"]
		if normal.y <= 0.9:
			_fail("surface splat %d normal %s does not point outward (+Y)" % [index, normal])
			return
		if float(record["confidence"]) <= 0.5:
			_fail("surface splat %d confidence %.3f is too low" % [index, record["confidence"]])
			return


func _test_transfer_marks_floaters_unconfident() -> void:
	var field := _build_field()
	var positions := PackedVector3Array()
	positions.append(_voxel_center(16, 28, 16))  # far above the surface
	positions.append(_voxel_center(16, 4, 16))   # deep inside the solid
	var result: Dictionary = SplatTransfer.transfer(positions, field, ProxyBuilder.default_settings())
	if not result.get("ok", false):
		_fail("floater transfer failed: %s" % result.get("error", ""))
		return
	var resource: Resource = _resource_from(positions.size(), result["splat_data"])
	for index in positions.size():
		var confidence := float(resource.read_splat(index)["confidence"])
		if confidence > 0.01:
			_fail("splat %d away from the surface has confidence %.3f, expected ~0" % [index, confidence])
	var stats: Dictionary = result["stats"]
	if int(stats["floater_splats"]) != positions.size():
		_fail("expected %d floaters, stats reported %d" % [positions.size(), stats["floater_splats"]])


func _test_transfer_ambient_occlusion_range() -> void:
	var field := _build_field()
	var positions := PackedVector3Array()
	positions.append(_voxel_center(16, SURFACE_VOXEL_Y - 1, 16))
	var settings: Dictionary = ProxyBuilder.default_settings()
	var open_result: Dictionary = SplatTransfer.transfer(positions, field, settings)
	if not open_result.get("ok", false):
		_fail("AO transfer failed: %s" % open_result.get("error", ""))
		return
	var flat_ao := float(_resource_from(1, open_result["splat_data"]).read_splat(0)["ao"])
	# A splat on an unobstructed flat plane is the AO reference: fully open.
	if flat_ao < 0.9:
		_fail("flat-surface AO is %.3f, expected ~1.0" % flat_ao)
	# Strength 0 must disable the effect entirely.
	settings["ao_strength"] = 0.0
	var disabled: Dictionary = SplatTransfer.transfer(positions, field, settings)
	var disabled_ao := float(_resource_from(1, disabled["splat_data"]).read_splat(0)["ao"])
	if absf(disabled_ao - 1.0) > 0.01:
		_fail("AO strength 0 produced %.3f, expected 1.0" % disabled_ao)


func _test_flat_openness_reference() -> void:
	# The reference must track the sampling geometry, not a fixed guess: the
	# (2r+1)-wide box centred `offset` voxels out still overlaps the solid side
	# by (r - offset) voxels.
	var reference: float = SplatTransfer.flat_openness_reference(3, 1.5)
	if absf(reference - (1.0 - 1.5 / 7.0)) > 1e-6:
		_fail("flat openness reference for r=3, offset=1.5 is %.4f, expected %.4f" % [
			reference, 1.0 - 1.5 / 7.0])
	# A box that no longer reaches the solid side sees nothing occluded.
	if absf(SplatTransfer.flat_openness_reference(1, 1.5) - 1.0) > 1e-6:
		_fail("a box that cannot reach the surface should reference fully open")
	if absf(SplatTransfer.flat_openness_reference(0, 1.5) - 1.0) > 1e-6:
		_fail("AO radius 0 should reference fully open")


func _test_ao_darkens_a_concave_corner() -> void:
	# The regression this guards: with a mis-set reference every splat clamps
	# to fully open and the AO channel carries no signal. A splat tucked
	# against a wall must read measurably darker than one on open floor.
	var field := _build_corner_field()
	var positions := PackedVector3Array()
	positions.append(_voxel_center(24, SURFACE_VOXEL_Y - 1, 16))  # open floor
	positions.append(_voxel_center(9, SURFACE_VOXEL_Y - 1, 16))   # against the wall
	var result: Dictionary = SplatTransfer.transfer(positions, field, ProxyBuilder.default_settings())
	if not result.get("ok", false):
		_fail("corner transfer failed: %s" % result.get("error", ""))
		return
	var resource: Resource = _resource_from(positions.size(), result["splat_data"])
	var open_ao := float(resource.read_splat(0)["ao"])
	var corner_ao := float(resource.read_splat(1)["ao"])
	if open_ao < 0.9:
		_fail("open-floor AO is %.3f, expected ~1.0" % open_ao)
	if corner_ao > open_ao - 0.1:
		_fail("corner AO %.3f is not meaningfully below open-floor AO %.3f" % [corner_ao, open_ao])


# --- proxy mesh -------------------------------------------------------------


func _test_vertex_normals_point_outward() -> void:
	# Unit cube centred on the origin, outward-wound; every vertex normal must
	# have a positive dot with its own direction from the centre.
	var positions := PackedVector3Array([
		Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
		Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1),
	])
	var indices := PackedInt32Array([
		0, 2, 1, 0, 3, 2,  # -Z
		4, 5, 6, 4, 6, 7,  # +Z
		0, 1, 5, 0, 5, 4,  # -Y
		3, 7, 6, 3, 6, 2,  # +Y
		0, 4, 7, 0, 7, 3,  # -X
		1, 2, 6, 1, 6, 5,  # +X
	])
	for smoothing in [0, 2]:
		var normals: PackedVector3Array = ProxyBuilder.vertex_normals(positions, indices, smoothing)
		if normals.size() != positions.size():
			_fail("vertex_normals returned %d normals for %d vertices" % [normals.size(), positions.size()])
			return
		for index in positions.size():
			if absf(normals[index].length() - 1.0) > 1e-4:
				_fail("vertex normal %d is not unit length (smoothing=%d)" % [index, smoothing])
				return
			if normals[index].dot(positions[index].normalized()) <= 0.0:
				_fail("vertex normal %d points inward (smoothing=%d)" % [index, smoothing])
				return


func _test_resource_validation() -> void:
	var resource: Resource = LightingResource.new()
	if resource.is_splat_data_valid():
		_fail("an empty lighting resource reported valid splat data")
	resource.source_point_count = 4
	resource.splat_data = PackedByteArray()
	resource.splat_data.resize(4 * LightingResource.BYTES_PER_SPLAT)
	if not resource.is_splat_data_valid():
		_fail("a correctly sized lighting resource reported invalid splat data")
	if resource.has_proxy_mesh():
		_fail("a lighting resource with no geometry reported a proxy mesh")
	if resource.build_proxy_mesh() != null:
		_fail("build_proxy_mesh returned a mesh with no geometry")
	# Reading out of range must fall back rather than crash.
	var record: Dictionary = resource.read_splat(99)
	if float(record["confidence"]) != 0.0:
		_fail("out-of-range read did not fall back to zero confidence")


# --- helpers ----------------------------------------------------------------


func _build_field() -> Dictionary:
	var grid: RefCounted = VoxelGrid.new(Vector3.ZERO, VOXEL_SIZE, GRID_DIM, GRID_DIM, GRID_DIM)
	for z in GRID_DIM:
		for y in SURFACE_VOXEL_Y:
			for x in GRID_DIM:
				grid.set_voxel_solid(x, y, z, true)
	return NormalField.build(grid, ProxyBuilder.default_settings())


# Same half-space, plus a wall filling x < 8, giving a concave corner along
# x = 8, y = SURFACE_VOXEL_Y.
func _build_corner_field() -> Dictionary:
	var grid: RefCounted = VoxelGrid.new(Vector3.ZERO, VOXEL_SIZE, GRID_DIM, GRID_DIM, GRID_DIM)
	for z in GRID_DIM:
		for y in GRID_DIM:
			for x in GRID_DIM:
				if y < SURFACE_VOXEL_Y or x < 8:
					grid.set_voxel_solid(x, y, z, true)
	return NormalField.build(grid, ProxyBuilder.default_settings())


func _voxel_center(x: int, y: int, z: int) -> Vector3:
	return (Vector3(x, y, z) + Vector3.ONE * 0.5) * VOXEL_SIZE


func _sample(field: PackedByteArray, x: int, y: int, z: int) -> int:
	return field[x + y * GRID_DIM + z * GRID_DIM * GRID_DIM]


func _resource_from(count: int, splat_data: PackedByteArray) -> Resource:
	var resource: Resource = LightingResource.new()
	resource.source_point_count = count
	resource.splat_data = splat_data
	return resource


func _fail(message: String) -> void:
	_failures.append(message)

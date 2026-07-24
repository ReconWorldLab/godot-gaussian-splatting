extends SceneTree

## Headless tests for the Raster backend's CPU-side logic: the counting sorter
## and the data-texture packing/addressing. No GPU required, so these run in CI
## alongside the smoke and collision tests.
##
##   godot --headless --path . --script tests/raster_test.gd

const Sorter := preload("res://addons/gdgs/runtime/render/raster/raster_sorter.gd")
const DataTextures := preload("res://addons/gdgs/runtime/render/raster/raster_data_textures.gd")

var _failures: PackedStringArray = []

func _initialize() -> void:
	_test_sorter_is_permutation()
	_test_sorter_back_to_front()
	_test_sorter_axis_order()
	_test_choose_width_multiple_of_splat()
	_test_data_image_roundtrip()
	_test_order_dims()

	if _failures.is_empty():
		print("raster tests passed")
		quit(0)
	else:
		for f in _failures:
			push_error("raster test: %s" % f)
		print("raster tests FAILED (%d)" % _failures.size())
		quit(1)

func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)

func _make_points(n: int, seed: int) -> PackedVector3Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var pts := PackedVector3Array()
	pts.resize(n)
	for i in range(n):
		pts[i] = Vector3(rng.randf_range(-10, 10), rng.randf_range(-10, 10), rng.randf_range(-10, 10))
	return pts

func _test_sorter_is_permutation() -> void:
	var pts := _make_points(500, 1)
	var order := Sorter.sort(pts, Vector3(0.3, -0.5, 0.8).normalized())
	_check(order.size() == pts.size(), "sorter size mismatch")
	var seen := {}
	for idx in order:
		_check(idx >= 0 and idx < pts.size(), "sorter index out of range: %d" % idx)
		_check(not seen.has(idx), "sorter duplicate index: %d" % idx)
		seen[idx] = true
	_check(seen.size() == pts.size(), "sorter is not a permutation")

func _test_sorter_back_to_front() -> void:
	# Keys must be non-increasing far->near, within one bucket's tolerance.
	var pts := _make_points(2000, 7)
	var dir := Vector3(0.1, 0.2, -0.97).normalized()
	var order := Sorter.sort(pts, dir)
	var span := 40.0 # points in [-10,10]^3 -> key range < ~35
	var tol := span / float(Sorter.BUCKET_COUNT) * 4.0
	var prev := INF
	for i in range(order.size()):
		var k := pts[order[i]].dot(dir)
		_check(k <= prev + tol, "sorter not back-to-front at %d: %f > %f" % [i, k, prev])
		prev = k

func _test_sorter_axis_order() -> void:
	# Points strictly along +X; dir = +X. Far (large x) must come first.
	var pts := PackedVector3Array([
		Vector3(1, 0, 0), Vector3(5, 0, 0), Vector3(-3, 0, 0), Vector3(2, 0, 0)])
	var order := Sorter.sort(pts, Vector3(1, 0, 0))
	# expected x order descending: 5, 2, 1, -3 -> indices 1, 3, 0, 2
	_check(order == PackedInt32Array([1, 3, 0, 2]), "axis order wrong: %s" % str(order))

func _test_choose_width_multiple_of_splat() -> void:
	for count in [1, 10, 1000, 250000]:
		var built := DataTextures.build_image(_make_resource(count))
		_check(bool(built.get("ok", false)), "build_image failed for count %d: %s" % [count, str(built.get("reason", ""))])
		if built.get("ok", false):
			_check(int(built["width"]) % DataTextures.TEXELS_PER_SPLAT == 0,
				"width %d not a multiple of %d" % [int(built["width"]), DataTextures.TEXELS_PER_SPLAT])

func _test_data_image_roundtrip() -> void:
	var count := 4
	var res: Resource = _make_resource(count)
	var built := DataTextures.build_image(res)
	if not built.get("ok", false):
		_failures.append("roundtrip build_image failed: %s" % str(built.get("reason", "")))
		return
	var image: Image = built["image"]
	var width := int(built["width"])
	var floats: PackedFloat32Array = res.get("point_data_float")
	# Verify a sampling of texels map back to the source floats.
	for s in range(count):
		for k in [0, 3, 7, 14]:
			var texel: int = s * DataTextures.TEXELS_PER_SPLAT + int(k)
			var px := image.get_pixel(texel % width, texel / width)
			var fbase: int = s * 60 + int(k) * 4
			var expected := Color(floats[fbase], floats[fbase + 1], floats[fbase + 2], floats[fbase + 3])
			var d := absf(px.r - expected.r) + absf(px.g - expected.g) + absf(px.b - expected.b) + absf(px.a - expected.a)
			_check(d < 1e-3, "texel s=%d k=%d mismatch got %s exp %s" % [s, k, str(px), str(expected)])

func _test_order_dims() -> void:
	for count in [1, 100, 1000000]:
		var dims := DataTextures.order_dimensions(count)
		_check(dims.x >= 1 and dims.y >= 1, "order dims invalid for %d" % count)
		_check(dims.x * dims.y >= count, "order dims too small for %d: %s" % [count, str(dims)])

func _make_resource(count: int) -> Resource:
	var res: Resource = GaussianResource.new()
	var floats := PackedFloat32Array()
	floats.resize(count * 60)
	for i in range(floats.size()):
		floats[i] = float(i % 997) * 0.5 - 3.0
	res.set("point_count", count)
	res.set("point_data_float", floats)
	res.set("point_data_byte", floats.to_byte_array())
	return res

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
	_test_width_alignment()
	_test_data_image_roundtrip()
	_test_sh_fp16_roundtrip()
	_test_default_build_preserves_tiny_covariance()
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

func _test_width_alignment() -> void:
	# 250000 splats also exercises the chunked strip reshape (>1 chunk of rows).
	for count in [1, 10, 1000, 250000]:
		var built := DataTextures.build_images(_make_resource(count))
		_check(bool(built.get("ok", false)), "build_images failed for count %d: %s" % [count, str(built.get("reason", ""))])
		if built.get("ok", false):
			_check(int(built["core_width"]) % DataTextures.CORE_TEXELS_PER_SPLAT == 0,
				"core width %d not a multiple of %d" % [int(built["core_width"]), DataTextures.CORE_TEXELS_PER_SPLAT])
			_check(int(built["sh_width"]) % DataTextures.SH_TEXELS_PER_SPLAT == 0,
				"sh width %d not a multiple of %d" % [int(built["sh_width"]), DataTextures.SH_TEXELS_PER_SPLAT])

func _core_pixel(built: Dictionary, splat: int, k: int) -> Color:
	var image: Image = built["core_image"]
	var width := int(built["core_width"])
	var texel: int = splat * DataTextures.CORE_TEXELS_PER_SPLAT + k
	return image.get_pixel(texel % width, texel / width)

func _sh_pixel(built: Dictionary, splat: int, j: int) -> Color:
	var image: Image = built["sh_image"]
	var width := int(built["sh_width"])
	var texel: int = splat * DataTextures.SH_TEXELS_PER_SPLAT + j
	return image.get_pixel(texel % width, texel / width)

func _test_data_image_roundtrip() -> void:
	# Full-FP32 build: every texel of both textures must map back to the source
	# floats exactly (core texel k holds floats k*4..k*4+3; SH texel j holds
	# floats 12 + j*4 ..).
	var count := 4
	var res: Resource = _make_resource(count)
	var built := DataTextures.build_images(res, false)
	if not built.get("ok", false):
		_failures.append("roundtrip build_images failed: %s" % str(built.get("reason", "")))
		return
	var floats: PackedFloat32Array = res.get("point_data_float")
	for s in range(count):
		for k in range(DataTextures.CORE_TEXELS_PER_SPLAT):
			var px := _core_pixel(built, s, k)
			var fbase: int = s * 60 + k * 4
			var expected := Color(floats[fbase], floats[fbase + 1], floats[fbase + 2], floats[fbase + 3])
			var d := absf(px.r - expected.r) + absf(px.g - expected.g) + absf(px.b - expected.b) + absf(px.a - expected.a)
			_check(d < 1e-6, "core texel s=%d k=%d mismatch got %s exp %s" % [s, k, str(px), str(expected)])
		for j in range(DataTextures.SH_TEXELS_PER_SPLAT):
			var px := _sh_pixel(built, s, j)
			var fbase: int = s * 60 + 12 + j * 4
			var expected := Color(floats[fbase], floats[fbase + 1], floats[fbase + 2], floats[fbase + 3])
			var d := absf(px.r - expected.r) + absf(px.g - expected.g) + absf(px.b - expected.b) + absf(px.a - expected.a)
			_check(d < 1e-6, "sh texel s=%d j=%d mismatch got %s exp %s" % [s, j, str(px), str(expected)])

func _test_sh_fp16_roundtrip() -> void:
	# Default build: SH texture is RGBA16F and must hold coefficients within
	# FP16 relative precision; the core texture must stay full RGBA32F.
	var count := 4
	var res: Resource = _make_resource(count)
	var built := DataTextures.build_images(res)
	if not built.get("ok", false):
		_failures.append("fp16 build_images failed: %s" % str(built.get("reason", "")))
		return
	_check((built["sh_image"] as Image).get_format() == Image.FORMAT_RGBAH,
		"sh image not RGBAH: %d" % (built["sh_image"] as Image).get_format())
	_check((built["core_image"] as Image).get_format() == Image.FORMAT_RGBAF,
		"core image not RGBAF: %d" % (built["core_image"] as Image).get_format())
	var floats: PackedFloat32Array = res.get("point_data_float")
	for s in range(count):
		for j in [0, 5, 11]:
			var px := _sh_pixel(built, s, int(j))
			var fbase: int = s * 60 + 12 + int(j) * 4
			for ch in range(4):
				var expected: float = floats[fbase + ch]
				var got: float = [px.r, px.g, px.b, px.a][ch]
				var tol: float = 0.002 * absf(expected) + 1e-4
				_check(absf(got - expected) <= tol,
					"fp16 sh texel s=%d j=%d ch=%d got %f exp %f" % [s, int(j), ch, got, expected])

func _test_default_build_preserves_tiny_covariance() -> void:
	# Regression guard: covariance entries are sigma^2 and sit far below the
	# FP16 minimum normal (6.1e-5) for millimetre-scale splats. Godot's FP16
	# conversion flushes those to zero, so the default build must keep the core
	# texels (position/covariance/opacity) in full FP32. An all-FP16 packing
	# shipped once and visually reproduced the pre-2.1.0 covariance bug.
	var count := 2
	var floats := PackedFloat32Array()
	floats.resize(count * 60)
	floats.fill(0.0)
	for s in range(count):
		var base := s * 60
		floats[base + 4] = 1.0e-6    # cov xx (sigma = 1 mm)
		floats[base + 5] = -2.5e-5   # cov xy
		floats[base + 9] = 6.0e-5    # cov zz, just below the FP16 min normal
		floats[base + 10] = 0.004    # opacity ~ 1/255
	var res := _make_resource_from(count, floats)
	var built := DataTextures.build_images(res)
	if not built.get("ok", false):
		_failures.append("tiny-cov build_images failed: %s" % str(built.get("reason", "")))
		return
	for s in range(count):
		var base := s * 60
		var t1 := _core_pixel(built, s, 1)   # cov xx, xy, xz, yy
		var t2 := _core_pixel(built, s, 2)   # cov yz, zz, opacity, pad
		# Compare against the float32-rounded source values: the round trip
		# through the RGBA32F image must be bit-exact.
		_check(t1.r == floats[base + 4], "tiny cov xx lost: %.10f" % t1.r)
		_check(t1.g == floats[base + 5], "tiny cov xy lost: %.10f" % t1.g)
		_check(t2.g == floats[base + 9], "tiny cov zz lost: %.10f" % t2.g)
		_check(t2.b == floats[base + 10], "opacity lost: %.10f" % t2.b)

func _test_order_dims() -> void:
	for count in [1, 100, 1000000]:
		var dims := DataTextures.order_dimensions(count)
		_check(dims.x >= 1 and dims.y >= 1, "order dims invalid for %d" % count)
		_check(dims.x * dims.y >= count, "order dims too small for %d: %s" % [count, str(dims)])

func _make_resource(count: int) -> Resource:
	var floats := PackedFloat32Array()
	floats.resize(count * 60)
	for i in range(floats.size()):
		floats[i] = float(i % 997) * 0.5 - 3.0
	return _make_resource_from(count, floats)

func _make_resource_from(count: int, floats: PackedFloat32Array) -> Resource:
	var res: Resource = GaussianResource.new()
	res.set("point_count", count)
	res.set("point_data_float", floats)
	res.set("point_data_byte", floats.to_byte_array())
	return res

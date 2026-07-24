@tool
extends RefCounted

## Builds the Raster backend's index-addressed data texture.
##
## The frozen GaussianResource blob (240 bytes = 60 float32 = 15 RGBA texels per
## splat) is copied verbatim into an RGBA32F texture — zero repack, matching the
## Compute backend's zero-repack upload. The shader addresses it as
## `texel = splat_index * 15 + k`, `x = texel % width`, `y = texel / width`.
##
## Width is rounded to a multiple of TEXELS_PER_SPLAT so each splat's 15 texels
## stay on a single row (no wrap mid-splat). FP16/quantized packing is a Phase 4+
## concern layered on top; this baseline stays FP32.

const TEXELS_PER_SPLAT := 15
const FLOATS_PER_SPLAT := 60
const BYTES_PER_TEXEL := 16      # RGBA32F
const BYTES_PER_SPLAT := 240
const MAX_TEXTURE_DIM := 16384

# Order texture: one R32F texel per sorted entry, storing a splat index as a
# float. Exact for indices up to 2^24 (~16.7M), which matches the single-2D
# data-texture splat ceiling, so no packing is needed here.
const ORDER_BYTES_PER_TEXEL := 4

## Returns {ok, texture, width} or {ok=false, reason}.
## By default the GPU texture is packed as RGBA16F (half the VRAM of the source
## FP32 blob) — the Raster backend's headline memory win. FP16 covers positions,
## covariance, opacity and SH with ample range for typical captures.
static func build(resource, half_precision: bool = true) -> Dictionary:
	var built: Dictionary = build_image(resource, half_precision)
	if not bool(built.get("ok", false)):
		return built
	var texture := ImageTexture.create_from_image(built["image"])
	if texture == null:
		return {"ok": false, "reason": "ImageTexture.create_from_image failed"}
	return {"ok": true, "texture": texture, "width": int(built["width"])}

## CPU-only half of build(): produces the padded data Image and its width.
## Split out so the packing/addressing can be unit-tested headless (no GPU).
## With half_precision the RGBA32F image is bulk-converted to RGBA16F in C++
## (Image.convert, no per-splat GDScript loop). Returns {ok, image, width} or
## {ok=false, reason}.
static func build_image(resource, half_precision: bool = false) -> Dictionary:
	if resource == null:
		return {"ok": false, "reason": "null resource"}

	var count := int(resource.get("point_count"))
	if count <= 0:
		return {"ok": false, "reason": "empty resource"}

	var data: PackedByteArray = resource.get("point_data_byte")
	var expected := count * BYTES_PER_SPLAT
	if data.size() != expected:
		return {"ok": false, "reason": "data size %d != expected %d" % [data.size(), expected]}

	var total_texels := count * TEXELS_PER_SPLAT
	var width := _choose_width(total_texels)
	var height := int(ceil(float(total_texels) / float(width)))
	if height > MAX_TEXTURE_DIM:
		return {"ok": false, "reason": "%d splats exceed a single 2D data texture" % count}

	# Pad the tail so the image data is exactly width*height*16 bytes. Padding
	# texels belong to no splat and are never fetched (point_count guards them).
	var needed := width * height * BYTES_PER_TEXEL
	var padded := data
	if padded.size() != needed:
		padded = data.duplicate()
		padded.resize(needed)

	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, padded)
	if image == null:
		return {"ok": false, "reason": "Image.create_from_data failed"}

	if half_precision:
		image.convert(Image.FORMAT_RGBAH)

	return {"ok": true, "image": image, "width": width}

# --- order texture (sorted splat indices) ---

## Roughly-square dimensions holding `count` R32F index texels.
static func order_dimensions(count: int) -> Vector2i:
	if count <= 0:
		return Vector2i(1, 1)
	var side := int(ceil(sqrt(float(count))))
	var width := clampi(side, 1, MAX_TEXTURE_DIM)
	var height := int(ceil(float(count) / float(width)))
	return Vector2i(width, height)

## Creates an R32F order Image of the given dimensions, initialised to identity
## (texel i = i), so the first frames render in resource order until the first
## sort completes.
static func make_order_image(dims: Vector2i) -> Image:
	var texels := dims.x * dims.y
	var floats := PackedFloat32Array()
	floats.resize(texels)
	for i in range(texels):
		floats[i] = float(i)
	return Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_RF, floats.to_byte_array())

## Fills `scratch` (reused across frames, sized to dims.x*dims.y) with the sorted
## order as floats and returns its byte view, ready for Image.set_data + update.
static func order_to_bytes(order: PackedInt32Array, scratch: PackedFloat32Array, texel_count: int) -> PackedByteArray:
	if scratch.size() != texel_count:
		scratch.resize(texel_count)
	var n := mini(order.size(), texel_count)
	for i in range(n):
		scratch[i] = float(order[i])
	return scratch.to_byte_array()

static func _choose_width(total_texels: int) -> int:
	if total_texels <= TEXELS_PER_SPLAT:
		return TEXELS_PER_SPLAT
	# Aim for a roughly square texture, rounded up to a whole number of splats
	# per row, capped at the largest splat-aligned width the GPU allows.
	var side := int(ceil(sqrt(float(total_texels))))
	var width := int(ceil(float(side) / float(TEXELS_PER_SPLAT))) * TEXELS_PER_SPLAT
	var max_width := (MAX_TEXTURE_DIM / TEXELS_PER_SPLAT) * TEXELS_PER_SPLAT
	return clampi(width, TEXELS_PER_SPLAT, max_width)

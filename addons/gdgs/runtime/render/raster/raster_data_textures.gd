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

## Returns {ok, texture, width} or {ok=false, reason}.
static func build(resource) -> Dictionary:
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

	var texture := ImageTexture.create_from_image(image)
	if texture == null:
		return {"ok": false, "reason": "ImageTexture.create_from_image failed"}

	return {"ok": true, "texture": texture, "width": width}

static func _choose_width(total_texels: int) -> int:
	if total_texels <= TEXELS_PER_SPLAT:
		return TEXELS_PER_SPLAT
	# Aim for a roughly square texture, rounded up to a whole number of splats
	# per row, capped at the largest splat-aligned width the GPU allows.
	var side := int(ceil(sqrt(float(total_texels))))
	var width := int(ceil(float(side) / float(TEXELS_PER_SPLAT))) * TEXELS_PER_SPLAT
	var max_width := (MAX_TEXTURE_DIM / TEXELS_PER_SPLAT) * TEXELS_PER_SPLAT
	return clampi(width, TEXELS_PER_SPLAT, max_width)

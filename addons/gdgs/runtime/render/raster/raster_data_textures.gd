@tool
extends RefCounted

## Builds the Raster backend's index-addressed data textures.
##
## The frozen GaussianResource blob (240 bytes = 60 float32 = 15 RGBA texels per
## splat) is split into two textures:
##
##   - core (RGBA32F, 3 texels/splat): position, 3D covariance and opacity —
##     floats 0-11 of the struct. This MUST stay full float32: covariance
##     entries are sigma^2 in metres^2, and Godot's FP16 conversion flushes
##     values below 6.1e-5 (the FP16 minimum normal) to zero, so any splat axis
##     thinner than ~8 mm collapses. An all-FP16 texture shipped once and
##     visually reproduced the pre-2.1.0 covariance-projection bug.
##   - sh (RGBA16F by default, 12 texels/splat): the 48 SH colour coefficients,
##     floats 12-59. Unit-scale values, safe in half precision. SH is 80% of
##     the data, so this still carries the Raster backend's VRAM win
##     (240 -> 144 bytes per splat).
##
## The shader addresses each texture as `texel = splat_index * texels_per_splat
## + k`, `x = texel % width`, `y = texel / width` (any width works; widths are
## kept splat-aligned so no splat wraps mid-row).
##
## The split uses bulk C++ operations only (PackedByteArray.slice and
## Image.get_region on strips of <= 16384 splat rows) — never a per-splat
## GDScript loop, which would take minutes at millions of splats.

const TEXELS_PER_SPLAT := 15        # source AoS blob texels
const CORE_TEXELS_PER_SPLAT := 3
const SH_TEXELS_PER_SPLAT := 12
const FLOATS_PER_SPLAT := 60
const BYTES_PER_SPLAT := 240
const BYTES_PER_TEXEL_F32 := 16     # RGBA32F
const BYTES_PER_TEXEL_F16 := 8      # RGBA16F
const MAX_TEXTURE_DIM := 16384
const SPLIT_CHUNK_ROWS := 16384     # strip height for the bulk reshape

# Order texture: one R32F texel per sorted entry, storing a splat index as a
# float. Exact for indices up to 2^24 (~16.7M), which exceeds the SH texture's
# splat ceiling, so no packing is needed here.
const ORDER_BYTES_PER_TEXEL := 4

# Lighting texture: one RGBA8 texel per splat, byte-identical to the baked
# GaussianLightingResource record (oct normal XY, AO, confidence). No repacking
# is needed — the blob is already in texel order — so this is a pure reshape.
const LIGHTING_TEXELS_PER_SPLAT := 1
const LIGHTING_BYTES_PER_TEXEL := 4

## Returns {ok, core_texture, core_width, sh_texture, sh_width} or
## {ok=false, reason}.
static func build(resource, sh_half: bool = true) -> Dictionary:
	var built: Dictionary = build_images(resource, sh_half)
	if not bool(built.get("ok", false)):
		return built
	var core_texture := ImageTexture.create_from_image(built["core_image"])
	var sh_texture := ImageTexture.create_from_image(built["sh_image"])
	if core_texture == null or sh_texture == null:
		return {"ok": false, "reason": "ImageTexture.create_from_image failed"}
	return {
		"ok": true,
		"core_texture": core_texture,
		"core_width": int(built["core_width"]),
		"sh_texture": sh_texture,
		"sh_width": int(built["sh_width"]),
	}

## CPU-only half of build(): produces the padded core/SH Images and widths.
## Split out so the packing/addressing can be unit-tested headless (no GPU).
## Returns {ok, core_image, core_width, sh_image, sh_width} or
## {ok=false, reason}.
static func build_images(resource, sh_half: bool = true) -> Dictionary:
	if resource == null:
		return {"ok": false, "reason": "null resource"}

	var count := int(resource.get("point_count"))
	if count <= 0:
		return {"ok": false, "reason": "empty resource"}

	var data: PackedByteArray = resource.get("point_data_byte")
	var expected := count * BYTES_PER_SPLAT
	if data.size() != expected:
		return {"ok": false, "reason": "data size %d != expected %d" % [data.size(), expected]}

	# Bulk reshape: view the blob as 15-texel-wide strips (one splat per row),
	# then cut the core and SH column bands out of each strip in C++.
	var core_bytes := PackedByteArray()
	var sh_bytes := PackedByteArray()
	var row := 0
	while row < count:
		var rows := mini(SPLIT_CHUNK_ROWS, count - row)
		var strip := Image.create_from_data(TEXELS_PER_SPLAT, rows, false, Image.FORMAT_RGBAF,
			data.slice(row * BYTES_PER_SPLAT, (row + rows) * BYTES_PER_SPLAT))
		if strip == null:
			return {"ok": false, "reason": "strip image create failed"}
		var core_strip := strip.get_region(Rect2i(0, 0, CORE_TEXELS_PER_SPLAT, rows))
		var sh_strip := strip.get_region(Rect2i(CORE_TEXELS_PER_SPLAT, 0, SH_TEXELS_PER_SPLAT, rows))
		if sh_half:
			sh_strip.convert(Image.FORMAT_RGBAH)
		core_bytes.append_array(core_strip.get_data())
		sh_bytes.append_array(sh_strip.get_data())
		row += rows

	var core := _stream_to_image(core_bytes, count * CORE_TEXELS_PER_SPLAT,
		CORE_TEXELS_PER_SPLAT, Image.FORMAT_RGBAF, BYTES_PER_TEXEL_F32)
	if not bool(core.get("ok", false)):
		return core
	var sh := _stream_to_image(sh_bytes, count * SH_TEXELS_PER_SPLAT,
		SH_TEXELS_PER_SPLAT,
		Image.FORMAT_RGBAH if sh_half else Image.FORMAT_RGBAF,
		BYTES_PER_TEXEL_F16 if sh_half else BYTES_PER_TEXEL_F32)
	if not bool(sh.get("ok", false)):
		return sh

	return {
		"ok": true,
		"core_image": core["image"],
		"core_width": int(core["width"]),
		"sh_image": sh["image"],
		"sh_width": int(sh["width"]),
	}

# --- lighting texture (baked per-splat surface record) ---

## Wraps a baked lighting blob as an RGBA8 texture, one texel per splat.
## Returns {ok, lighting_texture, lighting_width} or {ok=false, reason}.
##
## The uniform must NOT be declared `source_color` in the shader: these are
## data bytes, and an sRGB decode would skew every normal and occlusion value.
static func build_lighting(splat_data: PackedByteArray, count: int) -> Dictionary:
	var built := build_lighting_image(splat_data, count)
	if not bool(built.get("ok", false)):
		return built
	var texture := ImageTexture.create_from_image(built["lighting_image"])
	if texture == null:
		return {"ok": false, "reason": "ImageTexture.create_from_image failed"}
	return {
		"ok": true,
		"lighting_texture": texture,
		"lighting_width": int(built["lighting_width"]),
	}


## CPU-only half of build_lighting(), so the packing can be unit-tested
## headless. Returns {ok, lighting_image, lighting_width} or {ok=false, reason}.
static func build_lighting_image(splat_data: PackedByteArray, count: int) -> Dictionary:
	if count <= 0:
		return {"ok": false, "reason": "empty resource"}
	var expected := count * LIGHTING_BYTES_PER_TEXEL
	if splat_data.size() != expected:
		return {"ok": false, "reason": "lighting data size %d != expected %d" % [splat_data.size(), expected]}
	var packed := _stream_to_image(splat_data, count * LIGHTING_TEXELS_PER_SPLAT,
		LIGHTING_TEXELS_PER_SPLAT, Image.FORMAT_RGBA8, LIGHTING_BYTES_PER_TEXEL)
	if not bool(packed.get("ok", false)):
		return packed
	return {
		"ok": true,
		"lighting_image": packed["image"],
		"lighting_width": int(packed["width"]),
	}


# --- order texture (sorted splat indices) ---

## Roughly-square dimensions holding `count` R32F index texels.
static func order_dimensions(count: int) -> Vector2i:
	if count <= 0:
		return Vector2i(1, 1)
	var side := int(ceil(sqrt(float(count))))
	var width := clampi(side, 1, MAX_TEXTURE_DIM)
	var height := int(ceil(float(count) / float(width)))
	return Vector2i(width, height)

## Creates a zeroed R32F order Image of the given dimensions, to be filled by the
## first completed sort. Its contents are not a valid order, so the material
## starts with `use_order = false` (identity, i.e. resource order) and the
## backend flips the flag on when it uploads real data — that keeps this a bulk
## allocation instead of a per-splat identity fill.
static func make_order_image(dims: Vector2i) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(dims.x * dims.y * ORDER_BYTES_PER_TEXEL)   # zero-initialised
	return Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_RF, bytes)

# --- helpers ---

## Lays a texel byte stream out as a roughly-square Image, width aligned to
## `align` texels so no splat wraps mid-row. Pads the tail; padding texels
## belong to no splat and are never fetched (point_count guards them).
static func _stream_to_image(bytes: PackedByteArray, total_texels: int, align: int, format: int, bytes_per_texel: int) -> Dictionary:
	var width := _choose_width(total_texels, align)
	var height := int(ceil(float(total_texels) / float(width)))
	if height > MAX_TEXTURE_DIM:
		return {"ok": false, "reason": "%d texels exceed a single 2D texture" % total_texels}
	var needed := width * height * bytes_per_texel
	var padded := bytes
	if padded.size() != needed:
		padded = bytes.duplicate()
		padded.resize(needed)
	var image := Image.create_from_data(width, height, false, format, padded)
	if image == null:
		return {"ok": false, "reason": "Image.create_from_data failed"}
	return {"ok": true, "image": image, "width": width}

static func _choose_width(total_texels: int, align: int) -> int:
	if total_texels <= align:
		return align
	# Aim for a roughly square texture, rounded up to a whole number of splats
	# per row, capped at the largest splat-aligned width the GPU allows.
	var side := int(ceil(sqrt(float(total_texels))))
	var width := int(ceil(float(side) / float(align))) * align
	var max_width := (MAX_TEXTURE_DIM / align) * align
	return clampi(width, align, max_width)

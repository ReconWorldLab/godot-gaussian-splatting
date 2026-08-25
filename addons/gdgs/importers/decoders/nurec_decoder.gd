@tool
extends RefCounted

const MsgpackReader = preload("res://addons/gdgs/importers/parsers/msgpack_reader.gd")
const GaussianResourceBuilder = preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")

const SH_COEFF_COUNT := 48
const SPECULAR_COEFF_COUNT := 45
const KEY_PREFIX := ".gaussians_nodes.gaussians."

## Decodes a Scaniverse / Omniverse USDZ Gaussian splat into the canonical
## gaussian dictionary consumed by GaussianResourceBuilder.
##
## A USDZ here is a plain ZIP holding a `default.usda` / `gauss.usda` scene
## graph plus a single gzip-compressed MessagePack `.nurec` payload. The payload
## stores each gaussian as float16 tensors:
##   positions  (N,3)  world position
##   rotations  (N,4)  quaternion, scalar-first (w, x, y, z), unnormalized
##   scales     (N,3)  log-space scale (pre-activation)
##   densities  (N,1)  logit-space opacity (pre-activation)
##   features_albedo   (N,3) 0th-order SH (DC colour)
##   features_specular (N,45) higher-order SH, RGB interleaved per band
## The albedo + specular concatenation is byte-for-byte the 48-float SH layout
## the rest of the renderer already expects, so no coefficient reordering is
## required.

static func decode(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	var open_error := zip.open(path)
	if open_error != OK:
		return _error(open_error, "Unable to open USDZ archive: %s" % path)

	var nurec_name := ""
	for entry in zip.get_files():
		if String(entry).to_lower().ends_with(".nurec"):
			nurec_name = String(entry)
			break
	if nurec_name.is_empty():
		zip.close()
		return _error(ERR_FILE_NOT_FOUND, "USDZ archive does not contain a .nurec payload")

	var compressed := zip.read_file(nurec_name)
	zip.close()
	if compressed.is_empty():
		return _error(ERR_FILE_CORRUPT, "USDZ .nurec payload is empty")

	var decompressed := _decompress_gzip(compressed)
	if decompressed.is_empty():
		return _error(ERR_FILE_CORRUPT, "Unable to decompress the .nurec payload")

	var parsed := MsgpackReader.new().parse(decompressed)
	if not parsed.get("ok", false):
		return _error(
			int(parsed.get("error", ERR_INVALID_DATA)),
			String(parsed.get("message", "Unable to parse the .nurec MessagePack"))
		)

	var root: Variant = parsed.get("value")
	if typeof(root) != TYPE_DICTIONARY:
		return _error(ERR_INVALID_DATA, "Unexpected .nurec MessagePack root")

	var nre_data: Variant = root.get("nre_data", {})
	if typeof(nre_data) != TYPE_DICTIONARY:
		return _error(ERR_INVALID_DATA, ".nurec payload is missing nre_data")

	var state_dict: Variant = nre_data.get("state_dict", {})
	if typeof(state_dict) != TYPE_DICTIONARY:
		return _error(ERR_INVALID_DATA, ".nurec payload is missing its state_dict")

	return _decode_state_dict(state_dict)


static func _decode_state_dict(state_dict: Dictionary) -> Dictionary:
	var positions: PackedByteArray = state_dict.get(KEY_PREFIX + "positions", PackedByteArray())
	var rotations: PackedByteArray = state_dict.get(KEY_PREFIX + "rotations", PackedByteArray())
	var scales: PackedByteArray = state_dict.get(KEY_PREFIX + "scales", PackedByteArray())
	var densities: PackedByteArray = state_dict.get(KEY_PREFIX + "densities", PackedByteArray())
	var albedo: PackedByteArray = state_dict.get(KEY_PREFIX + "features_albedo", PackedByteArray())
	var specular: PackedByteArray = state_dict.get(KEY_PREFIX + "features_specular", PackedByteArray())

	var count := int(positions.size() / 6)
	if count <= 0:
		return _error(ERR_INVALID_DATA, ".nurec payload contains no gaussians")
	if rotations.size() != count * 8:
		return _error(ERR_INVALID_DATA, ".nurec rotations tensor has an unexpected size")
	if scales.size() != count * 6:
		return _error(ERR_INVALID_DATA, ".nurec scales tensor has an unexpected size")
	if densities.size() != count * 2:
		return _error(ERR_INVALID_DATA, ".nurec densities tensor has an unexpected size")
	if albedo.size() != count * 6:
		return _error(ERR_INVALID_DATA, ".nurec albedo tensor has an unexpected size")
	if specular.size() != count * SPECULAR_COEFF_COUNT * 2:
		return _error(ERR_INVALID_DATA, ".nurec specular tensor has an unexpected size")

	var canonical := GaussianResourceBuilder.create_canonical(count)
	var out_positions: PackedVector3Array = canonical["positions"]
	var out_scales: PackedVector3Array = canonical["scales_linear"]
	var out_rotations: Array = canonical["rotations"]
	var out_opacities: PackedFloat32Array = canonical["opacities"]
	var out_sh: PackedFloat32Array = canonical["sh_coeffs"]

	for i in count:
		var p := i * 6
		# NuRec is already in the same Y-down ("right-down-front") frame the
		# rest of the plugin canonicalises to, so positions are copied verbatim.
		# GaussianSplatNode applies its default -180° Z correction at the node
		# level to bring that frame into Godot's Y-up world space.
		out_positions[i] = Vector3(
			positions.decode_half(p + 0),
			positions.decode_half(p + 2),
			positions.decode_half(p + 4)
		)

		out_scales[i] = Vector3(
			exp(scales.decode_half(p + 0)),
			exp(scales.decode_half(p + 2)),
			exp(scales.decode_half(p + 4))
		)

		var q := i * 8
		# NuRec stores the quaternion scalar-first (w, x, y, z); Godot's
		# Quaternion constructor is vector-first (x, y, z, w).
		var rotation := Quaternion(
			rotations.decode_half(q + 2),
			rotations.decode_half(q + 4),
			rotations.decode_half(q + 6),
			rotations.decode_half(q + 0)
		).normalized()
		out_rotations[i] = rotation

		out_opacities[i] = _sigmoid(densities.decode_half(i * 2))

		var sh_offset := i * SH_COEFF_COUNT
		out_sh[sh_offset + 0] = albedo.decode_half(p + 0)
		out_sh[sh_offset + 1] = albedo.decode_half(p + 2)
		out_sh[sh_offset + 2] = albedo.decode_half(p + 4)

		var specular_offset := i * SPECULAR_COEFF_COUNT * 2
		for j in SPECULAR_COEFF_COUNT:
			out_sh[sh_offset + 3 + j] = specular.decode_half(specular_offset + j * 2)

	return {
		"ok": true,
		"canonical": canonical
	}


static func _decompress_gzip(compressed: PackedByteArray) -> PackedByteArray:
	# The gzip footer carries the uncompressed size (mod 2^32). For payloads
	# smaller than 4 GiB this is exact and is the ideal output buffer hint.
	var expected := 0
	if compressed.size() >= 4:
		for i in 4:
			expected |= int(compressed[compressed.size() - 4 + i]) << (8 * i)
	if expected <= 0:
		expected = maxi(compressed.size() * 8, 1 << 20)
	return compressed.decompress_dynamic(expected + 1, FileAccess.COMPRESSION_GZIP)


static func _sigmoid(value: float) -> float:
	return 1.0 / (1.0 + exp(-value))


static func _error(code: Error, message: String) -> Dictionary:
	return {
		"ok": false,
		"error": code,
		"message": message
	}

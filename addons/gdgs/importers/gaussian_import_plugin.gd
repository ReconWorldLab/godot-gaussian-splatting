@tool
extends EditorImportPlugin

const BinaryPlyReader = preload("res://addons/gdgs/importers/parsers/binary_ply_reader.gd")
const GaussianResourceBuilder = preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")
const StandardPlyDecoder = preload("res://addons/gdgs/importers/decoders/standard_ply_decoder.gd")
const CompressedPlyDecoder = preload("res://addons/gdgs/importers/decoders/compressed_ply_decoder.gd")
const SplatDecoder = preload("res://addons/gdgs/importers/decoders/splat_decoder.gd")
const SogDecoder = preload("res://addons/gdgs/importers/decoders/sog_decoder.gd")

func _get_priority() -> float:
	return 2.0

func _get_import_order() -> int:
	return 0

func _get_importer_name() -> String:
	return "gaussian.splat.importer"

func _get_format_version() -> int:
	return 5

func _get_visible_name() -> String:
	return "Gaussian Splat (.ply/.compressed.ply/.splat/.sog)"

func _get_recognized_extensions() -> PackedStringArray:
	return ["ply", "splat", "sog"]

func _get_save_extension() -> String:
	return "res"

func _get_resource_type() -> String:
	return "Resource"

func _get_preset_count() -> int:
	return 1

func _get_preset_name(preset_index: int) -> String:
	return "Default"

func _get_import_options(path: String, preset_index: int) -> Array[Dictionary]:
	return []

func _import(source_file, save_path, options, platform_variants, gen_files) -> Error:
	print("[gdgs]: importing gaussian splat file: %s" % source_file)

	var decode_result := _decode_source(String(source_file))
	if not decode_result.get("ok", false):
		push_error("[gdgs]: %s" % decode_result.get("message", "Unknown import error"))
		return int(decode_result.get("error", ERR_CANT_OPEN))

	var build_result := GaussianResourceBuilder.build(decode_result["canonical"])
	if not build_result.get("ok", false):
		push_error("[gdgs]: %s" % build_result.get("message", "Unable to build gaussian resource"))
		return int(build_result.get("error", ERR_INVALID_DATA))

	var filename := "%s.%s" % [save_path, _get_save_extension()]
	var error := ResourceSaver.save(build_result["resource"], filename)
	if error != OK:
		push_error("[gdgs]: failed to save gaussian resource (%d)" % error)
	else:
		print("[gdgs]: import complete, %d gaussians ready for rendering" % int(build_result["resource"].point_count))

	return error

func _decode_source(source_file: String) -> Dictionary:
	var lower_source := source_file.to_lower()
	if lower_source.ends_with(".splat"):
		return SplatDecoder.decode(source_file)
	if lower_source.ends_with(".sog"):
		return SogDecoder.decode(source_file)
	if lower_source.ends_with(".ply"):
		var header := BinaryPlyReader.read(source_file, false)
		if not header.get("ok", false):
			return header
		if _is_compressed_ply(source_file, header):
			return CompressedPlyDecoder.decode(source_file)
		return StandardPlyDecoder.decode(source_file)
	return {
		"ok": false,
		"error": ERR_FILE_UNRECOGNIZED,
		"message": "Unsupported gaussian splat extension: %s" % source_file.get_extension()
	}

func _is_compressed_ply(source_file: String, header: Dictionary) -> bool:
	if source_file.to_lower().ends_with(".compressed.ply"):
		return true

	var chunk_element := BinaryPlyReader.get_element(header, "chunk")
	var vertex_element := BinaryPlyReader.get_element(header, "vertex")
	if chunk_element.is_empty() or vertex_element.is_empty():
		return false

	var property_map: Dictionary = vertex_element.get("property_map", {})
	return property_map.has("packed_position") and property_map.has("packed_rotation") and property_map.has("packed_scale") and property_map.has("packed_color")

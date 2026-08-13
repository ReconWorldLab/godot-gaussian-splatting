@tool
extends RefCounted

const GaussianResourceBuilder = preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")

const SH_COEFF_COUNT := 48

static func decode(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _error(FileAccess.get_open_error(), "Unable to open glTF file: %s" % path)

	var is_glb = path.get_extension().to_lower() == "glb"
	var json_dict = {}
	var bin_buffer = PackedByteArray()

	# 1. Parse GLTF/GLB Structure
	if is_glb:
		file.get_32() # magic
		file.get_32() # version
		file.get_32() # length
		var chunk0_len = file.get_32()
		file.get_32() # chunk0_type (JSON)
		var json_str = file.get_buffer(chunk0_len).get_string_from_utf8()
		json_dict = JSON.parse_string(json_str)

		if file.get_position() < file.get_length():
			var chunk1_len = file.get_32()
			file.get_32() # chunk1_type (BIN)
			bin_buffer = file.get_buffer(chunk1_len)
	else:
		var json_str = file.get_as_text()
		json_dict = JSON.parse_string(json_str)
		var buffers = json_dict.get("buffers", [])
		if buffers.size() > 0 and buffers[0].has("uri"):
			var uri = buffers[0]["uri"]
			var bin_path = path.get_base_dir().path_join(uri)
			var bin_file = FileAccess.open(bin_path, FileAccess.READ)
			if bin_file != null:
				bin_buffer = bin_file.get_buffer(bin_file.get_length())

	# 2. Locate KHR_gaussian_splatting primitive
	var splat_prim = null
	var meshes = json_dict.get("meshes", [])
	for mesh in meshes:
		for prim in mesh.get("primitives", []):
			if prim.has("extensions") and prim["extensions"].has("KHR_gaussian_splatting"):
				splat_prim = prim
				break
		if splat_prim: break

	if not splat_prim:
		return _error(ERR_FILE_UNRECOGNIZED, "No KHR_gaussian_splatting extension found in glTF primitive.")

	var attributes = splat_prim.get("attributes", {})

	var pos_info = _get_accessor_info(json_dict, attributes, "POSITION")
	var scale_info = _get_accessor_info(json_dict, attributes, "KHR_gaussian_splatting:SCALE")
	var rot_info = _get_accessor_info(json_dict, attributes, "KHR_gaussian_splatting:ROTATION")
	var op_info = _get_accessor_info(json_dict, attributes, "KHR_gaussian_splatting:OPACITY")
	
	# Fetch all 16 possible SH VEC3 accessors
	var sh_accessors = []
	# Degree 0 (1 accessor)
	sh_accessors.append(_get_accessor_info(json_dict, attributes, "KHR_gaussian_splatting:SH_DEGREE_0_COEF_0"))
	# Degree 1 (3 accessors)
	for i in range(3): sh_accessors.append(_get_accessor_info(json_dict, attributes, "KHR_gaussian_splatting:SH_DEGREE_1_COEF_" + str(i)))
	# Degree 2 (5 accessors)
	for i in range(5): sh_accessors.append(_get_accessor_info(json_dict, attributes, "KHR_gaussian_splatting:SH_DEGREE_2_COEF_" + str(i)))
	# Degree 3 (7 accessors)
	for i in range(7): sh_accessors.append(_get_accessor_info(json_dict, attributes, "KHR_gaussian_splatting:SH_DEGREE_3_COEF_" + str(i)))

	if pos_info.is_empty() or scale_info.is_empty() or rot_info.is_empty() or op_info.is_empty() or sh_accessors[0].is_empty():
		return _error(ERR_INVALID_DATA, "Missing required KHR_gaussian_splatting attributes.")

	var count = int(pos_info.count)
	var canonical := GaussianResourceBuilder.create_canonical(count)
	
	var positions: PackedVector3Array = canonical["positions"]
	var scales_linear: PackedVector3Array = canonical["scales_linear"]
	var rotations: Array = canonical["rotations"]
	var opacities: PackedFloat32Array = canonical["opacities"]
	var sh_coeffs: PackedFloat32Array = canonical["sh_coeffs"]

	# 3. Decode buffers directly to the canonical layout
	for i in count:
		var p_byte = pos_info.byte_offset + i * pos_info.byte_stride
		positions[i] = Vector3(
			bin_buffer.decode_float(p_byte + 0),
			bin_buffer.decode_float(p_byte + 4),
			bin_buffer.decode_float(p_byte + 8)
		)

		var sc_byte = scale_info.byte_offset + i * scale_info.byte_stride
		scales_linear[i] = Vector3(
			bin_buffer.decode_float(sc_byte + 0),
			bin_buffer.decode_float(sc_byte + 4),
			bin_buffer.decode_float(sc_byte + 8)
		)

		var rot_byte = rot_info.byte_offset + i * rot_info.byte_stride
		rotations[i] = Quaternion(
			bin_buffer.decode_float(rot_byte + 0), # X
			bin_buffer.decode_float(rot_byte + 4), # Y
			bin_buffer.decode_float(rot_byte + 8), # Z
			bin_buffer.decode_float(rot_byte + 12) # W
		).normalized()

		var op_byte = op_info.byte_offset + i * op_info.byte_stride
		opacities[i] = bin_buffer.decode_float(op_byte)

		var sh_offset : int = i * SH_COEFF_COUNT
		
		# Degree 0 (Base color)
		var sh0_info = sh_accessors[0]
		var sh0_byte = sh0_info.byte_offset + i * sh0_info.byte_stride
		sh_coeffs[sh_offset + 0] = bin_buffer.decode_float(sh0_byte + 0)
		sh_coeffs[sh_offset + 1] = bin_buffer.decode_float(sh0_byte + 4)
		sh_coeffs[sh_offset + 2] = bin_buffer.decode_float(sh0_byte + 8)
		
		# --- Higher Order Spherical Harmonics Interleaved Mapping ---
		for acc_idx in range(1, 16):
			var acc = sh_accessors[acc_idx]
			if not acc.is_empty():
				var rest_sh_byte = acc.byte_offset + i * acc.byte_stride
				var coeff_idx = acc_idx - 1 # 0 to 14
				
				# Calculate the exact grouped offset expected by his canonical format
				var coeff_offset = sh_offset + 3 + (coeff_idx * 3)
				
				# VEC3 is strictly [R, G, B]. Pass it straight in!
				sh_coeffs[coeff_offset + 0] = bin_buffer.decode_float(rest_sh_byte + 0) # Red
				sh_coeffs[coeff_offset + 1] = bin_buffer.decode_float(rest_sh_byte + 4) # Green
				sh_coeffs[coeff_offset + 2] = bin_buffer.decode_float(rest_sh_byte + 8) # Blue

	return {
		"ok": true,
		"canonical": canonical
	}

static func _get_accessor_info(json_dict: Dictionary, attributes: Dictionary, attr_name: String) -> Dictionary:
	if not attributes.has(attr_name):
		return {}
		
	var acc_id = attributes[attr_name]
	var acc = json_dict["accessors"][acc_id]
	var bv = json_dict["bufferViews"][acc["bufferView"]]
	var count = acc["count"]
	
	var byte_offset = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
	var byte_stride = bv.get("byteStride", 0)
	
	var type_str = acc["type"]
	var comps = 1
	if type_str == "VEC2": comps = 2
	elif type_str == "VEC3": comps = 3
	elif type_str == "VEC4": comps = 4
	
	# If byte_stride is 0, the buffer is tightly packed
	if byte_stride == 0:
		byte_stride = comps * 4 
		
	return {
		"byte_offset": byte_offset,
		"byte_stride": byte_stride,
		"count": count
	}

static func _error(code: Error, message: String) -> Dictionary:
	return {
		"ok": false,
		"error": code,
		"message": message
	}

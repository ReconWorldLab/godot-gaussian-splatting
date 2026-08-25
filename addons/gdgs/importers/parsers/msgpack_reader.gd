@tool
extends RefCounted

## Minimal streaming MessagePack parser.
##
## The Scaniverse / Omniverse NuRec (.nurec) payload is a gzip-compressed
## MessagePack document. This reader turns that document into plain GDScript
## values (Dictionary / Array / String / int / float / PackedByteArray) so the
## nurec decoder can pull the Gaussian tensors out of it. It is intentionally
## the same "low-level binary reader" role that binary_ply_reader.gd plays for
## PLY: it knows the container format, not the Gaussian semantics.

var _data := PackedByteArray()
var _pos := 0

func parse(source: PackedByteArray) -> Dictionary:
	_data = source
	_pos = 0
	if _data.is_empty():
		return _error(ERR_INVALID_DATA, "Empty MessagePack payload")

	var value: Variant = _read_value()
	if _pos > _data.size():
		return _error(ERR_FILE_CORRUPT, "MessagePack payload is truncated or malformed")

	return {
		"ok": true,
		"value": value
	}


func _read_value() -> Variant:
	if _pos >= _data.size():
		return null

	var code := int(_data[_pos])
	_pos += 1

	# positive fixint
	if code <= 0x7f:
		return code
	# negative fixint
	if code >= 0xe0:
		return code - 256
	# fixstr
	if code >= 0xa0 and code <= 0xbf:
		return _read_string(code & 0x1f)
	# fixarray
	if code >= 0x90 and code <= 0x9f:
		return _read_array(code & 0x0f)
	# fixmap
	if code >= 0x80 and code <= 0x8f:
		return _read_map(code & 0x0f)

	match code:
		0xc0:
			return null
		0xc2:
			return false
		0xc3:
			return true
		0xc4:
			return _read_bin(_read_uint(1))
		0xc5:
			return _read_bin(_read_uint(2))
		0xc6:
			return _read_bin(_read_uint(4))
		0xca:
			return _read_float32()
		0xcb:
			return _read_float64()
		0xcc:
			return _read_uint(1)
		0xcd:
			return _read_uint(2)
		0xce:
			return _read_uint(4)
		0xcf:
			return _read_uint(8)
		0xd0:
			return _read_int(1)
		0xd1:
			return _read_int(2)
		0xd2:
			return _read_int(4)
		0xd3:
			return _read_int(8)
		0xd9:
			return _read_string(_read_uint(1))
		0xda:
			return _read_string(_read_uint(2))
		0xdb:
			return _read_string(_read_uint(4))
		0xdc:
			return _read_array(_read_uint(2))
		0xdd:
			return _read_array(_read_uint(4))
		0xde:
			return _read_map(_read_uint(2))
		0xdf:
			return _read_map(_read_uint(4))
		_:
			return _skip_extension(code)


func _skip_extension(code: int) -> Variant:
	# Extension types do not appear in NuRec payloads, but skipping them keeps
	# the cursor aligned if an unfamiliar writer ever emits one.
	var length := 0
	match code:
		0xd4:
			length = 1
		0xd5:
			length = 2
		0xd6:
			length = 4
		0xd7:
			length = 8
		0xd8:
			length = 16
		0xc7:
			length = _read_uint(1)
		0xc8:
			length = _read_uint(2)
		0xc9:
			length = _read_uint(4)
		_:
			return null
	# One type byte followed by `length` payload bytes.
	_pos += 1 + length
	return null


func _read_uint(length: int) -> int:
	var value := 0
	for i in length:
		value = (value << 8) | int(_data[_pos + i])
	_pos += length
	return value


func _read_int(length: int) -> int:
	var value := _read_uint(length)
	var bits := length * 8
	if value & (1 << (bits - 1)):
		value -= 1 << bits
	return value


func _read_string(length: int) -> String:
	var raw := _data.slice(_pos, _pos + length)
	_pos += length
	return raw.get_string_from_utf8()


func _read_bin(length: int) -> PackedByteArray:
	var raw := _data.slice(_pos, _pos + length)
	_pos += length
	return raw


func _read_array(length: int) -> Array:
	var result: Array = []
	result.resize(length)
	for i in length:
		result[i] = _read_value()
	return result


func _read_map(length: int) -> Dictionary:
	var result := {}
	for i in length:
		var key: Variant = _read_value()
		var value: Variant = _read_value()
		result[key] = value
	return result


func _read_float32() -> float:
	var raw := PackedByteArray()
	raw.resize(4)
	for i in 4:
		raw[i] = _data[_pos + (3 - i)]
	_pos += 4
	return raw.decode_float(0)


func _read_float64() -> float:
	var raw := PackedByteArray()
	raw.resize(8)
	for i in 8:
		raw[i] = _data[_pos + (7 - i)]
	_pos += 8
	return raw.decode_double(0)


func _error(code: Error, message: String) -> Dictionary:
	return {
		"ok": false,
		"error": code,
		"message": message
	}

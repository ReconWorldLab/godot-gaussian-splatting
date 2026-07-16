extends RefCounted


static func build(grid: RefCounted, max_exposed_faces: int, control: RefCounted = null) -> Dictionary:
	var geometry_result := build_geometry(grid, max_exposed_faces, control)
	if not geometry_result.get("ok", false):
		return geometry_result
	return create_mesh(geometry_result)


# Exposed voxel faces are grouped for greedy rectangle merging using three
# integers per face: bucket (face direction: 0/1 = -X/+X, 2/3 = -Y/+Y,
# 4/5 = -Z/+Z), plane (the face's integer coordinate along that axis), and
# (u, v) = the remaining two axes in x→y→z order (X faces use (y, z), Y faces
# (x, z), Z faces (x, y)). A group key is bucket * stride + plane; a face key
# within the group is u * stride + v. That is why the _add_face call sites
# below pass the coordinates in shuffled order.
static func build_geometry(grid: RefCounted, max_exposed_faces: int, control: RefCounted = null) -> Dictionary:
	var coordinate_stride := maxi(grid.nx, maxi(grid.ny, grid.nz)) + 1
	var face_groups: Dictionary = {}
	var exposed_faces := 0
	var occupied_blocks: Array = grid.get_occupied_block_indices()
	var block_count := occupied_blocks.size()

	for block_offset in block_count:
		if block_offset % 64 == 0:
			if _is_cancelled(control):
				return _cancelled_result()
			_report_progress(control, "Extracting exposed voxel faces", 0.80 + 0.06 * float(block_offset) / maxf(block_count, 1))
		var block_index := int(occupied_blocks[block_offset])
		var mask: int = grid.get_block_mask(block_index)
		var block_coordinate: Vector3i = grid.decode_block_index(block_index)
		var voxel_base := block_coordinate * 4
		for bit_index in 64:
			if mask != -1 and (mask & (1 << bit_index)) == 0:
				continue
			var ix := voxel_base.x + (bit_index & 3)
			var iy := voxel_base.y + ((bit_index >> 2) & 3)
			var iz := voxel_base.z + ((bit_index >> 4) & 3)
			if not grid.is_voxel_solid(ix - 1, iy, iz):
				_add_face(face_groups, coordinate_stride, 0, ix, iy, iz)
				exposed_faces += 1
			if not grid.is_voxel_solid(ix + 1, iy, iz):
				_add_face(face_groups, coordinate_stride, 1, ix + 1, iy, iz)
				exposed_faces += 1
			if not grid.is_voxel_solid(ix, iy - 1, iz):
				_add_face(face_groups, coordinate_stride, 2, iy, ix, iz)
				exposed_faces += 1
			if not grid.is_voxel_solid(ix, iy + 1, iz):
				_add_face(face_groups, coordinate_stride, 3, iy + 1, ix, iz)
				exposed_faces += 1
			if not grid.is_voxel_solid(ix, iy, iz - 1):
				_add_face(face_groups, coordinate_stride, 4, iz, ix, iy)
				exposed_faces += 1
			if not grid.is_voxel_solid(ix, iy, iz + 1):
				_add_face(face_groups, coordinate_stride, 5, iz + 1, ix, iy)
				exposed_faces += 1
			if exposed_faces > max_exposed_faces:
				return _failure(
					"Exposed voxel faces exceed the safety limit (%d). Increase voxel_size." % max_exposed_faces
				)

	if exposed_faces == 0:
		return _failure("Voxelization produced no exposed surface.")

	var rectangles := _merge_faces(face_groups, coordinate_stride, control)
	if rectangles.is_empty():
		if _is_cancelled(control):
			return _cancelled_result()
		return _failure("Greedy face merging produced no rectangles.")
	face_groups.clear()
	if _is_cancelled(control):
		return _cancelled_result()

	_report_progress(control, "Splitting T-junctions", 0.93)
	var line_points := _build_line_points(rectangles, coordinate_stride, control)
	if _is_cancelled(control):
		return _cancelled_result()
	var geometry := _triangulate_rectangles(rectangles, line_points, grid, coordinate_stride, control)
	if not geometry.get("ok", false):
		return geometry

	var positions: PackedVector3Array = geometry["positions"]
	var indices: PackedInt32Array = geometry["indices"]
	if positions.is_empty() or indices.is_empty():
		return _failure("T-junction-safe triangulation produced no triangles.")
	var rectangle_count := rectangles.size() / 6
	var triangle_count := indices.size() / 3
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"mesh": null,
		"geometry": {"positions": positions, "indices": indices},
		"stats": {
			"exposed_faces": exposed_faces,
			"rectangles": rectangle_count,
			"vertices": positions.size(),
			"triangles": triangle_count,
		},
		"exposed_faces": exposed_faces,
		"rectangles": rectangle_count,
		"vertices": positions.size(),
		"triangles": triangle_count,
	}


static func create_mesh(geometry_result: Dictionary) -> Dictionary:
	if not geometry_result.get("ok", false):
		return geometry_result
	var geometry: Dictionary = geometry_result.get("geometry", {})
	var positions: PackedVector3Array = geometry.get("positions", PackedVector3Array())
	var indices: PackedInt32Array = geometry.get("indices", PackedInt32Array())
	if positions.is_empty() or indices.is_empty() or indices.size() % 3 != 0:
		return _failure("Collision geometry arrays are empty or malformed.")
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mesh.get_surface_count() == 0:
		return _failure("Godot could not construct the collision mesh surface.")
	var result := geometry_result.duplicate(false)
	result["mesh"] = mesh
	result.erase("geometry")
	return result


static func _add_face(groups: Dictionary, stride: int, bucket: int, plane: int, u: int, v: int) -> void:
	var group_key := bucket * stride + plane
	var faces: Dictionary = groups.get(group_key, {})
	faces[u * stride + v] = true
	groups[group_key] = faces


static func _merge_faces(groups: Dictionary, stride: int, control: RefCounted) -> PackedInt32Array:
	var rectangles := PackedInt32Array()
	var group_keys: Array = groups.keys()
	group_keys.sort()
	var group_count := group_keys.size()
	for group_offset in group_count:
		if group_offset % 32 == 0:
			if _is_cancelled(control):
				return PackedInt32Array()
			_report_progress(control, "Greedy-merging voxel faces", 0.86 + 0.06 * float(group_offset) / maxf(group_count, 1))
		var group_key := int(group_keys[group_offset])
		var bucket := group_key / stride
		var plane := group_key % stride
		var remaining: Dictionary = groups[group_key].duplicate()
		var uv_keys: Array = remaining.keys()
		uv_keys.sort()
		for uv_key_value: Variant in uv_keys:
			var uv_key := int(uv_key_value)
			if not remaining.has(uv_key):
				continue
			var u0 := uv_key / stride
			var v0 := uv_key % stride
			var width := 1
			while remaining.has((u0 + width) * stride + v0):
				width += 1
			var height := 1
			while true:
				var can_grow := true
				for du in width:
					if not remaining.has((u0 + du) * stride + v0 + height):
						can_grow = false
						break
				if not can_grow:
					break
				height += 1
			for dv in height:
				for du in width:
					remaining.erase((u0 + du) * stride + v0 + dv)
			rectangles.append(bucket)
			rectangles.append(plane)
			rectangles.append(u0)
			rectangles.append(v0)
			rectangles.append(u0 + width)
			rectangles.append(v0 + height)
	return rectangles


static func _build_line_points(rectangles: PackedInt32Array, stride: int, control: RefCounted) -> Dictionary:
	var line_points: Dictionary = {}
	var rectangle_count := rectangles.size() / 6
	for rectangle_index in rectangle_count:
		if rectangle_index % 256 == 0 and _is_cancelled(control):
			return {}
		var base := rectangle_index * 6
		var axis := rectangles[base] >> 1
		var plane := rectangles[base + 1]
		var a := _global_point(axis, plane, rectangles[base + 2], rectangles[base + 3])
		var b := _global_point(axis, plane, rectangles[base + 4], rectangles[base + 3])
		var c := _global_point(axis, plane, rectangles[base + 4], rectangles[base + 5])
		var d := _global_point(axis, plane, rectangles[base + 2], rectangles[base + 5])
		_add_line_segment(line_points, stride, a, b)
		_add_line_segment(line_points, stride, b, c)
		_add_line_segment(line_points, stride, c, d)
		_add_line_segment(line_points, stride, d, a)

	for key: Variant in line_points.keys():
		var points: Array = line_points[key]
		points.sort()
		var unique := PackedInt32Array()
		var has_last := false
		var last := 0
		for point_value: Variant in points:
			var point := int(point_value)
			if not has_last or point != last:
				unique.append(point)
				last = point
				has_last = true
		line_points[key] = unique
	return line_points


static func _triangulate_rectangles(
	rectangles: PackedInt32Array,
	line_points: Dictionary,
	grid: RefCounted,
	stride: int,
	control: RefCounted
) -> Dictionary:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var vertex_map: Dictionary = {}
	var rectangle_count := rectangles.size() / 6
	for rectangle_index in rectangle_count:
		if rectangle_index % 128 == 0:
			if _is_cancelled(control):
				return _cancelled_result()
			_report_progress(control, "Triangulating merged faces", 0.95 + 0.045 * float(rectangle_index) / maxf(rectangle_count, 1))
		var base := rectangle_index * 6
		var bucket := rectangles[base]
		var axis := bucket >> 1
		var positive := (bucket & 1) == 1
		var plane := rectangles[base + 1]
		var a := _global_point(axis, plane, rectangles[base + 2], rectangles[base + 3])
		var b := _global_point(axis, plane, rectangles[base + 4], rectangles[base + 3])
		var c := _global_point(axis, plane, rectangles[base + 4], rectangles[base + 5])
		var d := _global_point(axis, plane, rectangles[base + 2], rectangles[base + 5])
		var perimeter_vertices: Array[int] = []
		var perimeter_uv: Array[Vector2i] = []
		_add_edge_vertices(axis, a, b, line_points, stride, grid, positions, vertex_map, perimeter_vertices, perimeter_uv)
		_add_edge_vertices(axis, b, c, line_points, stride, grid, positions, vertex_map, perimeter_vertices, perimeter_uv)
		_add_edge_vertices(axis, c, d, line_points, stride, grid, positions, vertex_map, perimeter_vertices, perimeter_uv)
		_add_edge_vertices(axis, d, a, line_points, stride, grid, positions, vertex_map, perimeter_vertices, perimeter_uv)
		if perimeter_vertices.size() > 1 and perimeter_vertices[0] == perimeter_vertices[-1]:
			perimeter_vertices.pop_back()
			perimeter_uv.pop_back()
		if perimeter_vertices.size() < 3:
			continue
		var local_ccw_is_positive := axis != 1
		var use_local_ccw := positive == local_ccw_is_positive
		_triangulate_perimeter(perimeter_vertices, perimeter_uv, indices, use_local_ccw)
	return {"ok": true, "positions": positions, "indices": indices}


static func _global_point(axis: int, plane: int, u: int, v: int) -> Vector3i:
	if axis == 0:
		return Vector3i(plane, u, v)
	if axis == 1:
		return Vector3i(u, plane, v)
	return Vector3i(u, v, plane)


static func _line_key(variable_axis: int, point: Vector3i, stride: int) -> int:
	if variable_axis == 0:
		return (point.y + point.z * stride) * 3
	if variable_axis == 1:
		return (point.x + point.z * stride) * 3 + 1
	return (point.x + point.y * stride) * 3 + 2


static func _add_line_segment(line_points: Dictionary, stride: int, start: Vector3i, end: Vector3i) -> void:
	var variable_axis := 0 if start.x != end.x else (1 if start.y != end.y else 2)
	var key := _line_key(variable_axis, start, stride)
	var points: Array = line_points.get(key, [])
	points.append(start[variable_axis])
	points.append(end[variable_axis])
	line_points[key] = points


static func _add_edge_vertices(
	axis: int,
	start_point: Vector3i,
	end_point: Vector3i,
	line_points: Dictionary,
	stride: int,
	grid: RefCounted,
	positions: PackedVector3Array,
	vertex_map: Dictionary,
	perimeter_vertices: Array[int],
	perimeter_uv: Array[Vector2i]
) -> void:
	var variable_axis := 0 if start_point.x != end_point.x else (1 if start_point.y != end_point.y else 2)
	var key := _line_key(variable_axis, start_point, stride)
	var points: PackedInt32Array = line_points.get(key, PackedInt32Array())
	var start := start_point[variable_axis]
	var end := end_point[variable_axis]
	var minimum := mini(start, end)
	var maximum := maxi(start, end)
	if start <= end:
		for point_offset in points.size():
			var coordinate := points[point_offset]
			if coordinate < minimum:
				continue
			if coordinate > maximum:
				break
			_append_perimeter_point(axis, variable_axis, coordinate, start_point, stride, grid, positions, vertex_map, perimeter_vertices, perimeter_uv)
	else:
		for point_offset in range(points.size() - 1, -1, -1):
			var coordinate := points[point_offset]
			if coordinate > maximum:
				continue
			if coordinate < minimum:
				break
			_append_perimeter_point(axis, variable_axis, coordinate, start_point, stride, grid, positions, vertex_map, perimeter_vertices, perimeter_uv)


static func _append_perimeter_point(
	axis: int,
	variable_axis: int,
	coordinate: int,
	line_origin: Vector3i,
	stride: int,
	grid: RefCounted,
	positions: PackedVector3Array,
	vertex_map: Dictionary,
	perimeter_vertices: Array[int],
	perimeter_uv: Array[Vector2i]
) -> void:
	var point := line_origin
	point[variable_axis] = coordinate
	var vertex := _get_vertex(point, stride, grid, positions, vertex_map)
	if not perimeter_vertices.is_empty() and perimeter_vertices[-1] == vertex:
		return
	perimeter_vertices.append(vertex)
	perimeter_uv.append(_local_uv(axis, point))


static func _get_vertex(
	point: Vector3i,
	stride: int,
	grid: RefCounted,
	positions: PackedVector3Array,
	vertex_map: Dictionary
) -> int:
	var key := point.x + point.y * stride + point.z * stride * stride
	if vertex_map.has(key):
		return int(vertex_map[key])
	var index := positions.size()
	positions.append(grid.origin + Vector3(point) * grid.voxel_size)
	vertex_map[key] = index
	return index


static func _local_uv(axis: int, point: Vector3i) -> Vector2i:
	if axis == 0:
		return Vector2i(point.y, point.z)
	if axis == 1:
		return Vector2i(point.x, point.z)
	return Vector2i(point.x, point.y)


static func _triangulate_perimeter(
	perimeter_vertices: Array[int],
	perimeter_uv: Array[Vector2i],
	indices: PackedInt32Array,
	use_local_ccw: bool
) -> void:
	var perimeter_count := perimeter_vertices.size()
	var previous := PackedInt32Array()
	var next := PackedInt32Array()
	previous.resize(perimeter_count)
	next.resize(perimeter_count)
	for index in perimeter_count:
		previous[index] = perimeter_count - 1 if index == 0 else index - 1
		next[index] = 0 if index == perimeter_count - 1 else index + 1
	var remaining := perimeter_count
	var current := 0
	var attempts := 0
	while remaining > 3 and attempts < remaining:
		var previous_index := previous[current]
		var next_index := next[current]
		var next_next_index := next[next_index]
		var keeps_area := remaining != 4 or _triangle_cross(perimeter_uv, previous_index, next_index, next_next_index) > 0
		if keeps_area and _triangle_cross(perimeter_uv, previous_index, current, next_index) > 0:
			_append_oriented_triangle(
				indices,
				perimeter_vertices[previous_index], perimeter_vertices[current], perimeter_vertices[next_index],
				use_local_ccw
			)
			next[previous_index] = next_index
			previous[next_index] = previous_index
			current = next_index
			remaining -= 1
			attempts = 0
		else:
			current = next_index
			attempts += 1
	if remaining == 3:
		var a := current
		var b := next[a]
		var c := next[b]
		if _triangle_cross(perimeter_uv, a, b, c) > 0:
			_append_oriented_triangle(indices, perimeter_vertices[a], perimeter_vertices[b], perimeter_vertices[c], use_local_ccw)


static func _triangle_cross(points: Array[Vector2i], a: int, b: int, c: int) -> int:
	var ab := points[b] - points[a]
	var ac := points[c] - points[a]
	return ab.x * ac.y - ab.y * ac.x


static func _append_oriented_triangle(indices: PackedInt32Array, a: int, b: int, c: int, local_ccw: bool) -> void:
	indices.append(a)
	if local_ccw:
		indices.append(b)
		indices.append(c)
	else:
		indices.append(c)
		indices.append(b)


static func _report_progress(control: RefCounted, stage: String, progress: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(progress, 0.0, 1.0))


static func _is_cancelled(control: RefCounted) -> bool:
	return control != null and control.is_cancel_requested()


static func _cancelled_result() -> Dictionary:
	return {"ok": false, "error": "Generation cancelled.", "cancelled": true, "mesh": null, "stats": {}}


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "cancelled": false, "mesh": null, "stats": {}}

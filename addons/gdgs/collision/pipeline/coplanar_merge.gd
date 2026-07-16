extends RefCounted

const NORMAL_DOT_MIN := 0.999
const PLANE_REL_EPS := 0.001
const MAX_PASSES := 8


# Conservative K=1 subset of splat-transform's topology-preserving coplanar
# merge. It removes a vertex only when its complete closed triangle fan is on
# one plane, then ear-clips the unchanged boundary polygon. No position is
# moved or fabricated and selected fans may not share triangles in one pass.
static func merge(geometry: Dictionary, voxel_size: float, control: RefCounted = null) -> Dictionary:
	var positions: PackedVector3Array = geometry.get("positions", PackedVector3Array())
	var indices: PackedInt32Array = geometry.get("indices", PackedInt32Array())
	if indices.is_empty():
		return _failure("Coplanar merge received empty geometry.")
	var input_triangles := indices.size() / 3
	var removed_vertices := 0
	for pass_index in MAX_PASSES:
		if _is_cancelled(control):
			return _cancelled_result()
		_report_progress(control, "Losslessly merging coplanar smooth regions", 0.94 + 0.055 * float(pass_index) / MAX_PASSES)
		var incidents: Array = []
		incidents.resize(positions.size())
		for vertex_index in positions.size():
			incidents[vertex_index] = []
		var normals := PackedVector3Array()
		var planes := PackedFloat32Array()
		var triangle_count := indices.size() / 3
		normals.resize(triangle_count)
		planes.resize(triangle_count)
		var valid := PackedByteArray()
		valid.resize(triangle_count)
		for triangle_index in triangle_count:
			var base := triangle_index * 3
			var a := indices[base]
			var b := indices[base + 1]
			var c := indices[base + 2]
			var normal := (positions[b] - positions[a]).cross(positions[c] - positions[a])
			var length := normal.length()
			if length <= 1.0e-10:
				continue
			normal /= length
			normals[triangle_index] = normal
			planes[triangle_index] = normal.dot(positions[a])
			valid[triangle_index] = 1
			incidents[a].append(triangle_index)
			incidents[b].append(triangle_index)
			incidents[c].append(triangle_index)
		var claimed := PackedByteArray()
		claimed.resize(triangle_count)
		var dead := PackedByteArray()
		dead.resize(triangle_count)
		var replacement := PackedInt32Array()
		var removed_this_pass := 0
		for vertex_index in positions.size():
			var fan: Array = incidents[vertex_index]
			if fan.size() < 3:
				continue
			var conflicts := false
			for triangle_index: int in fan:
				if valid[triangle_index] == 0 or claimed[triangle_index] != 0:
					conflicts = true
					break
			if conflicts or not _fan_is_coplanar(fan, normals, planes, voxel_size):
				continue
			var ring := _extract_ring(vertex_index, fan, indices)
			if ring.size() < 3:
				continue
			var triangulated := _ear_clip(ring, positions, normals[fan[0]])
			if triangulated.size() != (ring.size() - 2) * 3:
				continue
			for triangle_index: int in fan:
				claimed[triangle_index] = 1
				dead[triangle_index] = 1
			replacement.append_array(triangulated)
			removed_this_pass += 1
		if removed_this_pass == 0:
			break
		removed_vertices += removed_this_pass
		var next_indices := PackedInt32Array()
		for triangle_index in triangle_count:
			if dead[triangle_index] == 0 and valid[triangle_index] != 0:
				var base := triangle_index * 3
				next_indices.append(indices[base])
				next_indices.append(indices[base + 1])
				next_indices.append(indices[base + 2])
		next_indices.append_array(replacement)
		indices = next_indices

	var compacted := _compact(positions, indices)
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"geometry": compacted,
		"stats": {
			"coplanar_removed_vertices": removed_vertices,
			"coplanar_removed_triangles": input_triangles - (compacted["indices"] as PackedInt32Array).size() / 3,
		},
	}


static func _fan_is_coplanar(
	triangle_fan: Array,
	normals: PackedVector3Array,
	planes: PackedFloat32Array,
	voxel_size: float
) -> bool:
	var reference_normal: Vector3 = normals[int(triangle_fan[0])]
	var reference_plane: float = planes[int(triangle_fan[0])]
	for offset in range(1, triangle_fan.size()):
		var triangle_index: int = int(triangle_fan[offset])
		var plane: float = planes[triangle_index]
		var epsilon: float = PLANE_REL_EPS * (voxel_size + maxf(absf(reference_plane), absf(plane)))
		if normals[triangle_index].dot(reference_normal) < NORMAL_DOT_MIN or absf(plane - reference_plane) > epsilon:
			return false
	return true


static func _extract_ring(vertex: int, triangle_fan: Array, indices: PackedInt32Array) -> PackedInt32Array:
	var next_by_vertex: Dictionary = {}
	for triangle_index: int in triangle_fan:
		var base := triangle_index * 3
		var a := indices[base]
		var b := indices[base + 1]
		var c := indices[base + 2]
		var from := 0
		var to := 0
		if a == vertex:
			from = b
			to = c
		elif b == vertex:
			from = c
			to = a
		elif c == vertex:
			from = a
			to = b
		else:
			return PackedInt32Array()
		if next_by_vertex.has(from):
			return PackedInt32Array()
		next_by_vertex[from] = to
	if next_by_vertex.size() != triangle_fan.size():
		return PackedInt32Array()
	var keys: Array = next_by_vertex.keys()
	var start := int(keys[0])
	var current := start
	var ring := PackedInt32Array()
	for _step in triangle_fan.size():
		if not next_by_vertex.has(current):
			return PackedInt32Array()
		ring.append(current)
		current = int(next_by_vertex[current])
		if current == start and ring.size() < triangle_fan.size():
			return PackedInt32Array()
	if current != start:
		return PackedInt32Array()
	return ring


static func _ear_clip(ring: PackedInt32Array, positions: PackedVector3Array, normal: Vector3) -> PackedInt32Array:
	var points := PackedVector2Array()
	points.resize(ring.size())
	var dominant := 0
	if absf(normal.y) > absf(normal.x):
		dominant = 1
	if absf(normal.z) > absf(normal[dominant]):
		dominant = 2
	for index in ring.size():
		var point := positions[ring[index]]
		if dominant == 0:
			points[index] = Vector2(point.y, point.z)
		elif dominant == 1:
			points[index] = Vector2(point.x, point.z)
		else:
			points[index] = Vector2(point.x, point.y)
	var area := 0.0
	for index in points.size():
		var next := (index + 1) % points.size()
		area += points[index].cross(points[next])
	var order := PackedInt32Array()
	if area >= 0.0:
		for index in ring.size():
			order.append(index)
	else:
		for index in range(ring.size() - 1, -1, -1):
			order.append(index)
	var output := PackedInt32Array()
	var cursor := 0
	var stalls := 0
	while order.size() > 3 and stalls <= order.size():
		var previous := (cursor + order.size() - 1) % order.size()
		var next := (cursor + 1) % order.size()
		var a := order[previous]
		var b := order[cursor]
		var c := order[next]
		if _cross(points[a], points[b], points[c]) > 1.0e-10 and not _contains_other_point(points, order, a, b, c):
			output.append(ring[a])
			output.append(ring[b])
			output.append(ring[c])
			order.remove_at(cursor)
			if cursor >= order.size():
				cursor = 0
			stalls = 0
		else:
			cursor = next
			stalls += 1
	if order.size() != 3:
		return PackedInt32Array()
	output.append(ring[order[0]])
	output.append(ring[order[1]])
	output.append(ring[order[2]])
	# Projection can reverse 3D winding depending on the dropped axis.
	if output.size() >= 3:
		var out_normal := (positions[output[1]] - positions[output[0]]).cross(positions[output[2]] - positions[output[0]])
		if out_normal.dot(normal) < 0.0:
			for triangle_offset in range(0, output.size(), 3):
				var swap := output[triangle_offset + 1]
				output[triangle_offset + 1] = output[triangle_offset + 2]
				output[triangle_offset + 2] = swap
	return output


static func _cross(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b - a).cross(c - a)


static func _contains_other_point(
	points: PackedVector2Array,
	order: PackedInt32Array,
	a: int, b: int, c: int
) -> bool:
	for point_index: int in order:
		if point_index in [a, b, c]:
			continue
		var p := points[point_index]
		var d1 := _cross(points[a], points[b], p)
		var d2 := _cross(points[b], points[c], p)
		var d3 := _cross(points[c], points[a], p)
		if d1 >= -1.0e-10 and d2 >= -1.0e-10 and d3 >= -1.0e-10:
			return true
	return false


static func _compact(positions: PackedVector3Array, indices: PackedInt32Array) -> Dictionary:
	var remap := PackedInt32Array()
	remap.resize(positions.size())
	remap.fill(-1)
	var compact_positions := PackedVector3Array()
	var compact_indices := PackedInt32Array()
	compact_indices.resize(indices.size())
	for offset in indices.size():
		var old_index := indices[offset]
		if remap[old_index] < 0:
			remap[old_index] = compact_positions.size()
			compact_positions.append(positions[old_index])
		compact_indices[offset] = remap[old_index]
	return {"positions": compact_positions, "indices": compact_indices}


static func _report_progress(control: RefCounted, stage: String, progress: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(progress, 0.0, 1.0))


static func _is_cancelled(control: RefCounted) -> bool:
	return control != null and control.is_cancel_requested()


static func _cancelled_result() -> Dictionary:
	return {"ok": false, "error": "Generation cancelled.", "cancelled": true, "stats": {}}


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "cancelled": false, "stats": {}}

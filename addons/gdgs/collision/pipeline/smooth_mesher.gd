extends RefCounted

const COPLANAR_MERGE_SCRIPT := preload("res://addons/gdgs/collision/pipeline/coplanar_merge.gd")

# Table-free marching-cubes contouring for a binary voxel field. Each cube
# face contributes contour segments between intersected cube edges; the
# segments form one or more closed loops. Shared edge vertices are keyed in
# grid space, so adjacent cubes reuse the exact same vertex and cannot crack.

const CORNERS := [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(1, 1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(1, 1, 1), Vector3i(0, 1, 1),
]
const EDGE_CORNERS := [
	Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
	Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
	Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
]
const FACE_CORNERS := [
	[0, 1, 2, 3], [4, 5, 6, 7],
	[0, 1, 5, 4], [3, 2, 6, 7],
	[0, 3, 7, 4], [1, 2, 6, 5],
]
const FACE_EDGES := [
	[0, 1, 2, 3], [4, 5, 6, 7],
	[0, 9, 4, 8], [2, 10, 6, 11],
	[3, 11, 7, 8], [1, 10, 5, 9],
]


static func build_geometry(grid: RefCounted, max_surface_cells: int, control: RefCounted = null) -> Dictionary:
	var candidate_cells: Dictionary = {}
	var occupied_blocks: Array = grid.get_occupied_block_indices()
	var block_count := occupied_blocks.size()
	var cell_stride_x: int = grid.nx + 1
	var cell_stride_y: int = grid.ny + 1
	for block_offset in block_count:
		if block_offset % 64 == 0:
			if _is_cancelled(control):
				return _cancelled_result()
			_report_progress(control, "Indexing smooth surface cells", 0.80 + 0.05 * float(block_offset) / maxf(block_count, 1))
		var block_index := int(occupied_blocks[block_offset])
		var mask: int = grid.get_block_mask(block_index)
		var voxel_base: Vector3i = grid.decode_block_index(block_index) * 4
		for bit_index in 64:
			if mask != -1 and (mask & (1 << bit_index)) == 0:
				continue
			var voxel := voxel_base + Vector3i(bit_index & 3, (bit_index >> 2) & 3, (bit_index >> 4) & 3)
			for dz in 2:
				for dy in 2:
					for dx in 2:
						var cell := voxel - Vector3i(dx, dy, dz)
						var key: int = (cell.x + 1) + (cell.y + 1) * cell_stride_x + (cell.z + 1) * cell_stride_x * cell_stride_y
						candidate_cells[key] = true

	var cell_keys: Array = candidate_cells.keys()
	if cell_keys.size() > max_surface_cells:
		return _failure(
			"Smooth surface touches %d cells; the safety limit is %d. Increase voxel_size." %
			[cell_keys.size(), max_surface_cells]
		)
	cell_keys.sort()
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var vertex_map: Dictionary = {}
	var surface_cells := 0
	var contour_loops := 0
	var coplanar_polygons := 0
	var cell_count := cell_keys.size()
	for cell_offset in cell_count:
		if cell_offset % 256 == 0:
			if _is_cancelled(control):
				return _cancelled_result()
			_report_progress(control, "Extracting smooth marching-cubes surface", 0.85 + 0.145 * float(cell_offset) / maxf(cell_count, 1))
		var key := int(cell_keys[cell_offset])
		var shifted_z: int = key / (cell_stride_x * cell_stride_y)
		var remainder: int = key - shifted_z * cell_stride_x * cell_stride_y
		var shifted_y: int = remainder / cell_stride_x
		var shifted_x: int = remainder % cell_stride_x
		var cell := Vector3i(shifted_x - 1, shifted_y - 1, shifted_z - 1)
		var inside := PackedByteArray()
		inside.resize(8)
		var inside_count := 0
		var inside_center := Vector3.ZERO
		for corner_index in 8:
			var sample: Vector3i = cell + CORNERS[corner_index]
			if grid.is_voxel_solid(sample.x, sample.y, sample.z):
				inside[corner_index] = 1
				inside_count += 1
				inside_center += _sample_world(grid, sample)
		if inside_count == 0 or inside_count == 8:
			continue
		inside_center /= float(inside_count)
		var adjacency: Array[PackedInt32Array] = []
		adjacency.resize(12)
		for edge_index in 12:
			adjacency[edge_index] = PackedInt32Array()
		for face_index in 6:
			_add_face_segments(inside, FACE_CORNERS[face_index], FACE_EDGES[face_index], adjacency)
		var visited := PackedByteArray()
		visited.resize(12)
		var had_loop := false
		for start_edge in 12:
			if visited[start_edge] != 0 or adjacency[start_edge].is_empty():
				continue
			var loop_edges := _trace_loop(start_edge, adjacency, visited)
			if loop_edges.size() < 3:
				continue
			had_loop = true
			contour_loops += 1
			var loop_vertices: Array[int] = []
			var loop_positions := PackedVector3Array()
			for edge_value: int in loop_edges:
				var edge_position := _edge_world(grid, cell, edge_value)
				loop_positions.append(edge_position)
				loop_vertices.append(_get_edge_vertex(grid, cell, edge_value, edge_position, positions, vertex_map))
			if _is_coplanar(loop_positions):
				coplanar_polygons += 1
				_triangulate_fan(loop_vertices, loop_positions, inside_center, indices)
			else:
				_triangulate_center_fan(loop_vertices, loop_positions, inside_center, positions, indices)
		if had_loop:
			surface_cells += 1

	if indices.is_empty():
		return _failure("Marching cubes produced no smooth surface triangles.")
	var triangles_before_merge := indices.size() / 3
	var merge_result: Dictionary = COPLANAR_MERGE_SCRIPT.merge({
		"positions": positions, "indices": indices,
	}, grid.voxel_size, control)
	if not merge_result.get("ok", false):
		return merge_result
	positions = merge_result["geometry"]["positions"]
	indices = merge_result["geometry"]["indices"]
	var merge_stats: Dictionary = merge_result["stats"]
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"mesh": null,
		"geometry": {"positions": positions, "indices": indices},
		"stats": {
			"surface_cells": surface_cells,
			"contour_loops": contour_loops,
			"coplanar_polygons": coplanar_polygons,
			"triangles_before_coplanar_merge": triangles_before_merge,
			"coplanar_removed_vertices": merge_stats["coplanar_removed_vertices"],
			"coplanar_removed_triangles": merge_stats["coplanar_removed_triangles"],
			"vertices": positions.size(),
			"triangles": indices.size() / 3,
		},
		"surface_cells": surface_cells,
		"contour_loops": contour_loops,
		"coplanar_polygons": coplanar_polygons,
		"triangles_before_coplanar_merge": triangles_before_merge,
		"coplanar_removed_vertices": merge_stats["coplanar_removed_vertices"],
		"coplanar_removed_triangles": merge_stats["coplanar_removed_triangles"],
		"vertices": positions.size(),
		"triangles": indices.size() / 3,
	}


static func _add_face_segments(
	inside: PackedByteArray,
	face_corners: Array,
	face_edges: Array,
	adjacency: Array[PackedInt32Array]
) -> void:
	var crossing := PackedInt32Array()
	for side in 4:
		var next_side := (side + 1) & 3
		if inside[face_corners[side]] != inside[face_corners[next_side]]:
			crossing.append(face_edges[side])
	if crossing.size() == 2:
		_connect(adjacency, crossing[0], crossing[1])
	elif crossing.size() == 4:
		# Binary saddle: pair the two edges meeting at each inside corner. The
		# decision depends only on the shared face samples, so neighboring cubes
		# make the same choice.
		for corner_side in 4:
			if inside[face_corners[corner_side]] != 0:
				_connect(adjacency, face_edges[(corner_side + 3) & 3], face_edges[corner_side])


static func _connect(adjacency: Array[PackedInt32Array], a: int, b: int) -> void:
	if a == b:
		return
	if adjacency[a].find(b) < 0:
		adjacency[a].append(b)
	if adjacency[b].find(a) < 0:
		adjacency[b].append(a)


static func _trace_loop(start_edge: int, adjacency: Array[PackedInt32Array], visited: PackedByteArray) -> PackedInt32Array:
	var loop := PackedInt32Array()
	var previous := -1
	var current := start_edge
	for _step in 24:
		if current == start_edge and not loop.is_empty():
			return loop
		if current < 0 or visited[current] != 0:
			return PackedInt32Array()
		visited[current] = 1
		loop.append(current)
		var neighbors: PackedInt32Array = adjacency[current]
		var next_edge := -1
		for neighbor: int in neighbors:
			if neighbor != previous:
				next_edge = neighbor
				break
		previous = current
		current = next_edge
	return PackedInt32Array()


static func _sample_world(grid: RefCounted, sample: Vector3i) -> Vector3:
	return grid.origin + (Vector3(sample) + Vector3.ONE * 0.5) * grid.voxel_size


static func _edge_world(grid: RefCounted, cell: Vector3i, edge_index: int) -> Vector3:
	var pair: Vector2i = EDGE_CORNERS[edge_index]
	var a := _sample_world(grid, cell + CORNERS[pair.x])
	var b := _sample_world(grid, cell + CORNERS[pair.y])
	return (a + b) * 0.5


static func _get_edge_vertex(
	grid: RefCounted,
	cell: Vector3i,
	edge_index: int,
	position: Vector3,
	positions: PackedVector3Array,
	vertex_map: Dictionary
) -> int:
	var pair: Vector2i = EDGE_CORNERS[edge_index]
	var a: Vector3i = cell + CORNERS[pair.x]
	var b: Vector3i = cell + CORNERS[pair.y]
	var lower := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var axis := 0 if a.x != b.x else (1 if a.y != b.y else 2)
	var sx: int = grid.nx + 2
	var sy: int = grid.ny + 2
	var key: int = axis + 3 * ((lower.x + 1) + (lower.y + 1) * sx + (lower.z + 1) * sx * sy)
	if vertex_map.has(key):
		return int(vertex_map[key])
	var vertex_index := positions.size()
	positions.append(position)
	vertex_map[key] = vertex_index
	return vertex_index


static func _is_coplanar(points: PackedVector3Array) -> bool:
	if points.size() <= 3:
		return true
	var normal := (points[1] - points[0]).cross(points[2] - points[0])
	var scale := normal.length()
	if scale <= 1.0e-8:
		return false
	for index in range(3, points.size()):
		if absf(normal.dot(points[index] - points[0])) > 1.0e-5 * scale:
			return false
	return true


static func _triangulate_fan(
	vertices: Array[int],
	points: PackedVector3Array,
	inside_center: Vector3,
	indices: PackedInt32Array
) -> void:
	for offset in range(1, vertices.size() - 1):
		_append_outward_triangle(
			vertices[0], vertices[offset], vertices[offset + 1],
			points[0], points[offset], points[offset + 1], inside_center, indices
		)


static func _triangulate_center_fan(
	vertices: Array[int],
	points: PackedVector3Array,
	inside_center: Vector3,
	positions: PackedVector3Array,
	indices: PackedInt32Array
) -> void:
	var center := Vector3.ZERO
	for point: Vector3 in points:
		center += point
	center /= float(points.size())
	var center_index := positions.size()
	positions.append(center)
	for offset in vertices.size():
		var next := (offset + 1) % vertices.size()
		_append_outward_triangle(
			center_index, vertices[offset], vertices[next],
			center, points[offset], points[next], inside_center, indices
		)


static func _append_outward_triangle(
	a: int, b: int, c: int,
	pa: Vector3, pb: Vector3, pc: Vector3,
	inside_center: Vector3,
	indices: PackedInt32Array
) -> void:
	var normal := (pb - pa).cross(pc - pa)
	if normal.length_squared() <= 1.0e-16:
		return
	var triangle_center := (pa + pb + pc) / 3.0
	indices.append(a)
	if normal.dot(triangle_center - inside_center) >= 0.0:
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

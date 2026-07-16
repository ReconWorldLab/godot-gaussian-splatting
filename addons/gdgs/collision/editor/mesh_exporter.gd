@tool
extends RefCounted


static func export_mesh(mesh: ArrayMesh, path: String) -> Dictionary:
	if mesh == null or mesh.get_surface_count() == 0:
		return _failure("There is no collision mesh to export.")
	var extension := path.get_extension().to_lower()
	if extension == "res":
		return _export_resource(mesh, path)
	if extension == "obj":
		return _export_obj(mesh, path)
	if extension == "glb":
		return _export_glb(mesh, path)
	return _failure("Unsupported export extension '.%s'. Choose .res, .obj, or .glb." % extension)


static func mesh_from_collision_body(body: Node) -> Dictionary:
	if body == null:
		return _failure("CollisionBody does not exist.")
	var shape_node := body.get_node_or_null(NodePath("CollisionShape3D"))
	if not shape_node is CollisionShape3D:
		return _failure("CollisionBody has no CollisionShape3D child.")
	var shape: Shape3D = shape_node.shape
	if not shape is ConcavePolygonShape3D:
		return _failure("CollisionShape3D is not a concave polygon shape.")
	var faces: PackedVector3Array = shape.get_faces()
	if faces.is_empty() or faces.size() % 3 != 0:
		return _failure("The collision shape contains no valid triangle faces.")
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = faces
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mesh.get_surface_count() == 0:
		return _failure("Godot could not reconstruct an exportable mesh from the collision shape.")
	return {"ok": true, "error": "", "mesh": mesh}


static func _export_resource(mesh: ArrayMesh, path: String) -> Dictionary:
	var copy: ArrayMesh = mesh.duplicate(true)
	copy.resource_name = "GDGS Collision"
	var error := ResourceSaver.save(copy, path)
	return _save_result(error, path)


static func _export_obj(mesh: ArrayMesh, path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _failure("Could not open '%s' for writing: %s" % [path, error_string(FileAccess.get_open_error())])
	file.store_line("# GDGS Collision mesh")
	file.store_line("o GDGS_Collision")
	var vertex_offset := 1
	for surface_index in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(surface_index) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for vertex: Vector3 in vertices:
			file.store_line("v %.9f %.9f %.9f" % [vertex.x, vertex.y, vertex.z])
		if indices.is_empty():
			for triangle_offset in range(0, vertices.size(), 3):
				file.store_line("f %d %d %d" % [
					vertex_offset + triangle_offset,
					vertex_offset + triangle_offset + 1,
					vertex_offset + triangle_offset + 2,
				])
		else:
			for triangle_offset in range(0, indices.size(), 3):
				file.store_line("f %d %d %d" % [
					vertex_offset + indices[triangle_offset],
					vertex_offset + indices[triangle_offset + 1],
					vertex_offset + indices[triangle_offset + 2],
				])
		vertex_offset += vertices.size()
	file.close()
	return {"ok": true, "error": "", "path": path}


static func _export_glb(mesh: ArrayMesh, path: String) -> Dictionary:
	var root := Node3D.new()
	root.name = &"GDGS_Collision"
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = &"CollisionMesh"
	mesh_instance.mesh = mesh
	root.add_child(mesh_instance)
	mesh_instance.owner = root
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_scene(root, state)
	if error == OK:
		error = document.write_to_filesystem(state, path)
	root.free()
	return _save_result(error, path)


static func _save_result(error: Error, path: String) -> Dictionary:
	if error != OK:
		return _failure("Could not export '%s': %s" % [path, error_string(error)])
	return {"ok": true, "error": "", "path": path}


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "path": "", "mesh": null}

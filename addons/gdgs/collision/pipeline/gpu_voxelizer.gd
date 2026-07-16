extends RefCounted

const MAX_SIGMA := 7.0


static func voxelize(
	source: Dictionary,
	grid: RefCounted,
	opacity_cutoff: float,
	max_candidate_references: int,
	shader_source_text: String,
	control: RefCounted = null
) -> Dictionary:
	if shader_source_text.is_empty():
		return _failure("The private GPU voxelization shader source is unavailable.")
	var positions: PackedVector3Array = source["positions"]
	var inverse_covariances: PackedFloat32Array = source["inverse_covariances"]
	var extents: PackedVector3Array = source["extents"]
	var opacities: PackedFloat32Array = source["opacities"]
	var candidates: Dictionary = {}
	var candidate_references := 0
	for splat_index in positions.size():
		if splat_index % 1024 == 0:
			if _is_cancelled(control):
				return _cancelled_result()
			_report_progress(control, "Indexing splats for private GPU", 0.18 + 0.17 * float(splat_index) / maxf(positions.size(), 1))
		var min_voxel: Vector3i = grid.world_to_voxel_floor(positions[splat_index] - extents[splat_index])
		var max_voxel: Vector3i = grid.world_to_voxel_floor(positions[splat_index] + extents[splat_index])
		min_voxel = min_voxel.max(Vector3i.ZERO)
		max_voxel = max_voxel.min(Vector3i(grid.nx - 1, grid.ny - 1, grid.nz - 1))
		for bz in range(min_voxel.z >> 2, (max_voxel.z >> 2) + 1):
			for by in range(min_voxel.y >> 2, (max_voxel.y >> 2) + 1):
				for bx in range(min_voxel.x >> 2, (max_voxel.x >> 2) + 1):
					candidate_references += 1
					if candidate_references > max_candidate_references:
						return _failure(
							"Gaussian-to-block candidate references exceed the safety limit (%d). Increase voxel_size." %
							max_candidate_references
						)
					var block_index: int = grid.block_index(bx, by, bz)
					var block_candidates: Array = candidates.get(block_index, [])
					block_candidates.append(splat_index)
					candidates[block_index] = block_candidates
	if candidates.is_empty():
		return _failure("No Gaussian splats overlap the private GPU voxel grid.")
	if _is_cancelled(control):
		return _cancelled_result()

	_report_progress(control, "Packing private GPU buffers", 0.36)
	var splat_data := PackedFloat32Array()
	splat_data.resize(positions.size() * 16)
	for splat_index in positions.size():
		var base := splat_index * 16
		var inverse_base := splat_index * 6
		var position := positions[splat_index]
		var extent := extents[splat_index]
		splat_data[base + 0] = position.x
		splat_data[base + 1] = position.y
		splat_data[base + 2] = position.z
		splat_data[base + 3] = opacities[splat_index]
		splat_data[base + 4] = extent.x
		splat_data[base + 5] = extent.y
		splat_data[base + 6] = extent.z
		splat_data[base + 8] = inverse_covariances[inverse_base + 0]
		splat_data[base + 9] = inverse_covariances[inverse_base + 1]
		splat_data[base + 10] = inverse_covariances[inverse_base + 2]
		splat_data[base + 11] = inverse_covariances[inverse_base + 3]
		splat_data[base + 12] = inverse_covariances[inverse_base + 4]
		splat_data[base + 13] = inverse_covariances[inverse_base + 5]
	var candidate_keys: Array = candidates.keys()
	candidate_keys.sort()
	var block_data := PackedInt32Array()
	block_data.resize(candidate_keys.size() * 5)
	var candidate_data := PackedInt32Array()
	candidate_data.resize(candidate_references)
	var candidate_cursor := 0
	for group_index in candidate_keys.size():
		var block_index := int(candidate_keys[group_index])
		var coordinate: Vector3i = grid.decode_block_index(block_index)
		var base := group_index * 5
		var block_candidates: Array = candidates[block_index]
		block_data[base + 0] = coordinate.x
		block_data[base + 1] = coordinate.y
		block_data[base + 2] = coordinate.z
		block_data[base + 3] = candidate_cursor
		block_data[base + 4] = block_candidates.size()
		for splat_value: Variant in block_candidates:
			candidate_data[candidate_cursor] = int(splat_value)
			candidate_cursor += 1
	candidates.clear()

	var dispatch_groups_x := mini(candidate_keys.size(), 32768)
	var dispatch_groups_y := ceili(float(candidate_keys.size()) / dispatch_groups_x)
	var parameter_data := PackedFloat32Array([
		grid.origin.x, grid.origin.y, grid.origin.z, grid.voxel_size,
		-log(1.0 - opacity_cutoff), float(dispatch_groups_x), float(candidate_keys.size()), 0.0,
	])
	var output_bytes := PackedByteArray()
	output_bytes.resize(candidate_keys.size() * 8)
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		return _failure("Godot could not create a private local RenderingDevice on this renderer/device.")
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = shader_source_text.replace("#[compute]", "").strip_edges()
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)
	if spirv == null:
		rd.free()
		return _failure("The private GPU voxelization shader compiler returned no SPIR-V.")
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		rd.free()
		return _failure("Private GPU voxelization shader compilation failed: %s" % compile_error)
	var shader := rd.shader_create_from_spirv(spirv, "GDGS collision private voxelizer")
	if not shader.is_valid():
		rd.free()
		return _failure("Godot could not create the private GPU voxelization shader.")

	var buffers: Array[RID] = []
	var params_buffer := rd.storage_buffer_create(parameter_data.to_byte_array().size(), parameter_data.to_byte_array())
	var splat_buffer := rd.storage_buffer_create(splat_data.to_byte_array().size(), splat_data.to_byte_array())
	var block_buffer := rd.storage_buffer_create(block_data.to_byte_array().size(), block_data.to_byte_array())
	var candidate_buffer := rd.storage_buffer_create(candidate_data.to_byte_array().size(), candidate_data.to_byte_array())
	var output_buffer := rd.storage_buffer_create(output_bytes.size(), output_bytes)
	buffers.assign([params_buffer, splat_buffer, block_buffer, candidate_buffer, output_buffer])
	for buffer: RID in buffers:
		if not buffer.is_valid():
			_free_rids(rd, buffers, shader)
			rd.free()
			return _failure("Godot could not allocate a private GPU voxelization buffer.")
	var uniforms: Array[RDUniform] = []
	for binding in buffers.size():
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(buffers[binding])
		uniforms.append(uniform)
	var uniform_set := rd.uniform_set_create(uniforms, shader, 0)
	var pipeline := rd.compute_pipeline_create(shader)
	if not uniform_set.is_valid() or not pipeline.is_valid():
		if uniform_set.is_valid():
			rd.free_rid(uniform_set)
		if pipeline.is_valid():
			rd.free_rid(pipeline)
		_free_rids(rd, buffers, shader)
		rd.free()
		return _failure("Godot could not create the private GPU compute pipeline.")
	_report_progress(control, "Voxelizing on isolated private GPU", 0.48)
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, dispatch_groups_x, dispatch_groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var result_bytes := rd.buffer_get_data(output_buffer)
	rd.free_rid(pipeline)
	rd.free_rid(uniform_set)
	_free_rids(rd, buffers, shader)
	rd.free()
	if result_bytes.size() != output_bytes.size():
		return _failure("Private GPU readback returned %d bytes; expected %d." % [result_bytes.size(), output_bytes.size()])
	if _is_cancelled(control):
		return _cancelled_result()
	var words: PackedInt32Array = result_bytes.to_int32_array()
	var occupied_blocks := 0
	for group_index in candidate_keys.size():
		var low := int(words[group_index * 2]) & 0xffffffff
		var high := int(words[group_index * 2 + 1]) & 0xffffffff
		var mask := low | (high << 32)
		if mask != 0:
			grid.set_block_mask(int(candidate_keys[group_index]), mask)
			occupied_blocks += 1
	_report_progress(control, "Private GPU voxelization complete", 0.73)
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"mesh": null,
		"stats": {
			"candidate_references": candidate_references,
			"candidate_blocks": candidate_keys.size(),
			"occupied_blocks_before_cleanup": occupied_blocks,
			"compute_backend": "gpu",
			"private_rendering_device": true,
		},
		"candidate_references": candidate_references,
		"candidate_blocks": candidate_keys.size(),
		"occupied_blocks_before_cleanup": occupied_blocks,
	}


static func _free_rids(rd: RenderingDevice, buffers: Array[RID], shader: RID) -> void:
	for buffer: RID in buffers:
		if buffer.is_valid():
			rd.free_rid(buffer)
	if shader.is_valid():
		rd.free_rid(shader)


static func _report_progress(control: RefCounted, stage: String, progress: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(progress, 0.0, 1.0))


static func _is_cancelled(control: RefCounted) -> bool:
	return control != null and control.is_cancel_requested()


static func _cancelled_result() -> Dictionary:
	return {"ok": false, "error": "Generation cancelled.", "cancelled": true, "mesh": null, "stats": {}}


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "cancelled": false, "mesh": null, "stats": {}}

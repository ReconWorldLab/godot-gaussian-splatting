extends RefCounted

const COMMON := preload("res://addons/gdgs/collision/pipeline/pipeline_common.gd")
const CANDIDATE_INDEX_SCRIPT := preload("res://addons/gdgs/collision/pipeline/candidate_index.gd")


static func voxelize(
	source: Dictionary,
	grid: RefCounted,
	opacity_cutoff: float,
	max_candidate_references: int,
	shader_source_text: String,
	control: RefCounted = null
) -> Dictionary:
	if shader_source_text.is_empty():
		return COMMON.failure("The private GPU voxelization shader source is unavailable.")
	var index_result: Dictionary = CANDIDATE_INDEX_SCRIPT.build(source, grid, max_candidate_references, control)
	if not index_result.get("ok", false):
		return index_result
	var positions: PackedVector3Array = source["positions"]
	var inverse_covariances: PackedFloat32Array = source["inverse_covariances"]
	var extents: PackedVector3Array = source["extents"]
	var opacities: PackedFloat32Array = source["opacities"]
	var blocks: PackedInt32Array = index_result["blocks"]
	var starts: PackedInt32Array = index_result["starts"]
	var counts: PackedInt32Array = index_result["counts"]
	var candidate_data: PackedInt32Array = index_result["candidates"]
	var candidate_references: int = index_result["candidate_references"]
	var block_count := blocks.size()

	COMMON.phase_progress(control, "Packing private GPU buffers", &"voxelize", 0.02)
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
	var block_data := PackedInt32Array()
	block_data.resize(block_count * 5)
	for group_index in block_count:
		var coordinate: Vector3i = grid.decode_block_index(blocks[group_index])
		var base := group_index * 5
		block_data[base + 0] = coordinate.x
		block_data[base + 1] = coordinate.y
		block_data[base + 2] = coordinate.z
		block_data[base + 3] = starts[group_index]
		block_data[base + 4] = counts[group_index]

	var dispatch_groups_x := mini(block_count, 32768)
	var dispatch_groups_y := ceili(float(block_count) / dispatch_groups_x)
	var parameter_data := PackedFloat32Array([
		grid.origin.x, grid.origin.y, grid.origin.z, grid.voxel_size,
		-log(1.0 - opacity_cutoff), float(dispatch_groups_x), float(block_count), 0.0,
	])
	var output_bytes := PackedByteArray()
	output_bytes.resize(block_count * 8)
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		return COMMON.failure("Godot could not create a private local RenderingDevice on this renderer/device.")
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = shader_source_text.replace("#[compute]", "").strip_edges()
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)
	if spirv == null:
		rd.free()
		return COMMON.failure("The private GPU voxelization shader compiler returned no SPIR-V.")
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		rd.free()
		return COMMON.failure("Private GPU voxelization shader compilation failed: %s" % compile_error)
	var shader := rd.shader_create_from_spirv(spirv, "GDGS collision private voxelizer")
	if not shader.is_valid():
		rd.free()
		return COMMON.failure("Godot could not create the private GPU voxelization shader.")

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
			return COMMON.failure("Godot could not allocate a private GPU voxelization buffer.")
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
		return COMMON.failure("Godot could not create the private GPU compute pipeline.")
	COMMON.phase_progress(control, "Voxelizing on isolated private GPU", &"voxelize", 0.4)
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
		return COMMON.failure("Private GPU readback returned %d bytes; expected %d." % [result_bytes.size(), output_bytes.size()])
	if COMMON.is_cancelled(control):
		return COMMON.cancelled_result()
	var words: PackedInt32Array = result_bytes.to_int32_array()
	var occupied_blocks := 0
	for group_index in block_count:
		var low := int(words[group_index * 2]) & 0xffffffff
		var high := int(words[group_index * 2 + 1]) & 0xffffffff
		var mask := low | (high << 32)
		if mask != 0:
			grid.set_block_mask(blocks[group_index], mask)
			occupied_blocks += 1
	COMMON.phase_progress(control, "Private GPU voxelization complete", &"voxelize", 1.0)
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"mesh": null,
		"stats": {
			"candidate_references": candidate_references,
			"candidate_blocks": block_count,
			"occupied_blocks_before_cleanup": occupied_blocks,
			"compute_backend": "gpu",
			"private_rendering_device": true,
		},
		"candidate_references": candidate_references,
		"candidate_blocks": block_count,
		"occupied_blocks_before_cleanup": occupied_blocks,
	}


static func _free_rids(rd: RenderingDevice, buffers: Array[RID], shader: RID) -> void:
	for buffer: RID in buffers:
		if buffer.is_valid():
			rd.free_rid(buffer)
	if shader.is_valid():
		rd.free_rid(shader)

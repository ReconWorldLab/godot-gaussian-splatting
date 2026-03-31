@tool
extends RefCounted
class_name GaussianGpuStateCache

const RenderingDeviceContext := preload("res://addons/gdgs/runtime/render/gaussian_rendering_device_context.gd")

const TILE_SIZE := 16
const WORKGROUP_SIZE := 512
const RADIX := 256
const PARTITION_DIVISION := 8
const PARTITION_SIZE := PARTITION_DIVISION * WORKGROUP_SIZE
const MAX_RENDER_STATES := 4
const FLOATS_PER_SPLAT := 60
const FLOATS_PER_CULLED_SPLAT := 16
const BYTES_PER_FLOAT := 4
const MAX_SORT_ELEMENTS_PER_SPLAT := 10

const SHADER_PATH_PROJECTION := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_projection.glsl"
const SHADER_PATH_RADIX_UPSWEEP := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_upsweep.glsl"
const SHADER_PATH_RADIX_SPINE := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_spine.glsl"
const SHADER_PATH_RADIX_DOWNSWEEP := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_downsweep.glsl"
const SHADER_PATH_BOUNDARIES := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_boundaries.glsl"
const SHADER_PATH_RENDER := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_render.glsl"

class RenderState:
	extends RefCounted

	var texture_size := Vector2i.ONE
	var tile_dims := Vector2i.ONE
	var camera_projection: Projection
	var camera_view: Projection
	var camera_push_constants := PackedByteArray()
	var camera_world_position := Vector3.ZERO
	var depth_capture_alpha := 0.5
	var needs_gpu_rebuild := true
	var needs_splat_upload := false
	var needs_instance_upload := false
	var context: GdgsRenderingDeviceContext
	var shaders: Dictionary = {}
	var pipelines: Dictionary = {}
	var descriptors: Dictionary = {}

var _render_states: Dictionary = {}
var _render_state_lru: Array = []
var _pending_gpu_cleanup := false

func has_render_states() -> bool:
	return not _render_states.is_empty()

func request_cleanup() -> void:
	_pending_gpu_cleanup = true

func flush_pending_cleanup() -> void:
	if _pending_gpu_cleanup:
		cleanup_all()

func get_or_create_render_state(texture_size: Vector2i):
	var state: RenderState = _render_states.get(texture_size, null)
	if state == null:
		state = RenderState.new()
		state.texture_size = texture_size
		state.tile_dims = (texture_size + Vector2i(TILE_SIZE - 1, TILE_SIZE - 1)) / TILE_SIZE
		_render_states[texture_size] = state
	_touch_render_state(texture_size)
	_enforce_render_state_cache_limit()
	return state

func mark_all_render_states_needs_gpu_rebuild() -> void:
	for state in _render_states.values():
		state.needs_gpu_rebuild = true

func mark_all_render_states_needs_splat_upload(value: bool) -> void:
	for state in _render_states.values():
		state.needs_splat_upload = value

func mark_all_render_states_needs_instance_upload(value: bool) -> void:
	for state in _render_states.values():
		state.needs_instance_upload = value

func rebuild_gpu_state(state, point_count: int, unique_data_size: int, instance_count: int) -> void:
	cleanup_state(state)
	if point_count <= 0:
		return

	state.context = RenderingDeviceContext.create(RenderingServer.get_rendering_device())

	state.shaders["projection"] = state.context.load_shader(SHADER_PATH_PROJECTION)
	state.shaders["radix_upsweep"] = state.context.load_shader(SHADER_PATH_RADIX_UPSWEEP)
	state.shaders["radix_spine"] = state.context.load_shader(SHADER_PATH_RADIX_SPINE)
	state.shaders["radix_downsweep"] = state.context.load_shader(SHADER_PATH_RADIX_DOWNSWEEP)
	state.shaders["boundaries"] = state.context.load_shader(SHADER_PATH_BOUNDARIES)
	state.shaders["render"] = state.context.load_shader(SHADER_PATH_RENDER)

	var num_sort_elements_max := point_count * MAX_SORT_ELEMENTS_PER_SPLAT
	var num_partitions := (num_sort_elements_max + PARTITION_SIZE - 1) / PARTITION_SIZE
	var block_dims := PackedInt32Array()
	block_dims.resize(6)
	block_dims.fill(1)
	# Pre-size indirect dispatch dimensions on the CPU. On macOS/Metal, updating this
	# buffer from the projection pass can cause the entire GS pipeline to go blank.
	block_dims[0] = num_partitions
	block_dims[3] = ceili(num_sort_elements_max / 256.0)

	state.descriptors["splats"] = state.context.create_storage_buffer(unique_data_size)
	state.descriptors["culled_splats"] = state.context.create_storage_buffer(point_count * FLOATS_PER_CULLED_SPLAT * BYTES_PER_FLOAT)
	state.descriptors["grid_dimensions"] = state.context.create_storage_buffer(6 * 4, block_dims.to_byte_array(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	state.descriptors["histogram"] = state.context.create_storage_buffer(4 + (1 + 4 * RADIX + num_partitions * RADIX) * 4)
	state.descriptors["sort_keys"] = state.context.create_storage_buffer(num_sort_elements_max * 4 * 2)
	state.descriptors["sort_values"] = state.context.create_storage_buffer(num_sort_elements_max * 4 * 2)
	state.descriptors["splat_instance_ids"] = state.context.create_storage_buffer(point_count * 4 * 2)
	state.descriptors["instance_transforms"] = state.context.create_storage_buffer(instance_count * 16 * BYTES_PER_FLOAT)
	state.descriptors["uniforms"] = state.context.create_uniform_buffer(8 * 4)
	state.descriptors["tile_bounds"] = state.context.create_storage_buffer(state.tile_dims.x * state.tile_dims.y * 2 * 4)
	state.descriptors["tile_splat_pos"] = state.context.create_storage_buffer(4 * 4)
	state.descriptors["render_texture"] = state.context.create_texture(state.texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	state.descriptors["depth_texture"] = state.context.create_texture(state.texture_size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)

	var projection_set: RID = state.context.create_descriptor_set([
		state.descriptors["splats"],
		state.descriptors["culled_splats"],
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["sort_values"],
		state.descriptors["grid_dimensions"],
		state.descriptors["splat_instance_ids"],
		state.descriptors["instance_transforms"],
		state.descriptors["uniforms"]
	], state.shaders["projection"], 0)

	var radix_upsweep_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"]
	], state.shaders["radix_upsweep"], 0)

	var radix_spine_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"]
	], state.shaders["radix_spine"], 0)

	var radix_downsweep_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["sort_values"]
	], state.shaders["radix_downsweep"], 0)

	var boundaries_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["tile_bounds"]
	], state.shaders["boundaries"], 0)

	var render_set: RID = state.context.create_descriptor_set([
		state.descriptors["culled_splats"],
		state.descriptors["sort_values"],
		state.descriptors["tile_bounds"],
		state.descriptors["tile_splat_pos"],
		state.descriptors["render_texture"],
		state.descriptors["depth_texture"]
	], state.shaders["render"], 0)

	state.pipelines["gsplat_projection"] = state.context.create_pipeline([ceili(point_count / 256.0), 1, 1], [projection_set], state.shaders["projection"])
	state.pipelines["radix_sort_upsweep"] = state.context.create_pipeline([], [radix_upsweep_set], state.shaders["radix_upsweep"])
	state.pipelines["radix_sort_spine"] = state.context.create_pipeline([RADIX, 1, 1], [radix_spine_set], state.shaders["radix_spine"])
	state.pipelines["radix_sort_downsweep"] = state.context.create_pipeline([], [radix_downsweep_set], state.shaders["radix_downsweep"])
	state.pipelines["gsplat_boundaries"] = state.context.create_pipeline([], [boundaries_set], state.shaders["boundaries"])
	state.pipelines["gsplat_render"] = state.context.create_pipeline([state.tile_dims.x, state.tile_dims.y, 1], [render_set], state.shaders["render"])

	state.needs_gpu_rebuild = false
	state.needs_splat_upload = true
	state.needs_instance_upload = true

func upload_splats(state, point_data_byte: PackedByteArray, splat_instance_ids_byte: PackedByteArray) -> void:
	if state.context == null or point_data_byte.is_empty() or splat_instance_ids_byte.is_empty():
		return
	state.context.device.buffer_update(state.descriptors["splats"].rid, 0, point_data_byte.size(), point_data_byte)
	state.context.device.buffer_update(state.descriptors["splat_instance_ids"].rid, 0, splat_instance_ids_byte.size(), splat_instance_ids_byte)
	state.needs_splat_upload = false

func upload_instance_transforms(state, instance_transforms_byte: PackedByteArray) -> void:
	if state.context == null or instance_transforms_byte.is_empty():
		return
	state.context.device.buffer_update(state.descriptors["instance_transforms"].rid, 0, instance_transforms_byte.size(), instance_transforms_byte)
	state.needs_instance_upload = false

func cleanup_state(state) -> void:
	if state == null:
		return
	if state.context != null:
		state.context.free()
		state.context = null
	state.shaders.clear()
	state.pipelines.clear()
	state.descriptors.clear()
	state.needs_gpu_rebuild = true
	state.needs_splat_upload = true
	state.needs_instance_upload = true

func cleanup_all() -> void:
	for state in _render_states.values():
		cleanup_state(state)
	_render_states.clear()
	_render_state_lru.clear()
	_pending_gpu_cleanup = false

func _touch_render_state(texture_size: Vector2i) -> void:
	var existing_index := _render_state_lru.find(texture_size)
	if existing_index != -1:
		_render_state_lru.remove_at(existing_index)
	_render_state_lru.push_back(texture_size)

func _enforce_render_state_cache_limit() -> void:
	while _render_state_lru.size() > MAX_RENDER_STATES:
		var stale_size = _render_state_lru[0]
		_render_state_lru.remove_at(0)
		var stale_state = _render_states.get(stale_size, null)
		if stale_state != null:
			cleanup_state(stale_state)
			_render_states.erase(stale_size)

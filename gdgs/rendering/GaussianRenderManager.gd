@tool
extends Node
class_name GaussianRenderManager

const TILE_SIZE := 16
const WORKGROUP_SIZE := 512
const RADIX := 256
const PARTITION_DIVISION := 8
const PARTITION_SIZE := PARTITION_DIVISION * WORKGROUP_SIZE
const MAX_RENDER_STATES := 4
const FLOATS_PER_SPLAT := 60
const FLOATS_PER_CULLED_SPLAT := 16
const BYTES_PER_FLOAT := 4

const SHADER_PATH_PROJECTION := "res://addons/gdgs/rendering/shaders/compute/gsplat_projection.glsl"
const SHADER_PATH_RADIX_UPSWEEP := "res://addons/gdgs/rendering/shaders/compute/radix_sort_upsweep.glsl"
const SHADER_PATH_RADIX_SPINE := "res://addons/gdgs/rendering/shaders/compute/radix_sort_spine.glsl"
const SHADER_PATH_RADIX_DOWNSWEEP := "res://addons/gdgs/rendering/shaders/compute/radix_sort_downsweep.glsl"
const SHADER_PATH_BOUNDARIES := "res://addons/gdgs/rendering/shaders/compute/gsplat_boundaries.glsl"
const SHADER_PATH_RENDER := "res://addons/gdgs/rendering/shaders/compute/gsplat_render.glsl"

const RenderingContext := preload("res://addons/gdgs/rendering/RenderingContext.gd")

class RenderState:
	extends RefCounted

	var texture_size := Vector2i.ONE
	var tile_dims := Vector2i.ONE
	var camera_projection: Projection
	var camera_transform: Projection
	var camera_push_constants := PackedByteArray()
	var camera_world_position := Vector3.ZERO
	var depth_capture_alpha := 0.5
	var needs_gpu_rebuild := true
	var needs_splat_upload := false
	var needs_instance_upload := false
	var context: GdgsRenderingContext
	var shaders: Dictionary = {}
	var pipelines: Dictionary = {}
	var descriptors: Dictionary = {}

class NodeEntry:
	extends RefCounted

	var node: Node
	var point_count := 0
	var point_offset := 0
	var instance_index := -1
	var point_data_byte := PackedByteArray()
	var model_transform: Transform3D = Transform3D.IDENTITY

static var _instance

var _splat_nodes: Array[Node] = []
var _node_entries: Dictionary = {}

var _render_states: Dictionary = {}
var _render_state_lru: Array = []

var _point_count := 0
var _point_data_byte := PackedByteArray()
var _splat_instance_ids_byte := PackedByteArray()
var _instance_count := 0
var _instance_transforms_byte := PackedByteArray()

var _pending_gpu_cleanup := false

static func get_instance():
	if _instance != null and is_instance_valid(_instance):
		return _instance
	return null

func _enter_tree() -> void:
	_instance = self

func _exit_tree() -> void:
	if _instance == self:
		_instance = null

func register_splat_node(node: Node) -> void:
	if node == null:
		return
	if _splat_nodes.has(node):
		return
	_splat_nodes.push_back(node)
	_prune_splat_nodes()
	_sync_scene_resources(true)

func unregister_splat_node(node: Node) -> void:
	_splat_nodes.erase(node)
	_prune_splat_nodes()
	_sync_scene_resources(true)

func mark_resource_dirty(node: Node) -> void:
	if node == null:
		return
	_sync_scene_resources(false)

func mark_transform_dirty(node: Node) -> void:
	if node == null:
		return
	_sync_node_transform(node)

func shutdown() -> void:
	if _render_states.is_empty():
		return
	RenderingServer.call_on_render_thread(_cleanup_on_render_thread)

func render_for_compositor(
	texture_size: Vector2i,
	camera_transform: Transform3D,
	camera_projection: Projection,
	camera_world_position: Vector3,
	depth_capture_alpha: float = 0.5
) -> Dictionary:
	if _pending_gpu_cleanup:
		_cleanup_all_gpu_internal()
		_pending_gpu_cleanup = false

	var safe_size := Vector2i(maxi(texture_size.x, 1), maxi(texture_size.y, 1))

	if _point_count <= 0 or _point_data_byte.is_empty():
		if not _render_states.is_empty():
			_cleanup_all_gpu_internal()
		return {}

	var state := _get_or_create_render_state(safe_size)
	_update_camera_from_transform(state, camera_transform, camera_projection)
	state.camera_world_position = camera_world_position
	state.depth_capture_alpha = clampf(depth_capture_alpha, 0.0, 1.0)

	if state.context == null or state.needs_gpu_rebuild:
		_rebuild_gpu_internal(state)
	if state.context == null:
		return {}

	if state.needs_splat_upload:
		_upload_splats_internal(state)
	if state.needs_instance_upload:
		_upload_instance_transforms_internal(state)

	if state.camera_push_constants.is_empty():
		return {}

	_rasterize_internal(state)
	if state.descriptors.has("render_texture") and state.descriptors.has("depth_texture"):
		return {
			"color_alpha_texture": state.descriptors["render_texture"].rid,
			"depth_texture": state.descriptors["depth_texture"].rid
		}
	return {}

func _cleanup_on_render_thread() -> void:
	_cleanup_all_gpu_internal()
	_pending_gpu_cleanup = false

func _sync_scene_resources(force_rebuild: bool) -> void:
	_prune_splat_nodes()

	var next_entries: Dictionary = {}
	var merged_point_data := PackedByteArray()
	var merged_instance_ids := PackedInt32Array()
	var merged_instance_transforms := PackedFloat32Array()
	var total_point_count := 0
	var next_instance_index := 0

	for node in _splat_nodes:
		if not is_instance_valid(node):
			continue

		var entry := _build_node_entry(node, total_point_count, next_instance_index)
		next_entries[node.get_instance_id()] = entry
		if entry.point_count <= 0:
			continue

		total_point_count += entry.point_count
		next_instance_index += 1
		merged_point_data += entry.point_data_byte

		var node_instance_ids := PackedInt32Array()
		node_instance_ids.resize(entry.point_count)
		node_instance_ids.fill(entry.instance_index)
		merged_instance_ids.append_array(node_instance_ids)
		merged_instance_transforms.append_array(_transform_to_column_major_packed_floats(entry.model_transform))

	_node_entries = next_entries

	var merged_instance_ids_byte := merged_instance_ids.to_byte_array()
	var merged_instance_transforms_byte := merged_instance_transforms.to_byte_array()
	if total_point_count <= 0 or merged_point_data.is_empty():
		_point_count = 0
		_point_data_byte = PackedByteArray()
		_splat_instance_ids_byte = PackedByteArray()
		_instance_count = 0
		_instance_transforms_byte = PackedByteArray()
		_mark_all_render_states_needs_splat_upload(false)
		_mark_all_render_states_needs_instance_upload(false)
		_pending_gpu_cleanup = true
		return

	var count_changed := total_point_count != _point_count
	var point_data_size_changed := merged_point_data.size() != _point_data_byte.size()
	var instance_ids_size_changed := merged_instance_ids_byte.size() != _splat_instance_ids_byte.size()
	var instance_count_changed := next_instance_index != _instance_count
	var instance_transforms_size_changed := merged_instance_transforms_byte.size() != _instance_transforms_byte.size()

	_point_count = total_point_count
	_point_data_byte = merged_point_data
	_splat_instance_ids_byte = merged_instance_ids_byte
	_instance_count = next_instance_index
	_instance_transforms_byte = merged_instance_transforms_byte

	if force_rebuild or count_changed or point_data_size_changed or instance_ids_size_changed or instance_count_changed or instance_transforms_size_changed:
		_mark_all_render_states_needs_gpu_rebuild()
	_mark_all_render_states_needs_splat_upload(true)
	_mark_all_render_states_needs_instance_upload(true)

func _sync_node_transform(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return

	var entry: NodeEntry = _node_entries.get(node.get_instance_id(), null)
	if entry == null:
		_sync_scene_resources(false)
		return

	var model_transform := _get_node_transform(node)
	if entry.model_transform == model_transform:
		return

	entry.model_transform = model_transform
	if entry.instance_index < 0 or _instance_count <= 0:
		return

	var instance_transforms_byte := _build_instance_transforms_byte()
	var size_changed := instance_transforms_byte.size() != _instance_transforms_byte.size()
	_instance_transforms_byte = instance_transforms_byte
	if size_changed:
		_mark_all_render_states_needs_gpu_rebuild()
	else:
		_mark_all_render_states_needs_instance_upload(true)

func _build_node_entry(node: Node, point_offset: int, instance_index: int) -> NodeEntry:
	var entry := NodeEntry.new()
	entry.node = node
	entry.point_offset = point_offset
	entry.model_transform = _get_node_transform(node)

	var gaussian: Resource = node.get("gaussian")
	if gaussian == null:
		return entry

	var point_count := int(gaussian.get("point_count"))
	var point_data: PackedByteArray = gaussian.get("point_data_byte")
	if point_count <= 0 or point_data.is_empty():
		return entry

	var expected_size := point_count * FLOATS_PER_SPLAT * BYTES_PER_FLOAT
	if point_data.size() != expected_size:
		push_warning("[gdgs] GaussianResource data size mismatch. Expected %d, got %d bytes." % [expected_size, point_data.size()])
		return entry

	entry.point_count = point_count
	entry.instance_index = instance_index
	entry.point_data_byte = point_data
	return entry

func _get_node_transform(node: Node) -> Transform3D:
	if node is Node3D:
		return (node as Node3D).global_transform
	return Transform3D.IDENTITY

func _build_instance_transforms_byte() -> PackedByteArray:
	if _instance_count <= 0:
		return PackedByteArray()

	var transforms := PackedFloat32Array()
	for node in _splat_nodes:
		if not is_instance_valid(node):
			continue
		var entry: NodeEntry = _node_entries.get(node.get_instance_id(), null)
		if entry == null or entry.point_count <= 0 or entry.instance_index < 0:
			continue
		transforms.append_array(_transform_to_column_major_packed_floats(entry.model_transform))
	return transforms.to_byte_array()

func _get_or_create_render_state(texture_size: Vector2i) -> RenderState:
	var state: RenderState = _render_states.get(texture_size, null)
	if state == null:
		state = RenderState.new()
		state.texture_size = texture_size
		state.tile_dims = (texture_size + Vector2i(TILE_SIZE - 1, TILE_SIZE - 1)) / TILE_SIZE
		_render_states[texture_size] = state
	_touch_render_state(texture_size)
	_enforce_render_state_cache_limit()
	return state

func _touch_render_state(texture_size: Vector2i) -> void:
	var existing_index := _render_state_lru.find(texture_size)
	if existing_index != -1:
		_render_state_lru.remove_at(existing_index)
	_render_state_lru.push_back(texture_size)

func _enforce_render_state_cache_limit() -> void:
	while _render_state_lru.size() > MAX_RENDER_STATES:
		var stale_size = _render_state_lru[0]
		_render_state_lru.remove_at(0)
		var stale_state: RenderState = _render_states.get(stale_size, null)
		if stale_state != null:
			_cleanup_gpu_internal(stale_state)
			_render_states.erase(stale_size)

func _mark_all_render_states_needs_gpu_rebuild() -> void:
	for state in _render_states.values():
		state.needs_gpu_rebuild = true

func _mark_all_render_states_needs_splat_upload(value: bool) -> void:
	for state in _render_states.values():
		state.needs_splat_upload = value

func _mark_all_render_states_needs_instance_upload(value: bool) -> void:
	for state in _render_states.values():
		state.needs_instance_upload = value

func _rebuild_gpu_internal(state: RenderState) -> void:
	_cleanup_gpu_internal(state)
	if _point_count <= 0:
		return

	state.context = RenderingContext.create(RenderingServer.get_rendering_device())

	state.shaders["projection"] = state.context.load_shader(SHADER_PATH_PROJECTION)
	state.shaders["radix_upsweep"] = state.context.load_shader(SHADER_PATH_RADIX_UPSWEEP)
	state.shaders["radix_spine"] = state.context.load_shader(SHADER_PATH_RADIX_SPINE)
	state.shaders["radix_downsweep"] = state.context.load_shader(SHADER_PATH_RADIX_DOWNSWEEP)
	state.shaders["boundaries"] = state.context.load_shader(SHADER_PATH_BOUNDARIES)
	state.shaders["render"] = state.context.load_shader(SHADER_PATH_RENDER)

	var num_sort_elements_max := _point_count * 10
	var num_partitions := (num_sort_elements_max + PARTITION_SIZE - 1) / PARTITION_SIZE
	var block_dims := PackedInt32Array()
	block_dims.resize(6)
	block_dims.fill(1)

	state.descriptors["splats"] = state.context.create_storage_buffer(_point_count * FLOATS_PER_SPLAT * BYTES_PER_FLOAT)
	state.descriptors["culled_splats"] = state.context.create_storage_buffer(_point_count * FLOATS_PER_CULLED_SPLAT * BYTES_PER_FLOAT)
	state.descriptors["grid_dimensions"] = state.context.create_storage_buffer(6 * 4, block_dims.to_byte_array(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	state.descriptors["histogram"] = state.context.create_storage_buffer(4 + (1 + 4 * RADIX + num_partitions * RADIX) * 4)
	state.descriptors["sort_keys"] = state.context.create_storage_buffer(num_sort_elements_max * 4 * 2)
	state.descriptors["sort_values"] = state.context.create_storage_buffer(num_sort_elements_max * 4 * 2)
	state.descriptors["splat_instance_ids"] = state.context.create_storage_buffer(_point_count * 4)
	state.descriptors["instance_transforms"] = state.context.create_storage_buffer(_instance_count * 16 * BYTES_PER_FLOAT)
	state.descriptors["uniforms"] = state.context.create_uniform_buffer(8 * 4)
	state.descriptors["tile_bounds"] = state.context.create_storage_buffer(state.tile_dims.x * state.tile_dims.y * 2 * 4)
	state.descriptors["tile_splat_pos"] = state.context.create_storage_buffer(4 * 4)
	state.descriptors["render_texture"] = state.context.create_texture(state.texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	state.descriptors["depth_texture"] = state.context.create_texture(state.texture_size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)

	var projection_set := state.context.create_descriptor_set([
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

	var radix_upsweep_set := state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"]
	], state.shaders["radix_upsweep"], 0)

	var radix_spine_set := state.context.create_descriptor_set([
		state.descriptors["histogram"]
	], state.shaders["radix_spine"], 0)

	var radix_downsweep_set := state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["sort_values"]
	], state.shaders["radix_downsweep"], 0)

	var boundaries_set := state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["tile_bounds"]
	], state.shaders["boundaries"], 0)

	var render_set := state.context.create_descriptor_set([
		state.descriptors["culled_splats"],
		state.descriptors["sort_values"],
		state.descriptors["tile_bounds"],
		state.descriptors["tile_splat_pos"],
		state.descriptors["render_texture"],
		state.descriptors["depth_texture"]
	], state.shaders["render"], 0)

	state.pipelines["gsplat_projection"] = state.context.create_pipeline([ceili(_point_count / 256.0), 1, 1], [projection_set], state.shaders["projection"])
	state.pipelines["radix_sort_upsweep"] = state.context.create_pipeline([], [radix_upsweep_set], state.shaders["radix_upsweep"])
	state.pipelines["radix_sort_spine"] = state.context.create_pipeline([RADIX, 1, 1], [radix_spine_set], state.shaders["radix_spine"])
	state.pipelines["radix_sort_downsweep"] = state.context.create_pipeline([], [radix_downsweep_set], state.shaders["radix_downsweep"])
	state.pipelines["gsplat_boundaries"] = state.context.create_pipeline([], [boundaries_set], state.shaders["boundaries"])
	state.pipelines["gsplat_render"] = state.context.create_pipeline([state.tile_dims.x, state.tile_dims.y, 1], [render_set], state.shaders["render"])

	state.needs_gpu_rebuild = false
	state.needs_splat_upload = true
	state.needs_instance_upload = true

func _upload_splats_internal(state: RenderState) -> void:
	if state.context == null or _point_data_byte.is_empty() or _splat_instance_ids_byte.is_empty():
		return
	state.context.device.buffer_update(state.descriptors["splats"].rid, 0, _point_data_byte.size(), _point_data_byte)
	state.context.device.buffer_update(state.descriptors["splat_instance_ids"].rid, 0, _splat_instance_ids_byte.size(), _splat_instance_ids_byte)
	state.needs_splat_upload = false

func _upload_instance_transforms_internal(state: RenderState) -> void:
	if state.context == null or _instance_transforms_byte.is_empty():
		return
	state.context.device.buffer_update(state.descriptors["instance_transforms"].rid, 0, _instance_transforms_byte.size(), _instance_transforms_byte)
	state.needs_instance_upload = false

func _rasterize_internal(state: RenderState) -> void:
	if state.context == null:
		return

	var uniforms := RenderingContext.create_push_constant([
		state.camera_world_position.x,
		state.camera_world_position.y,
		state.camera_world_position.z,
		Time.get_ticks_msec() * 1e-3,
		state.texture_size.x,
		state.texture_size.y,
		0,
		0
	])
	state.context.device.buffer_update(state.descriptors["uniforms"].rid, 0, 8 * 4, uniforms)
	state.context.device.buffer_clear(state.descriptors["histogram"].rid, 0, 4 + 4 * RADIX * 4)
	state.context.device.buffer_clear(state.descriptors["tile_bounds"].rid, 0, state.tile_dims.x * state.tile_dims.y * 2 * 4)

	var compute_list := state.context.compute_list_begin()
	state.pipelines["gsplat_projection"].call(state.context, compute_list, state.camera_push_constants)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	for radix_shift_pass in range(4):
		var sort_push_constant := RenderingContext.create_push_constant([
			radix_shift_pass,
			_point_count * 10 * (radix_shift_pass % 2),
			_point_count * 10 * (1 - (radix_shift_pass % 2))
		])
		state.pipelines["radix_sort_upsweep"].call(state.context, compute_list, sort_push_constant, [], state.descriptors["grid_dimensions"].rid, 0)
		state.pipelines["radix_sort_spine"].call(state.context, compute_list, sort_push_constant)
		state.pipelines["radix_sort_downsweep"].call(state.context, compute_list, sort_push_constant, [], state.descriptors["grid_dimensions"].rid, 0)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	state.pipelines["gsplat_boundaries"].call(state.context, compute_list, PackedByteArray(), [], state.descriptors["grid_dimensions"].rid, 3 * 4)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	state.pipelines["gsplat_render"].call(
		state.context,
		compute_list,
		RenderingContext.create_push_constant([0.0, -1, state.depth_capture_alpha, 0.0])
	)
	state.context.compute_list_end()

func _cleanup_gpu_internal(state: RenderState) -> void:
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

func _cleanup_all_gpu_internal() -> void:
	for state in _render_states.values():
		_cleanup_gpu_internal(state)
	_render_states.clear()
	_render_state_lru.clear()

func _transform_to_column_major_floats(transform: Transform3D) -> Array:
	return [
		transform.basis.x[0], transform.basis.x[1], transform.basis.x[2], 0.0,
		transform.basis.y[0], transform.basis.y[1], transform.basis.y[2], 0.0,
		transform.basis.z[0], transform.basis.z[1], transform.basis.z[2], 0.0,
		transform.origin.x, transform.origin.y, transform.origin.z, 1.0
	]

func _transform_to_column_major_packed_floats(transform: Transform3D) -> PackedFloat32Array:
	return PackedFloat32Array(_transform_to_column_major_floats(transform))

func _projection_to_column_major_floats(matrix: Projection) -> Array:
	return [
		matrix.x[0], matrix.x[1], matrix.x[2], matrix.x[3],
		matrix.y[0], matrix.y[1], matrix.y[2], matrix.y[3],
		matrix.z[0], matrix.z[1], matrix.z[2], matrix.z[3],
		matrix.w[0], matrix.w[1], matrix.w[2], matrix.w[3]
	]

func _update_camera_from_transform(state: RenderState, camera_transform: Transform3D, camera_projection: Projection) -> bool:
	var view := Projection(camera_transform.affine_inverse())
	var proj := camera_projection
	if view != state.camera_transform or proj != state.camera_projection:
		state.camera_transform = view
		state.camera_projection = proj
		state.camera_push_constants = RenderingContext.create_push_constant(
			_projection_to_column_major_floats(view) + _projection_to_column_major_floats(proj)
		)
		return true
	return false

func _prune_splat_nodes() -> void:
	for i in range(_splat_nodes.size() - 1, -1, -1):
		if not is_instance_valid(_splat_nodes[i]):
			_splat_nodes.remove_at(i)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and not _render_states.is_empty():
		RenderingServer.call_on_render_thread(_cleanup_on_render_thread)

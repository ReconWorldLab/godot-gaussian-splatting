@tool
extends RefCounted
class_name GaussianSceneRegistry

const FLOATS_PER_SPLAT := 60
const BYTES_PER_FLOAT := 4
# Relighting: one baked record per splat (oct normal, AO, confidence) and two
# vec4 of per-instance knobs. Must match gsplat_projection.glsl.
const LIGHTING_BYTES_PER_SPLAT := 4
const RELIGHT_FLOATS_PER_INSTANCE := 8

class NodeEntry:
	extends RefCounted

	var point_count := 0
	var instance_index := -1
	var point_data_byte := PackedByteArray()
	var lighting_byte := PackedByteArray()
	var model_transform: Transform3D = Transform3D.IDENTITY
	var visible: bool = true
	var has_lighting := false

var _splat_nodes: Array[Node] = []
var _node_entries: Dictionary = {}

var _point_count := 0
var _point_data_byte := PackedByteArray()
var _splat_lighting_byte := PackedByteArray()
var _splat_instance_ids_byte := PackedByteArray()
var _instance_count := 0
var _instance_transforms_byte := PackedByteArray()
var _instance_relight_byte := PackedByteArray()
# The light rig is produced on the main thread and parked here so the renderer,
# which runs on the rendering thread, only ever uploads bytes.
var _light_rig_byte := PackedByteArray()
var _light_count := 0

func register_splat_node(node: Node) -> Dictionary:
	if node == null or _splat_nodes.has(node):
		return {}
	_splat_nodes.push_back(node)
	return _sync_scene_resources(true)

func unregister_splat_node(node: Node) -> Dictionary:
	_splat_nodes.erase(node)
	return _sync_scene_resources(true)

func mark_resource_dirty(node: Node) -> Dictionary:
	if node == null:
		return {}
	return _sync_scene_resources(false)

func mark_transform_dirty(node: Node) -> Dictionary:
	if node == null:
		return {}
	return _sync_node_transform(node)

func has_gpu_data() -> bool:
	return _point_count > 0 and not _point_data_byte.is_empty()

func get_point_count() -> int:
	return _point_count

func get_point_data_byte() -> PackedByteArray:
	return _point_data_byte

func get_splat_instance_ids_byte() -> PackedByteArray:
	return _splat_instance_ids_byte

func get_instance_count() -> int:
	return _instance_count

func get_instance_transforms_byte() -> PackedByteArray:
	return _instance_transforms_byte

func get_splat_lighting_byte() -> PackedByteArray:
	return _splat_lighting_byte

func get_instance_relight_byte() -> PackedByteArray:
	return _instance_relight_byte

func get_light_rig_byte() -> PackedByteArray:
	return _light_rig_byte

func get_light_count() -> int:
	return _light_count

## Main-thread tick from the render manager: parks the freshly packed light rig
## and re-reads every node's relight knobs. Returns true when the renderer needs
## to re-upload, which is only when something actually changed.
func refresh_relight(light_rig_byte: PackedByteArray, light_count: int) -> bool:
	var changed := false
	if light_count != _light_count or light_rig_byte != _light_rig_byte:
		_light_rig_byte = light_rig_byte
		_light_count = light_count
		changed = true
	var relight := _build_instance_relight_byte()
	if relight != _instance_relight_byte:
		_instance_relight_byte = relight
		changed = true
	return changed

func _sync_scene_resources(force_rebuild: bool) -> Dictionary:
	_prune_splat_nodes()

	var next_entries: Dictionary = {}
	var merged_point_data := PackedByteArray()
	var merged_lighting := PackedByteArray()
	var merged_instance_ids := PackedInt32Array()
	var merged_instance_transforms := PackedFloat32Array()
	var total_point_count := 0
	var next_instance_index := 0

	# Keep track of which resources we've already packed into the raw VRAM buffer
	var unique_resources := {}
	# The baked lighting records ride alongside the splat data under the same
	# unique index, so instanced nodes share one upload. A bake is a function of
	# the GaussianResource, so nodes sharing a resource are expected to share a
	# bake; if they disagree the first one wins and the conflict is reported.
	var unique_lighting := {}

	for node in _splat_nodes:
		if not is_instance_valid(node):
			continue

		var entry := _build_node_entry(node, next_instance_index)
		next_entries[node.get_instance_id()] = entry
		if entry.point_count <= 0:
			continue

		var gaussian: Resource = node.get("gaussian")
		var resource_start_index: int
		
		# Only upload the splat data if we haven't seen this resource yet
		if not unique_resources.has(gaussian):
			resource_start_index = merged_point_data.size() / (FLOATS_PER_SPLAT * BYTES_PER_FLOAT)
			unique_resources[gaussian] = resource_start_index
			unique_lighting[gaussian] = entry.has_lighting
			merged_point_data.append_array(entry.point_data_byte)
			merged_lighting.append_array(entry.lighting_byte)
		else:
			# If we already uploaded it, just get the index where it lives in the GPU buffer
			resource_start_index = unique_resources[gaussian]
			if entry.has_lighting and not bool(unique_lighting[gaussian]):
				push_warning(
					"[gdgs] compute: instanced nodes share a GaussianResource but only some "
					+ "carry a lighting bake; the first node's bake is used for all of them"
				)

		# Build the indirection array for this specific node (2 integers per point)
		var node_instance_ids := PackedInt32Array()
		node_instance_ids.resize(entry.point_count * 2) 
		for i in range(entry.point_count):
			node_instance_ids[i * 2] = next_instance_index          # x: Which transform matrix to use
			node_instance_ids[i * 2 + 1] = resource_start_index + i # y: Which raw splat data to read

		merged_instance_ids.append_array(node_instance_ids)
		merged_instance_transforms.append_array(_transform_to_column_major_packed_floats(entry.model_transform, entry.visible))

		total_point_count += entry.point_count
		next_instance_index += 1
	
	_node_entries = next_entries

	var merged_instance_ids_byte := merged_instance_ids.to_byte_array()
	var merged_instance_transforms_byte := merged_instance_transforms.to_byte_array()
	if total_point_count <= 0 or merged_point_data.is_empty():
		_point_count = 0
		_point_data_byte = PackedByteArray()
		_splat_lighting_byte = PackedByteArray()
		_splat_instance_ids_byte = PackedByteArray()
		_instance_count = 0
		_instance_transforms_byte = PackedByteArray()
		_instance_relight_byte = PackedByteArray()
		return _change_result(true, false, false, false)

	var count_changed := total_point_count != _point_count
	var point_data_size_changed := merged_point_data.size() != _point_data_byte.size()
	var instance_ids_size_changed := merged_instance_ids_byte.size() != _splat_instance_ids_byte.size()
	var instance_count_changed := next_instance_index != _instance_count
	var instance_transforms_size_changed := merged_instance_transforms_byte.size() != _instance_transforms_byte.size()

	_point_count = total_point_count
	_point_data_byte = merged_point_data
	_splat_lighting_byte = merged_lighting
	_splat_instance_ids_byte = merged_instance_ids_byte
	_instance_count = next_instance_index
	_instance_transforms_byte = merged_instance_transforms_byte
	_instance_relight_byte = _build_instance_relight_byte()

	return _change_result(
		false,
		force_rebuild or count_changed or point_data_size_changed or instance_ids_size_changed or instance_count_changed or instance_transforms_size_changed,
		true,
		true
	)

func _sync_node_transform(node: Node) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {}

	var entry: NodeEntry = _node_entries.get(node.get_instance_id(), null)
	if entry == null:
		return _sync_scene_resources(false)

	var model_transform := _get_node_transform(node)
	var model_visible := _get_node_visibility(node)
	if entry.model_transform == model_transform and entry.visible == model_visible:
		return {}

	entry.model_transform = model_transform
	entry.visible = model_visible
	if entry.instance_index < 0 or _instance_count <= 0:
		return {}

	var instance_transforms_byte := _build_instance_transforms_byte()
	var size_changed := instance_transforms_byte.size() != _instance_transforms_byte.size()
	_instance_transforms_byte = instance_transforms_byte

	return _change_result(false, size_changed, false, true)

func _build_node_entry(node: Node, instance_index: int) -> NodeEntry:
	var entry := NodeEntry.new()
	entry.model_transform = _get_node_transform(node)
	entry.visible = _get_node_visibility(node)

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
	entry.lighting_byte = _build_lighting_byte(node, point_count)
	entry.has_lighting = entry.lighting_byte.size() == point_count * LIGHTING_BYTES_PER_SPLAT and _node_has_bake(node)
	return entry

## The node's baked per-splat records, or a zero-filled block of the right size
## when there is no usable bake. The buffer must stay parallel to the splat
## data either way; the per-instance `enabled` flag is what actually gates
## relighting, so zeros are never read.
func _build_lighting_byte(node: Node, point_count: int) -> PackedByteArray:
	var expected := point_count * LIGHTING_BYTES_PER_SPLAT
	var lighting: Variant = node.get("lighting")
	if lighting != null and is_instance_valid(lighting) and lighting is Resource:
		var resource := lighting as Resource
		if resource.has_method("is_splat_data_valid") and bool(resource.call("is_splat_data_valid")):
			if int(resource.get("source_point_count")) == point_count:
				var data: PackedByteArray = resource.get("splat_data")
				if data.size() == expected:
					return data
			else:
				push_warning(
					"[gdgs] compute: lighting bake is for %d splats but the resource has %d; rebake it"
					% [int(resource.get("source_point_count")), point_count]
				)
	var empty := PackedByteArray()
	empty.resize(expected)
	return empty

func _node_has_bake(node: Node) -> bool:
	var lighting: Variant = node.get("lighting")
	if lighting == null or not is_instance_valid(lighting) or not (lighting is Resource):
		return false
	var resource := lighting as Resource
	return resource.has_method("is_splat_data_valid") and bool(resource.call("is_splat_data_valid"))

## Two vec4 per instance, in instance order:
##   [0] unlit level, light gain, DC-only flag, enabled flag
##   [1] ambient rgb, unused
func _build_instance_relight_byte() -> PackedByteArray:
	if _instance_count <= 0:
		return PackedByteArray()
	var packed := PackedFloat32Array()
	for node in _splat_nodes:
		if not is_instance_valid(node):
			continue
		var entry: NodeEntry = _node_entries.get(node.get_instance_id(), null)
		if entry == null or entry.point_count <= 0 or entry.instance_index < 0:
			continue
		var enabled := entry.has_lighting and bool(node.get("relight_enabled"))
		var ambient: Color = node.get("relight_ambient")
		packed.append_array(PackedFloat32Array([
			float(node.get("relight_unlit_level")),
			float(node.get("relight_light_gain")),
			1.0 if bool(node.get("relight_dc_only")) else 0.0,
			1.0 if enabled else 0.0,
			ambient.r, ambient.g, ambient.b, 0.0,
		]))
	return packed.to_byte_array()

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
		transforms.append_array(_transform_to_column_major_packed_floats(entry.model_transform, entry.visible))
	return transforms.to_byte_array()

func _get_node_transform(node: Node) -> Transform3D:
	if node is Node3D:
		return (node as Node3D).global_transform
	return Transform3D.IDENTITY
	
func _get_node_visibility(node: Node) -> bool:
	if node is Node3D:
		return (node as Node3D).is_visible_in_tree()
	return true

func _transform_to_column_major_packed_floats(transform: Transform3D, visibility: bool) -> PackedFloat32Array:
	return PackedFloat32Array([
		transform.basis.x[0], transform.basis.x[1], transform.basis.x[2], 1.0 if visibility else 0.0,
		transform.basis.y[0], transform.basis.y[1], transform.basis.y[2], 0.0,
		transform.basis.z[0], transform.basis.z[1], transform.basis.z[2], 0.0,
		transform.origin.x, transform.origin.y, transform.origin.z, 1.0
	])

func _prune_splat_nodes() -> void:
	for i in range(_splat_nodes.size() - 1, -1, -1):
		if not is_instance_valid(_splat_nodes[i]):
			_splat_nodes.remove_at(i)

func _change_result(
	request_cleanup: bool,
	require_gpu_rebuild: bool,
	require_splat_upload: bool,
	require_instance_upload: bool
) -> Dictionary:
	return {
		"request_cleanup": request_cleanup,
		"require_gpu_rebuild": require_gpu_rebuild,
		"require_splat_upload": require_splat_upload,
		"require_instance_upload": require_instance_upload
	}

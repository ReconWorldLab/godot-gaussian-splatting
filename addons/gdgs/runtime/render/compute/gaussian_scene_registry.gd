@tool
extends RefCounted
class_name GaussianSceneRegistry

const FLOATS_PER_SPLAT := 60
const BYTES_PER_FLOAT := 4

class NodeEntry:
	extends RefCounted

	var point_count := 0
	var instance_index := -1
	var point_data_byte := PackedByteArray()
	var model_transform: Transform3D = Transform3D.IDENTITY
	var visible: bool = true

var _splat_nodes: Array[Node] = []
var _node_entries: Dictionary = {}

var _point_count := 0
var _point_data_byte := PackedByteArray()
var _splat_instance_ids_byte := PackedByteArray()
var _instance_count := 0
var _instance_transforms_byte := PackedByteArray()

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

func _sync_scene_resources(force_rebuild: bool) -> Dictionary:
	_prune_splat_nodes()

	var next_entries: Dictionary = {}
	var merged_point_data := PackedByteArray()
	var merged_instance_ids := PackedInt32Array()
	var merged_instance_transforms := PackedFloat32Array()
	var total_point_count := 0
	var next_instance_index := 0
	
	# Keep track of which resources we've already packed into the raw VRAM buffer
	var unique_resources := {}

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
			merged_point_data.append_array(entry.point_data_byte)
		else:
			# If we already uploaded it, just get the index where it lives in the GPU buffer
			resource_start_index = unique_resources[gaussian]

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
		_splat_instance_ids_byte = PackedByteArray()
		_instance_count = 0
		_instance_transforms_byte = PackedByteArray()
		return _change_result(true, false, false, false)

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
	return entry

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

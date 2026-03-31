@tool
@icon("res://addons/gdgs/editor/icons/gaussian_splat_node.svg")
extends VisualInstance3D
class_name GaussianSplatNode

const MANAGER_SCRIPT := preload("res://addons/gdgs/runtime/render/gaussian_render_manager.gd")
const MANAGER_NODE_NAME := "_GdgsGaussianRenderManager"
const MANAGER_PENDING_META := "_gdgs_manager_pending"

@export var gaussian: GaussianResource:
	set(value):
		_set_gaussian(value)
	get:
		return _gaussian

var _gaussian: GaussianResource
var _local_aabb: AABB = AABB()
var _aabb_valid := false

static func get_model_orientation_correction() -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0.0, 0.0, -PI)), Vector3.ZERO)

func _enter_tree() -> void:
	_apply_default_orientation_if_needed()
	set_notify_transform(true)
	call_deferred("_register_with_manager")

func _ready() -> void:
	_connect_gaussian()
	if not _aabb_valid:
		_rebuild_aabb()

func _exit_tree() -> void:
	_unregister_from_manager()
	_disconnect_gaussian()

func _get_aabb() -> AABB:
	if _aabb_valid:
		return _local_aabb
	return AABB()

func _set_gaussian(value: GaussianResource) -> void:
	if _gaussian == value:
		return
	_disconnect_gaussian()
	_gaussian = value
	_connect_gaussian()
	_rebuild_aabb()
	if is_inside_tree():
		_mark_manager_dirty()
	if Engine.is_editor_hint():
		update_gizmos()

func _connect_gaussian() -> void:
	if _gaussian == null:
		return
	var callable := Callable(self, "_on_gaussian_changed")
	if not _gaussian.changed.is_connected(callable):
		_gaussian.changed.connect(callable)

func _disconnect_gaussian() -> void:
	if _gaussian == null:
		return
	var callable := Callable(self, "_on_gaussian_changed")
	if _gaussian.changed.is_connected(callable):
		_gaussian.changed.disconnect(callable)

func _on_gaussian_changed() -> void:
	_rebuild_aabb()
	if is_inside_tree():
		_mark_manager_dirty()
	if Engine.is_editor_hint():
		update_gizmos()

func _rebuild_aabb() -> void:
	_aabb_valid = false
	if _gaussian == null:
		_local_aabb = AABB()
		return
	_local_aabb = _gaussian.aabb
	_aabb_valid = true

func _apply_default_orientation_if_needed() -> void:
	if not transform.basis.orthonormalized().is_equal_approx(Basis.IDENTITY):
		return
	transform = transform * get_model_orientation_correction()

func _register_with_manager() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	var manager := _ensure_manager()
	if manager != null and manager.has_method("register_splat_node"):
		manager.register_splat_node(self)
	elif manager == null:
		call_deferred("_register_with_manager")

func _unregister_from_manager() -> void:
	var manager := _get_manager()
	if manager != null and manager.has_method("unregister_splat_node"):
		manager.unregister_splat_node(self)

func _mark_manager_dirty() -> void:
	var manager := _get_manager()
	if manager != null and manager.has_method("mark_resource_dirty"):
		manager.mark_resource_dirty(self)

func _mark_manager_transform_dirty() -> void:
	var manager := _get_manager()
	if manager != null and manager.has_method("mark_transform_dirty"):
		manager.mark_transform_dirty(self)

func _ensure_manager() -> Node:
	if not is_inside_tree():
		return null
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return null

	var root: Node = tree.root
	var manager := root.get_node_or_null(MANAGER_NODE_NAME)
	if manager != null:
		return manager

	if root.has_meta(MANAGER_PENDING_META):
		return null

	root.set_meta(MANAGER_PENDING_META, true)
	manager = MANAGER_SCRIPT.new()
	manager.name = MANAGER_NODE_NAME
	root.call_deferred("add_child", manager)
	root.call_deferred("remove_meta", MANAGER_PENDING_META)
	return null

func _get_manager() -> Node:
	if not is_inside_tree():
		return null
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(MANAGER_NODE_NAME)

func _notification(what: int) -> void:
	if (what == NOTIFICATION_TRANSFORM_CHANGED 
		or what == NOTIFICATION_VISIBILITY_CHANGED) and is_inside_tree():
		_mark_manager_transform_dirty()

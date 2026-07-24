@tool
@icon("res://addons/gdgs/editor/icons/gaussian_splat_node.svg")
extends VisualInstance3D
class_name GaussianSplatNode

const SELECTOR_SCRIPT := preload("res://addons/gdgs/runtime/render/backend/gaussian_backend_selector.gd")

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
	call_deferred("_register_with_backend")

func _ready() -> void:
	_connect_gaussian()
	if not _aabb_valid:
		_rebuild_aabb()

func _exit_tree() -> void:
	_unregister_from_backend()
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
		_mark_backend_resource_dirty()
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
		_mark_backend_resource_dirty()
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

# The node never talks to a concrete backend: the selector resolves the active
# one (Compute or Raster) once per session and every node shares that instance.
func _register_with_backend() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	var backend := SELECTOR_SCRIPT.get_backend(self)
	if backend != null:
		backend.attach_node(self)

func _unregister_from_backend() -> void:
	var backend := SELECTOR_SCRIPT.get_backend(self)
	if backend != null:
		backend.detach_node(self)

func _mark_backend_resource_dirty() -> void:
	var backend := SELECTOR_SCRIPT.get_backend(self)
	if backend != null:
		backend.notify_resource_changed(self)

func _mark_backend_transform_dirty() -> void:
	var backend := SELECTOR_SCRIPT.get_backend(self)
	if backend != null:
		backend.notify_transform_changed(self)

func _notification(what: int) -> void:
	if (what == NOTIFICATION_TRANSFORM_CHANGED
		or what == NOTIFICATION_VISIBILITY_CHANGED) and is_inside_tree():
		_mark_backend_transform_dirty()

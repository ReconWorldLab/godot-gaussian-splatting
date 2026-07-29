@tool
@icon("res://addons/gdgs/editor/icons/gaussian_splat_node.svg")
extends VisualInstance3D
class_name GaussianSplatNode

const SELECTOR_SCRIPT := preload("res://addons/gdgs/runtime/render/backend/gaussian_backend_selector.gd")
# Guarded load, not preload: runtime/lighting/ is deletable, and losing it must
# only cost the shadow caster. GaussianLightingResource itself lives in
# runtime/resources/ (the data-contract layer) precisely so the export below
# keeps parsing when runtime/lighting/ is gone.
const PROXY_SHADOW_CASTER_PATH := "res://addons/gdgs/runtime/lighting/proxy_shadow_caster.gd"

@export var gaussian: GaussianResource:
	set(value):
		_set_gaussian(value)
	get:
		return _gaussian

@export_group("Relighting")
## Baked lighting proxy: per-splat surface normals plus the proxy mesh used as
## a shadow caster. Bake it from the GDGS Lighting inspector panel.
@export var lighting: GaussianLightingResource:
	set(value):
		_set_lighting(value)
	get:
		return _lighting

## Mounts the baked proxy mesh as a SHADOWS_ONLY MeshInstance3D so this
## Gaussian scene casts shadows onto ordinary Godot geometry.
@export var relight_cast_shadows: bool = true:
	set(value):
		_set_relight_cast_shadows(value)
	get:
		return _relight_cast_shadows

## Light the splats from the scene's Light3D nodes using the baked proxy
## normals. Needs a `lighting` resource; ignored without one.
@export var relight_enabled: bool = false
## Colour floor where no light reaches. This is the "darken everything, let
## only lit regions climb back" control: 1.0 leaves the splats at their
## original brightness and only adds light on top.
@export_range(0.0, 1.0, 0.01) var relight_unlit_level: float = 0.25
## How strongly gathered light brightens the splats.
@export_range(0.0, 4.0, 0.01) var relight_light_gain: float = 1.0
## Ambient term, modulated by the baked ambient occlusion.
@export var relight_ambient: Color = Color(0.25, 0.25, 0.25, 1.0)
## Use only the spherical-harmonics DC term as the base colour. Baked
## view-dependent specular fights new lighting; this is the closest thing the
## data has to an albedo.
@export var relight_dc_only: bool = false

var _gaussian: GaussianResource
var _lighting: GaussianLightingResource
var _relight_cast_shadows := true
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
	_sync_lighting_proxy()

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

func _set_lighting(value: GaussianLightingResource) -> void:
	if _lighting == value:
		return
	_lighting = value
	_sync_lighting_proxy()
	# Backends that cache the bake (Compute uploads it into a storage buffer at
	# registration time) will otherwise keep rendering the state this node had
	# when it entered the tree — which is `null` for the common order of adding
	# the node first and assigning the resource afterwards.
	_mark_backend_lighting_dirty()

func _set_relight_cast_shadows(value: bool) -> void:
	if _relight_cast_shadows == value:
		return
	_relight_cast_shadows = value
	_sync_lighting_proxy()

# Mounting the proxy is the one piece of relighting that is free: a
# SHADOWS_ONLY MeshInstance3D is invisible to the camera but still writes into
# every light's shadow map, so the splat scene shadows ordinary geometry under
# both backends. Lighting the splats themselves is the light rig's job.
func _sync_lighting_proxy() -> void:
	if not is_inside_tree():
		return
	var caster_script := _load_proxy_shadow_caster()
	if caster_script == null:
		return
	caster_script.sync(self, _lighting, _relight_cast_shadows)

func _load_proxy_shadow_caster() -> GDScript:
	if not ResourceLoader.exists(PROXY_SHADOW_CASTER_PATH, "Script"):
		return null
	var script: Variant = load(PROXY_SHADOW_CASTER_PATH)
	if script == null or not (script is GDScript):
		return null
	return script as GDScript

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

func _mark_backend_lighting_dirty() -> void:
	if not is_inside_tree():
		return
	var backend := SELECTOR_SCRIPT.get_backend(self)
	if backend != null and backend.has_method("notify_lighting_changed"):
		backend.notify_lighting_changed(self)

func _notification(what: int) -> void:
	if (what == NOTIFICATION_TRANSFORM_CHANGED
		or what == NOTIFICATION_VISIBILITY_CHANGED) and is_inside_tree():
		_mark_backend_transform_dirty()

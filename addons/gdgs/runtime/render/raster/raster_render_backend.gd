@tool
extends "res://addons/gdgs/runtime/render/backend/gaussian_render_backend.gd"

## Raster ("sticker") backend — Phase 3 (sorted).
##
## Each GaussianSplatNode gets one MultiMeshInstance3D added as an internal child,
## so it inherits the node's global transform and visibility through the scene
## graph (MODEL_MATRIX in the shader == node global transform, matching Compute).
## The instance renders through the normal transparent pass with the hardware
## depth test; there is no CompositorEffect.
##
## A single driver node at the scene root ticks every frame: it polls each node's
## background sort (WorkerThreadPool, double-buffered) and re-kicks it when the
## camera direction relative to that node changes. Rendering always uses the last
## completed order, so the sort may lag the camera a frame or two (mild popping)
## without ever stalling the frame.
##
## Fully self-contained under render/raster/: it never imports Compute code. Its
## only shared dependency is the read-only GaussianResource and the interface.

const RASTER_SHADER := preload("res://addons/gdgs/runtime/render/raster/materials/gaussian_raster.gdshader")
const DataTextures := preload("res://addons/gdgs/runtime/render/raster/raster_data_textures.gd")
const SplatMesh := preload("res://addons/gdgs/runtime/render/raster/raster_splat_mesh.gd")
const SortJob := preload("res://addons/gdgs/runtime/render/raster/raster_sort_job.gd")
const SortDriver := preload("res://addons/gdgs/runtime/render/raster/raster_sort_driver.gd")

const SPLATS_PER_INSTANCE := 128
const DRIVER_NODE_NAME := "_GdgsRasterDriver"
# Re-sort when the local view direction rotates past ~1 degree (cos threshold).
const RESORT_DOT_THRESHOLD := 0.99985
# Guarded load, not preload: runtime/lighting/ is deletable and losing it must
# only cost relighting, leaving splats rendering unlit.
const LIGHT_RIG_PATH := "res://addons/gdgs/runtime/lighting/gaussian_light_rig.gd"

class Entry:
	extends RefCounted
	var mmi: MultiMeshInstance3D = null
	var material: ShaderMaterial = null
	var core_texture: Texture2D = null
	var sh_texture: Texture2D = null
	var point_count := 0
	var job: RefCounted = null
	var order_image: Image = null
	var order_texture: ImageTexture = null
	var order_dims := Vector2i(1, 1)
	var order_live := false
	var last_dir_local := Vector3.ZERO
	var has_kicked := false
	# Relighting: the baked resource the lighting texture was built from, the
	# knob values already pushed to the material, and the rig version already
	# uploaded. All compared per frame so nothing re-uploads while nothing moves.
	var lighting_resource: Resource = null
	var lighting_texture: Texture2D = null
	var lighting_checked := false
	var applied_knobs: Array = []
	var applied_rig_version := -1

var _base_mesh: ArrayMesh = null
var _driver: Node = null
var _entries: Dictionary = {}   # node instance id -> Entry
var _light_rig: RefCounted = null
var _light_rig_checked := false

func get_display_name() -> String:
	return "Raster"

func initialize(_tree: SceneTree) -> Dictionary:
	# Raster draws through the standard mesh pipeline, so it works on Forward+,
	# Mobile and Compatibility alike. Nothing to probe here; the data-texture
	# build reports its own failures per node.
	return {"ok": true}

func attach_node(node: Node) -> void:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return
	_ensure_driver(node)
	var key := node.get_instance_id()
	if _entries.has(key):
		_rebuild_entry(node)
		return
	var entry := Entry.new()
	_entries[key] = entry
	_populate_entry(entry, node)

func detach_node(node: Node) -> void:
	if node == null:
		return
	var key := node.get_instance_id()
	var entry: Entry = _entries.get(key, null)
	if entry == null:
		return
	_free_entry(entry)
	_entries.erase(key)

func notify_resource_changed(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	_rebuild_entry(node)

func notify_transform_changed(_node: Node) -> void:
	# The MultiMeshInstance3D is an internal child of the node, so transform and
	# visibility follow automatically. The driver picks up the new orientation on
	# its next tick and re-kicks the sort if it moved enough.
	pass

func shutdown() -> void:
	for entry in _entries.values():
		_free_entry(entry)
	_entries.clear()
	if _driver != null and is_instance_valid(_driver):
		_driver.queue_free()
	_driver = null
	_base_mesh = null

## Called every frame by the driver node: polls sorts and refreshes relighting.
func drive_sorts() -> void:
	var rig := _resolve_light_rig()
	var rig_changed := false
	if rig != null:
		rig_changed = rig.update(_any_attached_node())
	for entry in _entries.values():
		_drive_entry(entry)
		_drive_lighting(entry, rig, rig_changed)

## Relighting state is pulled from the node every frame rather than pushed
## through a new backend-interface event: the knobs are a handful of Variant
## reads, and polling picks up inspector edits, script writes and animation
## alike without widening the interface Compute also has to implement.
func _drive_lighting(entry: Entry, rig: RefCounted, rig_changed: bool) -> void:
	if entry.material == null or entry.mmi == null or not is_instance_valid(entry.mmi):
		return
	var node := entry.mmi.get_parent()
	if node == null or not is_instance_valid(node):
		return

	var lighting: Variant = node.get("lighting")
	var resource: Resource = lighting if lighting is Resource else null
	if resource != entry.lighting_resource or not entry.lighting_checked:
		_rebuild_lighting_texture(entry, resource)

	var enabled := bool(node.get("relight_enabled")) and entry.lighting_texture != null
	var knobs: Array = [
		enabled,
		float(node.get("relight_unlit_level")),
		float(node.get("relight_light_gain")),
		node.get("relight_ambient"),
		bool(node.get("relight_dc_only")),
	]
	if knobs != entry.applied_knobs:
		entry.applied_knobs = knobs
		entry.material.set_shader_parameter("relight_enabled", knobs[0])
		entry.material.set_shader_parameter("relight_unlit_level", knobs[1])
		entry.material.set_shader_parameter("relight_light_gain", knobs[2])
		entry.material.set_shader_parameter("relight_ambient", knobs[3])
		entry.material.set_shader_parameter("relight_dc_only", knobs[4])

	if rig != null and enabled and (rig_changed or entry.applied_rig_version != rig.version):
		entry.applied_rig_version = rig.version
		rig.apply(entry.material)

## Builds (or drops) the per-splat lighting texture for the node's currently
## assigned bake. A resource whose splat count disagrees with the Gaussian is a
## stale bake and is refused rather than rendered with mismatched records.
func _rebuild_lighting_texture(entry: Entry, resource: Resource) -> void:
	entry.lighting_resource = resource
	entry.lighting_checked = true
	entry.lighting_texture = null
	entry.applied_knobs = []
	entry.applied_rig_version = -1
	entry.material.set_shader_parameter("relight_enabled", false)
	if resource == null or not is_instance_valid(resource):
		return
	if not resource.has_method("is_splat_data_valid") or not bool(resource.call("is_splat_data_valid")):
		push_warning("[gdgs] raster: lighting resource has no usable per-splat data; rendering unlit")
		return
	if int(resource.get("source_point_count")) != entry.point_count:
		push_warning(
			"[gdgs] raster: lighting bake is for %d splats but the resource has %d; rebake it"
			% [int(resource.get("source_point_count")), entry.point_count]
		)
		return
	var built: Dictionary = DataTextures.build_lighting(
		resource.get("splat_data"), entry.point_count
	)
	if not bool(built.get("ok", false)):
		push_warning("[gdgs] raster: lighting texture build failed: %s" % str(built.get("reason", "")))
		return
	entry.lighting_texture = built["lighting_texture"]
	entry.material.set_shader_parameter("splat_lighting", entry.lighting_texture)
	entry.material.set_shader_parameter("lighting_width", int(built["lighting_width"]))

func _resolve_light_rig() -> RefCounted:
	if _light_rig_checked:
		return _light_rig
	_light_rig_checked = true
	if not ResourceLoader.exists(LIGHT_RIG_PATH, "Script"):
		return null
	var script: Variant = load(LIGHT_RIG_PATH)
	if script == null or not (script is GDScript) or not (script as GDScript).can_instantiate():
		push_warning("[gdgs] raster: light rig failed to load; splats render unlit")
		return null
	var instance: Variant = (script as GDScript).new()
	if instance is RefCounted:
		_light_rig = instance
	return _light_rig

## The rig only needs some node inside the tree to find the scene root from.
func _any_attached_node() -> Node:
	for entry in _entries.values():
		if entry.mmi != null and is_instance_valid(entry.mmi) and entry.mmi.is_inside_tree():
			return entry.mmi
	return null

func _drive_entry(entry: Entry) -> void:
	if entry.job == null or entry.mmi == null or not is_instance_valid(entry.mmi):
		return

	# Collect a finished sort and push it to the GPU.
	if entry.job.poll():
		_upload_order(entry)

	var node := entry.mmi.get_parent()
	if node == null or not (node is Node3D):
		return
	var camera := _find_camera(node)
	if camera == null:
		return

	# View forward expressed in the splat's local space (positions are local).
	var world_forward := -camera.global_transform.basis.z
	var node_basis := (node as Node3D).global_transform.basis
	var dir_local := node_basis.transposed() * world_forward
	if dir_local.length() < 1e-8:
		return
	var dir_n := dir_local.normalized()

	# Camera-static skip: only re-sort when the direction moved past threshold.
	var moved := (not entry.has_kicked) or (entry.last_dir_local.dot(dir_n) < RESORT_DOT_THRESHOLD)
	if moved and not entry.job.is_running():
		if entry.job.kick(dir_local):
			entry.last_dir_local = dir_n
			entry.has_kicked = true

## The worker already packed the R32F texel bytes, so a completed sort costs the
## main thread one Image.set_data plus the texture update — no per-splat work.
func _upload_order(entry: Entry) -> void:
	if entry.order_texture == null or entry.order_image == null:
		return
	var bytes: PackedByteArray = entry.job.front_bytes()
	if bytes.size() != entry.order_dims.x * entry.order_dims.y * DataTextures.ORDER_BYTES_PER_TEXEL:
		return
	entry.order_image.set_data(entry.order_dims.x, entry.order_dims.y, false, Image.FORMAT_RF, bytes)
	entry.order_texture.update(entry.order_image)
	if not entry.order_live:
		# Until the first real order lands the texture is zeroed, so the material
		# renders in resource order instead of reading it.
		entry.order_live = true
		if entry.material != null:
			entry.material.set_shader_parameter("use_order", true)

func _rebuild_entry(node: Node) -> void:
	var key := node.get_instance_id()
	var entry: Entry = _entries.get(key, null)
	if entry == null:
		attach_node(node)
		return
	_free_contents(entry)
	_populate_entry(entry, node)

func _populate_entry(entry: Entry, node: Node) -> void:
	var gaussian: Resource = node.get("gaussian")
	if gaussian == null:
		return
	var count := int(gaussian.get("point_count"))
	if count <= 0:
		return

	var built: Dictionary = DataTextures.build(gaussian)
	if not bool(built.get("ok", false)):
		push_warning("[gdgs] raster: data texture build failed: %s" % str(built.get("reason", "")))
		return

	if _base_mesh == null:
		_base_mesh = SplatMesh.build()

	# Order texture (starts zeroed with use_order off -> renders in resource order
	# until the first background sort lands).
	var order_dims: Vector2i = DataTextures.order_dimensions(count)
	var order_image: Image = DataTextures.make_order_image(order_dims)
	var order_texture: ImageTexture = ImageTexture.create_from_image(order_image)

	var material := ShaderMaterial.new()
	material.shader = RASTER_SHADER
	material.set_shader_parameter("splat_core", built["core_texture"])
	material.set_shader_parameter("core_width", int(built["core_width"]))
	material.set_shader_parameter("splat_sh", built["sh_texture"])
	material.set_shader_parameter("sh_width", int(built["sh_width"]))
	material.set_shader_parameter("point_count", count)
	material.set_shader_parameter("order_data", order_texture)
	material.set_shader_parameter("order_width", order_dims.x)
	material.set_shader_parameter("use_order", false)

	var instances := int(ceil(float(count) / float(SPLATS_PER_INSTANCE)))
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _base_mesh
	multimesh.instance_count = instances
	for i in range(instances):
		multimesh.set_instance_transform(i, Transform3D.IDENTITY)

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "_GdgsRasterSplat"
	mmi.multimesh = multimesh
	mmi.material_override = material
	mmi.extra_cull_margin = 16384.0
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED

	# Internal child: not persisted to the scene, hidden from the editor tree,
	# and inherits the node's transform/visibility.
	node.add_child(mmi, false, Node.INTERNAL_MODE_BACK)
	mmi.transform = Transform3D.IDENTITY

	var job := SortJob.new()
	job.set_positions(gaussian.get("xyz"))
	job.set_texel_count(order_dims.x * order_dims.y)

	entry.mmi = mmi
	entry.material = material
	entry.core_texture = built["core_texture"]
	entry.sh_texture = built["sh_texture"]
	entry.point_count = count
	entry.job = job
	entry.order_image = order_image
	entry.order_texture = order_texture
	entry.order_dims = order_dims
	entry.order_live = false
	entry.last_dir_local = Vector3.ZERO
	entry.has_kicked = false
	# Lighting is resolved on the next driver tick, which also picks up the
	# node's relight knobs.
	entry.lighting_resource = null
	entry.lighting_texture = null
	entry.lighting_checked = false
	entry.applied_knobs = []
	entry.applied_rig_version = -1

## Resolve the camera whose pose drives the sort. In-game this is the node's
## viewport camera. In the editor it MUST be the Node3DEditor viewport's own
## navigation camera: the edited scene's viewport also reports a "current"
## camera whenever the scene contains a Camera3D, but that one is static and
## not what the user is looking through — sorting to it reverses the blend
## order on opposite view angles. EditorInterface is resolved by name so
## exported builds never reference the class. With multiple 3D editor
## viewports open, viewport 0 drives the sort.
static func _find_camera(node: Node) -> Camera3D:
	if Engine.is_editor_hint():
		return _editor_camera()
	var viewport := node.get_viewport()
	if viewport != null:
		return viewport.get_camera_3d()
	return null

static func _editor_camera() -> Camera3D:
	if not Engine.has_singleton("EditorInterface"):
		return null
	var editor_interface := Engine.get_singleton("EditorInterface")
	if editor_interface == null or not editor_interface.has_method("get_editor_viewport_3d"):
		return null
	var editor_viewport: Object = editor_interface.call("get_editor_viewport_3d", 0)
	if editor_viewport == null or not editor_viewport.has_method("get_camera_3d"):
		return null
	return editor_viewport.call("get_camera_3d") as Camera3D

func _ensure_driver(node: Node) -> void:
	if _driver != null and is_instance_valid(_driver):
		return
	var tree := node.get_tree()
	if tree == null or tree.root == null:
		return
	var existing := tree.root.get_node_or_null(DRIVER_NODE_NAME)
	if existing != null:
		_driver = existing
		existing.set("backend", self)
		return
	var driver := SortDriver.new()
	driver.name = DRIVER_NODE_NAME
	driver.set("backend", self)
	_driver = driver
	tree.root.call_deferred("add_child", driver)

func _free_contents(entry: Entry) -> void:
	if entry.job != null:
		entry.job.flush()
	entry.job = null
	if entry.mmi != null and is_instance_valid(entry.mmi):
		entry.mmi.queue_free()
	entry.mmi = null
	entry.material = null
	entry.core_texture = null
	entry.sh_texture = null
	entry.order_image = null
	entry.order_texture = null
	entry.order_live = false
	entry.point_count = 0
	entry.has_kicked = false
	entry.lighting_resource = null
	entry.lighting_texture = null
	entry.lighting_checked = false
	entry.applied_knobs = []
	entry.applied_rig_version = -1

func _free_entry(entry: Entry) -> void:
	_free_contents(entry)

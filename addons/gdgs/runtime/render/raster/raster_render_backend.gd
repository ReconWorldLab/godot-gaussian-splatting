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

class Entry:
	extends RefCounted
	var mmi: MultiMeshInstance3D = null
	var material: ShaderMaterial = null
	var texture: Texture2D = null
	var width := 0
	var point_count := 0
	var job: RefCounted = null
	var order_image: Image = null
	var order_texture: ImageTexture = null
	var order_scratch := PackedFloat32Array()
	var order_dims := Vector2i(1, 1)
	var last_dir_local := Vector3.ZERO
	var has_kicked := false

var _base_mesh: ArrayMesh = null
var _driver: Node = null
var _entries: Dictionary = {}   # node instance id -> Entry

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

## Called every frame by the driver node.
func drive_sorts() -> void:
	for entry in _entries.values():
		_drive_entry(entry)

func _drive_entry(entry: Entry) -> void:
	if entry.job == null or entry.mmi == null or not is_instance_valid(entry.mmi):
		return

	# Collect a finished sort and push it to the GPU.
	if entry.job.poll():
		_upload_order(entry)

	var node := entry.mmi.get_parent()
	if node == null or not (node is Node3D):
		return
	var viewport := node.get_viewport()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
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

func _upload_order(entry: Entry) -> void:
	var order: PackedInt32Array = entry.job.front_order()
	if order.is_empty() or entry.order_texture == null or entry.order_image == null:
		return
	var texels := entry.order_dims.x * entry.order_dims.y
	var bytes := DataTextures.order_to_bytes(order, entry.order_scratch, texels)
	entry.order_image.set_data(entry.order_dims.x, entry.order_dims.y, false, Image.FORMAT_RF, bytes)
	entry.order_texture.update(entry.order_image)

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

	# Order texture (starts as identity -> renders in resource order until the
	# first background sort lands).
	var order_dims: Vector2i = DataTextures.order_dimensions(count)
	var order_image: Image = DataTextures.make_order_image(order_dims)
	var order_texture: ImageTexture = ImageTexture.create_from_image(order_image)

	var material := ShaderMaterial.new()
	material.shader = RASTER_SHADER
	material.set_shader_parameter("splat_data", built["texture"])
	material.set_shader_parameter("splat_data_width", int(built["width"]))
	material.set_shader_parameter("point_count", count)
	material.set_shader_parameter("order_data", order_texture)
	material.set_shader_parameter("order_width", order_dims.x)
	material.set_shader_parameter("use_order", true)

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

	entry.mmi = mmi
	entry.material = material
	entry.texture = built["texture"]
	entry.width = int(built["width"])
	entry.point_count = count
	entry.job = job
	entry.order_image = order_image
	entry.order_texture = order_texture
	entry.order_scratch = PackedFloat32Array()
	entry.order_dims = order_dims
	entry.last_dir_local = Vector3.ZERO
	entry.has_kicked = false

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
	entry.texture = null
	entry.order_image = null
	entry.order_texture = null
	entry.order_scratch = PackedFloat32Array()
	entry.width = 0
	entry.point_count = 0
	entry.has_kicked = false

func _free_entry(entry: Entry) -> void:
	_free_contents(entry)

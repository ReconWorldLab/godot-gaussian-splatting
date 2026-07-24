@tool
extends "res://addons/gdgs/runtime/render/backend/gaussian_render_backend.gd"

## Raster ("sticker") backend — Phase 2 (static, no sort yet).
##
## Each GaussianSplatNode gets one MultiMeshInstance3D added as an internal child,
## so it inherits the node's global transform and visibility through the scene
## graph (MODEL_MATRIX in the shader == node global transform, matching Compute).
## The instance renders through the normal transparent pass with the hardware
## depth test; there is no CompositorEffect and no per-frame tick in this phase.
##
## Fully self-contained under render/raster/: it never imports Compute code. Its
## only shared dependency is the read-only GaussianResource and the backend
## interface. Deleting render/raster/ leaves Compute untouched.

const RASTER_SHADER := preload("res://addons/gdgs/runtime/render/raster/materials/gaussian_raster.gdshader")
const DataTextures := preload("res://addons/gdgs/runtime/render/raster/raster_data_textures.gd")
const SplatMesh := preload("res://addons/gdgs/runtime/render/raster/raster_splat_mesh.gd")

const SPLATS_PER_INSTANCE := 128

class Entry:
	extends RefCounted
	var mmi: MultiMeshInstance3D = null
	var material: ShaderMaterial = null
	var texture: Texture2D = null
	var width := 0
	var point_count := 0

var _base_mesh: ArrayMesh = null
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
	# visibility follow automatically. Phase 3 will use this hook to re-kick the
	# CPU sort when the camera pose changes.
	pass

func shutdown() -> void:
	for entry in _entries.values():
		_free_entry(entry)
	_entries.clear()
	_base_mesh = null

func _rebuild_entry(node: Node) -> void:
	var key := node.get_instance_id()
	var entry: Entry = _entries.get(key, null)
	if entry == null:
		attach_node(node)
		return
	_free_instance(entry)
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

	var material := ShaderMaterial.new()
	material.shader = RASTER_SHADER
	material.set_shader_parameter("splat_data", built["texture"])
	material.set_shader_parameter("splat_data_width", int(built["width"]))
	material.set_shader_parameter("point_count", count)

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

	entry.mmi = mmi
	entry.material = material
	entry.texture = built["texture"]
	entry.width = int(built["width"])
	entry.point_count = count

func _free_instance(entry: Entry) -> void:
	if entry.mmi != null and is_instance_valid(entry.mmi):
		entry.mmi.queue_free()
	entry.mmi = null
	entry.material = null
	entry.texture = null
	entry.width = 0
	entry.point_count = 0

func _free_entry(entry: Entry) -> void:
	_free_instance(entry)

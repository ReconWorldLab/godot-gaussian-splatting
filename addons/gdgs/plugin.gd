@tool
extends EditorPlugin

const MANAGER_NODE_NAME := "_GdgsGaussianRenderManager"
const DIRECT_TEXTURE_OVERLAY_NAME := "_GdgsDirectTextureOverlay"
const COLLISION_FEATURE_PATH := "res://addons/gdgs/collision/collision_feature.gd"

var import_plugin: EditorImportPlugin
var gizmo_plugin: EditorNode3DGizmoPlugin
var collision_inspector_plugin: EditorInspectorPlugin

func _enter_tree() -> void:
	import_plugin = preload("res://addons/gdgs/importers/gaussian_import_plugin.gd").new()
	add_import_plugin(import_plugin)

	gizmo_plugin = preload("res://addons/gdgs/editor/gizmos/gaussian_splat_gizmo_plugin.gd").new()
	add_node_3d_gizmo_plugin(gizmo_plugin)

	print("[gdgs] enable gaussian splatting plugin")

	# Registered last and loaded at runtime: if the optional collision module
	# is missing or fails to parse, rendering above is already up and stays up.
	_enable_collision_feature()

func _exit_tree() -> void:
	_disable_collision_feature()
	if import_plugin != null:
		remove_import_plugin(import_plugin)
	if gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(gizmo_plugin)

	var tree := get_tree()
	if tree != null and tree.root != null:
		var manager := tree.root.get_node_or_null(MANAGER_NODE_NAME)
		if manager != null:
			if manager.has_method("shutdown"):
				manager.shutdown()
			manager.queue_free()

		var direct_texture_overlay := tree.root.get_node_or_null(DIRECT_TEXTURE_OVERLAY_NAME)
		if direct_texture_overlay != null:
			direct_texture_overlay.queue_free()

	print("[gdgs] disable gaussian splatting plugin")

func _enable_collision_feature() -> void:
	if not ResourceLoader.exists(COLLISION_FEATURE_PATH, "Script"):
		print("[gdgs] collision feature not present; skipping")
		return
	var feature_script: Variant = load(COLLISION_FEATURE_PATH)
	if feature_script == null or not feature_script is GDScript:
		push_warning("[gdgs] collision feature failed to load; splat rendering is unaffected")
		return
	# load() returns a script object even when compilation failed anywhere in
	# the module, so ask the feature to walk its own dependency chain first:
	# on a healthy module self_test() returns true, on a broken one the call
	# errors out and yields null.
	var gdscript := feature_script as GDScript
	if not gdscript.can_instantiate():
		push_warning("[gdgs] collision feature failed to compile; splat rendering is unaffected")
		return
	var healthy: Variant = gdscript.call(&"self_test")
	if not (healthy is bool and healthy == true):
		push_warning("[gdgs] collision feature failed its self-test; splat rendering is unaffected")
		return
	var inspector: Variant = gdscript.call(&"create_inspector_plugin", get_undo_redo(), get_editor_interface())
	if not inspector is EditorInspectorPlugin:
		push_warning("[gdgs] collision feature returned no inspector plugin; splat rendering is unaffected")
		return
	collision_inspector_plugin = inspector
	add_inspector_plugin(collision_inspector_plugin)
	print("[gdgs] collision feature enabled")

func _disable_collision_feature() -> void:
	if collision_inspector_plugin == null:
		return
	if collision_inspector_plugin.has_method("shutdown"):
		collision_inspector_plugin.call(&"shutdown")
	remove_inspector_plugin(collision_inspector_plugin)
	collision_inspector_plugin = null

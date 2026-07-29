@tool
extends EditorPlugin

const MANAGER_NODE_NAME := "_GdgsGaussianRenderManager"
const DIRECT_TEXTURE_OVERLAY_NAME := "_GdgsDirectTextureOverlay"
const COLLISION_FEATURE_PATH := "res://addons/gdgs/collision/collision_feature.gd"
const LIGHTING_FEATURE_PATH := "res://addons/gdgs/lighting/lighting_feature.gd"
const RENDER_BACKEND_SETTING := "gdgs/rendering/backend"

var import_plugin: EditorImportPlugin
var gizmo_plugin: EditorNode3DGizmoPlugin
var collision_inspector_plugin: EditorInspectorPlugin
var lighting_inspector_plugin: EditorInspectorPlugin

func _enter_tree() -> void:
	_register_project_settings()

	import_plugin = preload("res://addons/gdgs/importers/gaussian_import_plugin.gd").new()
	add_import_plugin(import_plugin)

	gizmo_plugin = preload("res://addons/gdgs/editor/gizmos/gaussian_splat_gizmo_plugin.gd").new()
	add_node_3d_gizmo_plugin(gizmo_plugin)

	print("[gdgs] enable gaussian splatting plugin")

	# Registered last and loaded at runtime: if an optional editor module is
	# missing or fails to parse, rendering above is already up and stays up.
	# Lighting comes after collision because its bake depends on it.
	_enable_collision_feature()
	_enable_lighting_feature()

func _exit_tree() -> void:
	_disable_lighting_feature()
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

# Exposes the startup-only backend choice in Project Settings as a dropdown.
# Registered with an initial value of "Auto" so the entry stays out of
# project.godot until the user explicitly picks another backend. The runtime
# selector reads the same key with an "Auto" default, so this editor-only
# registration is purely for the UI and never required for rendering.
func _register_project_settings() -> void:
	if not ProjectSettings.has_setting(RENDER_BACKEND_SETTING):
		ProjectSettings.set_setting(RENDER_BACKEND_SETTING, "Auto")
	ProjectSettings.add_property_info({
		"name": RENDER_BACKEND_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Auto,Compute,Raster",
	})
	ProjectSettings.set_initial_value(RENDER_BACKEND_SETTING, "Auto")
	ProjectSettings.set_as_basic(RENDER_BACKEND_SETTING, true)

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

# Same guarded pattern as collision: the lighting bake module is editor-only
# and optional. Its self-test also reports when the collision module it depends
# on is missing, and either way already-baked lighting resources keep
# rendering — nothing under runtime/ imports this module.
func _enable_lighting_feature() -> void:
	if not ResourceLoader.exists(LIGHTING_FEATURE_PATH, "Script"):
		print("[gdgs] lighting feature not present; skipping")
		return
	var feature_script: Variant = load(LIGHTING_FEATURE_PATH)
	if feature_script == null or not feature_script is GDScript:
		push_warning("[gdgs] lighting feature failed to load; splat rendering is unaffected")
		return
	var gdscript := feature_script as GDScript
	if not gdscript.can_instantiate():
		push_warning("[gdgs] lighting feature failed to compile; splat rendering is unaffected")
		return
	var healthy: Variant = gdscript.call(&"self_test")
	if not (healthy is bool and healthy == true):
		# self_test() pushes its own, more specific warning.
		return
	var inspector: Variant = gdscript.call(&"create_inspector_plugin", get_undo_redo(), get_editor_interface())
	if not inspector is EditorInspectorPlugin:
		push_warning("[gdgs] lighting feature returned no inspector plugin; splat rendering is unaffected")
		return
	lighting_inspector_plugin = inspector
	add_inspector_plugin(lighting_inspector_plugin)
	print("[gdgs] lighting feature enabled")

func _disable_lighting_feature() -> void:
	if lighting_inspector_plugin == null:
		return
	if lighting_inspector_plugin.has_method("shutdown"):
		lighting_inspector_plugin.call(&"shutdown")
	remove_inspector_plugin(lighting_inspector_plugin)
	lighting_inspector_plugin = null

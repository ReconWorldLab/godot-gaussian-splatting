@tool
extends RefCounted

# Fault boundary for the optional lighting-bake feature, mirroring
# collision_feature.gd. The GDGS plugin load()s this script instead of
# preloading it, so a parse error anywhere under lighting/ leaves rendering,
# import, gizmos and collision untouched.
#
# Unlike collision_feature.gd this file uses load() rather than a preload
# chain: the bake needs the collision module's voxelizer and mesher, and a
# preload chain through a missing collision/ would fail to compile here and
# report only a generic "self-test failed". Checking the dependency first
# turns that into an actionable message.

const COLLISION_PIPELINE_PATH := "res://addons/gdgs/collision/pipeline/collision_pipeline.gd"
const INSPECTOR_PLUGIN_PATH := "res://addons/gdgs/lighting/editor/lighting_inspector_plugin.gd"


static func create_inspector_plugin(
	undo_redo: EditorUndoRedoManager,
	editor_interface: EditorInterface
) -> EditorInspectorPlugin:
	var script := _load_inspector_script()
	if script == null:
		return null
	return script.new(undo_redo, editor_interface)


## Called by the GDGS plugin before registration.
static func self_test() -> bool:
	if not ResourceLoader.exists(COLLISION_PIPELINE_PATH, "Script"):
		push_warning(
			"[gdgs] lighting: baking a proxy needs addons/gdgs/collision (voxelizer + smooth mesher); "
			+ "the bake UI stays disabled. Already-baked lighting resources still render."
		)
		return false
	var script := _load_inspector_script()
	if script == null:
		return false
	# Walking a constant into the builder errors out (yielding null to the
	# caller) when any script in the bake chain failed to compile.
	var probe: Variant = script.PANEL_SCRIPT
	if probe == null:
		return false
	var defaults: Variant = script.BAKE_JOB_SCRIPT.BUILDER_SCRIPT.default_settings()
	return defaults is Dictionary and defaults.has("ao_radius")


static func _load_inspector_script() -> GDScript:
	if not ResourceLoader.exists(INSPECTOR_PLUGIN_PATH, "Script"):
		return null
	var script: Variant = load(INSPECTOR_PLUGIN_PATH)
	if script == null or not (script is GDScript):
		return null
	var gdscript := script as GDScript
	if not gdscript.can_instantiate():
		push_warning("[gdgs] lighting: the bake module failed to compile; rendering is unaffected")
		return null
	return gdscript

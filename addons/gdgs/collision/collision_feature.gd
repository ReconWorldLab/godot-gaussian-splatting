@tool
extends RefCounted

# Fault boundary for the optional collision feature. The GDGS plugin loads
# this script at runtime with load() instead of preload(), so a parse error
# or missing file anywhere under collision/ makes load() return null there
# and rendering/import/gizmo registration proceed untouched.
const INSPECTOR_PLUGIN_SCRIPT := preload("res://addons/gdgs/collision/editor/inspector_plugin.gd")


static func create_inspector_plugin(
	undo_redo: EditorUndoRedoManager,
	editor_interface: EditorInterface
) -> EditorInspectorPlugin:
	return INSPECTOR_PLUGIN_SCRIPT.new(undo_redo, editor_interface)


# Called by the GDGS plugin before registration. Walking a constant chain into
# the pipeline errors out (returning null to the caller) when any script in
# the module failed to compile, because broken scripts expose no constants.
static func self_test() -> bool:
	var probe: Variant = INSPECTOR_PLUGIN_SCRIPT.PIPELINE_SCRIPT.normalize_settings({})
	return probe is Dictionary and bool(probe.get("ok", false))

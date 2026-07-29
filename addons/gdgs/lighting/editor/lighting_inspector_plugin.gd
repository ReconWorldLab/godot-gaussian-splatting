@tool
extends EditorInspectorPlugin

# Orchestrates the lighting-proxy bake behind lighting_panel.gd: snapshot the
# GaussianResource on the main thread, run proxy_builder on WorkerThreadPool
# behind a cancellable progress dialog, then save the result to a .res the
# user picks and assign it in a single undo/redo action.
#
# The save-then-assign order is not cosmetic: assigning an unsaved Resource
# would embed the whole bake (proxy mesh + 4 bytes per splat) into the user's
# .tscn. Cancelling the save dialog therefore cancels the assignment too.
#
# The progress dialog is the collision module's — this module already requires
# collision/ for the voxelizer and mesher, so reusing its dialog is one more
# dependency on a module we cannot work without, not a new one.

const PIPELINE_SCRIPT := preload("res://addons/gdgs/collision/pipeline/collision_pipeline.gd")
const PROGRESS_DIALOG_SCRIPT := preload("res://addons/gdgs/collision/editor/progress_dialog.gd")
const BAKE_JOB_SCRIPT := preload("res://addons/gdgs/lighting/bake/bake_job.gd")
const PANEL_SCRIPT := preload("res://addons/gdgs/lighting/editor/lighting_panel.gd")
const METADATA_SCRIPT := preload("res://addons/gdgs/lighting/editor/lighting_metadata.gd")
const LIGHTING_RESOURCE_SCRIPT := preload("res://addons/gdgs/runtime/resources/gaussian_lighting_resource.gd")

const LIGHTING_PROPERTY := &"lighting"

var _undo_redo: EditorUndoRedoManager
var _editor_interface: EditorInterface
var _active_dialogs: Array = []
var _save_dialogs: Array = []
var _active_target_ids: Dictionary = {}


func _init(undo_redo: EditorUndoRedoManager, editor_interface: EditorInterface) -> void:
	_undo_redo = undo_redo
	_editor_interface = editor_interface


func shutdown() -> void:
	for dialog: Variant in _active_dialogs.duplicate():
		if dialog != null and is_instance_valid(dialog):
			dialog.call(&"cancel_and_wait")
			dialog.queue_free()
	_active_dialogs.clear()
	for dialog: Variant in _save_dialogs.duplicate():
		if dialog != null and is_instance_valid(dialog):
			dialog.queue_free()
	_save_dialogs.clear()
	_active_target_ids.clear()


# Duck-typed exactly like the collision inspector: any Node3D whose script is
# named GaussianSplatNode and which exposes a `lighting` property gets a panel.
func _can_handle(object: Object) -> bool:
	if not object is Node3D:
		return false
	var script: Script = object.get_script()
	if script == null:
		return false
	var is_gaussian_node := script.get_global_name() == &"GaussianSplatNode"
	if not is_gaussian_node:
		is_gaussian_node = script.resource_path.get_file() == "gaussian_splat_node.gd"
	return is_gaussian_node and _has_property(object, LIGHTING_PROPERTY)


func _parse_begin(object: Object) -> void:
	var node := object as Node3D
	var panel: PanelContainer = PANEL_SCRIPT.new(
		METADATA_SCRIPT.settings_from_node(node),
		_summarize_assigned(node)
	)
	panel.bake_pressed.connect(_on_bake_pressed.bind(node, panel))
	add_custom_control(panel)


# --- Bake -------------------------------------------------------------------


func _on_bake_pressed(object: Object, panel: PanelContainer) -> void:
	if object == null or not is_instance_valid(object) or not object is Node3D:
		_show_error("The selected GaussianSplatNode no longer exists.")
		return
	var target_id := object.get_instance_id()
	if _active_target_ids.has(target_id):
		_show_error("A lighting bake is already running for this node.")
		return

	var snapshot_result: Dictionary = PIPELINE_SCRIPT.create_snapshot(object.get("gaussian"))
	if not snapshot_result.get("ok", false):
		var message := "Failed: %s" % snapshot_result.get("error", "Unknown error")
		panel.set_status(message)
		_show_error(message)
		return

	var settings: Dictionary = panel.read_settings()
	var job = BAKE_JOB_SCRIPT.new(snapshot_result["snapshot"], settings)
	var progress_dialog = PROGRESS_DIALOG_SCRIPT.new(job)
	progress_dialog.title = "GDGS Lighting"
	progress_dialog.generation_completed.connect(
		_on_bake_completed.bind(object, settings, panel, progress_dialog, target_id)
	)
	_active_dialogs.append(progress_dialog)
	_active_target_ids[target_id] = true
	panel.set_baking(true)
	panel.set_status("Running on WorkerThreadPool…")
	_editor_interface.get_base_control().add_child(progress_dialog)
	progress_dialog.start()


func _on_bake_completed(
	worker_result: Dictionary,
	object: Object,
	settings: Dictionary,
	panel: PanelContainer,
	progress_dialog: Window,
	target_id: int
) -> void:
	_active_dialogs.erase(progress_dialog)
	_active_target_ids.erase(target_id)
	var panel_alive := panel != null and is_instance_valid(panel)
	if panel_alive:
		panel.set_baking(false)
	if worker_result.get("cancelled", false):
		if panel_alive:
			panel.set_status("Bake cancelled; scene unchanged.")
		return
	if not worker_result.get("ok", false):
		var message := "Failed: %s" % worker_result.get("error", "Unknown error")
		if panel_alive:
			panel.set_status(message)
		_show_error(message)
		return
	if object == null or not is_instance_valid(object) or not object is Node3D:
		_show_error("The bake finished, but the target GaussianSplatNode no longer exists. Scene unchanged.")
		return

	var resource: Resource = _build_resource(object, worker_result, settings)
	if resource == null:
		_show_error("Failed: the bake produced no usable lighting data.")
		return

	var stats: Dictionary = worker_result.get("stats", {})
	_log_stats(stats)
	if panel_alive:
		panel.set_status("Baked: %s · choose where to save it" % _summarize_stats(stats))
	_prompt_save(object, resource, settings, panel, stats)


func _build_resource(object: Object, worker_result: Dictionary, settings: Dictionary) -> Resource:
	var gaussian: Object = object.get("gaussian")
	if gaussian == null:
		return null
	var proxy: Dictionary = worker_result.get("proxy", {})
	var resource: Resource = LIGHTING_RESOURCE_SCRIPT.new()
	resource.format_version = LIGHTING_RESOURCE_SCRIPT.FORMAT_VERSION
	resource.source_point_count = int(gaussian.get("point_count"))
	resource.source_aabb = gaussian.get("aabb")
	resource.voxel_size = float(worker_result.get("voxel_size", 0.0))
	resource.splat_data = worker_result.get("splat_data", PackedByteArray())
	resource.proxy_positions = proxy.get("positions", PackedVector3Array())
	resource.proxy_normals = proxy.get("normals", PackedVector3Array())
	resource.proxy_indices = proxy.get("indices", PackedInt32Array())
	resource.bake_settings = settings.duplicate(true)
	resource.resource_name = "GDGS Lighting Proxy"
	if not resource.is_splat_data_valid():
		return null
	return resource


# --- Save and assign --------------------------------------------------------


func _prompt_save(
	object: Object,
	resource: Resource,
	settings: Dictionary,
	panel: PanelContainer,
	stats: Dictionary
) -> void:
	var dialog := EditorFileDialog.new()
	dialog.title = "Save GDGS Lighting Proxy"
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.res", "Godot binary resource")
	dialog.current_path = _default_save_path(object)
	_save_dialogs.append(dialog)
	_editor_interface.get_base_control().add_child(dialog)
	dialog.file_selected.connect(_on_save_path_selected.bind(object, resource, settings, panel, stats, dialog))
	dialog.canceled.connect(_on_save_cancelled.bind(panel, dialog))
	dialog.popup_centered_ratio(0.7)


func _on_save_path_selected(
	path: String,
	object: Object,
	resource: Resource,
	settings: Dictionary,
	panel: PanelContainer,
	stats: Dictionary,
	dialog: EditorFileDialog
) -> void:
	_close_save_dialog(dialog)
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		var message := "Could not save '%s': %s" % [path, error_string(error)]
		if panel != null and is_instance_valid(panel):
			panel.set_status(message)
		_show_error(message)
		return
	# Rebind the in-memory resource to the file so the node stores a path
	# reference instead of embedding the bake in the scene.
	resource.take_over_path(path)
	var filesystem := _editor_interface.get_resource_filesystem()
	if filesystem != null:
		filesystem.update_file(path)

	if object == null or not is_instance_valid(object) or not object is Node3D:
		_show_error("Saved '%s', but the target GaussianSplatNode no longer exists." % path)
		return
	var node := object as Node3D
	var old_resource: Variant = node.get(LIGHTING_PROPERTY)
	var old_metadata: Dictionary = METADATA_SCRIPT.capture(node)
	var new_metadata: Dictionary = METADATA_SCRIPT.metadata_from_settings(settings)
	_undo_redo.create_action("Bake GDGS Lighting Proxy")
	_undo_redo.add_do_method(self, &"_assign", node, resource, new_metadata)
	_undo_redo.add_undo_method(self, &"_assign", node, old_resource, old_metadata)
	_undo_redo.add_do_reference(resource)
	_undo_redo.commit_action()

	if panel != null and is_instance_valid(panel):
		panel.set_status("Saved %s · %s" % [path, _summarize_stats(stats)])


func _on_save_cancelled(panel: PanelContainer, dialog: EditorFileDialog) -> void:
	_close_save_dialog(dialog)
	if panel != null and is_instance_valid(panel):
		panel.set_status("Bake discarded: a lighting proxy must be saved to a .res, never embedded in the scene.")


func _close_save_dialog(dialog: EditorFileDialog) -> void:
	_save_dialogs.erase(dialog)
	if dialog != null and is_instance_valid(dialog):
		dialog.queue_free()


# The only place that mutates the node; used symmetrically for do/undo.
func _assign(node: Node, resource: Variant, metadata: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return
	node.set(LIGHTING_PROPERTY, resource)
	METADATA_SCRIPT.apply(node, metadata)


func _default_save_path(object: Object) -> String:
	var gaussian: Object = object.get("gaussian")
	var source_path := ""
	if gaussian != null and is_instance_valid(gaussian):
		source_path = String(gaussian.get("resource_path"))
	if source_path.is_empty():
		var scene_root := _editor_interface.get_edited_scene_root()
		if scene_root != null and not String(scene_root.scene_file_path).is_empty():
			source_path = String(scene_root.scene_file_path)
	if source_path.is_empty():
		return "res://gdgs_lighting.res"
	return "%s/%s_lighting.res" % [source_path.get_base_dir(), source_path.get_file().get_basename()]


# --- Reporting --------------------------------------------------------------


func _summarize_assigned(node: Node) -> String:
	var lighting: Variant = node.get(LIGHTING_PROPERTY)
	if lighting == null or not is_instance_valid(lighting):
		return "No lighting proxy baked. Splats render unlit."
	var gaussian: Variant = node.get("gaussian")
	if gaussian != null and is_instance_valid(gaussian) and lighting.has_method("matches_source"):
		if not bool(lighting.call("matches_source", gaussian)):
			return "Lighting proxy does not match the assigned Gaussian resource — rebake."
	var voxel := float(lighting.get("voxel_size"))
	var triangles := int(lighting.get("proxy_indices").size() / 3)
	return "Proxy: %d splat records · %d proxy triangles · %.3f m voxels." % [
		int(lighting.get("source_point_count")), triangles, voxel
	]


func _summarize_stats(stats: Dictionary) -> String:
	var splats := int(stats.get("splats", 0))
	var surfaced := int(stats.get("surfaced_splats", 0))
	var coverage := 0.0
	if splats > 0:
		coverage = 100.0 * float(surfaced) / float(splats)
	return "%d triangles · %.1f%% of splats on a surface · %.2f s" % [
		int(stats.get("proxy_triangles", 0)), coverage,
		float(stats.get("elapsed_msec", 0)) / 1000.0
	]


func _log_stats(stats: Dictionary) -> void:
	print(
		"[gdgs_lighting] voxel=%.3f grid=%s, splats=%d (surfaced=%d, floaters=%d), proxy=%d verts/%d tris, ao_radius=%d, time=%.2fs" % [
			float(stats.get("voxel_size", 0.0)), stats.get("grid_dimensions", Vector3i.ZERO),
			int(stats.get("splats", 0)), int(stats.get("surfaced_splats", 0)), int(stats.get("floater_splats", 0)),
			int(stats.get("proxy_vertices", 0)), int(stats.get("proxy_triangles", 0)),
			int(stats.get("ao_radius", 0)), float(stats.get("elapsed_msec", 0)) / 1000.0,
		]
	)


func _show_error(message: String) -> void:
	push_error("[gdgs_lighting] %s" % message)
	var dialog := AcceptDialog.new()
	dialog.title = "GDGS Lighting"
	dialog.dialog_text = message
	dialog.exclusive = true
	_editor_interface.get_base_control().add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(560, 180))


func _has_property(object: Object, property_name: StringName) -> bool:
	for property: Dictionary in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			return true
	return false

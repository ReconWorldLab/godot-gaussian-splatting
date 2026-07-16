@tool
extends EditorInspectorPlugin

# Orchestrates the collision workflow behind the panel built by
# collision_panel.gd: snapshot the GaussianResource on the main thread, run
# the pipeline on WorkerThreadPool behind a cancellable progress dialog, then
# commit the resulting CollisionBody in a single undo/redo action. Every
# failure path only shows a dialog; the scene tree is written exclusively in
# _swap_collision_body via undo/redo.

const PIPELINE_SCRIPT := preload("res://addons/gdgs/collision/pipeline/collision_pipeline.gd")
const JOB_SCRIPT := preload("res://addons/gdgs/collision/pipeline/pipeline_job.gd")
const PANEL_SCRIPT := preload("res://addons/gdgs/collision/editor/collision_panel.gd")
const PROGRESS_DIALOG_SCRIPT := preload("res://addons/gdgs/collision/editor/progress_dialog.gd")
const METADATA_SCRIPT := preload("res://addons/gdgs/collision/editor/generation_metadata.gd")
const EXPORTER_SCRIPT := preload("res://addons/gdgs/collision/editor/mesh_exporter.gd")
const COLLISION_BODY_NAME := &"CollisionBody"
const SEED_MARKER_NAME := &"CollisionSeed"

var _undo_redo: EditorUndoRedoManager
var _editor_interface: EditorInterface
var _active_dialogs: Array = []
var _export_dialogs: Array = []
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
	for dialog: Variant in _export_dialogs.duplicate():
		if dialog != null and is_instance_valid(dialog):
			dialog.queue_free()
	_export_dialogs.clear()
	_active_target_ids.clear()


# Duck-typed so this module never references GDGS classes directly: any Node3D
# whose script is named GaussianSplatNode and whose `gaussian` property looks
# like a GaussianResource gets the panel.
func _can_handle(object: Object) -> bool:
	if not object is Node3D:
		return false
	var script: Script = object.get_script()
	if script == null:
		return false
	var is_gaussian_node := script.get_global_name() == &"GaussianSplatNode"
	if not is_gaussian_node:
		is_gaussian_node = script.resource_path.get_file() == "gaussian_splat_node.gd"
	if not is_gaussian_node or not _has_property(object, &"gaussian"):
		return false
	var gaussian: Variant = object.get("gaussian")
	return gaussian == null or _looks_like_gaussian_resource(gaussian)


func _parse_begin(object: Object) -> void:
	var node := object as Node3D
	var panel: PanelContainer = PANEL_SCRIPT.new(
		METADATA_SCRIPT.settings_from_node(node),
		node.has_node(NodePath(String(COLLISION_BODY_NAME))),
		node.has_node(NodePath(String(SEED_MARKER_NAME)))
	)
	panel.generate_pressed.connect(_on_generate_pressed.bind(node, panel))
	panel.export_pressed.connect(_on_export_pressed.bind(node, panel))
	panel.seed_pressed.connect(_on_seed_pressed.bind(node, panel))
	add_custom_control(panel)


# --- Generation -------------------------------------------------------------


func _on_generate_pressed(object: Object, panel: PanelContainer) -> void:
	if object == null or not is_instance_valid(object) or not object is Node3D:
		_show_error("The selected GaussianSplatNode no longer exists.")
		return
	var target_id := object.get_instance_id()
	if _active_target_ids.has(target_id):
		_show_error("Collision generation is already running for this node.")
		return
	var settings: Dictionary = panel.read_settings()
	var needs_seed: bool = settings["scene_mode"] != "object" or settings["carve"]
	var seed_node := (object as Node3D).get_node_or_null(NodePath(String(SEED_MARKER_NAME)))
	if needs_seed and not seed_node is Marker3D:
		_show_error("Interior/outdoor fill and carve require a direct child Marker3D named CollisionSeed. Use 'Add / Select Seed' first.")
		return
	settings["seed"] = (seed_node as Marker3D).position if seed_node is Marker3D else Vector3.ZERO

	# Resource access and PackedArray duplication happen before the worker starts.
	var snapshot_result: Dictionary = PIPELINE_SCRIPT.create_snapshot(object.get("gaussian"))
	if not snapshot_result.get("ok", false):
		var message := "Failed: %s" % snapshot_result.get("error", "Unknown error")
		panel.set_status(message)
		_show_error(message)
		return

	var requested_voxel_size: float = 0.0 if settings["auto_voxel"] else settings["voxel_size"]
	var job = JOB_SCRIPT.new(snapshot_result["snapshot"], requested_voxel_size, settings["opacity_cutoff"], settings)
	var progress_dialog = PROGRESS_DIALOG_SCRIPT.new(job)
	progress_dialog.generation_completed.connect(
		_on_generation_completed.bind(object, settings, panel, progress_dialog, target_id)
	)
	_active_dialogs.append(progress_dialog)
	_active_target_ids[target_id] = true
	panel.set_generating(true)
	panel.set_status("Running on WorkerThreadPool…")
	_editor_interface.get_base_control().add_child(progress_dialog)
	progress_dialog.start()


func _on_generation_completed(
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
		panel.set_generating(false)
	if worker_result.get("cancelled", false):
		if panel_alive:
			panel.set_status("Generation cancelled; scene unchanged.")
		return
	if not worker_result.get("ok", false):
		var message := "Failed: %s" % worker_result.get("error", "Unknown error")
		if panel_alive:
			panel.set_status(message)
		_show_error(message)
		return
	if object == null or not is_instance_valid(object) or not object is Node3D:
		_show_error("Generation finished, but the target GaussianSplatNode no longer exists. Scene unchanged.")
		return

	# ArrayMesh and physics resources are created only after returning to main.
	var result: Dictionary = PIPELINE_SCRIPT.finalize_result(worker_result)
	if not result.get("ok", false):
		var finalize_message := "Failed: %s" % result.get("error", "Could not finalize mesh")
		if panel_alive:
			panel.set_status(finalize_message)
		_show_error(finalize_message)
		return
	var collision_shape: ConcavePolygonShape3D = PIPELINE_SCRIPT.create_collision_shape(result["mesh"])
	if collision_shape == null:
		_show_error("Failed: generated mesh has no usable collision triangles.")
		return

	var body := StaticBody3D.new()
	body.name = COLLISION_BODY_NAME
	var shape_node := CollisionShape3D.new()
	shape_node.name = &"CollisionShape3D"
	shape_node.shape = collision_shape
	body.add_child(shape_node)
	var parent := object as Node3D
	var old_body := parent.get_node_or_null(NodePath(String(COLLISION_BODY_NAME)))
	var scene_root := _editor_interface.get_edited_scene_root()
	var old_metadata: Dictionary = METADATA_SCRIPT.capture(parent)
	var new_metadata: Dictionary = METADATA_SCRIPT.metadata_from_settings(settings)
	_undo_redo.create_action("Generate GDGS Collision")
	_undo_redo.add_do_method(self, &"_swap_collision_body", parent, old_body, body, scene_root, new_metadata)
	_undo_redo.add_undo_method(self, &"_swap_collision_body", parent, body, old_body, scene_root, old_metadata)
	_undo_redo.add_do_reference(body)
	if old_body != null:
		_undo_redo.add_undo_reference(old_body)
	_undo_redo.commit_action()

	if panel_alive:
		panel.set_export_enabled(true)
		panel.set_status(_summarize(result["stats"]))
	_log_stats(result["stats"])


func _summarize(stats: Dictionary) -> String:
	var mesh_detail := "%d rectangles" % stats["rectangles"]
	if stats["mesh_mode"] == "smooth":
		mesh_detail = "%d smooth cells" % stats["surface_cells"]
	var backend_detail := String(stats["compute_backend"]).to_upper()
	if not String(stats.get("gpu_fallback_reason", "")).is_empty():
		backend_detail = "CPU fallback"
	return "%d voxels · %s · %d triangles · %s · %.2f s" % [
		stats["occupied_voxels"], mesh_detail, stats["triangles"], backend_detail,
		float(stats["elapsed_msec"]) / 1000.0
	]


func _log_stats(stats: Dictionary) -> void:
	print(
		"[gdgs_collision] mode=%s/%s backend=%s, splats=%d/%d, grid=%s (%d voxels), occupied=%d, triangles=%d, time=%.2fs [prepare=%dms voxelize=%dms cleanup=%dms scene=%dms mesh=%dms]" % [
			stats["mesh_mode"], stats["scene_mode"], stats["compute_backend"],
			stats["valid_splats"], stats["input_splats"], stats["grid_dimensions"], stats["grid_voxels"],
			stats["occupied_voxels"], stats["triangles"], float(stats["elapsed_msec"]) / 1000.0,
			stats["prepare_msec"], stats["voxelize_msec"], stats["cleanup_msec"], stats["scene_msec"], stats["mesher_msec"],
		]
	)


# The only place that mutates the scene tree; used symmetrically for do/undo.
func _swap_collision_body(
	parent: Node,
	remove_node: Node,
	add_node: Node,
	scene_root: Node,
	metadata: Dictionary
) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	if remove_node != null and is_instance_valid(remove_node) and remove_node.get_parent() == parent:
		parent.remove_child(remove_node)
	if add_node != null and is_instance_valid(add_node) and add_node.get_parent() == null:
		parent.add_child(add_node)
		_set_owner_recursive(add_node, scene_root)
	METADATA_SCRIPT.apply(parent, metadata)


# --- Seed marker ------------------------------------------------------------


func _on_seed_pressed(object: Object, panel: PanelContainer) -> void:
	if object == null or not is_instance_valid(object) or not object is Node3D:
		_show_error("The selected GaussianSplatNode no longer exists.")
		return
	var parent := object as Node3D
	var existing := parent.get_node_or_null(NodePath(String(SEED_MARKER_NAME)))
	if existing is Marker3D:
		_editor_interface.get_selection().clear()
		_editor_interface.get_selection().add_node(existing)
		panel.set_seed_label("Seed: CollisionSeed Marker3D")
		return
	if existing != null:
		_show_error("A child named CollisionSeed already exists but is not a Marker3D. Rename or remove it first.")
		return
	var marker := Marker3D.new()
	marker.name = SEED_MARKER_NAME
	var scene_root := _editor_interface.get_edited_scene_root()
	_undo_redo.create_action("Add GDGS Collision Seed")
	_undo_redo.add_do_method(self, &"_attach_seed_marker", parent, marker, scene_root)
	_undo_redo.add_undo_method(self, &"_detach_seed_marker", parent, marker)
	_undo_redo.add_do_reference(marker)
	_undo_redo.commit_action()
	panel.set_seed_label("Seed: CollisionSeed Marker3D (move it in the 3D view)")
	_editor_interface.get_selection().clear()
	_editor_interface.get_selection().add_node(marker)


func _attach_seed_marker(parent: Node, marker: Node, scene_root: Node) -> void:
	if is_instance_valid(parent) and is_instance_valid(marker) and marker.get_parent() == null:
		parent.add_child(marker)
		_set_owner_recursive(marker, scene_root)


func _detach_seed_marker(parent: Node, marker: Node) -> void:
	if is_instance_valid(parent) and is_instance_valid(marker) and marker.get_parent() == parent:
		parent.remove_child(marker)


# --- Export -----------------------------------------------------------------


func _on_export_pressed(object: Object, panel: PanelContainer) -> void:
	if object == null or not is_instance_valid(object) or not object is Node3D:
		_show_error("The selected GaussianSplatNode no longer exists.")
		return
	var body := (object as Node3D).get_node_or_null(NodePath(String(COLLISION_BODY_NAME)))
	var mesh_result: Dictionary = EXPORTER_SCRIPT.mesh_from_collision_body(body)
	if not mesh_result.get("ok", false):
		_show_error(mesh_result.get("error", "Could not read the collision mesh."))
		return
	var dialog := EditorFileDialog.new()
	dialog.title = "Export GDGS Collision Mesh"
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	dialog.add_filter("*.res", "Godot binary mesh resource")
	dialog.add_filter("*.obj", "Wavefront OBJ")
	dialog.add_filter("*.glb", "glTF binary")
	dialog.current_file = "gdgs_collision.glb"
	_export_dialogs.append(dialog)
	_editor_interface.get_base_control().add_child(dialog)
	dialog.file_selected.connect(_on_export_path_selected.bind(mesh_result["mesh"], panel, dialog))
	dialog.canceled.connect(_close_export_dialog.bind(dialog))
	dialog.popup_centered_ratio(0.7)


func _on_export_path_selected(path: String, mesh: ArrayMesh, panel: PanelContainer, dialog: EditorFileDialog) -> void:
	var result: Dictionary = EXPORTER_SCRIPT.export_mesh(mesh, path)
	_close_export_dialog(dialog)
	if not result.get("ok", false):
		_show_error(result.get("error", "Mesh export failed."))
		return
	if panel != null and is_instance_valid(panel):
		panel.set_status("Exported collision mesh: %s" % path)


func _close_export_dialog(dialog: EditorFileDialog) -> void:
	_export_dialogs.erase(dialog)
	if dialog != null and is_instance_valid(dialog):
		dialog.queue_free()


# --- Shared helpers ---------------------------------------------------------


func _set_owner_recursive(node: Node, owner: Node) -> void:
	if owner != null and is_instance_valid(owner):
		node.owner = owner
	for child: Node in node.get_children():
		_set_owner_recursive(child, owner)


func _show_error(message: String) -> void:
	push_error("[gdgs_collision] %s" % message)
	var dialog := AcceptDialog.new()
	dialog.title = "GDGS Collision"
	dialog.dialog_text = message
	dialog.exclusive = true
	_editor_interface.get_base_control().add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(520, 180))


func _looks_like_gaussian_resource(resource: Object) -> bool:
	if resource == null or not is_instance_valid(resource):
		return false
	return (
		_has_property(resource, &"point_count") and _has_property(resource, &"xyz") and
		_has_property(resource, &"point_data_float") and _has_property(resource, &"aabb")
	)


func _has_property(object: Object, property_name: StringName) -> bool:
	for property: Dictionary in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			return true
	return false

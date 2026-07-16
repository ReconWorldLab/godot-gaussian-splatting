@tool
extends PanelContainer

# The "GDGS Collision" block injected at the top of the inspector. This file
# only builds controls, keeps their enable/disable rules consistent, and
# reports the chosen settings; all generation/scene work happens in
# inspector_plugin.gd, which listens to the three signals below.

signal generate_pressed
signal export_pressed
signal seed_pressed

var _auto_voxel: CheckBox
var _voxel_size: SpinBox
var _opacity_cutoff: SpinBox
var _mesh_mode: OptionButton
var _compute_backend: OptionButton
var _scene_mode: OptionButton
var _dilation: SpinBox
var _carve: CheckBox
var _capsule_height: SpinBox
var _capsule_radius: SpinBox
var _seed_label: Label
var _seed_button: Button
var _generate_button: Button
var _export_button: Button
var _status_label: Label


func _init(defaults: Dictionary, has_collision: bool, has_seed: bool) -> void:
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 8)
	add_child(margin)
	var content := VBoxContainer.new()
	margin.add_child(content)

	var title := Label.new()
	title.text = "GDGS Collision"
	title.add_theme_font_size_override("font_size", 16)
	content.add_child(title)

	_auto_voxel = CheckBox.new()
	_auto_voxel.text = "Auto voxel size (longest axis / 128)"
	_auto_voxel.button_pressed = bool(defaults["auto_voxel"])
	content.add_child(_auto_voxel)
	_voxel_size = _add_spin_row(content, "Voxel size", 0.001, 10.0, 0.001, float(defaults["voxel_size"]))
	_voxel_size.custom_arrow_step = 0.01
	_opacity_cutoff = _add_spin_row(content, "Opacity cutoff", 0.001, 0.999, 0.01, float(defaults["opacity_cutoff"]))

	_mesh_mode = _add_option_row(content, "Mesh", [
		["Faces (greedy)", "faces"], ["Smooth (marching cubes)", "smooth"],
	], String(defaults["mesh_mode"]))
	_compute_backend = _add_option_row(content, "Compute", [
		["Auto (private GPU → CPU)", "auto"], ["CPU", "cpu"], ["Private GPU", "gpu"],
	], String(defaults["compute_backend"]))
	_scene_mode = _add_option_row(content, "Scene mode", [
		["Object", "object"], ["Interior", "interior"], ["Outdoor", "outdoor"],
	], String(defaults["scene_mode"]))
	_dilation = _add_spin_row(content, "Fill dilation", 0.01, 100.0, 0.05, float(defaults["dilation"]))
	_carve = CheckBox.new()
	_carve.text = "Carve capsule-reachable space"
	_carve.button_pressed = bool(defaults["carve"])
	content.add_child(_carve)
	_capsule_height = _add_spin_row(content, "Capsule height", 0.01, 100.0, 0.05, float(defaults["capsule_height"]))
	_capsule_radius = _add_spin_row(content, "Capsule radius", 0.0, 100.0, 0.05, float(defaults["capsule_radius"]))

	var seed_row := HBoxContainer.new()
	_seed_label = Label.new()
	_seed_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_label.text = "Seed: CollisionSeed Marker3D" if has_seed else "Seed: not added"
	seed_row.add_child(_seed_label)
	_seed_button = Button.new()
	_seed_button.text = "Add / Select Seed"
	seed_row.add_child(_seed_button)
	content.add_child(seed_row)

	var button_row := HBoxContainer.new()
	_generate_button = Button.new()
	_generate_button.text = "Generate Collision"
	_generate_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button_row.add_child(_generate_button)
	_export_button = Button.new()
	_export_button.text = "Export Mesh…"
	_export_button.disabled = not has_collision
	button_row.add_child(_export_button)
	content.add_child(button_row)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if has_collision:
		_status_label.text = "Collision exists · generation settings restored from node metadata."
	content.add_child(_status_label)

	_auto_voxel.toggled.connect(func(_on: bool) -> void: _refresh_enabled_controls())
	_scene_mode.item_selected.connect(func(_index: int) -> void: _refresh_enabled_controls())
	_carve.toggled.connect(func(_on: bool) -> void: _refresh_enabled_controls())
	_refresh_enabled_controls()
	_generate_button.pressed.connect(func() -> void: generate_pressed.emit())
	_export_button.pressed.connect(func() -> void: export_pressed.emit())
	_seed_button.pressed.connect(func() -> void: seed_pressed.emit())


# UI values under the settings keys the pipeline understands. The seed
# position is not a control; the caller resolves it from the CollisionSeed
# marker before starting a job.
func read_settings() -> Dictionary:
	return {
		"auto_voxel": _auto_voxel.button_pressed,
		"voxel_size": _voxel_size.value,
		"opacity_cutoff": _opacity_cutoff.value,
		"mesh_mode": _option_value(_mesh_mode),
		"compute_backend": _option_value(_compute_backend),
		"scene_mode": _option_value(_scene_mode),
		"dilation": _dilation.value,
		"carve": _carve.button_pressed,
		"capsule_height": _capsule_height.value,
		"capsule_radius": _capsule_radius.value,
	}


func set_status(text: String) -> void:
	_status_label.text = text


func set_generating(generating: bool) -> void:
	_generate_button.disabled = generating
	_generate_button.text = "Generating…" if generating else "Generate Collision"


func set_export_enabled(enabled: bool) -> void:
	_export_button.disabled = not enabled


func set_seed_label(text: String) -> void:
	_seed_label.text = text


func _refresh_enabled_controls() -> void:
	var scene_features := _option_value(_scene_mode) != "object"
	var carving := _carve.button_pressed
	_voxel_size.editable = not _auto_voxel.button_pressed
	_dilation.editable = scene_features
	_capsule_height.editable = carving
	_capsule_radius.editable = carving
	_seed_button.disabled = not scene_features and not carving


func _option_value(option: OptionButton) -> String:
	return String(option.get_item_metadata(option.selected))


func _add_option_row(content: VBoxContainer, label_text: String, entries: Array, selected_value: String) -> OptionButton:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var option := OptionButton.new()
	for entry: Array in entries:
		option.add_item(String(entry[0]))
		option.set_item_metadata(option.item_count - 1, String(entry[1]))
		if String(entry[1]) == selected_value:
			option.select(option.item_count - 1)
	row.add_child(option)
	content.add_child(row)
	return option


func _add_spin_row(
	content: VBoxContainer,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float
) -> SpinBox:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = clampf(value, minimum, maximum)
	row.add_child(spin)
	content.add_child(row)
	return spin

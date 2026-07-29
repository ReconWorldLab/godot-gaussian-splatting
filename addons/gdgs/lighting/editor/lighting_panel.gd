@tool
extends PanelContainer

# The "GDGS Lighting" block injected into the inspector below the collision
# panel. Builds controls and reports the chosen bake settings; every bake,
# save and scene write happens in lighting_inspector_plugin.gd.
#
# Deliberately plainer than collision_panel.gd: one flat two-column grid and a
# pair of buttons. Theme colours are pulled from the editor theme on
# NOTIFICATION_THEME_CHANGED, each lookup guarded by has_theme_*, so the panel
# still renders if a theme item is missing.

signal bake_pressed

var _auto_voxel: CheckBox
var _voxel_size: SpinBox
var _voxel_size_label: Label
var _opacity_cutoff: SpinBox
var _compute_backend: OptionButton
var _normal_smoothing: SpinBox
var _ao_radius: SpinBox
var _ao_strength: SpinBox
var _bake_button: Button
var _status_label: Label
var _title: Label
var _title_bar: PanelContainer
var _grid: GridContainer


func _init(defaults: Dictionary, proxy_summary: String) -> void:
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 6)
	add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	margin.add_child(content)

	_title_bar = PanelContainer.new()
	content.add_child(_title_bar)
	_title = Label.new()
	_title.text = "GDGS Lighting"
	_title.add_theme_font_size_override("font_size", 16)
	_title_bar.add_child(_title)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 4)
	content.add_child(_grid)

	_auto_voxel = _add_check_row(
		"Auto voxel size", bool(defaults["auto_voxel"]),
		"Derive the voxel size from the longest AABB axis / 128."
	)
	var voxel_row := _add_spin_row(
		"Voxel size", 0.001, 10.0, 0.001, float(defaults["voxel_size"]),
		" m", "Proxy resolution: the finest lighting detail the splats can borrow."
	)
	_voxel_size_label = voxel_row[0]
	_voxel_size = voxel_row[1]
	_voxel_size.custom_arrow_step = 0.01
	_opacity_cutoff = _add_spin_row(
		"Opacity cutoff", 0.001, 0.999, 0.01, float(defaults["opacity_cutoff"]),
		"", "Accumulated Gaussian density that counts as surface. Lower fills more."
	)[1]
	_compute_backend = _add_option_row("Compute", [
		["Auto (private GPU → CPU)", "auto"], ["CPU", "cpu"], ["Private GPU", "gpu"],
	], String(defaults["compute_backend"]), "Auto tries an isolated GPU device, then falls back to the CPU.")
	_normal_smoothing = _add_spin_row(
		"Normal smoothing", 0, 4, 1, float(defaults["normal_smoothing"]),
		"", "Rounds of neighbour averaging. Marching-cubes normals are faceted at 0."
	)[1]
	_ao_radius = _add_spin_row(
		"AO radius", 0, 16, 1, float(defaults["ao_radius"]),
		" vx", "Neighbourhood radius for ambient occlusion, in voxels. 0 disables AO."
	)[1]
	_ao_strength = _add_spin_row(
		"AO strength", 0.0, 1.0, 0.05, float(defaults["ao_strength"]),
		"", "How far occluded splats are darkened. 0 keeps every splat fully open."
	)[1]

	content.add_child(HSeparator.new())
	_bake_button = Button.new()
	_bake_button.text = "Bake Lighting Proxy"
	content.add_child(_bake_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = proxy_summary
	content.add_child(_status_label)

	_auto_voxel.toggled.connect(func(_on: bool) -> void: _refresh_enabled_controls())
	_ao_radius.value_changed.connect(func(_value: float) -> void: _refresh_enabled_controls())
	_bake_button.pressed.connect(func() -> void: bake_pressed.emit())
	_refresh_enabled_controls()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_editor_theme()


## UI values under the settings keys proxy_builder.bake() understands.
func read_settings() -> Dictionary:
	return {
		"auto_voxel": _auto_voxel.button_pressed,
		"voxel_size": _voxel_size.value,
		"opacity_cutoff": _opacity_cutoff.value,
		"compute_backend": _option_value(_compute_backend),
		"normal_smoothing": int(_normal_smoothing.value),
		"ao_radius": int(_ao_radius.value),
		"ao_strength": _ao_strength.value,
	}


func set_status(text: String) -> void:
	_status_label.text = text


func set_baking(baking: bool) -> void:
	_bake_button.disabled = baking
	_bake_button.text = "Baking…" if baking else "Bake Lighting Proxy"


func _refresh_enabled_controls() -> void:
	var manual_voxel := not _auto_voxel.button_pressed
	_voxel_size.visible = manual_voxel
	_voxel_size_label.visible = manual_voxel
	_ao_strength.editable = _ao_radius.value > 0.0


# --- control builders -------------------------------------------------------


func _add_check_row(text: String, value: bool, tooltip: String) -> CheckBox:
	_add_grid_label(text, tooltip)
	var check := CheckBox.new()
	check.button_pressed = value
	check.tooltip_text = tooltip
	_grid.add_child(check)
	return check


func _add_spin_row(
	text: String, minimum: float, maximum: float, step: float, value: float,
	suffix: String, tooltip: String
) -> Array:
	var label := _add_grid_label(text, tooltip)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.suffix = suffix
	spin.tooltip_text = tooltip
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(spin)
	return [label, spin]


func _add_option_row(text: String, entries: Array, value: String, tooltip: String) -> OptionButton:
	_add_grid_label(text, tooltip)
	var option := OptionButton.new()
	option.tooltip_text = tooltip
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for index in entries.size():
		var entry: Array = entries[index]
		option.add_item(String(entry[0]), index)
		option.set_item_metadata(index, entry[1])
		if String(entry[1]) == value:
			option.select(index)
	if option.selected < 0 and option.item_count > 0:
		option.select(0)
	_grid.add_child(option)
	return option


func _add_grid_label(text: String, tooltip: String) -> Label:
	var label := Label.new()
	label.text = text
	label.tooltip_text = tooltip
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(label)
	return label


func _option_value(option: OptionButton) -> String:
	if option.selected < 0:
		return ""
	return String(option.get_item_metadata(option.selected))


func _apply_editor_theme() -> void:
	if has_theme_stylebox("bg", "EditorInspectorCategory"):
		_title_bar.add_theme_stylebox_override("panel", get_theme_stylebox("bg", "EditorInspectorCategory"))
	if has_theme_font("bold", "EditorFonts"):
		_title.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	if has_theme_color("font_color", "Editor"):
		_title.add_theme_color_override("font_color", get_theme_color("font_color", "Editor"))

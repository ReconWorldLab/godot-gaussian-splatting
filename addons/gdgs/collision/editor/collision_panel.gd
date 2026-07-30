@tool
extends PanelContainer

# The "GDGS Collision" block injected at the top of the inspector. This file
# only builds controls, keeps their show/hide rules consistent, and reports the
# chosen settings; all generation/scene work happens in inspector_plugin.gd,
# which listens to the three signals below.
#
# Layout mimics native inspector groups: a category bar for the title (like the
# "Node3D" class bar) and foldable sections (like "Transform") whose rows sit in
# a two-column GridContainer inside a faintly tinted, indented body. Parameters
# that do not apply to the current scene mode / carve toggle are hidden rather
# than greyed. Editor fonts, colors, styleboxes and icons are pulled from the
# editor theme on NOTIFICATION_THEME_CHANGED, all guarded by has_theme_*.

signal generate_pressed
signal export_pressed
signal seed_pressed

var _auto_voxel: CheckBox
var _voxel_size: SpinBox
var _voxel_size_label: Label
var _opacity_cutoff: SpinBox
var _mesh_mode: OptionButton
var _compute_backend: OptionButton
var _scene_mode: OptionButton
var _dilation: SpinBox
var _dilation_label: Label
var _carve: CheckBox
var _capsule_height: SpinBox
var _capsule_height_label: Label
var _capsule_radius: SpinBox
var _capsule_radius_label: Label
var _seed_label: Label
var _seed_button: Button
var _generate_button: Button
var _export_button: Button
var _status_label: Label

var _title: Label
var _title_bar: PanelContainer
var _title_icon: TextureRect
var _section_headers: Array[Button] = []
var _section_bodies: Array[PanelContainer] = []


func _init(defaults: Dictionary, has_collision: bool, has_seed: bool) -> void:
	# Our labels are authored in English (repo convention) and must render that
	# way whatever locale the editor runs in. Without this, Godot auto-translates
	# any string that happens to match one of its own editor translation keys, so
	# a section header reading "Scene" came out localised next to an untranslated
	# "Scene mode" row — worse than either language on its own. Propagates to
	# children, which default to INHERIT.
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED

	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 6)
	add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	margin.add_child(content)

	# Title as a native-style category bar (icon + bold class-like name).
	_title_bar = PanelContainer.new()
	content.add_child(_title_bar)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	_title_bar.add_child(title_row)
	_title_icon = TextureRect.new()
	_title_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_title_icon.custom_minimum_size = Vector2(16, 16)
	_title_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(_title_icon)
	_title = Label.new()
	_title.text = "GDGS Collision"
	_title.add_theme_font_size_override("font_size", 16)
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(_title)

	# --- Voxelization ---------------------------------------------------------
	var voxelization := _add_section(content, "Voxelization")
	_auto_voxel = _add_check_row(
		voxelization, "Auto voxel size", bool(defaults["auto_voxel"]),
		"Derive the voxel size from the longest AABB axis / 128."
	)
	var voxel_row := _add_spin_row(
		voxelization, "Voxel size", 0.001, 10.0, 0.001, float(defaults["voxel_size"]),
		" m", "World-space edge length of one voxel. Smaller = finer but heavier."
	)
	_voxel_size_label = voxel_row[0]
	_voxel_size = voxel_row[1]
	_voxel_size.custom_arrow_step = 0.01
	_opacity_cutoff = _add_spin_row(
		voxelization, "Opacity cutoff", 0.001, 0.999, 0.01, float(defaults["opacity_cutoff"]),
		"", "Accumulated Gaussian density that counts as solid. Lower fills more."
	)[1]
	_compute_backend = _add_option_row(voxelization, "Compute", [
		["Auto (private GPU → CPU)", "auto"], ["CPU", "cpu"], ["Private GPU", "gpu"],
	], String(defaults["compute_backend"]), "Auto tries an isolated GPU device, then falls back to the CPU.")
	_mesh_mode = _add_option_row(voxelization, "Mesh", [
		["Faces (greedy)", "faces"], ["Smooth (marching cubes)", "smooth"],
	], String(defaults["mesh_mode"]), "Faces = greedy voxel boxes. Smooth = marching-cubes surface.")

	# --- Scene ----------------------------------------------------------------
	var scene := _add_section(content, "Scene")
	_scene_mode = _add_option_row(scene, "Scene mode", [
		["Object", "object"], ["Interior", "interior"], ["Outdoor", "outdoor"],
	], String(defaults["scene_mode"]), "Object = surface shell. Interior = seal a room. Outdoor = seal below the ground.")
	var dilation_row := _add_spin_row(
		scene, "Fill dilation", 0.01, 100.0, 0.05, float(defaults["dilation"]),
		" m", "How far walls/ground are thickened before sealing."
	)
	_dilation_label = dilation_row[0]
	_dilation = dilation_row[1]
	_carve = _add_check_row(
		scene, "Carve reachable space", bool(defaults["carve"]),
		"Keep only the space a capsule can reach from the seed, then wall off the rest."
	)
	var height_row := _add_spin_row(
		scene, "Capsule height", 0.01, 100.0, 0.05, float(defaults["capsule_height"]),
		" m", "Height of the navigation capsule used when carving."
	)
	_capsule_height_label = height_row[0]
	_capsule_height = height_row[1]
	var radius_row := _add_spin_row(
		scene, "Capsule radius", 0.0, 100.0, 0.05, float(defaults["capsule_radius"]),
		" m", "Radius of the navigation capsule used when carving."
	)
	_capsule_radius_label = radius_row[0]
	_capsule_radius = radius_row[1]
	_seed_label = _add_grid_label(
		scene, "Seed: CollisionSeed Marker3D" if has_seed else "Seed: not added",
		"A child Marker3D that marks a reachable point for interior fill / carve."
	)
	_seed_button = Button.new()
	_seed_button.text = "Add / Select"
	_seed_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scene.add_child(_seed_button)

	# --- Actions --------------------------------------------------------------
	content.add_child(HSeparator.new())
	_generate_button = Button.new()
	_generate_button.text = "Generate Collision"
	content.add_child(_generate_button)
	_export_button = Button.new()
	_export_button.text = "Export Mesh…"
	_export_button.disabled = not has_collision
	content.add_child(_export_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if has_collision:
		_status_label.text = "Collision exists · settings restored from node metadata."
	content.add_child(_status_label)

	_auto_voxel.toggled.connect(func(_on: bool) -> void: _refresh_enabled_controls())
	_scene_mode.item_selected.connect(func(_index: int) -> void: _refresh_enabled_controls())
	_carve.toggled.connect(func(_on: bool) -> void: _refresh_enabled_controls())
	_refresh_enabled_controls()
	_generate_button.pressed.connect(func() -> void: generate_pressed.emit())
	_export_button.pressed.connect(func() -> void: export_pressed.emit())
	_seed_button.pressed.connect(func() -> void: seed_pressed.emit())


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_editor_theme()


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
	_refresh_status_color()


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
	# Only interior fill and carve flood from the seed; outdoor derives its
	# fill direction from the node's orientation instead.
	var seed_used := _option_value(_scene_mode) == "interior" or carving
	_voxel_size.editable = not _auto_voxel.button_pressed
	_voxel_size_label.modulate.a = 1.0 if _voxel_size.editable else 0.5
	_set_row_visible(_dilation_label, _dilation, scene_features)
	_set_row_visible(_capsule_height_label, _capsule_height, carving)
	_set_row_visible(_capsule_radius_label, _capsule_radius, carving)
	_set_row_visible(_seed_label, _seed_button, seed_used)


# --- Theme ------------------------------------------------------------------


func _apply_editor_theme() -> void:
	_style_title()
	_set_button_icon(_generate_button, "Play")
	_set_button_icon(_export_button, "Save")
	_set_button_icon(_seed_button, "Add")
	for header: Button in _section_headers:
		_style_section_header(header)
	for body: PanelContainer in _section_bodies:
		body.add_theme_stylebox_override("panel", _section_body_stylebox())
	_refresh_status_color()


func _style_title() -> void:
	if _title != null:
		if has_theme_font("bold", "EditorFonts"):
			_title.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
		var title_size := 16
		if has_theme_font_size("main_size", "EditorFonts"):
			title_size = get_theme_font_size("main_size", "EditorFonts") + 2
		_title.add_theme_font_size_override("font_size", title_size)
	if _title_bar != null:
		_title_bar.add_theme_stylebox_override("panel", _category_bar_stylebox())
	if _title_icon != null and has_theme_icon("CollisionShape3D", "EditorIcons"):
		_title_icon.texture = get_theme_icon("CollisionShape3D", "EditorIcons")


func _style_section_header(header: Button) -> void:
	_update_section_arrow(header)
	if has_theme_font("bold", "EditorFonts"):
		header.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))


func _category_bar_stylebox() -> StyleBox:
	if not has_theme_color("prop_category", "Editor"):
		return StyleBoxEmpty.new()
	var box := StyleBoxFlat.new()
	box.bg_color = get_theme_color("prop_category", "Editor")
	box.content_margin_left = 6
	box.content_margin_right = 6
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	box.set_corner_radius_all(3)
	return box


func _section_body_stylebox() -> StyleBox:
	if not has_theme_color("prop_subsection", "Editor"):
		return StyleBoxEmpty.new()
	var box := StyleBoxFlat.new()
	box.bg_color = get_theme_color("prop_subsection", "Editor")
	box.set_corner_radius_all(3)
	return box


func _refresh_status_color() -> void:
	if _status_label == null:
		return
	if _status_label.text.begins_with("Failed") and has_theme_color("error_color", "Editor"):
		_status_label.add_theme_color_override("font_color", get_theme_color("error_color", "Editor"))
	else:
		_status_label.remove_theme_color_override("font_color")


func _set_button_icon(button: Button, icon_name: String) -> void:
	if button != null and has_theme_icon(icon_name, "EditorIcons"):
		button.icon = get_theme_icon(icon_name, "EditorIcons")


func _update_section_arrow(header: Button) -> void:
	var icon_name := "GuiTreeArrowDown" if header.button_pressed else "GuiTreeArrowRight"
	if has_theme_icon(icon_name, "EditorIcons"):
		header.icon = get_theme_icon(icon_name, "EditorIcons")


# --- Builders ---------------------------------------------------------------


func _add_section(content: VBoxContainer, title_text: String) -> GridContainer:
	var header := Button.new()
	header.flat = true
	header.toggle_mode = true
	# Sections start collapsed; the fold signal is connected below, so hiding
	# the body here (before the connect) keeps header state and body in sync.
	header.button_pressed = false
	header.text = title_text
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.focus_mode = Control.FOCUS_NONE
	content.add_child(header)

	var body := PanelContainer.new()
	body.visible = false
	content.add_child(body)
	var indent := MarginContainer.new()
	indent.add_theme_constant_override("margin_left", 10)
	indent.add_theme_constant_override("margin_right", 4)
	indent.add_theme_constant_override("margin_top", 2)
	indent.add_theme_constant_override("margin_bottom", 4)
	body.add_child(indent)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	indent.add_child(grid)

	header.toggled.connect(_on_section_toggled.bind(header, body))
	_section_headers.append(header)
	_section_bodies.append(body)
	return grid


func _on_section_toggled(toggled_on: bool, header: Button, body: Control) -> void:
	body.visible = toggled_on
	_update_section_arrow(header)


func _set_row_visible(label: Control, field: Control, visible: bool) -> void:
	label.visible = visible
	field.visible = visible


func _option_value(option: OptionButton) -> String:
	return String(option.get_item_metadata(option.selected))


func _add_grid_label(grid: GridContainer, label_text: String, tooltip: String) -> Label:
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tooltip
	grid.add_child(label)
	return label


func _add_option_row(
	grid: GridContainer,
	label_text: String,
	entries: Array,
	selected_value: String,
	tooltip: String = ""
) -> OptionButton:
	_add_grid_label(grid, label_text, tooltip)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.tooltip_text = tooltip
	for entry: Array in entries:
		option.add_item(String(entry[0]))
		option.set_item_metadata(option.item_count - 1, String(entry[1]))
		if String(entry[1]) == selected_value:
			option.select(option.item_count - 1)
	grid.add_child(option)
	return option


func _add_check_row(grid: GridContainer, label_text: String, pressed: bool, tooltip: String) -> CheckBox:
	_add_grid_label(grid, label_text, tooltip)
	var check := CheckBox.new()
	check.button_pressed = pressed
	check.tooltip_text = tooltip
	grid.add_child(check)
	return check


func _add_spin_row(
	grid: GridContainer,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	suffix: String = "",
	tooltip: String = ""
) -> Array:
	var label := _add_grid_label(grid, label_text, tooltip)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = clampf(value, minimum, maximum)
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.tooltip_text = tooltip
	if suffix != "":
		spin.suffix = suffix
	grid.add_child(spin)
	return [label, spin]

@tool
extends PanelContainer

# The "GDGS Lighting" block injected into the inspector below the collision
# panel. This file only builds controls, keeps their enabled/disabled rules
# consistent, and reports the chosen settings; every bake, save and scene write
# happens in lighting_inspector_plugin.gd, which listens to the signal below.
#
# Layout deliberately mirrors collision_panel.gd so the two blocks read as one
# feature set: a category bar for the title (like the "Node3D" class bar) and
# foldable sections (like "Transform") that start collapsed, whose rows sit in a
# two-column GridContainer inside a faintly tinted, indented body. Editor fonts,
# colors, styleboxes and icons are pulled from the editor theme on
# NOTIFICATION_THEME_CHANGED, all guarded by has_theme_*.

signal bake_pressed

var _auto_voxel: CheckBox
var _voxel_size: SpinBox
var _voxel_size_label: Label
var _opacity_cutoff: SpinBox
var _compute_backend: OptionButton
var _normal_smoothing: SpinBox
var _ao_radius: SpinBox
var _ao_strength: SpinBox
var _ao_strength_label: Label
var _bake_button: Button
var _status_label: Label

var _title: Label
var _title_bar: PanelContainer
var _title_icon: TextureRect
var _section_headers: Array[Button] = []
var _section_bodies: Array[PanelContainer] = []


func _init(defaults: Dictionary, proxy_summary: String) -> void:
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
	_title.text = "GDGS Lighting"
	_title.add_theme_font_size_override("font_size", 16)
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(_title)

	# --- Proxy ----------------------------------------------------------------
	var proxy := _add_section(content, "Proxy")
	_auto_voxel = _add_check_row(
		proxy, "Auto voxel size", bool(defaults["auto_voxel"]),
		"Derive the voxel size from the longest AABB axis / 128."
	)
	var voxel_row := _add_spin_row(
		proxy, "Voxel size", 0.001, 10.0, 0.001, float(defaults["voxel_size"]),
		" m", "Proxy resolution: the finest lighting detail splats can borrow."
	)
	_voxel_size_label = voxel_row[0]
	_voxel_size = voxel_row[1]
	_voxel_size.custom_arrow_step = 0.01
	# Step 0.001 rather than 0.01 on purpose: a SpinBox snaps to
	# `min_value + n * step`, so a 0.01 step over a 0.001 minimum would quietly
	# turn the 0.1 default into 0.101. custom_arrow_step keeps the arrows coarse.
	_opacity_cutoff = _add_spin_row(
		proxy, "Opacity cutoff", 0.001, 0.999, 0.001, float(defaults["opacity_cutoff"]),
		"", "Accumulated Gaussian density that counts as surface. Lower fills more."
	)[1]
	_opacity_cutoff.custom_arrow_step = 0.01
	_compute_backend = _add_option_row(proxy, "Compute", [
		["Auto (private GPU → CPU)", "auto"], ["CPU", "cpu"], ["Private GPU", "gpu"],
	], String(defaults["compute_backend"]), "Auto tries an isolated GPU device, then falls back to the CPU.")

	# --- Surface --------------------------------------------------------------
	var surface := _add_section(content, "Surface")
	_normal_smoothing = _add_spin_row(
		surface, "Normal smoothing", 0, 4, 1, float(defaults["normal_smoothing"]),
		"", "Rounds of neighbour averaging. Marching-cubes normals are faceted at 0."
	)[1]
	_ao_radius = _add_spin_row(
		surface, "AO radius", 0, 16, 1, float(defaults["ao_radius"]),
		" vx", "Neighbourhood radius for ambient occlusion, in voxels. 0 disables AO."
	)[1]
	var strength_row := _add_spin_row(
		surface, "AO strength", 0.0, 1.0, 0.05, float(defaults["ao_strength"]),
		"", "How far occluded splats are darkened. 0 keeps every splat fully open."
	)
	_ao_strength_label = strength_row[0]
	_ao_strength = strength_row[1]

	# --- Actions --------------------------------------------------------------
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
	_refresh_enabled_controls()
	_bake_button.pressed.connect(func() -> void: bake_pressed.emit())


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
	_refresh_status_color()


func set_baking(baking: bool) -> void:
	_bake_button.disabled = baking
	_bake_button.text = "Baking…" if baking else "Bake Lighting Proxy"


func _refresh_enabled_controls() -> void:
	_voxel_size.editable = not _auto_voxel.button_pressed
	_voxel_size_label.modulate.a = 1.0 if _voxel_size.editable else 0.5
	_ao_strength.editable = _ao_radius.value > 0.0
	_ao_strength_label.modulate.a = 1.0 if _ao_strength.editable else 0.5


# --- Theme ------------------------------------------------------------------


func _apply_editor_theme() -> void:
	_style_title()
	_set_button_icon(_bake_button, ["Bake", "Play"])
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
	if _title_icon != null:
		_title_icon.texture = _first_theme_icon(["LightmapGI", "DirectionalLight3D", "Light"])


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


func _set_button_icon(button: Button, icon_names: Array) -> void:
	if button == null:
		return
	var icon := _first_theme_icon(icon_names)
	if icon != null:
		button.icon = icon


## Editor icon names drift between Godot versions, so take the first that this
## build actually has and leave the slot empty rather than guessing.
func _first_theme_icon(icon_names: Array) -> Texture2D:
	for icon_name: String in icon_names:
		if has_theme_icon(icon_name, "EditorIcons"):
			return get_theme_icon(icon_name, "EditorIcons")
	return null


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


func _option_value(option: OptionButton) -> String:
	if option.selected < 0:
		return ""
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
	if option.selected < 0 and option.item_count > 0:
		option.select(0)
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

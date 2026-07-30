extends Node3D

## Interactive relighting sandbox.
##
##   godot --path . samples/relighting_demo.tscn
##
## Everything is built in code rather than stored in the .tscn, so this file
## doubles as a worked example of the relighting API and the scene stays a
## two-line text file that no editor version can churn.
##
## The lighting proxy is baked on startup instead of shipped: a bake for
## `demo.sog` is several megabytes and this repository keeps large binaries out
## of git. It is cached under `user://` afterwards, so only the first run waits.

const SPLAT_NODE_SCRIPT := preload("res://addons/gdgs/runtime/nodes/gaussian_splat_node.gd")
const LIGHTING_RESOURCE_SCRIPT := preload("res://addons/gdgs/runtime/resources/gaussian_lighting_resource.gd")
const COMPOSITOR_EFFECT_SCRIPT := preload("res://addons/gdgs/runtime/compositor/gaussian_compositor_effect.gd")
const GAUSSIAN_PATH := "res://samples/assets/demo.sog"

# The bake module is editor-side and optional, so it is loaded defensively;
# without it the demo still runs, just unlit.
const PIPELINE_PATH := "res://addons/gdgs/collision/pipeline/collision_pipeline.gd"
const BAKE_JOB_PATH := "res://addons/gdgs/lighting/bake/bake_job.gd"

const CACHE_PATH_TEMPLATE := "user://gdgs_relighting_demo_%d.res"
const BAKE_SETTINGS := {
	"auto_voxel": true,
	"opacity_cutoff": 0.1,
	"compute_backend": "auto",
	"normal_smoothing": 1,
	"ao_radius": 3,
	"ao_strength": 1.0,
}

const ORBIT_SPEED := 0.6
const LIGHT_SPEED := 1.2
const ZOOM_SPEED := 0.35
const MIN_DISTANCE := 1.2
const MAX_DISTANCE := 12.0

enum LightKind { DIRECTIONAL, OMNI, SPOT }

var _splats: Node3D
var _camera: Camera3D
var _light_pivot: Node3D
var _lights: Dictionary = {}
var _hud: Label
var _hud_panel: PanelContainer
var _ground: MeshInstance3D
var _probe: MeshInstance3D

var _target := Vector3.ZERO
var _distance := 4.3
var _camera_yaw := 0.6
var _camera_pitch := 0.12
var _light_yaw := 0.7
var _light_pitch := -0.65
var _light_kind := LightKind.DIRECTIONAL
var _auto_orbit_light := true
var _dragging := false
var _hud_visible := true

var _bake_job: RefCounted = null
var _bake_task := -1
var _status := "Preparing…"


func _ready() -> void:
	var gaussian: Resource = load(GAUSSIAN_PATH)
	if gaussian == null:
		_status = "Could not load %s" % GAUSSIAN_PATH
		_build_hud()
		return

	var bounds: AABB = gaussian.get("aabb")
	_target = Vector3(0.0, bounds.position.y + bounds.size.y * 0.45, 0.0)

	_build_environment(bounds)
	_build_lights(bounds)
	_build_camera()
	_build_hud()

	_splats = SPLAT_NODE_SCRIPT.new()
	_splats.name = "GaussianSplat"
	_splats.set("gaussian", gaussian)
	add_child(_splats)
	_splats.set("relight_unlit_level", 0.15)
	_splats.set("relight_light_gain", 1.0)
	_splats.set("relight_ambient", Color(0.10, 0.10, 0.13))

	_start_bake(gaussian)


# --- scene construction ------------------------------------------------------


func _build_environment(bounds: AABB) -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.05, 0.07)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.35, 0.38, 0.45)
	environment.ambient_light_energy = 0.12
	world_environment.environment = environment
	# Required by the Compute backend; inert under Raster.
	var compositor := Compositor.new()
	compositor.compositor_effects = [COMPOSITOR_EFFECT_SCRIPT.new()]
	world_environment.compositor = compositor
	add_child(world_environment)

	# Ordinary Godot geometry, so the same light can be compared side by side
	# with the splats, and so the proxy's cast shadow lands on something.
	var floor_y := bounds.position.y - 0.02
	_ground = MeshInstance3D.new()
	_ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(14.0, 14.0)
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.58, 0.58, 0.62)
	ground_material.roughness = 1.0
	plane.material = ground_material
	_ground.mesh = plane
	_ground.position = Vector3(0.0, floor_y, 0.0)
	add_child(_ground)

	_probe = MeshInstance3D.new()
	_probe.name = "ReferenceBox"
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.5, 0.5)
	var probe_material := StandardMaterial3D.new()
	probe_material.albedo_color = Color(0.75, 0.72, 0.68)
	probe_material.roughness = 0.85
	box.material = probe_material
	_probe.mesh = box
	_probe.position = Vector3(1.9, floor_y + 0.25, 1.3)
	add_child(_probe)


func _build_lights(bounds: AABB) -> void:
	_light_pivot = Node3D.new()
	_light_pivot.name = "LightPivot"
	_light_pivot.position = _target
	add_child(_light_pivot)

	var directional := DirectionalLight3D.new()
	directional.light_energy = 1.5
	directional.shadow_enabled = true
	_light_pivot.add_child(directional)
	_lights[LightKind.DIRECTIONAL] = directional

	var reach: float = maxf(bounds.size.length(), 2.0)
	var omni := OmniLight3D.new()
	omni.light_energy = 4.0
	omni.omni_range = reach * 1.5
	omni.shadow_enabled = true
	omni.position = Vector3(0.0, 0.0, -reach * 0.55)
	_light_pivot.add_child(omni)
	_lights[LightKind.OMNI] = omni

	var spot := SpotLight3D.new()
	spot.light_energy = 8.0
	spot.spot_range = reach * 2.0
	spot.spot_angle = 32.0
	spot.spot_angle_attenuation = 1.5
	spot.shadow_enabled = true
	spot.position = Vector3(0.0, 0.0, -reach * 0.9)
	_light_pivot.add_child(spot)
	_lights[LightKind.SPOT] = spot

	_apply_light_kind()


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.current = true
	add_child(_camera)
	_apply_camera()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud_panel = PanelContainer.new()
	_hud_panel.position = Vector2(14, 14)
	# The scene is dark; the default panel is not, so give the HUD its own
	# translucent dark background instead of fighting the theme.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	style.set_corner_radius_all(4)
	_hud_panel.add_theme_stylebox_override("panel", style)
	layer.add_child(_hud_panel)
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 8)
	_hud_panel.add_child(margin)
	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 12)
	_hud.add_theme_color_override("font_color", Color(0.92, 0.92, 0.95))
	margin.add_child(_hud)


# --- baking ------------------------------------------------------------------


func _start_bake(gaussian: Resource) -> void:
	var point_count := int(gaussian.get("point_count"))
	var cache_path := CACHE_PATH_TEMPLATE % point_count
	if ResourceLoader.exists(cache_path):
		var cached: Resource = ResourceLoader.load(cache_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if cached != null and cached.has_method("matches_source") and bool(cached.call("matches_source", gaussian)):
			_assign_lighting(cached)
			_status = "cached proxy (%s)" % cache_path.get_file()
			return

	if not ResourceLoader.exists(PIPELINE_PATH, "Script") or not ResourceLoader.exists(BAKE_JOB_PATH, "Script"):
		_status = "Bake modules missing (addons/gdgs/collision + /lighting); rendering unlit"
		return

	# create_snapshot() reads the Resource, so it must run here on the main
	# thread; everything after it is worker-safe by construction.
	var pipeline: GDScript = load(PIPELINE_PATH)
	var snapshot: Dictionary = pipeline.create_snapshot(gaussian)
	if not snapshot.get("ok", false):
		_status = "Bake failed: %s" % snapshot.get("error", "unknown")
		return
	var job_script: GDScript = load(BAKE_JOB_PATH)
	_bake_job = job_script.new(snapshot["snapshot"], BAKE_SETTINGS.duplicate())
	_bake_task = WorkerThreadPool.add_task(_bake_job.run, false, "Bake GDGS relighting demo proxy")
	_status = "Baking lighting proxy…"


func _poll_bake() -> void:
	if _bake_task < 0:
		return
	var progress: Dictionary = _bake_job.get_status()
	_status = "Baking: %s (%d%%)" % [progress.get("stage", ""), int(100.0 * float(progress.get("progress", 0.0)))]
	if not WorkerThreadPool.is_task_completed(_bake_task):
		return
	WorkerThreadPool.wait_for_task_completion(_bake_task)
	_bake_task = -1
	var result: Dictionary = _bake_job.get_result()
	_bake_job = null
	if not result.get("ok", false):
		_status = "Bake failed: %s" % result.get("error", "unknown")
		return

	var gaussian: Resource = _splats.get("gaussian")
	var proxy: Dictionary = result.get("proxy", {})
	var lighting: Resource = LIGHTING_RESOURCE_SCRIPT.new()
	lighting.source_point_count = int(gaussian.get("point_count"))
	lighting.source_aabb = gaussian.get("aabb")
	lighting.voxel_size = float(result.get("voxel_size", 0.0))
	lighting.splat_data = result.get("splat_data", PackedByteArray())
	lighting.proxy_positions = proxy.get("positions", PackedVector3Array())
	lighting.proxy_normals = proxy.get("normals", PackedVector3Array())
	lighting.proxy_indices = proxy.get("indices", PackedInt32Array())
	lighting.bake_settings = result.get("settings", {})

	var cache_path := CACHE_PATH_TEMPLATE % lighting.source_point_count
	var error := ResourceSaver.save(lighting, cache_path)
	_assign_lighting(lighting)
	if error == OK:
		_status = "baked, cached to %s" % cache_path.get_file()
	else:
		_status = "baked (cache write failed: %s)" % error_string(error)


func _assign_lighting(lighting: Resource) -> void:
	_splats.set("lighting", lighting)
	_splats.set("relight_enabled", true)
	_splats.set("relight_cast_shadows", true)


# --- interaction -------------------------------------------------------------


func _process(delta: float) -> void:
	_poll_bake()
	if _auto_orbit_light:
		_light_yaw += delta * 0.35
		_apply_light()
	_handle_held_keys(delta)
	_refresh_hud()


func _handle_held_keys(delta: float) -> void:
	var yaw := 0.0
	var pitch := 0.0
	if Input.is_key_pressed(KEY_LEFT):
		yaw -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		yaw += 1.0
	if Input.is_key_pressed(KEY_UP):
		pitch -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		pitch += 1.0
	if yaw == 0.0 and pitch == 0.0:
		return
	_auto_orbit_light = false
	_light_yaw += yaw * LIGHT_SPEED * delta
	_light_pitch = clampf(_light_pitch + pitch * LIGHT_SPEED * delta, -1.5, -0.05)
	_apply_light()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = clampf(_distance - ZOOM_SPEED, MIN_DISTANCE, MAX_DISTANCE)
			_apply_camera()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = clampf(_distance + ZOOM_SPEED, MIN_DISTANCE, MAX_DISTANCE)
			_apply_camera()
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		_camera_yaw -= motion.relative.x * 0.005 * ORBIT_SPEED * 2.0
		_camera_pitch = clampf(_camera_pitch + motion.relative.y * 0.005, -1.2, 1.2)
		_apply_camera()
	elif event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		_handle_key((event as InputEventKey).keycode)


func _handle_key(keycode: int) -> void:
	match keycode:
		KEY_SPACE:
			_splats.set("relight_enabled", not bool(_splats.get("relight_enabled")))
		KEY_S:
			_splats.set("relight_cast_shadows", not bool(_splats.get("relight_cast_shadows")))
		KEY_D:
			_splats.set("relight_dc_only", not bool(_splats.get("relight_dc_only")))
		KEY_A:
			_auto_orbit_light = not _auto_orbit_light
		KEY_G:
			_ground.visible = not _ground.visible
			_probe.visible = _ground.visible
		KEY_H:
			_hud_visible = not _hud_visible
			_hud_panel.visible = _hud_visible
		KEY_1:
			_light_kind = LightKind.DIRECTIONAL
			_apply_light_kind()
		KEY_2:
			_light_kind = LightKind.OMNI
			_apply_light_kind()
		KEY_3:
			_light_kind = LightKind.SPOT
			_apply_light_kind()
		KEY_BRACKETLEFT:
			_splats.set("relight_unlit_level", maxf(0.0, float(_splats.get("relight_unlit_level")) - 0.05))
		KEY_BRACKETRIGHT:
			_splats.set("relight_unlit_level", minf(1.0, float(_splats.get("relight_unlit_level")) + 0.05))
		KEY_MINUS:
			_splats.set("relight_light_gain", maxf(0.0, float(_splats.get("relight_light_gain")) - 0.1))
		KEY_EQUAL:
			_splats.set("relight_light_gain", minf(4.0, float(_splats.get("relight_light_gain")) + 0.1))
		KEY_ESCAPE:
			get_tree().quit()


func _apply_light_kind() -> void:
	for kind: int in _lights:
		(_lights[kind] as Light3D).visible = kind == _light_kind
	_apply_light()


func _apply_light() -> void:
	_light_pivot.rotation = Vector3(_light_pitch, _light_yaw, 0.0)


func _apply_camera() -> void:
	var offset := Vector3(
		cos(_camera_pitch) * sin(_camera_yaw),
		sin(_camera_pitch),
		cos(_camera_pitch) * cos(_camera_yaw)
	) * _distance
	var eye := _target + offset
	_camera.transform = Transform3D(Basis.looking_at(_target - eye, Vector3.UP), eye)


func _refresh_hud() -> void:
	if _hud == null:
		return
	if _splats == null:
		_hud.text = _status
		return
	var kind_names := ["Directional", "Omni", "Spot"]
	_hud.text = "\n".join([
		"GDGS relighting demo — %s" % _status,
		"",
		"Relighting   %s      (Space)" % _on_off(bool(_splats.get("relight_enabled"))),
		"Cast shadows %s      (S)" % _on_off(bool(_splats.get("relight_cast_shadows"))),
		"DC-only      %s      (D)" % _on_off(bool(_splats.get("relight_dc_only"))),
		"Light        %-11s (1/2/3)" % kind_names[_light_kind],
		"Auto-orbit   %s      (A)" % _on_off(_auto_orbit_light),
		"Ground       %s      (G)" % _on_off(_ground != null and _ground.visible),
		"Unlit level  %-11.2f ([ / ])" % float(_splats.get("relight_unlit_level")),
		"Light gain   %-11.2f (- / =)" % float(_splats.get("relight_light_gain")),
		"",
		"Arrows move the light · drag orbits · wheel zooms · H hides this · Esc quits",
	])


func _on_off(value: bool) -> String:
	return "ON " if value else "OFF"

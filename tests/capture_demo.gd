extends SceneTree

# Visual A/B harness: renders the reference scene with a chosen backend at 16:9
# into a PNG, so Raster and Compute output can be compared numerically.
#
# It deliberately uses tests/ab_reference.tscn rather than samples/demo.tscn:
# a regression gate needs a minimal, deterministic scene, and the sample demo
# is an interactive sandbox with a moving light, a HUD and a startup bake.
#
#   godot --path . --script res://tests/capture_demo.gd -- <raster|compute> <out.png> [angle_deg]
#
# Needs a real window (it skips under --headless): both backends require a
# rendering device, and Compute additionally needs the scene's CompositorEffect.

var _vp: SubViewport
var _frames := 0
var _out := "/tmp/cmp.png"

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("CMP SKIP headless"); quit(0); return
	var a := OS.get_cmdline_user_args()
	var backend := a[0] if a.size() > 0 else "raster"
	_out = a[1] if a.size() > 1 else _out
	var angle: float = float(a[2]) if a.size() > 2 else 0.0

	ProjectSettings.set_setting("gdgs/rendering/backend", "Compute" if backend == "compute" else "Raster")
	load("res://addons/gdgs/runtime/render/backend/gaussian_backend_selector.gd").reset()

	_vp = SubViewport.new()
	_vp.size = Vector2i(640, 360)   # 16:9, non-square on purpose
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	# Same scene for both backends (identical env/camera/tonemap) so images are
	# pixel-comparable. Under the Raster backend the scene's CompositorEffect
	# no-ops (no compute manager instance), so it is safe to keep.
	var demo := (load("res://tests/ab_reference.tscn") as PackedScene).instantiate()
	_vp.add_child(demo)
	var cam := demo.get_node_or_null("Camera3D") as Camera3D
	if cam != null and angle != 0.0:
		_orbit(cam, angle)

	root.add_child(_vp)

func _orbit(cam: Camera3D, angle_deg: float) -> void:
	# orbit around the look target (0,0.5,0) about world Y; build the transform
	# directly (look_at needs the node inside the tree, which it isn't yet here)
	var target := Vector3(0, 0.5, 0)
	var r := 3.0
	var rad := deg_to_rad(angle_deg)
	var pos := target + Vector3(sin(rad) * r, 0.25, cos(rad) * r)
	cam.transform = Transform3D(Basis.looking_at(target - pos, Vector3.UP), pos)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 50:
		return false
	_vp.get_texture().get_image().save_png(_out)
	print("CMP saved ", _out)
	quit(0)
	return true

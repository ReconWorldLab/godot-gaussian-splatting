@tool
class_name GaussianCompositorEffect
extends CompositorEffect

const WORKGROUP_SIZE := 16
const MANAGER_SCRIPT := preload("res://addons/gdgs/runtime/render/compute/gaussian_render_manager.gd")
const DIRECT_TEXTURE_SHADER := preload("res://addons/gdgs/runtime/debug/shaders/direct_texture_overlay.gdshader")
const DIRECT_TEXTURE_OVERLAY_NAME := "_GdgsDirectTextureOverlay"
const DEFAULT_TEXTURE_USAGE_BITS := 0x18B

enum DisplayMode {
	COMPOSITOR,
	DIRECT_TEXTURE
}

enum DebugView {
	COMPOSITE,
	GS_ALPHA,
	GS_COLOR,
	GS_DEPTH,
	SCENE_DEPTH,
	DEPTH_REJECT_MASK
}

@export_range(0.0, 1.0, 0.001) var alpha_cutoff := 0.01
@export_range(0.0, 1.0, 0.001) var depth_bias := 0.05
@export_range(0.0, 1.0, 0.001) var depth_test_min_alpha := 0.05
@export_range(0.0, 1.0, 0.001) var depth_capture_alpha = 0.5
@export_enum("Compositor", "Direct Texture") var display_mode: int:
	set(value):
		_display_mode = clampi(value, DisplayMode.COMPOSITOR, DisplayMode.DIRECT_TEXTURE)
		if _display_mode != DisplayMode.DIRECT_TEXTURE:
			_queue_direct_texture_overlay_state(false, RID())
	get:
		return _display_mode
@export_enum("Composite", "GS Alpha", "GS Color", "GS Depth", "Scene Depth", "Depth Reject Mask") var debug_view: int = DebugView.COMPOSITE

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var depth_sampler: RID
var fallback_depth_texture: RID

var _display_mode := DisplayMode.COMPOSITOR
var _direct_texture_resource: Texture2DRD
var _overlay_mutex := Mutex.new()
var _overlay_sync_queued := false
var _overlay_pending_visible := false
var _overlay_pending_texture_rid := RID()

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(initialize_compute_shader)

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return

	_overlay_mutex.lock()
	_overlay_sync_queued = false
	_overlay_pending_visible = false
	_overlay_pending_texture_rid = RID()
	_overlay_mutex.unlock()

	if _direct_texture_resource != null:
		_direct_texture_resource.texture_rd_rid = RID()
		_direct_texture_resource = null

	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		var tree: SceneTree = main_loop
		if tree.root != null:
			var overlay := tree.root.get_node_or_null(DIRECT_TEXTURE_OVERLAY_NAME) as MeshInstance3D
			if overlay != null:
				overlay.queue_free()

	if rd != null:
		if fallback_depth_texture.is_valid():
			rd.free_rid(fallback_depth_texture)
		if pipeline.is_valid():
			rd.free_rid(pipeline)
		if shader.is_valid():
			rd.free_rid(shader)
		if depth_sampler.is_valid():
			rd.free_rid(depth_sampler)
	fallback_depth_texture = RID()
	pipeline = RID()
	shader = RID()
	depth_sampler = RID()

func _render_callback(_effect_callback_type: int, render_data: RenderData) -> void:
	var is_direct_texture_mode := display_mode == DisplayMode.DIRECT_TEXTURE
	if not is_direct_texture_mode and (not rd or not shader.is_valid() or not pipeline.is_valid()):
		_queue_direct_texture_overlay_state(false, RID())
		return

	var scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var scene_data: RenderSceneDataRD = render_data.get_render_scene_data()
	if scene_buffers == null or scene_data == null:
		_queue_direct_texture_overlay_state(false, RID())
		return

	var manager = MANAGER_SCRIPT.get_instance()
	if manager == null:
		_queue_direct_texture_overlay_state(false, RID())
		return

	var size: Vector2i = scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		_queue_direct_texture_overlay_state(false, RID())
		return

	var x_groups: int = 0
	var y_groups: int = 0
	if not is_direct_texture_mode:
		x_groups = int(ceili(size.x / float(WORKGROUP_SIZE)))
		y_groups = int(ceili(size.y / float(WORKGROUP_SIZE)))

	var direct_texture_visible := false
	for view in scene_buffers.get_view_count():
		var camera_data := _get_camera_data(scene_data, view)
		if camera_data.is_empty():
			continue

		var gsplat_result: Dictionary = manager.render_for_compositor(
			size,
			camera_data["transform"],
			camera_data["projection"],
			camera_data["world_position"],
			_get_depth_capture_alpha()
		)
		if gsplat_result.is_empty():
			continue

		var gsplat_texture: RID = gsplat_result.get("color_alpha_texture", RID())
		var gsplat_depth_texture: RID = gsplat_result.get("depth_texture", RID())
		if not gsplat_texture.is_valid() or not gsplat_depth_texture.is_valid():
			continue

		if is_direct_texture_mode:
			_queue_direct_texture_overlay_state(true, gsplat_texture)
			direct_texture_visible = true
			break

		var scene_tex: RID = scene_buffers.get_color_layer(view)
		if not scene_tex.is_valid() or not depth_sampler.is_valid():
			continue

		var use_scene_depth := _debug_view_needs_scene_depth(debug_view)
		var scene_depth_tex: RID = _get_scene_depth_texture(scene_buffers, view)
		if use_scene_depth and not scene_depth_tex.is_valid():
			continue
		if not scene_depth_tex.is_valid():
			scene_depth_tex = fallback_depth_texture
		if not scene_depth_tex.is_valid():
			continue

		var push_constants := PackedFloat32Array([
			size.x,
			size.y,
			alpha_cutoff,
			depth_bias,
			depth_test_min_alpha,
			float(debug_view),
			1.0 if use_scene_depth else 0.0,
			0.0
		] + _projection_to_column_major_floats(camera_data["projection"].inverse()))

		var scene_uniform := RDUniform.new()
		scene_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		scene_uniform.binding = 0
		scene_uniform.add_id(scene_tex)

		var gsplat_uniform := RDUniform.new()
		gsplat_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		gsplat_uniform.binding = 1
		gsplat_uniform.add_id(gsplat_texture)

		var gsplat_depth_uniform := RDUniform.new()
		gsplat_depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		gsplat_depth_uniform.binding = 2
		gsplat_depth_uniform.add_id(gsplat_depth_texture)

		var scene_depth_uniform := RDUniform.new()
		scene_depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		scene_depth_uniform.binding = 3
		scene_depth_uniform.add_id(depth_sampler)
		scene_depth_uniform.add_id(scene_depth_tex)

		var uniform_set: RID = UniformSetCacheRD.get_cache(shader, 0, [
			scene_uniform,
			gsplat_uniform,
			gsplat_depth_uniform,
			scene_depth_uniform
		])
		var compute_list: int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		rd.compute_list_set_push_constant(
			compute_list,
			push_constants.to_byte_array(),
			push_constants.size() * 4
		)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()

	if is_direct_texture_mode and not direct_texture_visible:
		_queue_direct_texture_overlay_state(false, RID())
	elif not is_direct_texture_mode:
		_queue_direct_texture_overlay_state(false, RID())

func _get_camera_data(scene_data: RenderSceneDataRD, view: int) -> Dictionary:
	if scene_data == null:
		return {}
	if not scene_data.has_method("get_cam_transform") or not scene_data.has_method("get_view_projection"):
		return {}
	var camera_transform: Transform3D = scene_data.get_cam_transform()
	var camera_projection: Projection = scene_data.get_view_projection(view)
	var world_position: Vector3 = camera_transform.origin

	return {
		"transform": camera_transform,
		"projection": camera_projection,
		"world_position": world_position
	}

func _get_scene_depth_texture(scene_buffers: RenderSceneBuffersRD, view: int) -> RID:
	if scene_buffers == null:
		return RID()

	if scene_buffers.has_method("has_texture") and scene_buffers.has_method("get_texture_slice") and scene_buffers.has_texture("render_buffers", "depth"):
		var depth_slice: RID = scene_buffers.get_texture_slice("render_buffers", "depth", view, 0, 1, 1)
		if depth_slice.is_valid():
			return depth_slice

	if scene_buffers.has_method("get_depth_layer"):
		return scene_buffers.get_depth_layer(view)

	return RID()

func _projection_to_column_major_floats(matrix: Projection) -> Array:
	return [
		matrix.x[0], matrix.x[1], matrix.x[2], matrix.x[3],
		matrix.y[0], matrix.y[1], matrix.y[2], matrix.y[3],
		matrix.z[0], matrix.z[1], matrix.z[2], matrix.z[3],
		matrix.w[0], matrix.w[1], matrix.w[2], matrix.w[3]
	]

func _get_depth_capture_alpha() -> float:
	if depth_capture_alpha == null:
		return 0.5
	return clampf(float(depth_capture_alpha), 0.0, 1.0)

func _debug_view_needs_scene_depth(view: int) -> bool:
	return view == DebugView.COMPOSITE or view == DebugView.SCENE_DEPTH or view == DebugView.DEPTH_REJECT_MASK

func initialize_compute_shader() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		return

	var glsl_file: RDShaderFile = load("res://addons/gdgs/runtime/compositor/shaders/gaussian_composite.glsl")
	if glsl_file == null:
		return

	shader = rd.shader_create_from_spirv(glsl_file.get_spirv())
	pipeline = rd.compute_pipeline_create(shader)
	var sampler_state := RDSamplerState.new()
	depth_sampler = rd.sampler_create(sampler_state)
	fallback_depth_texture = _create_fallback_depth_texture()

func _create_fallback_depth_texture() -> RID:
	if rd == null:
		return RID()

	var texture_format := RDTextureFormat.new()
	texture_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	texture_format.width = 1
	texture_format.height = 1
	texture_format.usage_bits = DEFAULT_TEXTURE_USAGE_BITS

	return rd.texture_create(
		texture_format,
		RDTextureView.new(),
		[PackedFloat32Array([1.0]).to_byte_array()]
	)

func _queue_direct_texture_overlay_state(visible: bool, texture_rid: RID) -> void:
	var next_visible := visible and texture_rid.is_valid()
	var next_texture_rid := texture_rid if next_visible else RID()

	_overlay_mutex.lock()
	var state_changed := _overlay_pending_visible != next_visible or _overlay_pending_texture_rid != next_texture_rid
	_overlay_pending_visible = next_visible
	_overlay_pending_texture_rid = next_texture_rid
	var should_queue := state_changed and not _overlay_sync_queued
	if should_queue:
		_overlay_sync_queued = true
	_overlay_mutex.unlock()

	if should_queue:
		call_deferred("_sync_direct_texture_overlay")

func _sync_direct_texture_overlay() -> void:
	var pending_visible := false
	var pending_texture_rid := RID()

	_overlay_mutex.lock()
	pending_visible = _overlay_pending_visible
	pending_texture_rid = _overlay_pending_texture_rid
	_overlay_sync_queued = false
	_overlay_mutex.unlock()

	var overlay := _ensure_direct_texture_overlay() if pending_visible else _get_direct_texture_overlay()
	if overlay == null:
		return

	var texture := _ensure_direct_texture_resource()
	if texture == null:
		return

	texture.texture_rd_rid = pending_texture_rid if pending_visible else RID()
	overlay.visible = pending_visible and pending_texture_rid.is_valid()

func _ensure_direct_texture_overlay() -> MeshInstance3D:
	var overlay := _get_direct_texture_overlay()
	if overlay != null:
		_configure_direct_texture_overlay(overlay)
		return overlay

	var tree := _get_scene_tree()
	if tree == null or tree.root == null:
		return null

	overlay = MeshInstance3D.new()
	overlay.name = DIRECT_TEXTURE_OVERLAY_NAME
	overlay.visible = false
	tree.root.add_child(overlay)
	_configure_direct_texture_overlay(overlay)
	return overlay

func _configure_direct_texture_overlay(overlay: MeshInstance3D) -> void:
	if overlay == null:
		return

	var mesh := overlay.mesh as QuadMesh
	if mesh == null:
		mesh = QuadMesh.new()
	overlay.mesh = mesh
	mesh.flip_faces = true
	mesh.size = Vector2(2.0, 2.0)

	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	overlay.extra_cull_margin = 16384.0
	overlay.gi_mode = GeometryInstance3D.GI_MODE_DISABLED

	var material := overlay.get_active_material(0) as ShaderMaterial
	if material == null:
		material = ShaderMaterial.new()
	material.shader = DIRECT_TEXTURE_SHADER
	material.render_priority = 127
	material.set_shader_parameter("render_texture", _ensure_direct_texture_resource())
	overlay.set_surface_override_material(0, material)

func _ensure_direct_texture_resource() -> Texture2DRD:
	if _direct_texture_resource == null:
		_direct_texture_resource = Texture2DRD.new()
	return _direct_texture_resource

func _get_direct_texture_overlay() -> MeshInstance3D:
	var tree := _get_scene_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(DIRECT_TEXTURE_OVERLAY_NAME) as MeshInstance3D

func _free_direct_texture_overlay() -> void:
	if _direct_texture_resource != null:
		_direct_texture_resource.texture_rd_rid = RID()
		_direct_texture_resource = null

	var overlay := _get_direct_texture_overlay()
	if overlay != null:
		overlay.queue_free()

func _get_scene_tree() -> SceneTree:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		return main_loop
	return null

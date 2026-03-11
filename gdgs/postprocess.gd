@tool
class_name PostProcess
extends CompositorEffect

const WORKGROUP_SIZE := 16
const MANAGER_SCRIPT := preload("res://addons/gdgs/rendering/GaussianRenderManager.gd")

@export_range(0.0, 1.0, 0.001) var alpha_cutoff := 0.01
@export_range(0.0, 1.0, 0.001) var depth_bias := 0.05
@export_range(0.0, 1.0, 0.001) var depth_test_min_alpha := 0.05
@export_range(0.0, 1.0, 0.001) var depth_capture_alpha = 0.5
@export_enum("Composite", "GS Alpha", "GS Color", "GS Depth", "Scene Depth", "Depth Reject Mask") var debug_view := 0

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var depth_sampler: RID

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(initialize_compute_shader)

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if pipeline.is_valid():
		RenderingServer.free_rid(pipeline)
	if shader.is_valid():
		RenderingServer.free_rid(shader)
	if depth_sampler.is_valid():
		RenderingServer.free_rid(depth_sampler)

func _render_callback(_effect_callback_type: int, render_data: RenderData) -> void:
	if not rd or not shader.is_valid() or not pipeline.is_valid():
		return

	var scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var scene_data: RenderSceneDataRD = render_data.get_render_scene_data()
	if scene_buffers == null or scene_data == null:
		return

	var manager = MANAGER_SCRIPT.get_instance()
	if manager == null:
		return

	var size: Vector2i = scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return

	var x_groups: int = int(ceili(size.x / float(WORKGROUP_SIZE)))
	var y_groups: int = int(ceili(size.y / float(WORKGROUP_SIZE)))

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

		var scene_tex: RID = scene_buffers.get_color_layer(view)
		var scene_depth_tex: RID = _get_scene_depth_texture(scene_buffers, view)
		if not scene_tex.is_valid() or not scene_depth_tex.is_valid() or not depth_sampler.is_valid():
			continue

		var push_constants := PackedFloat32Array([
			size.x,
			size.y,
			alpha_cutoff,
			depth_bias,
			depth_test_min_alpha,
			float(debug_view),
			0.0,
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

func _get_camera_data(scene_data: RenderSceneDataRD, view: int) -> Dictionary:
	if scene_data == null:
		return {}
	if not scene_data.has_method("get_cam_transform") or not scene_data.has_method("get_cam_projection"):
		return {}

	var camera_transform: Transform3D = scene_data.get_cam_transform()
	var camera_projection: Projection = scene_data.get_cam_projection()
	var world_position: Vector3 = camera_transform.origin

	if scene_data.has_method("get_view_eye_offset"):
		world_position += scene_data.get_view_eye_offset(view)

	return {
		"transform": camera_transform,
		"projection": camera_projection,
		"world_position": world_position
	}

func _get_scene_depth_texture(scene_buffers: RenderSceneBuffersRD, view: int) -> RID:
	if scene_buffers == null:
		return RID()

	if scene_buffers.has_method("has_texture") and scene_buffers.has_texture("render_buffers", "depth"):
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

func initialize_compute_shader() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		return

	var glsl_file: RDShaderFile = load("res://addons/gdgs/post.glsl")
	if glsl_file == null:
		return

	shader = rd.shader_create_from_spirv(glsl_file.get_spirv())
	pipeline = rd.compute_pipeline_create(shader)
	var sampler_state := RDSamplerState.new()
	depth_sampler = rd.sampler_create(sampler_state)

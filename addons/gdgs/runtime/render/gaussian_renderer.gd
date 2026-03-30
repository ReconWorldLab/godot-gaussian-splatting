@tool
extends RefCounted
class_name GaussianRenderer

const RenderingDeviceContext := preload("res://addons/gdgs/runtime/render/gaussian_rendering_device_context.gd")
const RADIX := 256
const MAX_SORT_ELEMENTS_PER_SPLAT := 10

func render_for_compositor(
	state_cache: GaussianGpuStateCache,
	scene_registry: GaussianSceneRegistry,
	texture_size: Vector2i,
	camera_transform: Transform3D,
	camera_projection: Projection,
	camera_world_position: Vector3,
	depth_capture_alpha: float = 0.5
) -> Dictionary:
	state_cache.flush_pending_cleanup()

	if not scene_registry.has_gpu_data():
		if state_cache.has_render_states():
			state_cache.cleanup_all()
		return {}

	var point_count := scene_registry.get_point_count()
	var safe_size := Vector2i(maxi(texture_size.x, 1), maxi(texture_size.y, 1))
	var state = state_cache.get_or_create_render_state(safe_size)
	_update_camera_from_transform(state, camera_transform, camera_projection)
	state.camera_world_position = camera_world_position
	state.depth_capture_alpha = clampf(depth_capture_alpha, 0.0, 1.0)

	var unique_data_size := scene_registry.get_point_data_byte().size()

	if state.context == null or state.needs_gpu_rebuild:
		state_cache.rebuild_gpu_state(state, point_count, unique_data_size, scene_registry.get_instance_count())
	if state.context == null:
		return {}

	if state.needs_splat_upload:
		state_cache.upload_splats(state, scene_registry.get_point_data_byte(), scene_registry.get_splat_instance_ids_byte())
	if state.needs_instance_upload:
		state_cache.upload_instance_transforms(state, scene_registry.get_instance_transforms_byte())

	if state.camera_push_constants.is_empty():
		return {}

	_rasterize_state(state, point_count)
	if state.descriptors.has("render_texture") and state.descriptors.has("depth_texture"):
		return {
			"color_alpha_texture": state.descriptors["render_texture"].rid,
			"depth_texture": state.descriptors["depth_texture"].rid
		}
	return {}

func _rasterize_state(state, point_count: int) -> void:
	if state.context == null:
		return

	var uniforms := RenderingDeviceContext.create_push_constant([
		state.camera_world_position.x,
		state.camera_world_position.y,
		state.camera_world_position.z,
		Time.get_ticks_msec() * 1e-3,
		state.texture_size.x,
		state.texture_size.y,
		point_count,
		0
	])
	state.context.device.buffer_update(state.descriptors["uniforms"].rid, 0, 8 * 4, uniforms)
	state.context.device.buffer_clear(state.descriptors["histogram"].rid, 0, 4 + 4 * RADIX * 4)
	state.context.device.buffer_clear(state.descriptors["tile_bounds"].rid, 0, state.tile_dims.x * state.tile_dims.y * 2 * 4)

	var compute_list: int = state.context.compute_list_begin()
	state.pipelines["gsplat_projection"].call(state.context, compute_list, state.camera_push_constants)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	for radix_shift_pass in range(4):
		var sort_push_constant := RenderingDeviceContext.create_push_constant([
			radix_shift_pass,
			point_count * MAX_SORT_ELEMENTS_PER_SPLAT * (radix_shift_pass % 2),
			point_count * MAX_SORT_ELEMENTS_PER_SPLAT * (1 - (radix_shift_pass % 2))
		])
		state.pipelines["radix_sort_upsweep"].call(state.context, compute_list, sort_push_constant, [], state.descriptors["grid_dimensions"].rid, 0)
		state.pipelines["radix_sort_spine"].call(state.context, compute_list, sort_push_constant)
		state.pipelines["radix_sort_downsweep"].call(state.context, compute_list, sort_push_constant, [], state.descriptors["grid_dimensions"].rid, 0)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	state.pipelines["gsplat_boundaries"].call(state.context, compute_list, PackedByteArray(), [], state.descriptors["grid_dimensions"].rid, 3 * 4)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	state.pipelines["gsplat_render"].call(
		state.context,
		compute_list,
		RenderingDeviceContext.create_push_constant([0.0, -1, state.depth_capture_alpha, 0.0])
	)
	state.context.compute_list_end()

func _update_camera_from_transform(state, camera_transform: Transform3D, camera_projection: Projection) -> void:
	var view := Projection(camera_transform.affine_inverse())
	if view != state.camera_view or camera_projection != state.camera_projection:
		state.camera_view = view
		state.camera_projection = camera_projection
		state.camera_push_constants = RenderingDeviceContext.create_push_constant(
			_projection_to_column_major_floats(view) + _projection_to_column_major_floats(camera_projection)
		)

func _projection_to_column_major_floats(matrix: Projection) -> Array:
	return [
		matrix.x[0], matrix.x[1], matrix.x[2], matrix.x[3],
		matrix.y[0], matrix.y[1], matrix.y[2], matrix.y[3],
		matrix.z[0], matrix.z[1], matrix.z[2], matrix.z[3],
		matrix.w[0], matrix.w[1], matrix.w[2], matrix.w[3]
	]

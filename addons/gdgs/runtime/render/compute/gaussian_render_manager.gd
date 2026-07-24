@tool
extends Node
class_name GaussianRenderManager

const SceneRegistryScript := preload("res://addons/gdgs/runtime/render/compute/gaussian_scene_registry.gd")
const GpuStateCacheScript := preload("res://addons/gdgs/runtime/render/compute/gaussian_gpu_state_cache.gd")
const RendererScript := preload("res://addons/gdgs/runtime/render/compute/gaussian_renderer.gd")

static var _instance

var _scene_registry: GaussianSceneRegistry = SceneRegistryScript.new()
var _gpu_state_cache: GaussianGpuStateCache = GpuStateCacheScript.new()
var _renderer: GaussianRenderer = RendererScript.new()

static func get_instance():
	if _instance != null and is_instance_valid(_instance):
		return _instance
	return null

func _enter_tree() -> void:
	_instance = self

func _exit_tree() -> void:
	if _instance == self:
		_instance = null

func register_splat_node(node: Node) -> void:
	_apply_registry_result(_scene_registry.register_splat_node(node))

func unregister_splat_node(node: Node) -> void:
	_apply_registry_result(_scene_registry.unregister_splat_node(node))

func mark_resource_dirty(node: Node) -> void:
	_apply_registry_result(_scene_registry.mark_resource_dirty(node))

func mark_transform_dirty(node: Node) -> void:
	_apply_registry_result(_scene_registry.mark_transform_dirty(node))

func shutdown() -> void:
	if not _gpu_state_cache.has_render_states():
		return
	RenderingServer.call_on_render_thread(_cleanup_on_render_thread)

func render_for_compositor(
	texture_size: Vector2i,
	camera_transform: Transform3D,
	camera_projection: Projection,
	camera_world_position: Vector3,
	depth_capture_alpha: float = 0.5
) -> Dictionary:
	return _renderer.render_for_compositor(
		_gpu_state_cache,
		_scene_registry,
		texture_size,
		camera_transform,
		camera_projection,
		camera_world_position,
		depth_capture_alpha
	)

func _cleanup_on_render_thread() -> void:
	_gpu_state_cache.cleanup_all()

func _apply_registry_result(result: Dictionary) -> void:
	if result.is_empty():
		return
	if result.get("request_cleanup", false):
		_gpu_state_cache.request_cleanup()
	if result.has("require_gpu_rebuild") and bool(result["require_gpu_rebuild"]):
		_gpu_state_cache.mark_all_render_states_needs_gpu_rebuild()
	if result.has("require_splat_upload") and bool(result["require_splat_upload"]):
		_gpu_state_cache.mark_all_render_states_needs_splat_upload(true)
	if result.has("require_instance_upload") and bool(result["require_instance_upload"]):
		_gpu_state_cache.mark_all_render_states_needs_instance_upload(true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _gpu_state_cache.has_render_states():
		RenderingServer.call_on_render_thread(_cleanup_on_render_thread)

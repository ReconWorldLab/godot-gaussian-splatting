@tool
extends "res://addons/gdgs/runtime/render/backend/gaussian_render_backend.gd"

## Compute backend: thin adapter over the existing tile-based render manager.
##
## It owns the on-demand `_GdgsGaussianRenderManager` node at the scene root and
## routes the abstract lifecycle events to the manager's original API. The
## manager, its GPU state cache, the CompositorEffect, and the debug overlay are
## all Compute-only; this adapter is the seam that keeps GaussianSplatNode
## unaware of them.
##
## This backend loads its manager script through the selector, so deleting
## `render/raster/` leaves it untouched. Its own dependency on the manager is a
## preload of a sibling under render/; deleting the Compute path is what disables
## this backend (the selector falls back to Raster).

const MANAGER_SCRIPT := preload("res://addons/gdgs/runtime/render/compute/gaussian_render_manager.gd")
const MANAGER_NODE_NAME := "_GdgsGaussianRenderManager"
const MANAGER_PENDING_META := "_gdgs_manager_pending"

func get_display_name() -> String:
	return "Compute"

func initialize(_tree: SceneTree) -> Dictionary:
	# The Compute path needs a RenderingDevice (Forward+/Mobile). The selector
	# already routes Auto to this backend only where compute can run, but keep a
	# guard so an explicit "Compute" on a GL Compatibility project fails cleanly
	# and falls back rather than spamming render-thread errors.
	if RenderingServer.get_rendering_device() == null:
		return {"ok": false, "reason": "no RenderingDevice (compute unavailable on this renderer)"}
	return {"ok": true}

func attach_node(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not node.is_inside_tree() or node.is_queued_for_deletion():
		return
	var manager := _ensure_manager(node)
	if manager != null and manager.has_method("register_splat_node"):
		manager.register_splat_node(node)
	elif manager == null:
		# Manager creation is deferred (add_child on the root); retry next frame
		# until it exists. The is_inside_tree guard above stops the retry loop if
		# the node leaves the tree in the meantime.
		call_deferred("attach_node", node)

func detach_node(node: Node) -> void:
	var manager := _get_manager(node)
	if manager != null and manager.has_method("unregister_splat_node"):
		manager.unregister_splat_node(node)

func notify_resource_changed(node: Node) -> void:
	var manager := _get_manager(node)
	if manager != null and manager.has_method("mark_resource_dirty"):
		manager.mark_resource_dirty(node)

func notify_transform_changed(node: Node) -> void:
	var manager := _get_manager(node)
	if manager != null and manager.has_method("mark_transform_dirty"):
		manager.mark_transform_dirty(node)

## The baked records live in the merged splat buffer, so a changed bake needs
## the same scene re-sync a changed GaussianResource does.
func notify_lighting_changed(node: Node) -> void:
	var manager := _get_manager(node)
	if manager != null and manager.has_method("mark_resource_dirty"):
		manager.mark_resource_dirty(node)

func shutdown() -> void:
	# Best-effort: the manager also frees GPU state on its own PREDELETE, but a
	# selector-driven shutdown should release it eagerly.
	var manager := _get_manager_from_main_loop()
	if manager != null and manager.has_method("shutdown"):
		manager.shutdown()

func _ensure_manager(node: Node) -> Node:
	var tree: SceneTree = node.get_tree()
	if tree == null or tree.root == null:
		return null

	var root: Node = tree.root
	var manager := root.get_node_or_null(MANAGER_NODE_NAME)
	if manager != null:
		return manager

	if root.has_meta(MANAGER_PENDING_META):
		return null

	root.set_meta(MANAGER_PENDING_META, true)
	manager = MANAGER_SCRIPT.new()
	manager.name = MANAGER_NODE_NAME
	root.call_deferred("add_child", manager)
	root.call_deferred("remove_meta", MANAGER_PENDING_META)
	return null

func _get_manager(node: Node) -> Node:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return null
	var tree: SceneTree = node.get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(MANAGER_NODE_NAME)

func _get_manager_from_main_loop() -> Node:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		var tree: SceneTree = main_loop
		if tree.root != null:
			return tree.root.get_node_or_null(MANAGER_NODE_NAME)
	return null

@tool
extends RefCounted

## Abstract rendering-backend interface.
##
## gdgs supports two interchangeable rendering backends selected once at startup
## (see CLAUDE.md): the tile-based Compute rasterizer and the sorted-quad Raster
## rasterizer. Both implement this interface; a GaussianSplatNode only ever talks
## to the resolved backend through the GaussianBackendSelector and never knows
## which one is active.
##
## The interface is deliberately just the lifecycle events the node already emits
## and carries no per-frame tick: each backend drives its own frame work
## (Compute through its render manager, Raster through its own driver node).
##
## Subclasses must not depend on each other. Their only shared dependencies are
## GaussianResource (read-only) and this interface.

## Human-readable backend name, used in log messages ("Compute" / "Raster").
func get_display_name() -> String:
	return "Abstract"

## Fault-isolating self-test, run once by the selector before the backend is
## used. Return a result dictionary with an "ok" key; on failure include a
## "reason" string so the selector can log it and fall back to the other backend.
## The scene tree is passed for backends that need to probe render state; it may
## be null when resolution happens outside the tree.
func initialize(_tree: SceneTree) -> Dictionary:
	return {"ok": true}

## A node entered the tree with (potentially) a resource assigned.
func attach_node(_node: Node) -> void:
	pass

## A node is leaving the tree; release any per-node state.
func detach_node(_node: Node) -> void:
	pass

## The node's assigned GaussianResource changed (or its contents changed).
func notify_resource_changed(_node: Node) -> void:
	pass

## The node's global transform or visibility changed.
func notify_transform_changed(_node: Node) -> void:
	pass

## The node's assigned lighting bake changed. Separate from
## notify_resource_changed because it is far cheaper to honour: only the
## relighting data is stale, not the splat buffers or data textures. Backends
## that rebuild relight state on their own tick can leave this a no-op.
func notify_lighting_changed(_node: Node) -> void:
	pass

## Free all GPU/thread state owned by the backend. Best-effort; safe to call
## when nothing was ever attached.
func shutdown() -> void:
	pass

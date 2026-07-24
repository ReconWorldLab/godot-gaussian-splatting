@tool
extends RefCounted

## Backend selector: resolves the `gdgs/rendering/backend` project setting once
## per session and hands every GaussianSplatNode the same active backend.
##
## Startup-only by design (see CLAUDE.md decisions log): the setting is read on
## the first request and the resolved backend is cached for the whole session.
## Changing the setting takes effect on the next editor/game restart. There is no
## runtime switching API and no per-node override.
##
## Both backends are loaded through guarded paths, never cross-preloaded, so
## deleting `render/raster/` leaves Compute working and vice versa. If the chosen
## backend fails its self-test the selector logs a warning and falls back to the
## other; if both fail it returns null and rendering is skipped without crashing.

const SETTING_KEY := "gdgs/rendering/backend"

const BACKEND_AUTO := "Auto"
const BACKEND_COMPUTE := "Compute"
const BACKEND_RASTER := "Raster"

const COMPUTE_BACKEND_PATH := "res://addons/gdgs/runtime/render/compute/gaussian_compute_backend.gd"
const RASTER_BACKEND_PATH := "res://addons/gdgs/runtime/render/raster/raster_render_backend.gd"

static var _resolved_backend: RefCounted = null
static var _resolution_done := false

## Returns the active backend for the session, resolving it on first call.
## `context_node` supplies a SceneTree for backend self-tests; it may be null.
## Returns null only if every candidate backend failed to initialize.
static func get_backend(context_node: Node) -> RefCounted:
	if _resolution_done:
		return _resolved_backend
	_resolution_done = true
	var tree: SceneTree = null
	if context_node != null and context_node.is_inside_tree():
		tree = context_node.get_tree()
	_resolved_backend = _resolve(tree)
	return _resolved_backend

## Test/utility hook: forget the cached backend so the next get_backend re-reads
## the setting. Not part of the runtime flow (selection is startup-only).
static func reset() -> void:
	if _resolved_backend != null and _resolved_backend.has_method("shutdown"):
		_resolved_backend.shutdown()
	_resolved_backend = null
	_resolution_done = false

static func _resolve(tree: SceneTree) -> RefCounted:
	if _is_headless():
		# No display server and no RenderingDevice: nothing renders regardless of
		# backend. Stay quiet (import, CI, headless tooling) instead of emitting
		# fallback warnings for an expected condition. A GL Compatibility project
		# also has a null RenderingDevice but is NOT headless, so it still runs the
		# normal selection below and correctly prefers Raster.
		print("[gdgs] headless environment: rendering backend selection skipped")
		return null
	var setting := _read_setting()
	for kind in _candidate_order(setting):
		var backend := _instantiate(kind)
		if backend == null:
			continue
		var result: Dictionary = backend.initialize(tree)
		if bool(result.get("ok", false)):
			print("[gdgs] rendering backend: %s" % backend.get_display_name())
			return backend
		push_warning("[gdgs] backend '%s' failed self-test: %s" % [
			kind, str(result.get("reason", "unknown"))
		])
	push_warning("[gdgs] no rendering backend available; splats will not render")
	return null

static func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"

static func _read_setting() -> String:
	var value := str(ProjectSettings.get_setting(SETTING_KEY, BACKEND_AUTO))
	match value:
		BACKEND_COMPUTE, BACKEND_RASTER:
			return value
		_:
			return BACKEND_AUTO

## Candidate order encodes the fallback policy: an explicit choice is tried
## first, then the other backend; Auto picks by renderer, preferring Compute
## where compute shaders can run and Raster elsewhere.
static func _candidate_order(setting: String) -> Array:
	match setting:
		BACKEND_COMPUTE:
			return [BACKEND_COMPUTE, BACKEND_RASTER]
		BACKEND_RASTER:
			return [BACKEND_RASTER, BACKEND_COMPUTE]
		_:
			if _compute_preferred():
				return [BACKEND_COMPUTE, BACKEND_RASTER]
			return [BACKEND_RASTER, BACKEND_COMPUTE]

## Auto prefers Compute on Forward+ with a RenderingDevice (preserving current
## behavior for existing projects); Mobile/Compatibility prefer Raster.
static func _compute_preferred() -> bool:
	if RenderingServer.get_rendering_device() == null:
		return false
	var method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus"))
	return method == "forward_plus"

static func _instantiate(kind: String) -> RefCounted:
	var path := ""
	match kind:
		BACKEND_COMPUTE:
			path = COMPUTE_BACKEND_PATH
		BACKEND_RASTER:
			path = RASTER_BACKEND_PATH
		_:
			return null
	# Guarded load (not preload) so a missing/broken sibling backend folder is a
	# graceful skip, not a parse error in this selector.
	if not ResourceLoader.exists(path, "Script"):
		return null
	var script: Variant = load(path)
	if script == null or not (script is GDScript):
		return null
	var gdscript := script as GDScript
	if not gdscript.can_instantiate():
		push_warning("[gdgs] backend script '%s' failed to compile; skipping" % path)
		return null
	var instance: Variant = gdscript.new()
	if not (instance is RefCounted):
		return null
	return instance

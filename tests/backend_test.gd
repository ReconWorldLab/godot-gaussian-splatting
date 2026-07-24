extends SceneTree

## Headless tests for the rendering-backend selector: fallback policy and the
## guarded, decoupled loading that lets either backend folder be deleted without
## breaking the other. Pure logic (no GPU), so it runs in CI.
##
##   godot --headless --path . --script tests/backend_test.gd

const Selector := preload("res://addons/gdgs/runtime/render/backend/gaussian_backend_selector.gd")

const INTERFACE_METHODS := [
	"attach_node", "detach_node", "notify_resource_changed",
	"notify_transform_changed", "shutdown", "get_display_name", "initialize",
]

var _failures: PackedStringArray = []

func _initialize() -> void:
	_test_candidate_order_fallback()
	_test_guarded_instantiation()
	_test_backends_implement_interface()

	if _failures.is_empty():
		print("backend tests passed")
		quit(0)
	else:
		for f in _failures:
			push_error("backend test: %s" % f)
		print("backend tests FAILED (%d)" % _failures.size())
		quit(1)

func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)

func _test_candidate_order_fallback() -> void:
	# Explicit choice is tried first, then the other backend (fallback).
	_check(Selector._candidate_order("Compute") == ["Compute", "Raster"],
		"Compute order wrong: %s" % str(Selector._candidate_order("Compute")))
	_check(Selector._candidate_order("Raster") == ["Raster", "Compute"],
		"Raster order wrong: %s" % str(Selector._candidate_order("Raster")))
	# Auto resolves to both, in some order.
	var auto := Selector._candidate_order("Auto")
	_check(auto.size() == 2 and auto.has("Compute") and auto.has("Raster"),
		"Auto order wrong: %s" % str(auto))

func _test_guarded_instantiation() -> void:
	# Present backends instantiate; a missing one guard-loads to null (this is
	# what makes "delete render/raster/ and Compute still works" hold, and vice
	# versa: _resolve() skips the null and falls through to the other candidate).
	_check(Selector._instantiate("Compute") != null, "Compute backend did not instantiate")
	_check(Selector._instantiate("Raster") != null, "Raster backend did not instantiate")
	_check(Selector._instantiate("Bogus") == null, "unknown backend should be null")

func _test_backends_implement_interface() -> void:
	for kind in ["Compute", "Raster"]:
		var backend: Variant = Selector._instantiate(kind)
		if backend == null:
			_failures.append("%s backend missing" % kind)
			continue
		for method in INTERFACE_METHODS:
			_check(backend.has_method(method), "%s backend missing %s()" % [kind, method])
		_check(str(backend.get_display_name()) == kind,
			"%s backend display name is %s" % [kind, str(backend.get_display_name())])

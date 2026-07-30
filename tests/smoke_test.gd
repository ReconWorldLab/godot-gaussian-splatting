extends SceneTree

## CI smoke test: verifies that the plugin scripts parse, the demo asset
## imports into a non-empty GaussianResource, and both bundled scenes load.
## Run after importing the project:
##   godot --headless --path . --import
##   godot --headless --path . --script tests/smoke_test.gd

func _initialize() -> void:
	var failures: PackedStringArray = []

	# The A/B fixture is the scene that still wires a resource statically, so
	# it is what an "is the import chain healthy" check can assert against.
	# samples/demo.tscn builds itself in code and has no children until _ready.
	var reference: PackedScene = load("res://tests/ab_reference.tscn")
	if reference == null:
		failures.append("failed to load tests/ab_reference.tscn")
	else:
		var reference_root := reference.instantiate()
		if reference_root == null:
			failures.append("failed to instantiate the reference scene")
		else:
			var splat := reference_root.get_node_or_null("GaussianSplat")
			var gaussian: Resource = splat.get("gaussian") if splat != null else null
			if gaussian == null:
				failures.append("reference scene has no gaussian resource assigned")
			elif int(gaussian.get("point_count")) <= 0:
				failures.append("imported gaussian resource is empty")
			reference_root.free()

	# The demo only has to load and instantiate; it wires itself up on _ready,
	# which needs a display server this test does not have.
	var demo: PackedScene = load("res://samples/demo.tscn")
	if demo == null:
		failures.append("failed to load samples/demo.tscn")
	else:
		var demo_root := demo.instantiate()
		if demo_root == null:
			failures.append("failed to instantiate the demo scene")
		else:
			if demo_root.get_script() == null:
				failures.append("demo scene has no script attached")
			demo_root.free()

	if failures.is_empty():
		print("smoke test passed")
		quit(0)
	else:
		for failure in failures:
			push_error("smoke test: %s" % failure)
		quit(1)

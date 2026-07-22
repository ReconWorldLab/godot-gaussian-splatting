extends SceneTree

## CI smoke test: verifies that the plugin scripts parse, the demo asset
## imports into a non-empty GaussianResource, and the demo scene loads.
## Run after importing the project:
##   godot --headless --path . --import
##   godot --headless --path . --script tests/smoke_test.gd

func _initialize() -> void:
	var failures: PackedStringArray = []

	var scene: PackedScene = load("res://samples/demo.tscn")
	if scene == null:
		failures.append("failed to load samples/demo.tscn")
	else:
		var demo_root := scene.instantiate()
		if demo_root == null:
			failures.append("failed to instantiate demo scene")
		else:
			var splat := demo_root.get_node_or_null("GaussianSplat")
			var gaussian: Resource = splat.get("gaussian") if splat != null else null
			if gaussian == null:
				failures.append("demo scene has no gaussian resource assigned")
			elif int(gaussian.get("point_count")) <= 0:
				failures.append("imported gaussian resource is empty")
			demo_root.free()

	if failures.is_empty():
		print("smoke test passed")
		quit(0)
	else:
		for failure in failures:
			push_error("smoke test: %s" % failure)
		quit(1)

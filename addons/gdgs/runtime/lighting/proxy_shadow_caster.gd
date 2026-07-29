@tool
extends RefCounted

## Mounts a baked lighting proxy as a shadow-only MeshInstance3D.
##
## This is the one half of "let Godot do the lighting" that is genuinely free:
## a MeshInstance3D with `cast_shadow = SHADOWS_ONLY` is invisible to the
## camera but still writes into every light's shadow map, so a Gaussian scene
## casts real shadows onto ordinary Godot geometry. It works identically under
## both rendering backends because it is an ordinary scene mesh and has nothing
## to do with how splats are drawn.
##
## What it does NOT do is light the splats: Godot computes the proxy's own
## shading into the frame buffer and there is no API to read that back. Splats
## receiving light is the light rig's job (Phase R2+).
##
## Backend-agnostic and deletable: `gaussian_splat_node.gd` guarded-`load()`s
## this file, so removing `runtime/lighting/` only drops the shadow caster.

const CASTER_NAME := "_GdgsLightingProxy"
## The proxy hull tracks the splat cloud, whose own AABB is already used for
## culling; a generous margin keeps it from being culled while its shadow is
## still on screen.
const EXTRA_CULL_MARGIN := 16384.0


## Creates, refreshes or removes the caster so it matches (lighting, enabled).
## Safe to call repeatedly; rebuilds the ArrayMesh only when the source
## resource actually changed. `node` must be inside the tree.
static func sync(node: Node3D, lighting: Object, enabled: bool) -> void:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return
	var mesh: ArrayMesh = null
	if enabled and lighting != null and is_instance_valid(lighting):
		if lighting.has_method("build_proxy_mesh") and bool(lighting.call("has_proxy_mesh")):
			mesh = lighting.call("build_proxy_mesh")
	if mesh == null:
		clear(node)
		return

	var caster := _find(node)
	if caster == null:
		caster = MeshInstance3D.new()
		caster.name = CASTER_NAME
		# Internal child: never persisted to the user's scene, hidden from the
		# scene tree dock, and inherits the node's transform and visibility.
		node.add_child(caster, false, Node.INTERNAL_MODE_BACK)
	caster.transform = Transform3D.IDENTITY
	caster.mesh = mesh
	caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	caster.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	caster.extra_cull_margin = EXTRA_CULL_MARGIN


static func clear(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		return
	var caster := _find(node)
	if caster != null:
		caster.queue_free()


static func _find(node: Node3D) -> MeshInstance3D:
	return node.get_node_or_null(NodePath(CASTER_NAME)) as MeshInstance3D

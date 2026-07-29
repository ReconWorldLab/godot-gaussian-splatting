@tool
extends RefCounted

## Gathers the scene's Light3D nodes into shader-ready world-space arrays.
##
## Relighting evaluates lights per splat in the vertex/projection stage rather
## than per fragment, so the light set has to arrive as plain uniforms instead
## of Godot's own clustered light buffers (which a custom shader cannot read).
## This is that packing, shared by every GaussianSplatNode in the scene.
##
## World space, not node-local: a node-local packing would save the shader one
## mat3 multiply, but distances — and therefore range attenuation — come out
## wrong the moment a node is scaled. The shader already builds `object_linear`
## for the covariance projection, so rotating the baked normal into world space
## is nearly free, and one packing then serves every node.
##
## Attenuation reproduces Godot's own `get_omni_attenuation` and spot cone
## falloff so a light looks the same on splats as it does on the mesh next to
## them. Keep the shader copies in parity with the comments here.
##
## Nothing recomputes while nothing moves: `update()` repacks every frame but
## only bumps `version` when a value actually changed, and callers upload only
## on a version change.

## Must match the array size declared in gaussian_raster.gdshader (and any
## other consumer). Changing it means editing both.
const MAX_LIGHTS := 8

const TYPE_DIRECTIONAL := 0.0
const TYPE_OMNI := 1.0
const TYPE_SPOT := 2.0

## Rediscovering Light3D nodes walks the scene, so it happens on an interval
## rather than every frame; a newly added light appears within this many frames.
## Cached lights are re-read every frame, so moving one is picked up at once.
const RESCAN_INTERVAL_FRAMES := 30
## Guard against pathological scenes; the walk stops after this many nodes.
const MAX_VISITED_NODES := 20000

var version: int = 0
var light_count: int = 0
var vectors: PackedVector3Array = PackedVector3Array()
var colors: PackedColorArray = PackedColorArray()
var params: PackedColorArray = PackedColorArray()
var spot_directions: PackedVector3Array = PackedVector3Array()

var _lights: Array = []
var _frames_since_scan := RESCAN_INTERVAL_FRAMES
var _warned_overflow := false


func _init() -> void:
	_reset_arrays()


## Re-reads the cached lights (rescanning the scene periodically) and repacks.
## Returns true when the packed data changed, i.e. when callers should upload.
func update(context: Node) -> bool:
	_frames_since_scan += 1
	if _frames_since_scan >= RESCAN_INTERVAL_FRAMES or _has_stale_light():
		_frames_since_scan = 0
		_rescan(context)

	var next_vectors := PackedVector3Array()
	var next_colors := PackedColorArray()
	var next_params := PackedColorArray()
	var next_spots := PackedVector3Array()
	next_vectors.resize(MAX_LIGHTS)
	next_colors.resize(MAX_LIGHTS)
	next_params.resize(MAX_LIGHTS)
	next_spots.resize(MAX_LIGHTS)

	var count := 0
	for light_variant: Variant in _lights:
		if count >= MAX_LIGHTS:
			break
		var light: Light3D = light_variant
		if not _is_active(light):
			continue
		_pack(light, count, next_vectors, next_colors, next_params, next_spots)
		count += 1

	if (count == light_count and next_vectors == vectors and next_colors == colors
			and next_params == params and next_spots == spot_directions):
		return false
	light_count = count
	vectors = next_vectors
	colors = next_colors
	params = next_params
	spot_directions = next_spots
	version += 1
	return true


## Pushes the packed arrays onto a material (the Raster path). Always writes
## full-size arrays; `light_count` bounds the shader's loop, so trailing slots
## are ignored.
func apply(material: ShaderMaterial) -> void:
	if material == null:
		return
	material.set_shader_parameter("light_count", light_count)
	material.set_shader_parameter("light_vectors", vectors)
	material.set_shader_parameter("light_colors", colors)
	material.set_shader_parameter("light_params", params)
	material.set_shader_parameter("light_spot_directions", spot_directions)


## Flat float layout for the Compute path's storage buffer: four vec4 per light
## in the same order the Raster shader's four uniform arrays hold them, so the
## two shaders read identical numbers. Always MAX_LIGHTS entries long.
##
##   [i*16 +  0..3] direction to light (directional) or world position, w unused
##   [i*16 +  4..7] colour * energy, w = type (0 directional, 1 omni, 2 spot)
##   [i*16 +  8..11] 1/range, decay, cos(spot angle), spot angle attenuation
##   [i*16 + 12..15] direction the light travels (spot cone axis), w unused
func to_packed_floats() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(MAX_LIGHTS * 16)
	for index in MAX_LIGHTS:
		var base := index * 16
		var vector := vectors[index]
		var tint := colors[index]
		var setup := params[index]
		var spot := spot_directions[index]
		out[base + 0] = vector.x
		out[base + 1] = vector.y
		out[base + 2] = vector.z
		out[base + 4] = tint.r
		out[base + 5] = tint.g
		out[base + 6] = tint.b
		out[base + 7] = tint.a
		out[base + 8] = setup.r
		out[base + 9] = setup.g
		out[base + 10] = setup.b
		out[base + 11] = setup.a
		out[base + 12] = spot.x
		out[base + 13] = spot.y
		out[base + 14] = spot.z
	return out


func _pack(
	light: Light3D,
	index: int,
	out_vectors: PackedVector3Array,
	out_colors: PackedColorArray,
	out_params: PackedColorArray,
	out_spots: PackedVector3Array
) -> void:
	var basis := light.global_transform.basis
	# Godot lights point down their local -Z, so the direction *to* the light is
	# +Z and the direction light travels is -Z.
	var to_light := basis.z.normalized()
	var travel := -to_light
	var energy := light.light_energy
	if light.light_negative:
		energy = -energy
	var tint := light.light_color

	var type := TYPE_DIRECTIONAL
	var vector := to_light
	var range_value := 0.0
	var decay := 0.0
	var cone_cosine := -1.0
	var cone_attenuation := 1.0

	if light is OmniLight3D:
		var omni := light as OmniLight3D
		type = TYPE_OMNI
		vector = light.global_transform.origin
		range_value = omni.omni_range
		decay = omni.omni_attenuation
	elif light is SpotLight3D:
		var spot := light as SpotLight3D
		type = TYPE_SPOT
		vector = light.global_transform.origin
		range_value = spot.spot_range
		decay = spot.spot_attenuation
		cone_cosine = cos(deg_to_rad(clampf(spot.spot_angle, 0.0, 89.9)))
		cone_attenuation = spot.spot_angle_attenuation

	out_vectors[index] = vector
	out_colors[index] = Color(tint.r * energy, tint.g * energy, tint.b * energy, type)
	out_params[index] = Color(
		1.0 / maxf(range_value, 0.001), decay, cone_cosine, cone_attenuation
	)
	out_spots[index] = travel


## Directional lights come first because they always reach the whole scene;
## the rest are ranked by a crude reach heuristic. Only the strongest
## MAX_LIGHTS survive.
func _rescan(context: Node) -> void:
	var root := _scene_root(context)
	_lights.clear()
	if root == null:
		return
	var found: Array = []
	_collect(root, found, [0])
	var directional: Array = []
	var positional: Array = []
	for light_variant: Variant in found:
		var light: Light3D = light_variant
		if light is DirectionalLight3D:
			directional.append(light)
		else:
			positional.append(light)
	positional.sort_custom(func(a: Light3D, b: Light3D) -> bool:
		return _reach(a) > _reach(b))
	_lights = directional + positional
	if _lights.size() > MAX_LIGHTS and not _warned_overflow:
		_warned_overflow = true
		push_warning(
			"[gdgs] relighting: %d lights in the scene, only the %d strongest affect splats"
			% [_lights.size(), MAX_LIGHTS]
		)


func _collect(node: Node, found: Array, budget: Array) -> void:
	budget[0] += 1
	if budget[0] > MAX_VISITED_NODES:
		return
	if node is Light3D:
		found.append(node)
	for child: Node in node.get_children():
		_collect(child, found, budget)


static func _reach(light: Light3D) -> float:
	var range_value := 1.0
	if light is OmniLight3D:
		range_value = (light as OmniLight3D).omni_range
	elif light is SpotLight3D:
		range_value = (light as SpotLight3D).spot_range
	return absf(light.light_energy) * range_value


## Deliberately does not test is_inside_tree(): a node parented into a tree
## still reports false until the tree goes live, which silently produced an
## empty rig in every harness that builds its scene by hand. Validity plus
## visibility plus non-zero energy is the real question.
static func _is_active(light: Light3D) -> bool:
	return (
		light != null and is_instance_valid(light)
		and light.is_visible_in_tree() and not is_zero_approx(light.light_energy)
	)


## Freed or unparented lights force an immediate rescan instead of waiting out
## the interval.
func _has_stale_light() -> bool:
	for light_variant: Variant in _lights:
		if not is_instance_valid(light_variant):
			return true
		if (light_variant as Node).get_parent() == null:
			return true
	return false


## In the editor the walk must start at the edited scene, not the editor's own
## root (which holds the whole editor UI). EditorInterface is resolved by name
## so exported builds never reference the class — same pattern as the Raster
## backend's editor-camera lookup.
##
## Everywhere else it walks up from the context node to its topmost ancestor.
## That is deliberately not `SceneTree.current_scene`: harnesses that build a
## tree by hand (the capture, preview and test scripts) leave `current_scene`
## pointing somewhere that does not contain the node, and the scan silently
## found no lights at all.
static func _scene_root(context: Node) -> Node:
	if context == null or not is_instance_valid(context):
		return null
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		var editor_interface := Engine.get_singleton("EditorInterface")
		if editor_interface != null and editor_interface.has_method("get_edited_scene_root"):
			var edited: Object = editor_interface.call("get_edited_scene_root")
			if edited is Node:
				return edited as Node
	var node := context
	while node.get_parent() != null:
		node = node.get_parent()
	return node


func _reset_arrays() -> void:
	vectors.resize(MAX_LIGHTS)
	colors.resize(MAX_LIGHTS)
	params.resize(MAX_LIGHTS)
	spot_directions.resize(MAX_LIGHTS)

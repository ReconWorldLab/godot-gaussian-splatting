@tool
extends EditorNode3DGizmoPlugin
class_name GaussianSplatGizmoPlugin

## Selection gizmo for GaussianSplatNode: draws the resource's AABB as a
## wireframe box. Deliberately no point-cloud preview — drawing every splat
## position as a point occludes the rendered splat itself.

const DEFAULT_COLOR := Color(0.2, 0.8, 1.0)

func _init() -> void:
	create_material("bounds", DEFAULT_COLOR)

func _get_gizmo_name() -> String: return "GaussianSplatNode"
func _get_priority() -> int: return 0
func _has_gizmo(node: Node3D) -> bool: return node is GaussianSplatNode

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	if node == null:
		return
	var gaussian: GaussianResource = node.gaussian
	if gaussian == null:
		return
	var aabb: AABB = gaussian.aabb
	if aabb.size == Vector3.ZERO:
		return

	# The 12 box edges: endpoints connected by an edge differ in exactly one
	# bit of their AABB.get_endpoint index.
	var lines := PackedVector3Array()
	for i in range(8):
		for bit in [1, 2, 4]:
			var j: int = i | bit
			if j != i:
				lines.append(aabb.get_endpoint(i))
				lines.append(aabb.get_endpoint(j))

	gizmo.add_lines(lines, get_material("bounds", gizmo))
	# Keep the node click-selectable in the viewport via its bounds edges.
	gizmo.add_collision_segments(lines)

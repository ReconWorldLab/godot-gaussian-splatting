@tool
extends RefCounted

## Builds the Raster backend's instanced base mesh: SPLATS_PER_INSTANCE quads.
##
## Each MultiMesh instance draws one base mesh, i.e. SPLATS_PER_INSTANCE
## consecutive splats, so the total blend order is instance-major then
## primitive-index — the order the transparent ROP pass is verified to preserve
## (see memory: raster draw-order gate). Vertex positions are placeholders; the
## shader writes clip-space POSITION directly. Each vertex carries its splat slot
## in UV.x (0..SPLATS_PER_INSTANCE-1) and its quad corner in UV.y (0..3).

const SPLATS_PER_INSTANCE := 128

static func build() -> ArrayMesh:
	var vertex_count := SPLATS_PER_INSTANCE * 4
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	verts.resize(vertex_count)
	uvs.resize(vertex_count)
	indices.resize(SPLATS_PER_INSTANCE * 6)

	for s in range(SPLATS_PER_INSTANCE):
		var vbase := s * 4
		for c in range(4):
			verts[vbase + c] = Vector3.ZERO       # overwritten by POSITION in vertex()
			uvs[vbase + c] = Vector2(float(s), float(c))
		var ibase := s * 6
		indices[ibase + 0] = vbase + 0
		indices[ibase + 1] = vbase + 1
		indices[ibase + 2] = vbase + 2
		indices[ibase + 3] = vbase + 0
		indices[ibase + 4] = vbase + 2
		indices[ibase + 5] = vbase + 3

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Base geometry sits at the origin; real extent comes from the POSITION
	# override, so give the mesh a large custom AABB to avoid frustum culling
	# (the instance also carries a big extra_cull_margin as a backstop).
	mesh.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	return mesh

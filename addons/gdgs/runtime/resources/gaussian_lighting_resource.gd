@tool
extends Resource
class_name GaussianLightingResource

## Baked lighting proxy for a GaussianResource (relighting, Phase R1).
##
## A splat stores radiance, not material: no normal, no albedo, no occlusion.
## This resource supplies the missing geometry, baked once in the editor from
## the same voxel field the collision module contours into a smooth mesh:
##
##   - `splat_data`: 4 bytes per splat — an octahedral outward normal (2×u8),
##     an ambient-occlusion term (u8) and a confidence (u8). Confidence is the
##     normalised surface-gradient magnitude, so floaters and deep-interior
##     splats (where no surface is defined) come out at 0 and the renderer can
##     fade them to flat ambient instead of lighting them with a bogus normal.
##   - `proxy_*`: the contoured smooth mesh with vertex normals, mounted at
##     runtime as a SHADOWS_ONLY MeshInstance3D so the Gaussian scene casts
##     real shadows onto ordinary Godot geometry.
##
## The GaussianResource blob is never touched: relighting is entirely additive
## and an unassigned/absent lighting resource renders exactly as before.
##
## This file lives in `runtime/resources/` — the data-contract layer — and not
## in `runtime/lighting/`, because `GaussianSplatNode` types an `@export`
## against it: `runtime/lighting/` must stay deletable, and deleting a class a
## script exports would break that script's parse.

const FORMAT_VERSION := 1
const BYTES_PER_SPLAT := 4

const OFFSET_NORMAL_X := 0
const OFFSET_NORMAL_Y := 1
const OFFSET_AO := 2
const OFFSET_CONFIDENCE := 3

@export var format_version: int = FORMAT_VERSION
## Splat count of the GaussianResource this was baked from; a mismatch means
## the bake is stale and must not be used.
@export var source_point_count: int = 0
@export var source_aabb: AABB = AABB()
## World-space voxel edge used for the bake; the effective lighting resolution.
@export var voxel_size: float = 0.0
## 4 bytes per splat: oct normal X, oct normal Y, AO, confidence.
@export var splat_data: PackedByteArray = PackedByteArray()
@export var proxy_positions: PackedVector3Array = PackedVector3Array()
@export var proxy_normals: PackedVector3Array = PackedVector3Array()
@export var proxy_indices: PackedInt32Array = PackedInt32Array()
## Provenance of the bake (voxel size, opacity cutoff, smoothing, AO settings).
@export var bake_settings: Dictionary = {}


## True when this bake describes the given GaussianResource. Duck-typed so this
## resource never hard-depends on the GaussianResource class.
func matches_source(gaussian: Object) -> bool:
	if gaussian == null or not is_instance_valid(gaussian):
		return false
	var count: Variant = gaussian.get("point_count")
	if typeof(count) != TYPE_INT or int(count) != source_point_count:
		return false
	return is_splat_data_valid()


func is_splat_data_valid() -> bool:
	return source_point_count > 0 and splat_data.size() == source_point_count * BYTES_PER_SPLAT


func has_proxy_mesh() -> bool:
	return (
		proxy_positions.size() >= 3
		and proxy_indices.size() >= 3
		and proxy_indices.size() % 3 == 0
		and proxy_normals.size() == proxy_positions.size()
	)


## Rebuilds the proxy ArrayMesh. Main-thread only (ArrayMesh is an engine
## Resource); returns null when no usable proxy geometry was baked.
func build_proxy_mesh() -> ArrayMesh:
	if not has_proxy_mesh():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = proxy_positions
	arrays[Mesh.ARRAY_NORMAL] = proxy_normals
	arrays[Mesh.ARRAY_INDEX] = proxy_indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mesh.get_surface_count() == 0:
		return null
	mesh.resource_name = "GDGS Lighting Proxy"
	return mesh


# --- per-splat record codec -------------------------------------------------
#
# Shared by the baker (writes) and the headless tests (reads); the shaders
# re-implement the decode side, which is why the encoding is kept trivial.


## Octahedral projection of a unit vector onto [-1, 1]². Normals carry a known
## outward sense (the mesher orients every triangle away from the solid
## interior), so the ~1° round-trip error of an 8-bit oct pair is invisible for
## diffuse lighting while costing a quarter of a float3.
static func oct_encode(normal: Vector3) -> Vector2:
	var l1 := absf(normal.x) + absf(normal.y) + absf(normal.z)
	if l1 <= 0.0:
		return Vector2.ZERO
	var p := Vector2(normal.x, normal.y) / l1
	if normal.z < 0.0:
		p = Vector2(
			(1.0 - absf(p.y)) * _non_zero_sign(p.x),
			(1.0 - absf(p.x)) * _non_zero_sign(p.y)
		)
	return p


static func oct_decode(encoded: Vector2) -> Vector3:
	var v := Vector3(encoded.x, encoded.y, 1.0 - absf(encoded.x) - absf(encoded.y))
	if v.z < 0.0:
		v = Vector3(
			(1.0 - absf(encoded.y)) * _non_zero_sign(encoded.x),
			(1.0 - absf(encoded.x)) * _non_zero_sign(encoded.y),
			v.z
		)
	if v.length_squared() <= 0.0:
		return Vector3(0.0, 0.0, 1.0)
	return v.normalized()


## [-1, 1] → u8 and back, used for the two oct components.
static func encode_signed_byte(value: float) -> int:
	return clampi(int(roundf((clampf(value, -1.0, 1.0) * 0.5 + 0.5) * 255.0)), 0, 255)


static func decode_signed_byte(value: int) -> float:
	return float(value) / 255.0 * 2.0 - 1.0


## [0, 1] → u8 and back, used for AO and confidence.
static func encode_unit_byte(value: float) -> int:
	return clampi(int(roundf(clampf(value, 0.0, 1.0) * 255.0)), 0, 255)


static func decode_unit_byte(value: int) -> float:
	return float(value) / 255.0


## Decodes one splat record into {normal, ao, confidence}. Convenience for
## tests and tooling; the render path decodes in the shader.
func read_splat(index: int) -> Dictionary:
	var base := index * BYTES_PER_SPLAT
	if index < 0 or base + BYTES_PER_SPLAT > splat_data.size():
		return {"normal": Vector3(0.0, 0.0, 1.0), "ao": 1.0, "confidence": 0.0}
	return {
		"normal": oct_decode(Vector2(
			decode_signed_byte(splat_data[base + OFFSET_NORMAL_X]),
			decode_signed_byte(splat_data[base + OFFSET_NORMAL_Y])
		)),
		"ao": decode_unit_byte(splat_data[base + OFFSET_AO]),
		"confidence": decode_unit_byte(splat_data[base + OFFSET_CONFIDENCE]),
	}


static func _non_zero_sign(value: float) -> float:
	# signf() returns 0 at 0, which would collapse an octahedron fold.
	return -1.0 if value < 0.0 else 1.0

extends RefCounted

## Transfers the proxy's surface field onto the splats: one 4-byte record per
## splat (octahedral outward normal, ambient occlusion, confidence).
##
## This is the whole point of the proxy. A splat has no normal; the field built
## from the same voxel occupancy the smooth mesh is contoured from has one
## everywhere, and a splat only needs an O(1) lookup to borrow it:
##
##   normal      = normalize(-∇surface)   (∇ points toward solid)
##   confidence  = |∇surface| / scale     (0 in open space and deep interiors)
##   ao          = openness just outside the surface, remapped so a flat wall
##                 reads 1.0 and a fully enclosed pocket reads 0.0
##
## Worker-safe and cancellable. This is a per-splat GDScript loop, which the
## load-time rule forbids — it is an editor-time bake on WorkerThreadPool
## behind a progress dialog, exactly like the collision voxelizer's own
## per-splat CPU pass. Budget roughly 1.5 µs/splat.

const RESOURCE_SCRIPT := preload("res://addons/gdgs/runtime/resources/gaussian_lighting_resource.gd")
const FIELD_SCRIPT := preload("res://addons/gdgs/lighting/bake/normal_field.gd")

const PROGRESS_INTERVAL := 65536
## How far outside the surface, in voxels, the AO neighbourhood is centred.
const AO_SAMPLE_OFFSET_VOXELS := 1.5

const DEFAULT_NORMAL := Vector3(0.0, 0.0, 1.0)


## Returns {ok, splat_data, stats} or {ok=false, error, cancelled}.
static func transfer(
	xyz: PackedVector3Array,
	field: Dictionary,
	settings: Dictionary,
	control: RefCounted = null
) -> Dictionary:
	var count := xyz.size()
	if count <= 0:
		return {"ok": false, "error": "No splat positions to transfer onto.", "cancelled": false}
	var surface: PackedByteArray = field.get("surface", PackedByteArray())
	var dims: Vector3i = field.get("dims", Vector3i.ZERO)
	if surface.size() != dims.x * dims.y * dims.z or surface.is_empty():
		return {"ok": false, "error": "Lighting field is missing or malformed.", "cancelled": false}

	var open: PackedByteArray = field.get("open", PackedByteArray())
	var has_ao := open.size() == surface.size()
	var ao_strength := clampf(float(settings.get("ao_strength", 1.0)), 0.0, 1.0)
	var origin: Vector3 = field.get("origin", Vector3.ZERO)
	var voxel_size: float = float(field.get("voxel_size", 1.0))
	if voxel_size <= 0.0:
		return {"ok": false, "error": "Lighting field has a non-positive voxel size.", "cancelled": false}
	var inverse_voxel := 1.0 / voxel_size

	var nx := dims.x
	var ny := dims.y
	var nz := dims.z
	var row_stride := nx
	var slice_stride := nx * ny
	# Central differences are taken on a clamped voxel so the six neighbour
	# reads never need bounds checks. The grid is padded to 4-voxel blocks
	# around the splats' 3σ bounds, so the clamped border layer holds no splats.
	var max_x := nx - 2
	var max_y := ny - 2
	var max_z := nz - 2
	if max_x < 1 or max_y < 1 or max_z < 1:
		return {"ok": false, "error": "Voxel grid is too small to derive surface normals.", "cancelled": false}

	var ao_offset := AO_SAMPLE_OFFSET_VOXELS * voxel_size
	var flat_openness := flat_openness_reference(int(settings.get("ao_radius", 3)), AO_SAMPLE_OFFSET_VOXELS)
	var confidence_scale := 1.0 / FIELD_SCRIPT.CONFIDENCE_GRADIENT_SCALE

	var splat_data := PackedByteArray()
	splat_data.resize(count * RESOURCE_SCRIPT.BYTES_PER_SPLAT)
	var surfaced := 0

	for index in count:
		if index % PROGRESS_INTERVAL == 0:
			if control != null and control.is_cancel_requested():
				return {"ok": false, "error": "Bake cancelled.", "cancelled": true}
			_progress(control, "Transferring surface normals onto splats", float(index) / float(count))

		var position: Vector3 = xyz[index]
		var local := (position - origin) * inverse_voxel
		var vx := clampi(int(floorf(local.x)), 1, max_x)
		var vy := clampi(int(floorf(local.y)), 1, max_y)
		var vz := clampi(int(floorf(local.z)), 1, max_z)
		var center := vx + vy * row_stride + vz * slice_stride

		# ∇surface points toward solid; the outward normal is its negation.
		var gradient := Vector3(
			float(surface[center + 1] - surface[center - 1]),
			float(surface[center + row_stride] - surface[center - row_stride]),
			float(surface[center + slice_stride] - surface[center - slice_stride])
		)
		var gradient_length := gradient.length()
		var normal := DEFAULT_NORMAL
		var confidence := 0.0
		if gradient_length > 0.0:
			normal = gradient / -gradient_length
			confidence = clampf(gradient_length * confidence_scale, 0.0, 1.0)
			if confidence > 0.0:
				surfaced += 1

		var ao := 1.0
		if has_ao and confidence > 0.0:
			var sample := (position + normal * ao_offset - origin) * inverse_voxel
			var sx := clampi(int(floorf(sample.x)), 0, nx - 1)
			var sy := clampi(int(floorf(sample.y)), 0, ny - 1)
			var sz := clampi(int(floorf(sample.z)), 0, nz - 1)
			var openness := 1.0 - float(open[sx + sy * row_stride + sz * slice_stride]) / 255.0
			ao = lerpf(1.0, clampf(openness / flat_openness, 0.0, 1.0), ao_strength)

		var encoded := RESOURCE_SCRIPT.oct_encode(normal)
		var base := index * RESOURCE_SCRIPT.BYTES_PER_SPLAT
		splat_data[base + RESOURCE_SCRIPT.OFFSET_NORMAL_X] = RESOURCE_SCRIPT.encode_signed_byte(encoded.x)
		splat_data[base + RESOURCE_SCRIPT.OFFSET_NORMAL_Y] = RESOURCE_SCRIPT.encode_signed_byte(encoded.y)
		splat_data[base + RESOURCE_SCRIPT.OFFSET_AO] = RESOURCE_SCRIPT.encode_unit_byte(ao)
		splat_data[base + RESOURCE_SCRIPT.OFFSET_CONFIDENCE] = RESOURCE_SCRIPT.encode_unit_byte(confidence)

	_progress(control, "Splat lighting records ready", 1.0)
	return {
		"ok": true,
		"error": "",
		"cancelled": false,
		"splat_data": splat_data,
		"stats": {
			"splats": count,
			"surfaced_splats": surfaced,
			"floater_splats": count - surfaced,
			"ambient_occlusion": has_ao,
		},
	}


## Openness the AO neighbourhood reads just outside a flat, unobstructed wall —
## the reference that maps to "fully lit".
##
## Derived, not guessed. The separable blur's box is (2r+1) voxels wide and is
## centred `offset` voxels outside the surface, so it still overlaps the solid
## side by (r − offset) voxels and a flat wall reads that fraction closed. A
## hardcoded 0.5 put the reference far below what flat geometry actually
## produces (0.79 at the default r=3, offset=1.5), so 88% of a real asset's
## splats clamped to fully-open and the AO channel carried no signal at all.
static func flat_openness_reference(ao_radius: int, offset: float) -> float:
	if ao_radius <= 0:
		return 1.0
	var window := float(2 * ao_radius + 1)
	var solid := maxf(0.0, float(ao_radius) - offset)
	# The floor keeps a degenerate radius from turning the division explosive.
	return clampf(1.0 - solid / window, 0.05, 1.0)


static func _progress(control: RefCounted, stage: String, fraction: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(fraction, 0.0, 1.0))

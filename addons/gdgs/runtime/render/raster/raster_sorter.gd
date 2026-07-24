@tool
extends RefCounted

## CPU counting sort producing a back-to-front splat order for the Raster backend.
##
## Reads only positions (GaussianResource.xyz); it never touches the 60-float
## blob. The sort key is `dot(center, view_dir_local)` — the splat centre
## projected onto the camera forward direction expressed in the splat's local
## space (positions are the recentered local coordinates). Larger key = farther
## into the scene = drawn first, so the result is ordered far→near for standard
## "over" blending.
##
## A single 16-bit counting pass gives 65536 depth buckets across the scene's
## depth range — ample resolution for splatting, O(n + buckets), and cheap enough
## to run every frame the camera moves (on a worker thread; see raster_sort_job).
## Within a bucket, ties keep original index order (stable).

const BUCKET_BITS := 16
const BUCKET_COUNT := 1 << BUCKET_BITS   # 65536

## Sort into a caller-provided buffer to avoid per-frame allocation. `out_order`
## is resized to xyz.size() and filled with splat indices far→near. Returns the
## same array for convenience.
static func sort_into(xyz: PackedVector3Array, view_dir_local: Vector3, out_order: PackedInt32Array) -> PackedInt32Array:
	var n := xyz.size()
	if out_order.size() != n:
		out_order.resize(n)
	if n == 0:
		return out_order

	var dx := view_dir_local.x
	var dy := view_dir_local.y
	var dz := view_dir_local.z

	var keys := PackedFloat32Array()
	keys.resize(n)
	var kmin := INF
	var kmax := -INF
	for i in range(n):
		var p := xyz[i]
		var k := p.x * dx + p.y * dy + p.z * dz
		keys[i] = k
		if k < kmin:
			kmin = k
		if k > kmax:
			kmax = k

	if kmax <= kmin:
		for i in range(n):
			out_order[i] = i
		return out_order

	var scale := float(BUCKET_COUNT - 1) / (kmax - kmin)

	var counts := PackedInt32Array()
	counts.resize(BUCKET_COUNT)   # zero-initialised
	for i in range(n):
		var b := int((keys[i] - kmin) * scale)
		b = clampi(b, 0, BUCKET_COUNT - 1)
		counts[b] += 1

	# Descending scatter offsets: bucket BUCKET_COUNT-1 (farthest) goes first.
	var offset := 0
	for b in range(BUCKET_COUNT - 1, -1, -1):
		var c := counts[b]
		counts[b] = offset
		offset += c

	for i in range(n):
		var b := int((keys[i] - kmin) * scale)
		b = clampi(b, 0, BUCKET_COUNT - 1)
		out_order[counts[b]] = i
		counts[b] += 1

	return out_order

## Convenience wrapper that allocates a fresh order array.
static func sort(xyz: PackedVector3Array, view_dir_local: Vector3) -> PackedInt32Array:
	return sort_into(xyz, view_dir_local, PackedInt32Array())

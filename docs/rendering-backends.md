# Rendering Backends

`gdgs` renders 3D Gaussian Splatting content through one of two interchangeable
backends behind the same `GaussianSplatNode` API and the same imported
`GaussianResource`. The backend is chosen **once at startup** by the
`gdgs/rendering/backend` project setting; changing it takes effect on the next
editor/game restart. The names follow PlayCanvas's renderer constants
(`GSPLAT_RENDERER_COMPUTE`, `GSPLAT_RENDERER_RASTER`).

## At a Glance

|  | **Compute** | **Raster** |
| --- | --- | --- |
| Approach | Tile-based compute-shader rasterizer, outside the scene pipeline | Sorted, instanced hardware quads ("sticker") through the scene pipeline |
| Scene blending | A `CompositorEffect` composites the offscreen splat image against the scene colour/depth buffers | Hardware ROP blending in Godot's standard transparent pass — no compositor |
| Occlusion vs. opaque scene | Manual depth comparison with tunable `depth_bias` / `depth_test_min_alpha` | Per-pixel hardware depth test, zero parameters |
| Splat ordering | Per-tile-exact: GPU radix sort of `(tile \| depth)` keys every frame, zero camera lag | Global back-to-front: threaded CPU counting sort, may lag the camera 1–3 frames (mild popping) |
| Renderers | `Forward Plus` only (needs compute shaders and the compositor) | `Forward Plus`, `Mobile`, `Compatibility` |
| MSAA / VR / multiview | Not supported | Supported (standard pipeline) |
| VRAM per splat | 240 B splat buffer plus per-frame tile/sort buffers (~2.8 GB at 6M splats) | 144 B in data textures (FP32 core + FP16 SH) plus a small order texture |
| Scene setup | Requires a `CompositorEffect` on the scene compositor | Add the node, assign the resource — nothing else |
| Colour handling | Blends SH colours in sRGB space, converts to linear once at composite time | Converts each splat's colour to linear and blends in the scene's linear pass (`Forward Plus`/`Mobile`); on `Compatibility` it blends directly in sRGB, like Compute |

## How Compute Renders

The Compute backend rasterizes splats entirely outside Godot's mesh pipeline:

1. The full splat buffer (the `GaussianResource` blob, uploaded verbatim to a
   storage buffer) is projected on the GPU every frame.
2. Projected splats are duplicated per covered 16×16 screen tile and sorted by
   a radix sort over `(tile | depth)` keys, giving an exact back-to-front order
   inside every tile with no camera lag.
3. A tile-local compute pass blends the splats into an offscreen colour/alpha
   image, front to back with early termination.
4. A `CompositorEffect` (post-transparent callback) composites that image into
   the scene: it converts the blended sRGB-space result to linear, and rejects
   splat pixels behind scene geometry by comparing depths with a small tunable
   `depth_bias`.

Because everything happens in compute shaders and the compositor, this path
needs `Forward Plus` and cannot run on `Mobile`/`Compatibility`.

## How Raster Renders

The Raster backend makes each splat an ordinary (if unusual) transparent scene
object:

1. **Data textures.** At load, the resource blob is split into two
   index-addressed textures: an FP32 *core* texture (3 texels per splat —
   position, 3D covariance, opacity) and an FP16 *SH* texture (12 texels per
   splat — the 48 spherical-harmonics colour coefficients). The core stays full
   float on purpose: covariance entries are σ² and underflow FP16 for
   millimetre-scale splats. SH is 80% of the data, so halving it still cuts
   VRAM from 240 to 144 bytes per splat.
2. **Geometry.** Each `GaussianSplatNode` gets one `MultiMeshInstance3D` whose
   base mesh packs 128 quads; each instance therefore draws 128 consecutive
   splats, and the total blend order is instance-major then primitive order —
   which Godot's transparent pass preserves.
3. **Sorting.** A worker-thread counting sort over the splat centres
   (`dot(center, view_dir)` key, 65536 buckets) produces a far-to-near index
   order, double-buffered into a small order texture. The sort re-runs only
   when the view direction rotates past ~1°; rendering always uses the last
   completed order, so it never stalls a frame but can lag the camera briefly.
4. **Shader.** A spatial shader projects each splat's 3D covariance to a 2D
   screen ellipse in `vertex()` (the same math as the compute projection —
   the two sources are kept in explicit parity), expands the quad along the
   ellipse's eigen-axes, clips it at the exact alpha-cutoff radius, evaluates
   degree-3 SH, converts the colour from sRGB to linear, and lets `fragment()`
   apply the Gaussian falloff. The standard transparent pass does the rest:
   hardware depth test against the opaque scene, ROP alpha blending, then the
   engine's tonemap.

No compositor, no compute shaders, no per-scene setup — which is exactly what
makes `Mobile` and `Compatibility` possible.

## Choosing a Backend

Set `Project > Project Settings > gdgs > rendering > backend`:

- `Auto` (default) — Compute on `Forward Plus` when compute shaders are
  available (preserves existing projects), Raster otherwise.
- `Compute` / `Raster` — force one; if it fails to initialize, the plugin logs
  a warning and falls back to the other.

Practical guidance:

- **Compute** when you want the most faithful splat ordering (dense,
  overlapping captures viewed up close) on a desktop `Forward Plus` project and
  VRAM is plentiful.
- **Raster** when splats must mix with regular geometry without depth tuning,
  when VRAM is constrained, or when you target `Mobile`/`Compatibility`, MSAA,
  or VR.

## Known Differences Between the Two Outputs

- Raster's global order can pop briefly during fast camera rotation; Compute
  never lags.
- On `Forward Plus`/`Mobile`, Raster blends splat-over-splat in linear space
  (each splat converted from sRGB first), while Compute accumulates in sRGB
  space and converts once; on `Compatibility` Raster also accumulates in sRGB
  (`OUTPUT_IS_SRGB`), matching Compute's blend space. On matching poses of the
  demo scene the backends differ by ~1.5/255 mean pixel value, concentrated in
  soft splat edges.
- Compute's tile pass culls sub-pixel splats slightly more aggressively.
- In the editor, Raster's sort follows the first 3D editor viewport's camera.

## Fault Isolation

The two backends never import each other's code; their only shared
dependencies are the read-only `GaussianResource` and the backend interface in
`runtime/render/backend/`. The selector loads backend scripts with guarded
`load()` calls, so deleting `runtime/render/raster/` leaves Compute fully
working and deleting `runtime/render/compute/` (plus `compositor/`/`debug/`)
leaves Raster working.

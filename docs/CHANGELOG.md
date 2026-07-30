# Changelog

All notable, user-visible changes to `gdgs` are documented in this file.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning note: the historical `1.0` release is normalized here as `1.0.0`.

## [3.3.0] - 2026-07-30

- Added **relighting**: Gaussian splats can now be lit by the scene's `Light3D` nodes. A splat stores radiance, not material — no normal, no albedo, no occlusion — so an editor bake derives the missing geometry from a *lighting proxy* (the same voxel field the collision module contours into a smooth mesh) and gives every splat an outward surface normal, an ambient-occlusion term and a confidence value. At runtime the colour is scaled by `unlit_level + gain × irradiance`, so enabling relighting darkens everything to a floor and lets only lit regions climb back up. Directional, omni and spot lights are supported with Godot's own range and cone falloff, up to eight at a time, and they may move freely. See [docs/relighting.md](relighting.md).
- Added the `GaussianLightingResource` bake artifact: **4 bytes per splat** plus the proxy mesh, saved as a `.res` and assigned to the node's new `lighting` property. The imported `GaussianResource` is untouched, so relighting is entirely additive and costs nothing when unused.
- Added a **GDGS Lighting** inspector panel that bakes on a background thread behind a cancellable progress dialog, saves the result and assigns it in one undo/redo action. Like collision, the module is optional and fault-isolated; unlike collision it is bake-time only, so a shipped game can relight from a baked resource with `addons/gdgs/collision` deleted.
- Added `relight_cast_shadows`: the baked proxy mounts as a `SHADOWS_ONLY` `MeshInstance3D`, so a Gaussian scene casts real shadows onto ordinary Godot geometry under both rendering backends. This is independent of whether the splats themselves are relit.
- Relighting is evaluated once per splat in the vertex/projection stage rather than per fragment, because splat clouds have 10–50× overdraw. At 271123 splats and 1280×720 with a close-in camera it costs +4.7% of frame time with one light and +16.0% with eight.
- Both rendering backends implement relighting with identical maths, verified: with the multiplier pinned to 1.0 the two agree to 1.4786/255, against a 1.4781/255 unlit baseline, and the Raster backend is bit-identical to relighting-off.
- Letting Godot light the Raster splats natively — which would give splats cast shadows for free — was implemented and measured rather than assumed. It works, but costs 2.5–3.9× the frame time (rising with overdraw, since `light()` is fragment-stage) and could never apply to the Compute backend, so it is not shipped. Splats therefore cast shadows but do not receive them.
- Fixed the node never telling the rendering backend that its lighting resource changed. The Raster backend polls its nodes and did not notice, but the Compute backend caches the bake at registration time and kept rendering the state the node had when it entered the tree — `null` for the usual order of adding a node and assigning the resource afterwards, including from the inspector.
- Added a `keep_grid` option to the collision pipeline so a caller can ask for the occupancy field the mesh was contoured from, not just the contour. Existing behaviour is unchanged.
- Added headless tests for the lighting bake (octahedral round-trip, surface field, per-splat transfer, concave-corner ambient occlusion, proxy vertex normals), the light rig (per-type packing, change detection, hidden/dark light rejection) and the Raster lighting texture packing.

## [3.2.0-beta] - 2026-07-24

**Beta release.** The Raster backend is new in this version: it is verified against the Compute backend on desktop Forward+ (matching-pose captures differ by ~1.5/255 mean pixel value), while coverage on real mobile hardware is still in progress. Feedback is very welcome.

- Added a second, selectable rendering backend — **Raster** ("sticker") — alongside the existing tile-based **Compute** backend. Raster draws each splat as a sorted, instanced hardware quad through Godot's normal transparent pass with the hardware depth test (no depth-bias params): it runs on Mobile/Compatibility as well as Forward+, gets MSAA/VR/multiview for free, and uses far less VRAM (split FP32 core + FP16 SH data textures, 144 instead of 240 bytes per splat). See `docs/rendering-backends.md` for the full comparison. It projects the 3D covariance in a spatial shader (kept in parity with the compute projection), evaluates full degree-3 spherical harmonics, and orders splats back-to-front with a threaded CPU counting sort (double-buffered, with a camera-static skip). The trade-off versus Compute is a global (not per-tile-exact) order that can lag the camera a frame or two.
- Added the `gdgs/rendering/backend` project setting (`Auto` | `Compute` | `Raster`) that selects the backend **once at startup**; changing it takes effect on the next editor/game restart (no runtime switching, by design). `Auto` picks Compute on Forward+ with compute support and Raster elsewhere. An explicit choice falls back to the other backend if it fails to initialize, and both backends are fully decoupled — deleting `addons/gdgs/runtime/render/raster/` leaves Compute working and vice versa. `GaussianSplatNode` now routes all rendering through the resolved backend, with no change to its public API or to existing Compute projects.
- Added headless CI tests for the Raster backend (counting-sort correctness, data-texture packing and FP16 round-trip, tiny-covariance preservation) and the backend selector (fallback policy and guarded, decoupled loading).
- The Raster data texture is split on purpose: position, covariance and opacity stay FP32 while only the SH coefficients pack to FP16. Covariance entries are σ² and sit below FP16's minimum normal for millimetre-scale splats — an early all-FP16 packing flushed them to zero and visually reproduced the pre-`2.1.0` covariance-projection bug.
- Raster converts each splat's SH colour from sRGB to linear before scene blending, matching the Compute compositor's `srgb_to_linear` (and PlayCanvas's per-splat `decodeGamma`); without it the engine's output encode brightened the Gaussian tails roughly tenfold and read as haze. The conversion is renderer-aware (`OUTPUT_IS_SRGB`): on the Compatibility renderer, which renders and blends directly in sRGB, the colour passes through unchanged — mirroring the Compute compositor's sRGB-space accumulation.
- Raster quads are clipped at the exact alpha-cutoff radius, so low-opacity splats cover fewer pixels with no visible truncation.
- Fixed Raster depth sorting in the editor: the sort now follows the Node3DEditor navigation camera. It previously used the scene viewport's current camera — the scene's own static `Camera3D` whenever one exists — so opposite view angles blended in exactly reversed order.
- Replaced the selection gizmo's point-cloud preview with an AABB wireframe (with clickable collision segments); drawing every splat position as a point occluded the rendered splat itself.
- Moved the Compute backend into `runtime/render/compute/` so both backends are self-contained, deletable units under `runtime/render/`; user-facing script paths (`runtime/compositor/`) are unchanged.
- Fixed the `Outdoor` collision scene mode sealing the wrong side of the ground surface for standard Y-down Gaussian assets: the fill direction is now derived from the node's orientation at generation time (`floor_y_sign` in the pipeline settings API, default assumes Y-down data).
- Gaussian resources above 2M splats are now uniformly subsampled with density compensation instead of being rejected, so large scanned scenes can generate collision.
- Rewrote the Gaussian-to-block candidate index shared by the CPU and private-GPU voxelizers as a CSR layout over packed int arrays: one implementation instead of two, far lower memory, and the arrays upload to the GPU without conversion; the CPU density loop also gained local-variable hoisting and block-saturation early-exit.
- `Outdoor` scene mode no longer requires a `CollisionSeed` marker (only `Interior` and carve flood from the seed).
- Fixed collision generation progress jumping backwards during interior/outdoor/carve; the pipeline stages now share one monotonic progress table (`pipeline_common.gd`), which also replaces the per-file result/cancel helper boilerplate.
- Added headless regression tests for the collision pipeline (synthetic assets, CPU backend) to CI, including an outdoor fill-direction check and a subsampling check.
- Bundled the MIT LICENSE inside `addons/gdgs` so it ships with every distribution of the plugin.
- Added a tag-driven release workflow (`v*` tags) that packages a project-root-installable plugin zip and publishes release notes from this changelog.
- Added a development `project.godot` and a ready-to-run demo scene (`samples/demo.tscn`).
- Added CI (headless import + smoke test on the minimum and latest supported Godot versions), issue/PR templates, and a contributing guide.
- Moved the large `.ply` sample assets out of the repository; samples beyond `demo.sog` are distributed via GitHub Releases.
- Moved non-README documentation into `docs/` (including the Chinese README) and removed internal review notes.
- Corrected the documented minimum supported Godot version to `4.3`.

## [3.1.0] - 2026-07-16

- Added editor-side collision generation for `GaussianSplatNode` (`addons/gdgs/collision`): voxelizes the Gaussian data (opacity-weighted Mahalanobis accumulation with a Beer–Lambert style cutoff), cleans isolated voxels and holes, and extracts either a greedy rectangle mesh or a watertight marching-cubes mesh into a `StaticBody3D` + `ConcavePolygonShape3D` child.
- Added CPU and private-GPU voxelization backends with automatic fallback; the GPU path uses `RenderingServer.create_local_rendering_device()` only and never touches the splat renderer's GPU state.
- Added `Object` / `Interior` / `Outdoor` scene modes and capsule-based carve for walkable space, seeded by a `CollisionSeed` marker.
- Added background generation on `WorkerThreadPool` with a cancellable progress dialog, single-action undo/redo, per-node settings persistence, and collision mesh export to `.res` / `.obj` / `.glb`.
- Generated shapes enable `backface_collision` so thin single-voxel shells resist tunneling and remain compatible with CCD.
- The collision module loads through a fault-isolating self-test: a missing or broken `addons/gdgs/collision` folder only logs a warning and rendering keeps working.
- Fixed push-constant alignment for Godot `4.7` compatibility (padded to 16 bytes).
- Added Godot Asset Library export attributes and icon.

## [2.2.0] - 2026-04-24

- Added editor icons for `GaussianSplatNode` and Gaussian resources.
- Added visibility propagation so Gaussian instances respect runtime/editor visibility toggles.
- Added instancing support so multiple nodes can share the same Gaussian data without duplicating GPU splat uploads.
- Fixed VR rendering support by using the correct view-projection path with eye offsets.

## [2.1.0] - 2026-03-20

- Fixed the screen-space covariance projection regression that could rotate splats incorrectly in the Godot 4 compositor path.
- Corrected the 2D covariance projection chain to use `screen_transform = jacobian * mat3(view_matrix)` and `cov_2d = screen_transform * cov_3d * transpose(screen_transform)`.
- Fixed the compositor/Vulkan projection-sign bug where `RenderData` can provide a negative `projection.y.y` to encode a render-target Y flip, which previously inverted the Y clamp range used during covariance projection.
- Bumped the Gaussian importer format version to force resource regeneration in Godot projects that still carry stale imported `.res` data.

## [2.0.0] - 2026-03-18

- Reorganized the repository into the shipping layout: `addons/gdgs`, `docs`, and `samples`.
- Split the render stack into focused modules for manager lifetime, scene registry, GPU state caching, and frame execution.
- Renamed and relocated the main runtime and editor entry files to match the new module layout.
- Fixed the macOS and Metal blank-render issue by pre-sizing indirect dispatch dimensions on the CPU.
- Fixed Godot 4.4 regressions around descriptor set typing, compute list typing, and compositor overlay teardown.
- Fixed the `GaussianSplatNode` transform duplication and serialization bug so duplicated nodes no longer receive orientation or scale handling twice.
- Restored transform consistency between editor gizmos and runtime rendering after the orientation fix.
- Updated the documentation and sample references for the new structure.

## [1.1.0] - 2026-03-16

- Added import support for `.compressed.ply`, `.splat`, and `.sog`.
- Unified multiple input formats into a shared GPU-ready Gaussian resource build pipeline.
- Centered imported Gaussian data during resource build for easier placement in scenes.
- Added default Z-axis orientation correction behavior for newly added `GaussianSplatNode` instances.
- Expanded the README, sample coverage, and plugin metadata for the `1.1.0` release.

## [1.0.0] - 2026-03-11

- Initial public plugin release.
- Added standard Gaussian `.ply` import support.
- Added compositor-based Gaussian rendering with scene-depth compositing.
- Added multi-node scene support.
- Added editor preview, gizmo display, and debug view support.

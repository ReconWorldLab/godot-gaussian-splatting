# gdgs: Godot Gaussian Splatting

Maintainer: ReconWorldLab

[Chinese README](README_CN.md)

Current plugin version: `3.1.0`

## News

- 2026-07-16: Version `3.1.0` adds editor-side collision generation: select a `GaussianSplatNode` and generate a `StaticBody3D` collision body directly from the Gaussian data. The pipeline is a GDScript port of the collision approach in [PlayCanvas splat-transform](https://github.com/playcanvas/splat-transform).
- 2026-04-20: Featured by [GameFromScratch in an article](https://gamefromscratch.com/gaussian-splats-in-godot/).
- 2026-04-20: Covered by [GameFromScratch on YouTube](https://www.youtube.com/watch?v=VfGYLlDHdrw).
- 2026-03-31: Merged community contribution [PR #6](https://github.com/ReconWorldLab/godot-gaussian-splatting/pull/6), adding icons, visibility handling, and instancing support.
- 2026-03-27: Published a packaged release on the [GitHub Releases page](https://github.com/ReconWorldLab/godot-gaussian-splatting/releases).
- 2026-03-11: Project introduction video published on [Bilibili](https://www.bilibili.com/video/BV1NRwFzYEVc).

## 0x00 What Is 3DGS

3DGS (`3D Gaussian Splatting`) is a newer 3D rendering pipeline. Instead of representing a scene with traditional triangle meshes, it uses large sets of 3D Gaussians to reconstruct and render views, which can provide higher quality real-time rendering for captured scenes.

### Showcase

These previews show roughly 6 million Gaussian points rendered together inside a real-time game scene.

| Room 0 | Room 1 |
| --- | --- |
| ![Room 0 showcase](samples/media/showcase-room0.gif) | ![Room 1 showcase](samples/media/showcase-room1.gif) |

| Train | Truck |
| --- | --- |
| ![Train showcase](samples/media/showcase-train.gif) | ![Truck showcase](samples/media/showcase-truck.gif) |

## 0x01 Why This Plugin

3DGS does not follow Godot's native mesh rendering pipeline, and Godot does not currently provide built-in support for importing, rendering, and compositing 3D Gaussian Splatting content.

`gdgs` fills that gap by providing:

- Import and resource handling for supported 3DGS assets.
- Scene integration through `GaussianSplatNode`.
- Hybrid rendering with regular Godot 3D content through `CompositorEffect`.
- Depth-aware composition and occlusion against the scene depth buffer.
- Editor-side collision generation, so splat scenes can interact with Godot physics.

## 0x02 How To Use

### Requirements

- Godot `4.4` or newer.
- `Forward Plus` rendering backend.
- A desktop GPU and driver with compute shader support.
- A supported Gaussian asset in one of the formats listed below.

### Installation

1. Create an `addons` folder in your Godot project if it does not already exist.
2. Copy the `addons/gdgs` folder from this repository into your project as `addons/gdgs`.
3. Open the project in Godot.
4. Go to `Project > Project Settings > Plugins`.
5. Enable the `gdgs` plugin.

After installation, the plugin root should be available at `res://addons/gdgs`.

### Quick Start

1. Add a supported Gaussian asset to your project. The repository includes `samples/assets/demo.ply`, `samples/assets/demo.compressed.ply`, and `samples/assets/demo.sog` as sample assets.
2. Wait for Godot to import it into a resource.
3. Add a `GaussianSplatNode` to your scene.
4. Assign the imported resource to the `gaussian` property of `GaussianSplatNode`.
5. Add a `WorldEnvironment` node to the scene.
6. Create a `Compositor` resource on `WorldEnvironment.compositor`.
7. Add a `CompositorEffect` to that `Compositor`, and set its script to `res://addons/gdgs/runtime/compositor/gaussian_compositor_effect.gd`.
8. Run the scene.

### Collision Generation

1. Select a `GaussianSplatNode` that has a Gaussian resource assigned.
2. In the Inspector, find the **GDGS Collision** block at the top.
3. Adjust the parameters if needed (the defaults work for most single objects) and click **Generate Collision**.
4. A `StaticBody3D` named `CollisionBody` with a `ConcavePolygonShape3D` is added as a child of the node. Generation runs on a background thread with a cancellable progress dialog, commits as a single undo/redo action, and remembers the settings on the node.

Options:

- **Mesh**: `Faces (greedy)` produces few triangles with a blocky silhouette; `Smooth (marching cubes)` produces a watertight smoothed surface.
- **Compute**: `Auto` voxelizes on a private GPU device when available and falls back to CPU; the plugin never touches the rendering pipeline's GPU state.
- **Scene mode**: `Object` for single objects; `Interior` seals a scanned room from the outside; `Outdoor` fills the ground below the surface. Interior/Outdoor and **Carve** (which removes capsule-reachable walkable space) need a child `Marker3D` named `CollisionSeed` — use **Add / Select Seed**.
- **Export Mesh…** exports the collision mesh as `.res`, `.obj`, or `.glb`.

Physics notes: the generated shape is a hollow triangle-mesh shell with `backface_collision` enabled. For small, fast-moving rigid bodies, enable `continuous_cd` on the body (or raise `physics_ticks_per_second`) to avoid tunneling through thin walls.

The collision module is optional and fault-isolated: if `addons/gdgs/collision` is missing or fails to load, the plugin logs a warning and rendering is unaffected, so you can delete that folder for a rendering-only installation.

## 0x03 Version History

Versioning note: the historical `1.0` release is normalized here as `1.0.0`.

### 3.1.0

- Added editor-side collision generation for `GaussianSplatNode` (`addons/gdgs/collision`): voxelizes the Gaussian data (opacity-weighted Mahalanobis accumulation with a Beer–Lambert style cutoff), cleans isolated voxels and holes, and extracts either a greedy rectangle mesh or a watertight marching-cubes mesh into a `StaticBody3D` + `ConcavePolygonShape3D` child.
- Added CPU and private-GPU voxelization backends with automatic fallback; the GPU path uses `RenderingServer.create_local_rendering_device()` only and never touches the splat renderer's GPU state.
- Added `Object` / `Interior` / `Outdoor` scene modes and capsule-based carve for walkable space, seeded by a `CollisionSeed` marker.
- Added background generation on `WorkerThreadPool` with a cancellable progress dialog, single-action undo/redo, per-node settings persistence, and collision mesh export to `.res` / `.obj` / `.glb`.
- Generated shapes enable `backface_collision` so thin single-voxel shells resist tunneling and remain compatible with CCD.
- The collision module loads through a fault-isolating self-test: a missing or broken `addons/gdgs/collision` folder only logs a warning and rendering keeps working.
- Fixed push-constant alignment for Godot `4.7` compatibility (padded to 16 bytes).
- Added Godot Asset Library export attributes and icon.

### 2.2.0

- Added editor icons for `GaussianSplatNode` and Gaussian resources.
- Added visibility propagation so Gaussian instances respect runtime/editor visibility toggles.
- Added instancing support so multiple nodes can share the same Gaussian data without duplicating GPU splat uploads.
- Fixed VR rendering support by using the correct view-projection path with eye offsets.

### 2.1.0

- Fixed the screen-space covariance projection regression that could rotate splats incorrectly in the Godot 4 compositor path.
- Corrected the 2D covariance projection chain to use `screen_transform = jacobian * mat3(view_matrix)` and `cov_2d = screen_transform * cov_3d * transpose(screen_transform)`.
- Fixed the compositor/Vulkan projection-sign bug where `RenderData` can provide a negative `projection.y.y` to encode a render-target Y flip, which previously inverted the Y clamp range used during covariance projection.
- Bumped the Gaussian importer format version to force resource regeneration in Godot projects that still carry stale imported `.res` data.

| Before 2.1.0 | After 2.1.0 |
| --- | --- |
| ![Before 2.1.0](samples/media/before_2.1.0.png) | ![After 2.1.0](samples/media/after_2.1.0.png) |

### 2.0.0

- Reorganized the repository into the shipping layout: `addons/gdgs`, `docs`, and `samples`.
- Split the render stack into focused modules for manager lifetime, scene registry, GPU state caching, and frame execution.
- Renamed and relocated the main runtime and editor entry files to match the new module layout.
- Fixed the macOS and Metal blank-render issue by pre-sizing indirect dispatch dimensions on the CPU.
- Fixed Godot 4.4 regressions around descriptor set typing, compute list typing, and compositor overlay teardown.
- Fixed the `GaussianSplatNode` transform duplication and serialization bug so duplicated nodes no longer receive orientation or scale handling twice.
- Restored transform consistency between editor gizmos and runtime rendering after the orientation fix.
- Updated the documentation and sample references for the new structure.

### 1.1.0

- Added import support for `.compressed.ply`, `.splat`, and `.sog`.
- Unified multiple input formats into a shared GPU-ready Gaussian resource build pipeline.
- Centered imported Gaussian data during resource build for easier placement in scenes.
- Added default Z-axis orientation correction behavior for newly added `GaussianSplatNode` instances.
- Expanded the README, sample coverage, and plugin metadata for the `1.1.0` release.

### 1.0.0

- Initial public plugin release.
- Added standard Gaussian `.ply` import support.
- Added compositor-based Gaussian rendering with scene-depth compositing.
- Added multi-node scene support.
- Added editor preview, gizmo display, and debug view support.

## 0x04 Features

- Import supported Gaussian assets from `.ply`, `.compressed.ply`, `.splat`, and `.sog`.
- Convert different source formats into a shared GPU-ready Gaussian resource.
- Center imported Gaussian data by default during resource build.
- Initialize new `GaussianSplatNode` instances with a default `-180` degree Z correction when they enter the tree in the default orientation.
- Render one or more `GaussianSplatNode` instances in the same scene.
- Composite Gaussian Splat rendering with standard Godot 3D content through `WorldEnvironment.compositor`.
- Mix Gaussian results against the scene depth buffer.
- Preview in the editor and manipulate the node with a gizmo.
- Built-in debug views for alpha, color, GS depth, scene depth, and depth rejection.
- Generate static collision (`StaticBody3D` + `ConcavePolygonShape3D`) from Gaussian data in the editor, with faces/smooth meshing, CPU/private-GPU voxelization, interior/outdoor scene modes, capsule carve, and mesh export.

## 0x05 Scene Setup Notes

- `GaussianSplatNode` stores transform and resource references. Actual rendering is performed by the compositor pass, not by Godot's standard mesh pipeline.
- Multiple `GaussianSplatNode` instances are supported and are rendered together in the same Gaussian pass.
- Imported Gaussian data is centered around its average position during resource build, so scenes start closer to the origin by default.
- A newly added `GaussianSplatNode` applies a one-time default Z correction when it enters the tree with the identity orientation. This keeps duplicated and serialized nodes from receiving the correction twice.
- If you replace the source asset contents, reimport it in Godot so the generated resource stays in sync.

## 0x06 Post Process Parameters

The compositor effect script is `res://addons/gdgs/runtime/compositor/gaussian_compositor_effect.gd`.

- `alpha_cutoff`: Pixels with alpha below this threshold are ignored during final composition.
- `depth_bias`: Small bias used when comparing GS depth against scene depth.
- `depth_test_min_alpha`: Minimum GS alpha required before depth rejection is applied.
- `debug_view`: Debug output mode.

`debug_view` options:

- `Composite`: Final composited result.
- `GS Alpha`: Gaussian alpha buffer.
- `GS Color`: Gaussian color buffer.
- `GS Depth`: Gaussian depth buffer.
- `Scene Depth`: Scene depth buffer.
- `Depth Reject Mask`: Shows which GS pixels are rejected by depth testing.

## 0x07 Supported Formats

### Standard Gaussian `.ply`

The importer supports binary little-endian Gaussian Splat `.ply` files with these properties:

- Position: `x`, `y`, `z`
- DC color coefficients: `f_dc_0`, `f_dc_1`, `f_dc_2`
- Remaining SH coefficients: `f_rest_0` to `f_rest_44`
- Opacity: `opacity`
- Scale: `scale_0`, `scale_1`, `scale_2`
- Rotation: `rot_0`, `rot_1`, `rot_2`, `rot_3`

### `.compressed.ply`

- Supported through the dedicated compressed PLY decoder.
- Detected automatically from the `.compressed.ply` suffix or packed vertex properties.

### Legacy `.splat`

- Supported for older Gaussian Splat record-based assets.

### `.sog`

- Supports SOG version `2` archives.

This importer is meant for Gaussian Splatting style assets, not generic point cloud files.

## 0x08 Repository Layout

- `addons/gdgs`: Plugin root in this repository.
- `addons/gdgs/importers`: Import plugins, parsers, decoders, and resource builders.
- `addons/gdgs/runtime`: Runtime nodes, resources, compositor code, and render modules.
- `addons/gdgs/editor`: Editor-only integrations such as gizmos.
- `addons/gdgs/collision`: Optional editor-side collision generation (inspector UI, worker pipeline, voxelizer shader).
- `docs`: Architecture notes and internal review records.
- `samples/assets`: Sample Gaussian assets.
- `samples/media`: Screenshots and debug images.

## 0x09 Known Limitations

- The plugin currently targets desktop `Forward Plus` rendering only.
- Rendering depends on Godot's compositor and compute pipeline, so compatibility and mobile renderers are not supported.
- On 4K displays, rendering errors or visual glitches may occur when GPU memory pressure becomes too high. Reducing the Godot viewport resolution may help. Reported in [issue #3](https://github.com/ReconWorldLab/godot-gaussian-splatting/issues/3).
- The render manager currently lives as a shared root-level runtime manager, so very complex editor multi-scene or multi-viewport workflows may still need additional validation.
- Standard `.ply` support expects binary little-endian Gaussian Splat data, not arbitrary point cloud layouts.
- `.sog` support currently targets version `2` archives only.

## 0x0A Acknowledgements

- The collision generation pipeline is a GDScript port of the voxelization and collision approach in [PlayCanvas splat-transform](https://github.com/playcanvas/splat-transform), published by PlayCanvas Ltd. under the MIT License. Many thanks to the PlayCanvas team for openly sharing that work.
- The shader work in this plugin was developed with reference to [2Retr0/GodotGaussianSplatting](https://github.com/2Retr0/GodotGaussianSplatting). Thanks to 2Retr0 for publishing that project.
- Thanks to [@4321ba](https://github.com/4321ba) for [PR #6](https://github.com/ReconWorldLab/godot-gaussian-splatting/pull/6), which contributed editor icons, visibility handling improvements, and instancing support for shared Gaussian data.
- The upstream `2Retr0/GodotGaussianSplatting` repository is published under the MIT License. If you reuse or redistribute closely related derivative work, review and retain the relevant upstream license notice.
- The radix sort shader files also retain their own upstream attribution headers, as documented in the shader sources.

## 0x0B References

- [2Retr0/GodotGaussianSplatting](https://github.com/2Retr0/GodotGaussianSplatting)
- [PlayCanvas splat-transform](https://github.com/playcanvas/splat-transform)
- [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://arxiv.org/abs/2308.04079)

## 0x0C License

This project is released under the [MIT License](LICENSE).

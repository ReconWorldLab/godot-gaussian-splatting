# gdgs: Godot Gaussian Splatting

Maintainer: ReconWorldLab

[中文 README](docs/README_CN.md)

Current plugin version: `3.2.0-beta`

## News

- 2026-07-24: Version `3.2.0-beta` introduces dual rendering backends: alongside the original **Compute** path, the new **Raster** ("sticker") backend renders splats through Godot's standard pipeline — bringing `Mobile` and `Compatibility` renderer support, hardware depth-tested occlusion with zero tuning parameters, and materially lower VRAM. This is a **beta release**: the Raster backend is new and feedback is very welcome. See [Rendering Backends](#rendering-backends) and [docs/rendering-backends.md](docs/rendering-backends.md).
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

- Godot `4.3` or newer.
- A supported Gaussian asset in one of the formats listed below.
- For the **Compute** rendering backend (default on desktop): the `Forward Plus` renderer and a GPU/driver with compute shader support.
- The **Raster** rendering backend has no compute requirement and also runs on the `Mobile` and `Compatibility` renderers (see [Rendering Backends](#rendering-backends)).

### Rendering Backends

`gdgs` can render splats two ways, selected once at startup by the
`gdgs/rendering/backend` project setting:

- **Compute** (`GSPLAT_RENDERER_COMPUTE`) — the original tile-based compute
  rasterizer. Per-frame GPU projection, a radix sort of `(tile | depth)` keys,
  tile-local blending, and composition against scene depth through a
  `CompositorEffect`. Per-tile-exact ordering with zero camera lag, at the cost
  of higher VRAM and a `Forward Plus`-only, compute-only requirement.
- **Raster** (`GSPLAT_RENDERER_RASTER`) — a sorted-quad hardware rasterizer
  ("sticker"). Splat data lives in split data textures (FP32 core + FP16
  spherical harmonics), one instanced quad mesh is projected per splat in a
  spatial shader, and the standard transparent pass blends it with the hardware
  depth test (no depth-bias params). Much lower VRAM, MSAA/VR/multiview and
  `Mobile`/`Compatibility` support for free; the trade-off is a global (not
  per-tile) back-to-front order — produced by a threaded CPU counting sort —
  that can lag the camera a frame or two (mild popping).

A deeper comparison — pipeline, data layout, sorting, and colour handling —
lives in [docs/rendering-backends.md](docs/rendering-backends.md).

Set the backend in `Project > Project Settings > gdgs > rendering > backend`:

- `Auto` (default) — Compute on `Forward Plus` with compute support, Raster
  otherwise.
- `Compute` / `Raster` — force a specific backend.

Selection is **startup-only by design**: changing the setting takes effect on
the next editor/game restart. If the chosen backend fails to initialize, the
plugin logs a warning and falls back to the other one. The Raster backend draws
through the normal scene, so it does **not** use the `WorldEnvironment`
compositor (that step is Compute-only).

### Try It Directly

This repository is itself a Godot project: clone it, open the repository root in Godot `4.3+`, wait for the first import, and run `samples/demo.tscn`. The demo scene already has the compositor effect configured.

### Installation

1. Create an `addons` folder in your Godot project if it does not already exist.
2. Copy the `addons/gdgs` folder from this repository into your project as `addons/gdgs`.
3. Open the project in Godot.
4. Go to `Project > Project Settings > Plugins`.
5. Enable the `gdgs` plugin.

After installation, the plugin root should be available at `res://addons/gdgs`.

### Quick Start

1. Add a supported Gaussian asset to your project. The repository includes `samples/assets/demo.sog` as a compact sample; larger `.ply` samples are distributed through the [GitHub Releases page](https://github.com/ReconWorldLab/godot-gaussian-splatting/releases) to keep clones small.
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
- **Scene mode**: `Object` for single objects; `Interior` seals a scanned room from the outside; `Outdoor` fills the ground below the surface. `Interior` and **Carve** (which removes capsule-reachable walkable space) need a child `Marker3D` named `CollisionSeed` — use **Add / Select Seed**. `Outdoor` derives its down direction from the node's current orientation, so orient the node the way it will be used before generating; it also seals the outer rim of the scan where no ground exists.
- **Export Mesh…** exports the collision mesh as `.res`, `.obj`, or `.glb`.

Physics notes: the generated shape is a hollow triangle-mesh shell with `backface_collision` enabled. For small, fast-moving rigid bodies, enable `continuous_cd` on the body (or raise `physics_ticks_per_second`) to avoid tunneling through thin walls.

The collision module is optional and fault-isolated: if `addons/gdgs/collision` is missing or fails to load, the plugin logs a warning and rendering is unaffected, so you can delete that folder for a rendering-only installation.

## 0x03 Version History

The current version is `3.2.0-beta`. The full per-version history lives in [docs/CHANGELOG.md](docs/CHANGELOG.md).

Highlights of `3.2.0-beta`:

- A second, selectable rendering backend — **Raster** — that draws splats through Godot's standard pipeline, enabling the `Mobile` and `Compatibility` renderers, MSAA/VR/multiview, and hardware depth-tested occlusion with zero tuning parameters, at materially lower VRAM (FP32 core + FP16 SH data textures).
- The `gdgs/rendering/backend` project setting (`Auto` | `Compute` | `Raster`) with startup-time resolution and fault-isolated fallback between backends.
- Raster output verified against the Compute backend on matching captures (mean pixel difference ~1.5/255), including per-splat sRGB-to-linear colour handling matching the Compute compositor.
- **Beta status**: the Raster backend is new; desktop Forward+ is well verified, real mobile hardware coverage is still in progress.

## 0x04 Features

- Import supported Gaussian assets from `.ply`, `.compressed.ply`, `.splat`, and `.sog`.
- Render through either of two interchangeable backends — tile-based **Compute** or standard-pipeline **Raster** — selected by one project setting, with automatic fallback.
- Run on the `Mobile` and `Compatibility` renderers through the Raster backend.
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

- `GaussianSplatNode` stores transform and resource references. Actual rendering is performed by the active backend: the **Compute** backend draws through the compositor pass, while the **Raster** backend draws through Godot's standard transparent pass.
- Multiple `GaussianSplatNode` instances are supported: Compute renders them together in one Gaussian pass; Raster renders one instanced draw per node.
- The `WorldEnvironment` compositor setup (Quick Start steps 5–7) is only required for the **Compute** backend; with **Raster**, adding the node and assigning the resource is enough.
- Imported Gaussian data is centered around its average position during resource build, so scenes start closer to the origin by default.
- A newly added `GaussianSplatNode` applies a one-time default Z correction when it enters the tree with the identity orientation. This keeps duplicated and serialized nodes from receiving the correction twice.
- If you replace the source asset contents, reimport it in Godot so the generated resource stays in sync.

## 0x06 Post Process Parameters

These parameters belong to the **Compute** backend's compositor effect; the Raster backend has no depth-tuning parameters (occlusion is the hardware depth test).

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
- `addons/gdgs/runtime`: Runtime nodes, resources, the backend seam (`render/backend`), the Compute backend (`render/compute` + `compositor` + `debug`), and the Raster backend (`render/raster`).
- `addons/gdgs/editor`: Editor-only integrations such as gizmos.
- `addons/gdgs/collision`: Optional editor-side collision generation (inspector UI, worker pipeline, voxelizer shader).
- `docs`: All non-README documentation — Chinese README, changelog, contributing guide, architecture notes, and the rendering-backend comparison.
- `samples`: Demo scene (`demo.tscn`), sample Gaussian assets, and media.
- `tests`: Headless tests used by CI (smoke, collision pipeline, Raster sorter/data-texture, backend selector).
- `project.godot`: Development project for working on the plugin itself; excluded from Asset Library exports.

Only `addons/` ships to users; everything else is development and documentation support.

## 0x09 Known Limitations

- The **Raster** backend is new in `3.2.0-beta`: it is verified against the Compute backend on desktop `Forward Plus` (matching-pose captures differ by ~1.5/255 on average), but coverage on real mobile hardware is still in progress, and its colour conversion is not yet renderer-aware on `Compatibility` (splats may render slightly dark there). Please report what you see.
- The **Compute** backend targets desktop `Forward Plus` only and depends on Godot's compositor and compute pipeline, so it does not run on the `Mobile` or `Compatibility` renderers. Use the **Raster** backend there (see [Rendering Backends](#rendering-backends)).
- The **Raster** backend uses a global (not per-tile-exact) back-to-front order that can lag the camera a frame or two, so fast rotations may show mild popping.
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

## 0x0C Contributing

Issues and pull requests are welcome, in English or Chinese. See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for the development setup (the repository opens directly as a Godot project), style notes, and the CI checks that run on every PR.

## 0x0D License

This project is released under the [MIT License](LICENSE). A copy of the license is bundled inside `addons/gdgs`, so it travels with the plugin wherever the folder is copied or downloaded.

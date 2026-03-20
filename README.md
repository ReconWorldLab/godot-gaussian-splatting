# gdgs: Godot Gaussian Splatting

Maintainer: ReconWorldLab

[Chinese README](README_CN.md)

Current plugin version: `2.1.0`

`gdgs` is a Godot 4 Gaussian Splatting plugin built around `CompositorEffect` and compute shaders.

It imports supported 3D Gaussian Splat assets, places them in a scene through `GaussianSplatNode`, and composites the result with the regular 3D scene using scene depth.

## Demo

![Demo screenshot](samples/media/demo.png)

- Video: [Bilibili - BV1NRwFzYEVc](https://www.bilibili.com/video/BV1NRwFzYEVc)

## Version History

Versioning note: the historical `1.0` release is normalized here as `1.0.0`.

### 2.1.0

- Fixed the screen-space covariance projection regression that could rotate splats incorrectly in the Godot 4 compositor path.
- Corrected the 2D covariance projection chain to use `screen_transform = jacobian * mat3(view_matrix)` and `cov_2d = screen_transform * cov_3d * transpose(screen_transform)`.
- Fixed the compositor/Vulkan projection-sign bug where `RenderData` can provide a negative `projection.y.y` to encode a render-target Y flip, which previously inverted the Y clamp range used during covariance projection.
- Bumped the Gaussian importer format version to force resource regeneration in Godot projects that still carry stale imported `.res` data.

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

## Features

- Import supported Gaussian assets from `.ply`, `.compressed.ply`, `.splat`, and `.sog`.
- Convert different source formats into a shared GPU-ready Gaussian resource.
- Center imported Gaussian data by default during resource build.
- Initialize new `GaussianSplatNode` instances with a default `-180` degree Z correction when they enter the tree in the default orientation.
- Render one or more `GaussianSplatNode` instances in the same scene.
- Composite Gaussian Splat rendering with standard Godot 3D content through `WorldEnvironment.compositor`.
- Mix Gaussian results against the scene depth buffer.
- Preview in the editor and manipulate the node with a gizmo.
- Built-in debug views for alpha, color, GS depth, scene depth, and depth rejection.

## Requirements

- Godot `4.4` or newer.
- `Forward Plus` rendering backend.
- A desktop GPU and driver with compute shader support.
- A supported Gaussian asset in one of the formats listed below.

## Installation

1. Create an `addons` folder in your Godot project if it does not already exist.
2. Copy the `addons/gdgs` folder from this repository into your project as `addons/gdgs`.
3. Open the project in Godot.
4. Go to `Project > Project Settings > Plugins`.
5. Enable the `gdgs` plugin.

After installation, the plugin root should be available at `res://addons/gdgs`.

## Quick Start

1. Add a supported Gaussian asset to your project. The repository includes `samples/assets/demo.ply`, `samples/assets/demo.compressed.ply`, and `samples/assets/demo.sog` as sample assets.
2. Wait for Godot to import it into a resource.
3. Add a `GaussianSplatNode` to your scene.
4. Assign the imported resource to the `gaussian` property of `GaussianSplatNode`.
5. Add a `WorldEnvironment` node to the scene.
6. Create a `Compositor` resource on `WorldEnvironment.compositor`.
7. Add a `CompositorEffect` to that `Compositor`, and set its script to `res://addons/gdgs/runtime/compositor/gaussian_compositor_effect.gd`.
8. Run the scene.

## Scene Setup Notes

- `GaussianSplatNode` stores transform and resource references. Actual rendering is performed by the compositor pass, not by Godot's standard mesh pipeline.
- Multiple `GaussianSplatNode` instances are supported and are rendered together in the same Gaussian pass.
- Imported Gaussian data is centered around its average position during resource build, so scenes start closer to the origin by default.
- A newly added `GaussianSplatNode` applies a one-time default Z correction when it enters the tree with the identity orientation. This keeps duplicated and serialized nodes from receiving the correction twice.
- If you replace the source asset contents, reimport it in Godot so the generated resource stays in sync.

## 2.1.0 Bug Fix Notes

The main rendering issue fixed in `2.1.0` was not in Godot's camera matrices themselves, but in how the plugin projected 3D Gaussian covariance into screen space inside `gsplat_projection.glsl`.

Cause:
- The previous shader mixed matrix order in the 2D covariance projection path, which made the screen-space covariance more sensitive to view rotation and instance transforms than it should have been.
- In the compositor path, Godot's `RenderData` can provide a projection matrix whose `projection.y.y` is negative to encode the render-target Y flip used by Vulkan/Forward+.
- The old shader reused that signed Y value both for focal scaling and for FOV clamp bounds. The focal term must keep the sign, but the clamp bounds must stay positive. Reusing the signed value inverted the Y clamp range and skewed the projected covariance orientation.

Fix:
- Keep the signed focal scale from the projection matrix so screen-space Y continues to match Godot's compositor path.
- Use `abs(projection_matrix[0][0..1][1])` when deriving the FOV extents used by the covariance clamp.
- Build the projection as `screen_transform = jacobian * mat3(view_matrix)`.
- Compute the final 2D covariance as `cov_2d = screen_transform * cov_3d * transpose(screen_transform)`.

If your project already imported Gaussian assets before updating to `2.1.0`, open the project once after upgrading so Godot can reimport the generated Gaussian resources.

## Post Process Parameters

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

## Supported Formats

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

## Repository Layout

- `addons/gdgs`: Plugin root in this repository.
- `addons/gdgs/importers`: Import plugins, parsers, decoders, and resource builders.
- `addons/gdgs/runtime`: Runtime nodes, resources, compositor code, and render modules.
- `addons/gdgs/editor`: Editor-only integrations such as gizmos.
- `docs`: Architecture notes and internal review records.
- `samples/assets`: Sample Gaussian assets.
- `samples/media`: Screenshots and debug images.

## Known Limitations

- The plugin currently targets desktop `Forward Plus` rendering only.
- Rendering depends on Godot's compositor and compute pipeline, so compatibility and mobile renderers are not supported.
- The render manager currently lives as a shared root-level runtime manager, so very complex editor multi-scene or multi-viewport workflows may still need additional validation.
- Standard `.ply` support expects binary little-endian Gaussian Splat data, not arbitrary point cloud layouts.
- `.sog` support currently targets version `2` archives only.

## Acknowledgements

- The shader work in this plugin was developed with reference to [2Retr0/GodotGaussianSplatting](https://github.com/2Retr0/GodotGaussianSplatting). Thanks to 2Retr0 for publishing that project.
- The upstream `2Retr0/GodotGaussianSplatting` repository is published under the MIT License. If you reuse or redistribute closely related derivative work, review and retain the relevant upstream license notice.
- The radix sort shader files also retain their own upstream attribution headers, as documented in the shader sources.

## References

- [2Retr0/GodotGaussianSplatting](https://github.com/2Retr0/GodotGaussianSplatting)
- [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://arxiv.org/abs/2308.04079)

## License

This project is released under the [MIT License](LICENSE).

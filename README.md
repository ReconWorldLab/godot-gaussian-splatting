# gdgs: Godot Gaussian Splatting

Maintainer: ReconWorldLab

[简体中文说明](README_CN.md)

`gdgs` is a Godot 4 Gaussian Splatting plugin built around `CompositorEffect` and compute shaders.

It imports supported 3D Gaussian Splat `.ply` assets, places them in a scene through `GaussianSplatNode`, and composites the result with the regular 3D scene using scene depth.

## Demo

![Demo screenshot](image.png)

- Video: [Bilibili - BV1NRwFzYEVc](https://www.bilibili.com/video/BV1NRwFzYEVc)

## Features

- Import supported Gaussian Splat `.ply` files as Godot resources.
- Render one or more `GaussianSplatNode` instances in the same scene.
- Composite Gaussian Splat rendering with standard Godot 3D content through `WorldEnvironment.compositor`.
- Mix Gaussian results against the scene depth buffer.
- Preview in the editor and manipulate the node with a gizmo.
- Built-in debug views for alpha, color, GS depth, scene depth, and depth rejection.

## Requirements

- Godot `4.4` or newer.
- `Forward Plus` rendering backend.
- A desktop GPU and driver with compute shader support.
- A supported binary Gaussian Splat `.ply` file.

## Installation

1. Create an `addons` folder in your Godot project if it does not already exist.
2. Copy the `gdgs` folder from this repository into your project as `addons/gdgs`.
3. Open the project in Godot.
4. Go to `Project > Project Settings > Plugins`.
5. Enable the `gdgs` plugin.

After installation, the plugin root should be available at `res://addons/gdgs`.

## Quick Start

1. Add a supported `.ply` file to your project. The repository includes `demo.ply` as a sample asset.
2. Wait for Godot to import it into a resource.
3. Add a `GaussianSplatNode` to your scene.
4. Assign the imported resource to the `gaussian` property of `GaussianSplatNode`.
5. Add a `WorldEnvironment` node to the scene.
6. Create a `Compositor` resource on `WorldEnvironment.compositor`.
7. Add a `CompositorEffect` to that `Compositor`, and set its script to `res://addons/gdgs/postprocess.gd`.
8. Run the scene.

## Scene Setup Notes

- `GaussianSplatNode` stores transform and resource references. Actual rendering is performed by the compositor pass, not by Godot's standard mesh pipeline.
- Multiple `GaussianSplatNode` instances are supported and are rendered together in the same Gaussian pass.
- If you replace the source `.ply` file contents, reimport it in Godot so the generated resource stays in sync.

## Post Process Parameters

The compositor effect script is `res://addons/gdgs/postprocess.gd`.

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

## Supported PLY Format

The importer expects a Gaussian Splat PLY with the following properties:

- Position: `x`, `y`, `z`
- DC color coefficients: `f_dc_0`, `f_dc_1`, `f_dc_2`
- Remaining SH coefficients: `f_rest_0` to `f_rest_44`
- Opacity: `opacity`
- Scale: `scale_0`, `scale_1`, `scale_2`
- Rotation: `rot_0`, `rot_1`, `rot_2`, `rot_3`

This importer is meant for 3D Gaussian Splatting style assets, not generic point cloud `.ply` files.

## Repository Layout

- `gdgs/`: Plugin root in this repository. Copy this folder into your Godot project as `addons/gdgs`.
- `gdgs/gaussian`: PLY importer and Gaussian resource definitions.
- `gdgs/node`: Scene node and editor gizmo.
- `gdgs/rendering`: Render manager, rendering context, and compute shaders.
- `gdgs/postprocess.gd`: Compositor effect entry point.
- `demo.ply`: Sample Gaussian asset for import testing.

## Known Limitations

- The plugin currently targets desktop `Forward Plus` rendering only.
- Rendering depends on Godot's compositor and compute pipeline, so compatibility and mobile renderers are not supported.
- The render manager currently lives as a shared root-level runtime manager, so very complex editor multi-scene or multi-viewport workflows may still need additional validation.
- The importer expects a specific Gaussian Splat property layout.

## Acknowledgements

- The shader work in this plugin was developed with reference to [2Retr0/GodotGaussianSplatting](https://github.com/2Retr0/GodotGaussianSplatting). Thanks to 2Retr0 for publishing that project.
- The upstream `2Retr0/GodotGaussianSplatting` repository is published under the MIT License. If you reuse or redistribute closely related derivative work, review and retain the relevant upstream license notice.
- The radix sort shader files also retain their own upstream attribution headers, as documented in the shader sources.

## References

- [2Retr0/GodotGaussianSplatting](https://github.com/2Retr0/GodotGaussianSplatting)
- [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://arxiv.org/abs/2308.04079)

## License

This project is released under the [MIT License](LICENSE).

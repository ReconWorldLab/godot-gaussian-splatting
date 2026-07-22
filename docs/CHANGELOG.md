# Changelog

All notable, user-visible changes to `gdgs` are documented in this file.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning note: the historical `1.0` release is normalized here as `1.0.0`.

## [Unreleased]

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

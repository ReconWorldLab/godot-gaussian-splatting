# GDGS Architecture

The repository now mirrors the plugin's shipping layout.

## Top-Level Layout

- `addons/gdgs`: The plugin itself.
- `docs`: All non-README documentation (Chinese README, changelog, contributing guide, this file).
- `samples`: Demo scene, example assets, and media.
- `tests`: Headless tests used by CI (smoke, collision pipeline, Raster sorter/data textures, backend selector, lighting bake and light rig).
- `project.godot`: Development project for working on the plugin; excluded from Asset Library exports.

## Plugin Modules

- `addons/gdgs/plugin.gd`: Editor plugin entry point.
- `addons/gdgs/editor`: Editor-only integrations.
- `addons/gdgs/importers`: Asset import pipeline.
- `addons/gdgs/runtime`: Runtime-facing nodes, resources, compositor code, and rendering internals.
- `addons/gdgs/collision`: Optional editor-side collision generation, loaded through a fault-isolating self-test.
- `addons/gdgs/lighting`: Optional editor-side lighting-proxy bake, loaded the
  same way. Bake-time only: it depends on the collision module's voxelizer and
  mesher, but nothing under `runtime/` imports it, so a shipped game relights
  from a baked resource with either module deleted.

## Render Split

Rendering is split into two interchangeable backends behind one seam; see
[rendering-backends.md](rendering-backends.md) for the full comparison.

- `runtime/render/backend/`: The backend-agnostic seam — the abstract backend
  interface and the selector that resolves the `gdgs/rendering/backend` project
  setting once at startup, with fault-isolated fallback between backends.
- `runtime/render/compute/`: The tile-based Compute backend — backend adapter,
  orchestration manager (`gaussian_render_manager.gd`), scene registry, GPU
  state cache, per-frame renderer, and the projection/radix-sort compute
  shaders. Composites into the scene through `runtime/compositor/` (which stays
  outside this folder because user scenes reference its script path).
- `runtime/render/raster/`: The sorted-quad Raster backend — data-texture
  packing, instanced quad mesh, threaded CPU counting sort with double-buffered
  order handoff, and the spatial shader. Draws through the standard transparent
  pass; no compositor.

- `runtime/lighting/`: Runtime relighting behaviour shared by both backends —
  the scene light rig and the shadow-only proxy caster. Guarded-loaded, so
  deleting it degrades every node to unlit. The `GaussianLightingResource` data
  contract itself lives in `runtime/resources/` alongside `GaussianResource`,
  because `GaussianSplatNode` exports it and this folder must stay deletable.

Each backend folder is deletable as a unit: the selector loads backend scripts
with guarded `load()` calls and falls back if one is missing or broken.

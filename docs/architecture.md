# GDGS Architecture

The repository now mirrors the plugin's shipping layout.

## Top-Level Layout

- `addons/gdgs`: The plugin itself.
- `docs`: All non-README documentation (Chinese README, changelog, contributing guide, this file).
- `samples`: Demo scene, example assets, and media.
- `tests`: Headless smoke test used by CI.
- `project.godot`: Development project for working on the plugin; excluded from Asset Library exports.

## Plugin Modules

- `addons/gdgs/plugin.gd`: Editor plugin entry point.
- `addons/gdgs/editor`: Editor-only integrations.
- `addons/gdgs/importers`: Asset import pipeline.
- `addons/gdgs/runtime`: Runtime-facing nodes, resources, compositor code, and rendering internals.
- `addons/gdgs/collision`: Optional editor-side collision generation, loaded through a fault-isolating self-test.

## Render Split

The render stack is intentionally split by responsibility:

- `gaussian_render_manager.gd`: Thin orchestration shell and singleton lifetime.
- `gaussian_scene_registry.gd`: Tracks scene nodes and builds merged CPU-side buffers.
- `gaussian_gpu_state_cache.gd`: Owns render-state caching and GPU resource lifetimes.
- `gaussian_renderer.gd`: Executes per-frame render work against the active state cache.

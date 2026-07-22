# Contributing to gdgs

Thanks for your interest! Issues and pull requests are welcome in English or Chinese.

## Development setup

1. Clone the repository.
2. Open the repository root directly in Godot `4.3` or newer (a `project.godot` is included; the plugin is pre-enabled).
3. Wait for the first import to finish, then run `samples/demo.tscn` to verify rendering works.

The repository layout and render-stack module split are described in [architecture.md](architecture.md).

## Making changes

- Keep the plugin self-contained under `addons/gdgs`. Everything outside `addons/` is development-only and is excluded from Asset Library exports via `.gitattributes`.
- The minimum supported Godot version is `4.3` — avoid APIs introduced after it, or guard them with `has_method` checks like the existing code does.
- Match the existing GDScript style: tabs for indentation, typed declarations where practical, one focused module per file.
- The collision module (`addons/gdgs/collision`) must stay optional: it is loaded through a fault-isolating self-test, and rendering must keep working if the folder is deleted.
- Do not commit large binary assets. Sample assets beyond the small `demo.sog` are distributed through GitHub Releases.

## Before opening a PR

- CI runs a headless import plus a smoke test (`tests/smoke_test.gd`) on the minimum and latest supported Godot versions. You can run the same checks locally:

  ```sh
  godot --headless --path . --import
  godot --headless --path . --script tests/smoke_test.gd
  ```

- If you change user-facing docs, update both `README.md` and `docs/README_CN.md`.
- Record user-visible changes in [CHANGELOG.md](CHANGELOG.md).

## License

By contributing you agree that your contributions are licensed under the [MIT License](../LICENSE).

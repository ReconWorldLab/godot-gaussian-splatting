# Relighting

A Gaussian splat stores **radiance, not material**: the colour baked into every
splat is what the capture camera saw, with no normal, no albedo and no
occlusion. There is nothing for a light to interact with.

Relighting fixes that by baking the missing geometry once, in the editor, from
a **lighting proxy** — the same voxel field the collision module contours into
a smooth mesh. Each splat borrows a surface normal, an ambient-occlusion term
and a confidence value from it, and the renderer then evaluates the scene's
`Light3D` nodes per splat:

```
colour × (unlit_level + light_gain × irradiance)
```

Turning relighting on therefore **darkens everything to `unlit_level` and lets
only lit regions climb back up**.

Read [Limitations](#limitations) before deciding whether this suits your asset.
The technique cannot remove light that was baked in at capture time.

## Baking a proxy

1. Select a `GaussianSplatNode` with a Gaussian resource assigned.
2. In the Inspector, find the **GDGS Lighting** block.
3. Adjust the settings if needed and click **Bake Lighting Proxy**.
4. Save the result as a `.res` when prompted. It is assigned to the node's
   `lighting` property in a single undo/redo action.

The bake runs on a background thread with a cancellable progress dialog. It
needs the collision module (`addons/gdgs/collision`) for the voxelizer and
mesher; the bake UI stays disabled without it, but **already-baked resources
still render**, so a shipped game never depends on it.

Saving is mandatory rather than a convenience: an unsaved `Resource` assigned
to a node is serialised *into the scene file*, and a bake is several megabytes.
Cancelling the save dialog therefore cancels the assignment.

### Bake settings

| Setting | Meaning |
| --- | --- |
| **Auto voxel size** | Derive the voxel size from the longest AABB axis / 128. |
| **Voxel size** | Proxy resolution — the finest lighting detail splats can borrow. Smaller is sharper but slower to bake. |
| **Opacity cutoff** | Accumulated Gaussian density that counts as surface. Lower fills more. |
| **Compute** | `Auto` voxelizes on a private GPU device when available and falls back to the CPU. It never touches the renderer's GPU state. |
| **Normal smoothing** | Rounds of neighbour averaging on the proxy's vertex normals. Marching-cubes normals off a binary field are faceted at `0`. |
| **AO radius** | Neighbourhood radius for ambient occlusion, in voxels. `0` disables AO. |
| **AO strength** | How far occluded splats are darkened. `0` keeps every splat fully open. |

### What gets stored

A `GaussianLightingResource` holds **4 bytes per splat** — an octahedral
outward normal, an AO term and a confidence — plus the contoured proxy mesh
with vertex normals. The imported `GaussianResource` is never modified, so
relighting is entirely additive and costs nothing when unused.

## Runtime properties

All under the node's **Relighting** group.

| Property | Default | Meaning |
| --- | --- | --- |
| `lighting` | `null` | The baked `GaussianLightingResource`. Without one, nothing below has any effect. |
| `relight_cast_shadows` | `true` | Mounts the proxy mesh as a `SHADOWS_ONLY` `MeshInstance3D`, so the splat scene casts real shadows onto ordinary Godot geometry. Independent of `relight_enabled`. |
| `relight_enabled` | `false` | Light the splats from the scene's `Light3D` nodes. |
| `relight_unlit_level` | `0.25` | Colour floor where no light reaches. `1.0` keeps the original brightness and only adds light on top. |
| `relight_light_gain` | `1.0` | How strongly gathered light brightens the splats. |
| `relight_ambient` | grey `0.25` | Ambient term, modulated by the baked AO. |
| `relight_dc_only` | `false` | Use only the spherical-harmonics DC term as the base colour. Baked view-dependent specular fights new lighting; this is the closest thing the data has to an albedo. |

Directional, omni and spot lights are all supported, with Godot's own range and
cone falloff, so a light reads the same on splats as on the mesh beside them.
The **eight** strongest lights affect splats (directional lights first, then by
reach); a scene with more logs a warning.

Lights may move freely at runtime. Nothing is recomputed while nothing moves.

## Cost

Lighting is evaluated **once per splat**, in the vertex/projection stage, not
per fragment — a splat cloud has 10–50× overdraw, so per-fragment lighting
would run the whole light loop that many times per pixel.

Measured at 271 123 splats, 1280×720, close-in high-overdraw camera, vsync off:

| | frame time | vs unlit |
| --- | --- | --- |
| relighting off | 4.636 ms | — |
| one light | 4.851 ms | +4.7 % |
| eight lights | 5.375 ms | +16.0 % |

Roughly 0.14 ms fixed plus 0.075 ms per light. Both rendering backends
implement the same maths and are verified to agree.

## Limitations

These are inherent to relighting baked radiance. No setting works around them.

- **Splats store radiance, not albedo.** Baked shadows, highlights and bounce
  light stay in the data; a new light adds on top of them. Strong relighting of
  an asset captured in hard sunlight will look wrong. Separating material from
  illumination is inverse rendering and is out of scope.
- **Relighting is a modulation.** It can darken toward `unlit_level` and
  brighten by `light_gain`, but it cannot change hue or remove a baked shadow.
- **Lighting resolution is the proxy's resolution.** Thin structures, foliage
  and semi-transparent volumes get a hull, not a surface, and their normals are
  correspondingly noisy.
- **Floaters and interior splats have no meaningful normal.** They are detected
  at bake time (confidence ≈ 0) and fall back to flat ambient rather than
  picking up a bogus terminator.
- **Splats do not receive cast shadows.** They *cast* them, through the proxy,
  but nothing occludes light reaching a splat: a wall between a lamp and the
  splats behind it will not darken them. Letting Godot light the splats
  natively was measured and would deliver this, but costs 2.5–3.9× the frame
  time, rising with overdraw. See [Rendering Backends](rendering-backends.md).
- **No bundled demo.** A baked proxy for the sample asset is several megabytes,
  and this repository keeps large binaries out of git. Bake one yourself with
  the steps above; `samples/assets/demo.sog` takes a few seconds.

## Fault isolation

- Deleting `addons/gdgs/lighting/` removes only the bake UI. Baked resources
  keep rendering.
- Deleting `addons/gdgs/runtime/lighting/` degrades every node to unlit with
  one warning.
- Deleting either rendering backend leaves the other working, relighting
  included.

# gdgs: Godot Gaussian Splatting

维护者：ReconWorldLab

[English README](../README.md)

当前插件版本：`3.3.0`

## 新闻

- 2026-07-24：`3.2.0-beta` 版本引入双渲染后端：在原有 **Compute** 路径之外，新增 **Raster**（"贴纸"）后端，让 splat 走 Godot 标准渲染管线——从而支持 `Mobile` 和 `Compatibility` 渲染器、零调参的硬件深度遮挡，以及显著更低的显存占用。这是一个**测试版本（beta）**：Raster 后端是新实现，非常欢迎反馈。详见[渲染后端](#渲染后端)与 [docs/rendering-backends.md](rendering-backends.md)。
- 2026-07-16：`3.1.0` 版本新增编辑器内碰撞生成：选中 `GaussianSplatNode` 即可直接从 Gaussian 数据生成 `StaticBody3D` 碰撞体。该管线移植自 [PlayCanvas splat-transform](https://github.com/playcanvas/splat-transform) 的碰撞方案。
- 2026-04-20：GameFromScratch 发布了对本插件的文章介绍：[Gaussian Splats in Godot](https://gamefromscratch.com/gaussian-splats-in-godot/)
- 2026-04-20：GameFromScratch 在 YouTube 发布了本插件的视频介绍：[观看视频](https://www.youtube.com/watch?v=VfGYLlDHdrw)
- 2026-03-31：合并了社区贡献 [PR #6](https://github.com/ReconWorldLab/godot-gaussian-splatting/pull/6)，补充了编辑器图标、可见性联动和实例化复用支持。
- 2026-03-27：在 [GitHub Releases 页面](https://github.com/ReconWorldLab/godot-gaussian-splatting/releases) 发布了打包版本。
- 2026-03-11：在 [Bilibili](https://www.bilibili.com/video/BV1NRwFzYEVc) 发布了项目介绍视频。

## 0x00 什么是 3DGS

3DGS（`3D Gaussian Splatting`）可以理解为一种新的三维渲染管线。它不再使用传统三角形 mesh 来表达场景，而是使用大量 3D Gaussian 原语来重建和渲染视图，因此通常能够带来更细腻、更高质量的实时渲染效果。

### 效果展示

以下展示的是约 600 万高斯点同时在一个游戏场景中进行渲染的效果：

| Room 0 | Room 1 |
| --- | --- |
| ![Room 0 showcase](../samples/media/showcase-room0.gif) | ![Room 1 showcase](../samples/media/showcase-room1.gif) |

| Train | Truck |
| --- | --- |
| ![Train showcase](../samples/media/showcase-train.gif) | ![Truck showcase](../samples/media/showcase-truck.gif) |

## 0x01 为什么需要这个插件

3DGS 的渲染方式和 Godot 原生的 mesh 渲染管线并不相同，Godot 目前也没有内建完整的 3D Gaussian Splatting 导入、渲染和合成能力。

`gdgs` 的作用就是把这部分能力补上：

- 导入并管理受支持的 3DGS 资源。
- 让 `GaussianSplatNode` 接入 Godot 场景工作流。
- 通过 `CompositorEffect` 与常规 3D 内容进行混合渲染。
- 基于场景深度完成遮挡、深度测试和深度合成。
- 编辑器内碰撞生成，让 splat 场景可以参与 Godot 物理交互。

## 0x02 如何使用

### 环境要求

- Godot `4.3` 或更新版本。
- 一份受支持格式的 Gaussian 资源文件。
- 使用 **Compute** 渲染后端（桌面默认）时：需要 `Forward Plus` 渲染器，以及支持 compute shader 的 GPU 和驱动。
- **Raster** 渲染后端不需要 compute，可在 `Mobile` 和 `Compatibility` 渲染器上运行（见[渲染后端](#渲染后端)）。

### 渲染后端

`gdgs` 提供两种渲染方式，由项目设置 `gdgs/rendering/backend` 在启动时选择一次：

- **Compute**（`GSPLAT_RENDERER_COMPUTE`）——原有的基于 tile 的 compute 光栅化器。每帧在 GPU 上投影、对 `(tile | depth)` 键做 radix 排序、tile 内混合，并通过 `CompositorEffect` 与场景深度合成。排序在每个 tile 内精确、无相机延迟，但显存占用较高，且只能在 `Forward Plus` + compute 环境运行。
- **Raster**（`GSPLAT_RENDERER_RASTER`）——排序四边形硬件光栅化器（“贴纸”方案）。splat 数据存于拆分的数据纹理（FP32 核心 + FP16 球谐系数），每个 splat 在 spatial shader 中投影为一个实例化四边形，走标准透明通道并使用硬件深度测试（无需 depth-bias 参数）。显存大幅降低，天然支持 MSAA/VR/multiview 以及 `Mobile`/`Compatibility`；代价是采用全局（非每 tile 精确）的从后到前排序——由多线程 CPU 计数排序产生——可能比相机滞后一两帧（轻微弹跳）。

关于两种后端更深入的对比——管线、数据布局、排序与色彩处理——见
[docs/rendering-backends.md](rendering-backends.md)（英文）。

在 `项目 > 项目设置 > gdgs > rendering > backend` 中设置：

- `Auto`（默认）——在支持 compute 的 `Forward Plus` 上选择 Compute，其余情况选择 Raster。
- `Compute` / `Raster` —— 强制指定某个后端。

后端选择**设计为仅在启动时生效**：修改设置需在下次编辑器/游戏重启后才会应用。若所选后端初始化失败，插件会打印警告并回退到另一个后端。Raster 后端走普通场景渲染，因此**不使用** `WorldEnvironment` 的 compositor（该步骤仅属于 Compute）。

### 直接试用

本仓库本身就是一个 Godot 工程：克隆后用 Godot `4.3+` 直接打开仓库根目录，等待首次导入完成，运行 `samples/demo.tscn` 即可。示例场景已经配置好了 compositor effect。

### 安装方法

1. 如果你的 Godot 项目里还没有 `addons` 目录，先创建它。
2. 将本仓库中的 `addons/gdgs` 文件夹复制到项目中，目标路径为 `addons/gdgs`。
3. 使用 Godot 打开项目。
4. 进入 `Project > Project Settings > Plugins`。
5. 启用 `gdgs` 插件。

安装完成后，插件根目录应位于 `res://addons/gdgs`。

### 快速开始

1. 将一个受支持的 Gaussian 资源加入项目。仓库附带了小体积示例 `samples/assets/demo.sog`；更大的 `.ply` 示例改为通过 [GitHub Releases 页面](https://github.com/ReconWorldLab/godot-gaussian-splatting/releases) 分发，以保持仓库克隆体积较小。
2. 等待 Godot 将其导入为资源。
3. 在场景中添加一个 `GaussianSplatNode`。
4. 将导入后的资源赋值给 `GaussianSplatNode` 的 `gaussian` 属性。
5. 在场景中添加一个 `WorldEnvironment` 节点。
6. 在 `WorldEnvironment.compositor` 上创建一个 `Compositor` 资源。
7. 在该 `Compositor` 中添加一个 `CompositorEffect`，并将脚本设为 `res://addons/gdgs/runtime/compositor/gaussian_compositor_effect.gd`。
8. 运行场景。

### 碰撞生成

1. 选中一个已赋值 Gaussian 资源的 `GaussianSplatNode`。
2. 在 Inspector 顶部找到 **GDGS Collision** 区块。
3. 按需调整参数（默认值适合大多数单物体场景），点击 **Generate Collision**。
4. 节点下会生成一个名为 `CollisionBody` 的 `StaticBody3D`（内含 `ConcavePolygonShape3D`）。生成在后台线程运行、进度窗口可取消，以单个 Undo/Redo 动作提交，参数会记忆在节点上。

参数说明：

- **Mesh**：`Faces (greedy)` 三角形少、轮廓偏方块感；`Smooth (marching cubes)` 生成水密的平滑表面。
- **Compute**：`Auto` 优先在私有 GPU 设备上体素化、不可用时回退 CPU；插件不会触碰渲染管线的 GPU 状态。
- **Scene mode**：`Object` 适合单物体；`Interior` 从外部封闭扫描的房间；`Outdoor` 填充地表以下。`Interior` 和 **Carve**（雕除胶囊可达的可行走空间）需要一个名为 `CollisionSeed` 的子 `Marker3D`，用 **Add / Select Seed** 创建。`Outdoor` 会根据节点当前朝向推导重力方向，生成前请先把节点摆到实际使用的朝向；扫描范围外没有地面的边缘会被整体封闭。
- **Export Mesh…** 可将碰撞网格导出为 `.res`、`.obj` 或 `.glb`。

物理提示：生成的碰撞体是空心三角网格壳，已开启 `backface_collision`。对于体积小、速度快的刚体，请开启其 `continuous_cd`（或提高 `physics_ticks_per_second`），避免穿透薄壁。

碰撞模块是可选且故障隔离的：如果 `addons/gdgs/collision` 缺失或加载失败，插件只会打印警告，渲染完全不受影响；需要纯渲染安装时可直接删除该目录。

### 重新打光

1. 选中一个已赋值 Gaussian 资源的 `GaussianSplatNode`。
2. 在 Inspector 中找到 **GDGS Lighting** 区块，按需调整参数后点击 **Bake Lighting Proxy**。
3. 在弹出的对话框中保存为 `.res`，随后会自动赋给节点的 `lighting` 属性。
4. 勾选节点 **Relighting** 分组下的 **Relight Enabled**，并在场景中添加一个 `Light3D`。

splat 存的是辐射亮度而非材质：没有法线、没有反照率、没有遮蔽。烘焙过程从*光照代理*——碰撞模块用的同一套体素场——推导出这些缺失的几何信息，给每个 splat 一个表面法线、一个环境遮蔽值和一个置信度。运行时颜色按 `unlit_level + gain × 辐照度` 缩放，所以开启后整体变暗、只有被照到的地方提亮。方向光、点光、聚光都支持，运行时可自由移动，两个渲染后端使用完全相同的数学。

`Relight Cast Shadows` 是独立开关且默认开启：它把烘焙出的代理挂成仅投影网格，让 Gaussian 场景把真实阴影投到普通 Godot 几何体上。

交互试用：`godot --path . samples/relighting_demo.tscn` 会让一盏灯绕着示例资源转，所有选项都能实时切换。该场景首次运行时自行烘焙并缓存，只有第一次需要等待。

**使用前请先读 [relighting.md](relighting.md)（英文）。** 重新打光无法去除拍摄时就烘进数据里的光照，splat 不接收投影阴影，且光照细节受限于代理的体素分辨率。

## 0x03 版本记录

当前版本为 `3.3.0`。完整的逐版本记录见 [CHANGELOG.md](CHANGELOG.md)（英文）。

`3.3.0` 亮点：

- **重新打光**：场景中的 `Light3D` 照亮 splat，法线与环境遮蔽来自烘焙的光照代理。最多 8 盏灯、运行时可自由移动、两个渲染后端表现一致，单光源开销约 +4.7% 帧时间。
- 烘焙出的代理还能让 Gaussian 场景把**真实阴影**投射到普通 Godot 几何体上。
- 烘焙产物为**每 splat 4 字节**，导入的 Gaussian 资源完全不受影响，不使用时零开销。

`3.2.0-beta` 亮点：

- 新增第二个可选渲染后端 **Raster**：splat 走 Godot 标准管线渲染，支持 `Mobile` 和 `Compatibility` 渲染器、MSAA/VR/multiview，遮挡由硬件深度测试完成（零调参），显存显著降低（FP32 核心 + FP16 SH 拆分数据纹理）。
- 新增项目设置 `gdgs/rendering/backend`（`Auto` | `Compute` | `Raster`），启动时解析一次，后端初始化失败时自动故障隔离回退。
- Raster 输出已与 Compute 后端在相同视角下做过对比验证（平均像素差约 1.5/255），包括与 Compute 合成器一致的逐 splat sRGB 转线性色彩处理。
- **测试版说明**：Raster 后端是新实现；桌面 Forward+ 验证充分，真实移动硬件的覆盖仍在进行中。

## 0x04 功能特性

- 支持导入 `.ply`、`.compressed.ply`、`.splat` 和 `.sog` 格式的 Gaussian 资源。
- 提供两个可互换的渲染后端——基于 tile 的 **Compute** 与标准管线的 **Raster**——由一个项目设置选择，并支持自动回退。
- 通过 Raster 后端支持 `Mobile` 和 `Compatibility` 渲染器。
- 将不同输入格式统一转换为共享的 GPU 可用 Gaussian 资源。
- 导入构建时默认对 Gaussian 数据做居中处理。
- 当 `GaussianSplatNode` 以默认朝向进入场景树时，会自动初始化一个 `-180` 度的 Z 轴修正。
- 支持在同一场景中渲染一个或多个 `GaussianSplatNode`。
- 通过 `WorldEnvironment.compositor` 与常规 Godot 3D 场景进行合成。
- 基于场景深度缓冲进行遮挡混合。
- 支持编辑器内预览和 gizmo 操作。
- 内置 alpha、颜色、GS 深度、场景深度和深度剔除遮罩等调试视图。
- 在编辑器中从 Gaussian 数据生成静态碰撞（`StaticBody3D` + `ConcavePolygonShape3D`），支持 faces/smooth 网格、CPU/私有 GPU 体素化、室内/室外场景模式、胶囊 carve 与网格导出。
- 用烘焙自光照代理的法线与环境遮蔽，让场景灯光重新照亮 splat；并让 splat 场景把阴影投射到普通几何体上。

## 0x05 场景说明

- `GaussianSplatNode` 只负责保存变换和资源引用，实际渲染由当前后端完成：**Compute** 后端走 compositor pass，**Raster** 后端走 Godot 标准透明通道。
- 支持多个 `GaussianSplatNode` 同时存在：Compute 在同一个 Gaussian pass 中统一渲染；Raster 为每个节点做一次实例化绘制。
- `WorldEnvironment` 的 compositor 配置（快速开始第 5–7 步）只有 **Compute** 后端需要；使用 **Raster** 时，添加节点并赋值资源即可。
- 导入后的 Gaussian 数据会按平均位置做居中处理，因此默认更接近场景原点。
- 新加入场景且仍为默认朝向的 `GaussianSplatNode` 会在进入场景树时只做一次 Z 轴修正，避免复制或序列化后的节点再次被重复修正。
- 如果你替换了源资源文件内容，请在 Godot 中重新导入，以确保生成资源与源文件保持同步。

## 0x06 后处理参数

以下参数属于 **Compute** 后端的 compositor effect；Raster 后端没有深度调参项（遮挡由硬件深度测试完成）。

compositor effect 脚本位于 `res://addons/gdgs/runtime/compositor/gaussian_compositor_effect.gd`。

- `alpha_cutoff`：Alpha 低于该阈值的像素会在最终合成时被忽略。
- `depth_bias`：GS 深度与场景深度比较时使用的小偏移量。
- `depth_test_min_alpha`：只有当 GS alpha 高于该阈值时才应用深度剔除。
- `debug_view`：调试输出模式。

`debug_view` 可选项：

- `Composite`：最终合成结果。
- `GS Alpha`：Gaussian alpha 缓冲。
- `GS Color`：Gaussian 颜色缓冲。
- `GS Depth`：Gaussian 深度缓冲。
- `Scene Depth`：场景深度缓冲。
- `Depth Reject Mask`：显示哪些 GS 像素因为深度测试被剔除。

## 0x07 支持的格式

### 标准 Gaussian `.ply`

导入器支持二进制小端的 Gaussian Splat `.ply` 文件，要求至少包含以下属性：

- 位置：`x`、`y`、`z`
- DC 颜色系数：`f_dc_0`、`f_dc_1`、`f_dc_2`
- 剩余 SH 系数：`f_rest_0` 到 `f_rest_44`
- 不透明度：`opacity`
- 缩放：`scale_0`、`scale_1`、`scale_2`
- 旋转：`rot_0`、`rot_1`、`rot_2`、`rot_3`

### `.compressed.ply`

- 通过独立的 compressed PLY 解码器导入。
- 可以通过 `.compressed.ply` 后缀或压缩顶点属性自动识别。

### 旧版 `.splat`

- 支持较早期的 Gaussian Splat record 格式资源。

### `.sog`

- 当前支持 SOG `v2` 归档格式。

该导入器面向 Gaussian Splatting 风格资源，不适用于通用点云文件。

## 0x08 仓库结构

- `addons/gdgs`：插件根目录。
- `addons/gdgs/importers`：导入插件、解析器、解码器和资源构建器。
- `addons/gdgs/runtime`：运行时节点、资源、后端接缝（`render/backend`）、Compute 后端（`render/compute` + `compositor` + `debug`）与 Raster 后端（`render/raster`）。
- `addons/gdgs/editor`：编辑器侧扩展，例如 gizmo。
- `addons/gdgs/collision`：可选的编辑器内碰撞生成模块（Inspector UI、工作线程管线、体素化 shader）。
- `addons/gdgs/lighting`：可选的编辑器内光照代理烘焙模块（Inspector UI、工作线程烘焙管线）。仅烘焙期需要——发布的游戏只靠烘焙好的资源即可重新打光。
- `docs`：除英文 README 外的全部文档——中文 README、changelog、贡献指南、架构说明和渲染后端对比。
- `samples`：示例场景（`demo.tscn`、`relighting_demo.tscn`）、示例 Gaussian 资源和媒体文件。
- `tests`：CI 使用的 headless 测试（冒烟、碰撞管线、Raster 排序器/数据纹理、后端选择器、光照烘焙与光源 rig）。
- `project.godot`：用于开发插件本身的工程文件；不会包含在 Asset Library 导出中。

只有 `addons/` 会分发给用户，其余内容都是开发与文档配套。

## 0x09 已知限制

- **Raster** 后端是 `3.2.0-beta` 的新实现：已在桌面 `Forward Plus` 和 `Compatibility` 上与 Compute 后端做过对比验证（相同视角截图平均差约 1.5/255），但真实移动硬件的覆盖仍在进行中。欢迎反馈实际效果。
- **Compute** 后端仅面向桌面 `Forward Plus`，依赖 Godot 的 compositor 与 compute 管线，因此无法在 `Mobile` / `Compatibility` 渲染器上运行；这些环境请使用 **Raster** 后端（见[渲染后端](#渲染后端)）。
- **Raster** 后端采用全局（非每 tile 精确）的从后到前排序，可能比相机滞后一两帧，快速旋转时会有轻微弹跳。
- 在 4K 显示器下，如果显存压力过高，可能会出现渲染错误或画面异常；将 Godot 视口分辨率调低后通常会有所缓解。该限制来源于 [issue #3](https://github.com/ReconWorldLab/godot-gaussian-splatting/issues/3)。
- 重新打光是对烘焙辐射亮度的调制，因此无法去除拍摄时就进入数据的光照；splat 通过代理**投射**阴影，但不**接收**阴影。完整清单见 [relighting.md](relighting.md#limitations)（英文）。
- 当前渲染管理器仍以共享的 root 级运行时管理器存在，复杂的编辑器多场景或多视口工作流仍需要进一步验证。
- 标准 `.ply` 仅支持 Gaussian Splat 所需的二进制小端布局，不支持任意点云属性结构。
- `.sog` 当前仅支持 `v2` 格式。

## 0x0A 致谢

- 碰撞生成管线移植自 [PlayCanvas splat-transform](https://github.com/playcanvas/splat-transform) 的体素化与碰撞方案（PlayCanvas Ltd. 以 MIT License 发布）。衷心感谢 PlayCanvas 团队开源这项工作。
- 本项目中的 shader 实现参考了 [2Retr0/GodotGaussianSplatting](https://github.com/2Retr0/GodotGaussianSplatting)。感谢 2Retr0 公开该项目。
- 感谢 [@4321ba](https://github.com/4321ba) 提交 [PR #6](https://github.com/ReconWorldLab/godot-gaussian-splatting/pull/6)，为项目补充了编辑器图标、可见性联动处理，以及共享 Gaussian 数据的实例化复用支持。
- 上游 `2Retr0/GodotGaussianSplatting` 仓库采用 MIT License。若你复用与其实现密切相关的衍生内容，请同时检查并保留相应的上游许可说明。
- radix sort 相关 shader 文件也保留了各自的上游来源说明，详见对应 shader 文件头部注释。

## 0x0B 参考资料

- [2Retr0/GodotGaussianSplatting](https://github.com/2Retr0/GodotGaussianSplatting)
- [PlayCanvas splat-transform](https://github.com/playcanvas/splat-transform)
- [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://arxiv.org/abs/2308.04079)

## 0x0C 参与贡献

欢迎提交 issue 和 PR，中英文均可。开发环境搭建（仓库可直接作为 Godot 工程打开）、代码风格约定和 CI 检查项见 [CONTRIBUTING.md](CONTRIBUTING.md)（英文）。

## 0x0D 许可证

本项目采用 [MIT License](../LICENSE)。`addons/gdgs` 目录内也附带了一份许可证副本,插件文件夹被复制或下载到哪里,许可证就跟到哪里。

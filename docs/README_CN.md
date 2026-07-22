# gdgs: Godot Gaussian Splatting

维护者：ReconWorldLab

[English README](../README.md)

当前插件版本：`3.1.0`

## 新闻

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
- 使用 `Forward Plus` 渲染后端。
- 支持 compute shader 的桌面 GPU 和驱动。
- 一份受支持格式的 Gaussian 资源文件。

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
- **Scene mode**：`Object` 适合单物体；`Interior` 从外部封闭扫描的房间；`Outdoor` 填充地表以下。Interior/Outdoor 和 **Carve**（雕除胶囊可达的可行走空间）需要一个名为 `CollisionSeed` 的子 `Marker3D`，用 **Add / Select Seed** 创建。
- **Export Mesh…** 可将碰撞网格导出为 `.res`、`.obj` 或 `.glb`。

物理提示：生成的碰撞体是空心三角网格壳，已开启 `backface_collision`。对于体积小、速度快的刚体，请开启其 `continuous_cd`（或提高 `physics_ticks_per_second`），避免穿透薄壁。

碰撞模块是可选且故障隔离的：如果 `addons/gdgs/collision` 缺失或加载失败，插件只会打印警告，渲染完全不受影响；需要纯渲染安装时可直接删除该目录。

## 0x03 版本记录

当前版本为 `3.1.0`。完整的逐版本记录见 [CHANGELOG.md](CHANGELOG.md)（英文）。

`3.1.0` 亮点：

- 编辑器内从 Gaussian 数据生成碰撞（`StaticBody3D` + `ConcavePolygonShape3D`），支持 faces/smooth 网格、CPU/私有 GPU 体素化、场景模式、胶囊 carve 与网格导出。
- 修复 push constants 对齐问题，适配 Godot `4.7`。
- 新增 Asset Library 导出属性与图标。

## 0x04 功能特性

- 支持导入 `.ply`、`.compressed.ply`、`.splat` 和 `.sog` 格式的 Gaussian 资源。
- 将不同输入格式统一转换为共享的 GPU 可用 Gaussian 资源。
- 导入构建时默认对 Gaussian 数据做居中处理。
- 当 `GaussianSplatNode` 以默认朝向进入场景树时，会自动初始化一个 `-180` 度的 Z 轴修正。
- 支持在同一场景中渲染一个或多个 `GaussianSplatNode`。
- 通过 `WorldEnvironment.compositor` 与常规 Godot 3D 场景进行合成。
- 基于场景深度缓冲进行遮挡混合。
- 支持编辑器内预览和 gizmo 操作。
- 内置 alpha、颜色、GS 深度、场景深度和深度剔除遮罩等调试视图。
- 在编辑器中从 Gaussian 数据生成静态碰撞（`StaticBody3D` + `ConcavePolygonShape3D`），支持 faces/smooth 网格、CPU/私有 GPU 体素化、室内/室外场景模式、胶囊 carve 与网格导出。

## 0x05 场景说明

- `GaussianSplatNode` 只负责保存变换和资源引用，实际渲染由 compositor pass 完成，不走 Godot 标准 mesh 渲染管线。
- 支持多个 `GaussianSplatNode` 同时存在，并在同一个 Gaussian pass 中统一渲染。
- 导入后的 Gaussian 数据会按平均位置做居中处理，因此默认更接近场景原点。
- 新加入场景且仍为默认朝向的 `GaussianSplatNode` 会在进入场景树时只做一次 Z 轴修正，避免复制或序列化后的节点再次被重复修正。
- 如果你替换了源资源文件内容，请在 Godot 中重新导入，以确保生成资源与源文件保持同步。

## 0x06 后处理参数

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
- `addons/gdgs/runtime`：运行时节点、资源、compositor 代码和渲染模块。
- `addons/gdgs/editor`：编辑器侧扩展，例如 gizmo。
- `addons/gdgs/collision`：可选的编辑器内碰撞生成模块（Inspector UI、工作线程管线、体素化 shader）。
- `docs`：除英文 README 外的全部文档——中文 README、changelog、贡献指南和架构说明。
- `samples`：示例场景（`demo.tscn`）、示例 Gaussian 资源和媒体文件。
- `tests`：CI 使用的 headless 冒烟测试。
- `project.godot`：用于开发插件本身的工程文件；不会包含在 Asset Library 导出中。

只有 `addons/` 会分发给用户，其余内容都是开发与文档配套。

## 0x09 已知限制

- 当前仅面向桌面 `Forward Plus` 渲染。
- 依赖 Godot 的 compositor 与 compute 管线，因此不支持 compatibility 和 mobile 渲染器。
- 在 4K 显示器下，如果显存压力过高，可能会出现渲染错误或画面异常；将 Godot 视口分辨率调低后通常会有所缓解。该限制来源于 [issue #3](https://github.com/ReconWorldLab/godot-gaussian-splatting/issues/3)。
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

本项目采用 [MIT License](../LICENSE)。

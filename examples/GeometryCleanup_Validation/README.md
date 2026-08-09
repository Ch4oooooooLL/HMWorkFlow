# Geometry Cleanup 验证几何模型

本目录提供 `modules/geometry_cleanup.tcl`（Geometry Cleanup: Chamfer/Recess）的验证几何模型，
覆盖 **CHAMFER**（倒角/圆角清除）、**POCKET**（沉台补平）、**AUTO**（自动分派）三种模式以及
**失败/边界** 场景。模型为真实冲压/铸造件级别的实体几何，用于导入 HyperMesh 2019 后人工或
半自动验证模块行为。

## 生成命令与依赖

```bash
# 仓库根目录执行
python examples/GeometryCleanup_Validation/generate_geometry.py
```

- 依赖：系统 Python（3.14 + cadquery 2.8.0），需先 `pip install cadquery`。
- 生成器确定性（固定常量，无随机），输出两个 STEP 与一个 manifest：

| 文件 | 内容 |
| --- | --- |
| `GeometryCleanup_Chamfer_Validation.step` | C01、C02、C07、C08（CHAMFER / 失败） |
| `GeometryCleanup_Pocket_Validation.step`  | C03、C04、C05、C06（POCKET / AUTO / 失败） |
| `GeometryCleanup_Validation_manifest.json` | schema_version 1.0，8 个 case 的坐标、期望模式、种子面指引 |

自检：

```bash
python examples/GeometryCleanup_Validation/verify_geometry.py
```

读回 `.step` 校验每个场景的实体数、体积为正、面数、bbox 与 manifest 一致，失败则 raise。

> `.step` 与 `*_manifest.json` 已被仓库 `.gitignore` 忽略，只提交生成器脚本、verify 脚本与本 README。

## 模型布局

两个 STEP 文件内场景沿 X 轴等距排布（间距 360 mm），坐标均为全局坐标（mm）：

| 文件 | 场景 | X 范围 | Y 范围 | Z 范围 | 实体/面数 |
| --- | --- | --- | --- | --- | --- |
| Chamfer | C01 CHAMFER 正常 | -160..160 | -90..90 | 0..8.5 | 1 / 39 |
| Chamfer | C02 CHAMFER 边界 | 360..450 | 0..60 | 0..260 | 1 / 9 |
| Chamfer | C07 CHAMFER 边界 | 550..890 | 0..6 | 0..3 | 1 / 14 |
| Chamfer | C08 失败/小特征 | 970..1270 | -80..80 | 0..3 | 1 / 16 |
| Pocket | C03 POCKET 正常 | -130..130 | -80..80 | -12..0 | 1 / 14 |
| Pocket | C04 POCKET 多个 | 210..510 | -90..90 | -12..0 | 1 / 22 |
| Pocket | C05 AUTO 模式 | 590..850 | -80..80 | -12..0 | 1 / 18 |
| Pocket | C06 失败/光顺件 | 1120..1420 | -60..60 | 0..40 | 1 / 10 |

每个场景独立为一个实体（solid），互不相交。manifest 中每个 case 给出精确种子面坐标
（`seed_point.global_point`），可在 HyperMesh 中按坐标快速定位。

## HyperMesh 2019 操作步骤

1. **导入**：HyperMesh 2019，任意 profile（建议 Geometry），`File > Import > Geometry` 选择
   `GeometryCleanup_Chamfer_Validation.step` 或 `GeometryCleanup_Pocket_Validation.step`。
   导入后每个场景为一个 solid 的多个 surface。
2. **启动模块**：运行工具箱，打开“几何清理 / Geometry Cleanup: Chamfer/Recess”。
3. **参数**：保持默认（`fillet_min_r=0`、`fillet_max_r=5`、`chain_by_fillet=1`、
   `chain_by_small_area=1`、`max_chain_depth=6`、`stitch_tolerance=0.2`、
   `create_solid_from_chamfer_bounds=1`）；特殊场景按下方说明调整。
4. **选择模式**：按场景选择 `CHAMFER` / `POCKET` / `AUTO`。
5. **连续清洗**：按 manifest 的 `seed_point.global_point` 选中对应种子面，中键执行；
   结果观察 Tcl 控制台与状态栏输出（模式、`target_surfs`、`new_surfs`、`new_solids`），
   并在 Model Browser 中核对表面/实体变化。

### C01 CHAMFER 正常：带加强筋冲压支架

- 选择 `CHAMFER` 模式。
- 种子面：任一顶缘圆角面（manifest 给出，约 `(-160, -89.9, 0.7)`，r=2 圆柱面）。
- 预期：圆角链经 `hm_getfilletfacesfrommark` 扩展覆盖 4 个顶缘圆角面并清除
  （`*surfacefilletremove` 或按半径范围 `*deletemark surfs`），直角拓扑重建；
  `create_solid_from_chamfer_bounds=1` 时尝试 `*solids_create_from_surfaces`，
  应看到 `new_solids` 非空（顶缘清理后剩余 surface 组成封闭体，重建为实体）。
- 验证点：加强筋（r=2 棱边圆角）与四角螺栓孔 r=5 不被误删；实体数量不减少且重建成功。

### C02 CHAMFER 边界：大折弯圆角 r=8

- 选择 `CHAMFER` 模式。
- 种子面（两个可选，分别验证两种行为）：
  - 长腿外壁平面 `(405, 0, 130)`（默认参数下验证“不误删大圆角”）；
  - 内折弯圆角面 `(371.6, 3.8, -0.1)`（r=8 直接作种子，验证半径查询不返回自身）。
- 预期：
  - 半径查询范围 `[0,5]` **不会**返回 r=8 折弯面（超出 `fillet_max_r`）。
  - 默认 `chain_by_small_area=1`：平面种子会走“相邻小面回退链”，可能把 r=8 面列入
    `target_surfs`；但 HM2019 回退删除按半径过滤（`hm_getfilletfacesfrommark [0,5]`），
    r=8 面应**保留**。
  - 将 `chain_by_small_area` 设为 `0`：半径查询为空 → 模块应报
    “倒角/圆角清理失败：surfacefilletremove=...；fillet query=...”，**不删除任何面**。
- 验证点：处理后 r=8 折弯面仍存在；零件面数不减少。

### C07 CHAMFER 边界：9 段连续凸弧圆角链

- 选择 `CHAMFER` 模式。
- 种子面：端部第 1 个凸弧圆柱面 `(550, 3.3, -0.1)`（r=3）。
- 预期：链式 BFS 从种子扩展，按 `max_chain_depth=6` 截断（覆盖深度 0..6，约 7 段）；
  末端第 9 段凸弧（`(598, 3.3, -0.1)`）**不被误删**。验证方式：处理后圆柱面数减少
  但未清零，第 9 段凸弧仍在；日志 `target_surfs` 长度约为 7。
- 注意：本场景无其他特征（两端已移除安装孔），链结构纯净，便于核对截断边界。

### C08 失败/边界：含 6 个小通孔 + 小圆角

- 选择 `CHAMFER` 模式，`chain_by_small_area=0`（推荐，验证半径查询保护）。
- 种子面：顶面平面（z=3，最右侧孔旁）`(1080, 30, 3)`。
- 预期：半径查询 `[0,5]` 不含平面种子 → 安全拒绝，报“倒角/圆角清理失败”，
  **6 个 r=1.5 通孔与 4 个 r=1.5 顶缘圆角面全部保留**。核对处理前后孔数不变。
- 附加：在 r=1.5 顶缘圆角面上选种子且保持默认参数时，可观察小面积孔壁
  （r=1.5，面积≈28）是否被回退链纳入 —— 设计上孔壁互不相邻，不会被链式扩展。

### C03 POCKET 正常：单沉台

- 选择 `POCKET` 模式。
- 种子面：沉台底面环形面 `(30, 0, -4)`（R=20..40，z=-4，双边界环）。
- 预期：模块找到外壁（高 4）与内孔壁（高 8，满足 `outerScore < innerScore` 区分条件），
  复制内环/基准环构造线，删除沉台面与外壁面，将内环与基准环 `*surfacecreateruled` 连接，
  `*selfstitchcombine` 缝合（`stitch_tolerance=0.2`）。处理后面数减少，沉台被补平，
  中央仅剩一个通孔（R=20 贯穿顶面）。
- 验证点：新连接面归集到原沉台 component；控制台输出 `POCKET` 与 `new_surfs` 非空。

### C04 POCKET 多个：同板 3 个沉台

- 选择 `POCKET` 模式（连续清洗）。
- 种子面（依次选择三个底面，逐个中键执行）：
  - A：`(321.5, 0, -4)`，R=45 深 4；
  - B：`(391, 55, -3)`，R=30 深 3；
  - C：`(447.5, -40, -2)`，R=45 深 2。
- 预期：三个沉台各自独立完成补平，互不影响；深度 2/3/4 均小于板厚一半（6），
  外壁高严格小于内孔壁高，可被 `classifyPocketLoops` 可靠区分。
- 验证点：三个底面逐次消失，最终顶面仅剩三个通孔；完成计数为 3。

### C05 AUTO 模式：顶缘圆角链 + 中央沉台

- 选择 `AUTO` 模式，保持默认参数。
- 种子面（两个入口，分别验证分派）：
  - 顶缘圆角面 `(590, -79.9, -1.8)`（r=2）：AUTO 应分派 **CHAMFER**，清除 4 面圆角环并重建实体；
  - 沉台底面 `(750, 0, -4)`：AUTO 应分派 **POCKET**，补平沉台。
- 预期：Tcl 日志先打印“模式：CHAMFER/POCKET”，按对应流程执行；控制台 `mode=` 与实际行为一致。

### C06 失败：纯拉伸 U 型槽（无圆角无沉台）

- 选择 `CHAMFER` 模式（或任一模式）。
- 种子面：底腹板平面 `(1270, 0, 0)`（300x120）。
- 预期：半径查询为空、种子面无圆角 → 模块报
  “倒角/圆角清理失败：surfacefilletremove=...；fillet query=...”，
  **不删除任何面**；即使 `*surfacefilletremove` 以空链“成功”，也不产生删除
  （无圆角面可删），实体与 10 个面保持完整。连续清洗计数 `failed` 加 1 后继续等待。
- 验证点：处理前后 U 型槽面数不变（10），无任何 surface 被删除。

## 失败形态总览（模块对不支持输入的行为）

对照 `modules/geometry_cleanup.tcl` 源码确认的判定标准：

| 输入形态 | 模块行为 |
| --- | --- |
| 无候选圆角（平面种子，`chain_by_small_area=0`） | `removeChamfer` 报错“倒角/圆角清理失败：surfacefilletremove=...；fillet query=...”，不删面 |
| 无候选圆角（平面种子，默认 `chain_by_small_area=1`） | 回退链为空或仅含平面种子，同上报错或空操作，不删面 |
| 种子面边界环数 != 2（POCKET/AUTO 回退） | `removePocket` 报错“要求恰好一个外边和一个内边”，不删面 |
| 沉台壁高无法区分（外壁≈内孔壁） | `classifyPocketLoops` 报错“无法可靠区分…已停止，避免误删其他平面” |
| 找不到壁面/基准边 | 报错“未找到…竖直连接面/基准边/孔壁/基准平面”，不删面 |
| 连续清洗中单面失败 | 捕获错误，`failed` 计数 +1，继续等待下一次选面，不中断 |
| 倒角清理成功后的实体重建 | `create_solid_from_chamfer_bounds=1` 时对封闭 surface 边界尝试 `*solids_create_from_surfaces` |

## 边界与注意事项

- 本模型用于模块**识别与流程验证**，不是生产求解模型；几何尺寸为整数/半圆构造，便于坐标核对。
- 沉台场景要求外壁高（沉孔深 d）< 板厚一半，且沉孔半径 > 通孔半径，以符合
  `classifyPocketLoops` 的“外环短、内环长”区分逻辑；请勿改动尺寸比例。
- C07 的凸弧链截断验证依赖默认 `max_chain_depth=6`；修改该参数会改变 `target_surfs` 预期长度。
- STEP 导出由 OCCT 写入元数据（非几何），多次生成文件字节可能不同，但几何签名（体积/面数/bbox）
  恒定（已验证确定性）。

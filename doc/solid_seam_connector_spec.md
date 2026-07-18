# 实体焊缝自动识别与创建模块 Spec

## 1. 文档目的

本文档用于指导在现有 HyperMesh 工具箱项目中新增“实体焊缝自动识别与创建”模块。

模块基于以下技术路线：

- 使用 HyperMesh 自带的 Components 选择器完成组件选择；
- 使用 Tcl 获取 HyperMesh 模型数据、控制界面、显示候选结果并执行焊缝创建；
- 使用 Python 对已选组件进行网格拓扑分析、自由边识别、候选焊缝识别、接头类型分类和结果校核；
- 使用 HyperMesh 原生 seam connector 完成 PENTA 焊缝单元及其两侧 RBE3 连接的创建；
- Python 不直接创建 PENTA、RBE3、Connector 或修改模型网格。

本次实现范围包括：

- V1：最小闭环；
- V2：多组件识别；
- V4：多种 PENTA 类型分类与创建；
- V5：创建后校核与日志。

---

# 2. 模块定位

## 2.1 核心目标

用户选择两个或多个 Components 后，模块自动完成：

1. 判断选中组件中的 Solid 与 Shell 类型；
2. 根据选择模式确定需要分析的组件组合；
3. 从 Solid Component 中提取可用于创建 seam connector 的自由边或特征边；
4. 判断这些边与已选目标 Component 之间是否存在合理的实体焊缝关系；
5. 将连续候选边组织为可供 HyperMesh seam connector 使用的 nodelist；
6. 判断候选焊缝对应的接头类型及建议的 PENTA realization 类型；
7. 在 HyperMesh 中对候选焊缝进行预览、确认、修改和批量处理；
8. 调用 HyperMesh 原生 seam connector 创建 PENTA 焊缝；
9. 检查 realization 状态、连接对象、单元数量、单元质量和重复焊缝；
10. 输出完整操作日志和结果报告。

## 2.2 模块不负责的内容

本模块不负责：

- Shell–Shell 焊缝创建；
- Python 直接创建 PENTA 单元；
- Python 直接创建 RBE3；
- Python 直接创建 Connector；
- Shell 厚度、Z0、offset 或真实表面重建；
- 对 Shell 中面到实体边之间的距离进行厚度修正；
- 根据焊缝工艺图自动判断焊角尺寸；
- 修改实体或 Shell 网格；
- 自动修复不合格网格；
- 多组件模式下的 Solid–Solid 自动识别；
- 根据 CAD 几何重建焊缝。

---

# 3. 工程假设

## 3.1 Solid–Shell 连接

以铸件与钣金件 T 型焊接为例：

- 钣金件已抽取中面并划分 Shell 网格；
- 铸件已划分 Solid 网格；
- 实体边与 Shell 中面之间可以存在明显距离；
- 该距离不代表不存在焊缝；
- HyperMesh seam connector 会基于实体侧 nodelist 创建 PENTA；
- HyperMesh 再通过 RBE3 将 PENTA 与实体和 Shell 组件连接；
- 因此，本模块只需识别合适的实体侧 nodelist 和目标组件，不进行 Shell 厚度或偏移修正。

## 3.2 Solid–Solid 连接

Solid–Solid 焊缝仅在以下条件下启用：

- 用户恰好选择两个 Components；
- 两个 Components 均为 Solid Components。

当用户选择三个及以上 Components 时：

- 只处理 Solid–Shell；
- 不处理任何 Solid–Solid 组合。

## 3.3 Nodelist 来源

正常情况下，焊缝 nodelist 来源于 Solid Component 上靠近被焊接区域的：

- 外表面边界边；
- 外表面明显特征边；
- 由多个连续网格边组成的边链；
- 闭合边链。

Shell Component 不作为焊缝 nodelist 的来源。

---

# 4. 用户操作流程

```text
启动模块
  ↓
调用 HyperMesh 原生 Components 选择器
  ↓
用户选择两个或多个 Components
  ↓
Tcl 分类 Solid / Shell / Mixed / Unsupported
  ↓
判定运行模式
  ↓
导出相关网格拓扑数据
  ↓
Python 识别候选焊缝
  ↓
返回候选 nodelist、目标组件、接头类型和建议 realization
  ↓
Tcl 在 HyperMesh 中展示候选结果
  ↓
用户批量或逐条确认
  ↓
Tcl 调用原生 seam connector
  ↓
HyperMesh 创建 PENTA + RBE3
  ↓
执行创建后校核
  ↓
输出结果摘要和日志
```

---

# 5. 运行模式判定

## 5.1 组件分类

Tcl 应对每个选中 Component 统计其包含的二维、三维单元数量，并分类为：

```text
SOLID
SHELL
MIXED
EMPTY
UNSUPPORTED
```

判定原则：

- 仅包含受支持三维单元：`SOLID`
- 仅包含受支持二维单元：`SHELL`
- 同时包含二维和三维单元：`MIXED`
- 不包含单元：`EMPTY`
- 仅包含当前模块不支持的单元类型：`UNSUPPORTED`

第一版对 `MIXED` Component 不自动拆分，应提示用户将其拆成独立 Components。

## 5.2 模式规则

### 模式 A：两个 Solid

```text
selected_count = 2
solid_count = 2
shell_count = 0
```

进入：

```text
SOLID_SOLID_PAIR
```

处理：

```text
Solid A ↔ Solid B
```

### 模式 B：一个 Solid + 一个 Shell

```text
selected_count = 2
solid_count = 1
shell_count = 1
```

进入：

```text
SOLID_SHELL_PAIR
```

处理：

```text
Solid → Shell
```

### 模式 C：多个 Components

```text
selected_count > 2
solid_count >= 1
shell_count >= 1
```

进入：

```text
MULTI_SOLID_SHELL
```

处理：

```text
每个 Solid × 每个 Shell
```

不处理：

```text
Solid × Solid
Shell × Shell
```

### 模式 D：全部为 Shell

终止，并提示：

```text
当前选择中不存在实体组件。
Shell–Shell 连接应使用现有 Shell 焊缝模块。
```

### 模式 E：只选择一个 Component

终止，并提示至少选择两个 Components。

### 模式 F：存在 Mixed / Empty / Unsupported

列出问题 Components，阻止进入识别流程，避免隐式跳过。

---

# 6. 系统架构

```text
solid_seam/
├─ tcl/
│  ├─ main.tcl
│  ├─ ui.tcl
│  ├─ component_selector.tcl
│  ├─ component_classifier.tcl
│  ├─ mesh_exporter.tcl
│  ├─ python_bridge.tcl
│  ├─ candidate_viewer.tcl
│  ├─ candidate_editor.tcl
│  ├─ seam_creator.tcl
│  ├─ realization_profiles.tcl
│  ├─ realization_validator.tcl
│  └─ logger.tcl
│
├─ python/
│  ├─ main.py
│  ├─ schema.py
│  ├─ mesh_reader.py
│  ├─ solid_surface_extractor.py
│  ├─ solid_edge_extractor.py
│  ├─ target_surface_builder.py
│  ├─ spatial_index.py
│  ├─ candidate_detector.py
│  ├─ edge_chain_builder.py
│  ├─ joint_classifier.py
│  ├─ confidence.py
│  ├─ duplicate_detector.py
│  ├─ result_validator.py
│  └─ result_writer.py
│
├─ config/
│  ├─ detection_defaults.json
│  ├─ realization_profiles.json
│  └─ solver_profiles.json
│
├─ runtime/
│  ├─ request.json
│  ├─ mesh_data.json
│  ├─ candidates.json
│  ├─ accepted_candidates.json
│  ├─ realization_result.json
│  └─ operation.log
│
└─ tests/
   ├─ fixtures/
   ├─ unit/
   ├─ integration/
   └─ acceptance/
```

---

# 7. Tcl 与 Python 职责边界

## 7.1 Tcl 职责

Tcl 负责：

- 调用 HyperMesh Components 选择器；
- 获取选中 Component IDs；
- 统计单元类型；
- 导出节点、单元、组件和已有 Connector 信息；
- 启动 Python；
- 读取 Python 输出；
- 在 HyperMesh 中显示候选 nodelist；
- 控制局部显示、隔离、缩放和高亮；
- 记录用户接受、拒绝和修改；
- 根据 node IDs 创建节点 mark 或 nodelist；
- 调用 HyperMesh 原生 seam connector；
- 设置 link Components；
- 应用 realization profile；
- 执行 realize；
- 获取 Connector 状态；
- 获取新生成的 PENTA、RBE3 和相关实体；
- 执行创建后校核；
- 输出日志和结果摘要。

## 7.2 Python 职责

Python 负责：

- 读取 Tcl 导出的网格数据；
- 提取 Solid 外表面；
- 提取外表面边界边和特征边；
- 构建 Shell 或 Solid 目标表面空间索引；
- 对 Solid 候选边执行邻近搜索；
- 判断候选边与目标组件之间是否存在合理焊缝关系；
- 将连续边合并为候选边链；
- 对候选进行分段；
- 判断 T、LAP、BUTT、ANGLED、UNKNOWN；
- 推荐 PENTA realization 类型；
- 计算置信度；
- 标记疑似重复焊缝；
- 输出结构化候选数据；
- 不修改 HyperMesh 模型。

---

# 8. 数据交换格式

## 8.1 request.json

```json
{
  "schema_version": "1.0",
  "run_id": "20260715_130000_001",
  "mode": "MULTI_SOLID_SHELL",
  "selected_component_ids": [10, 20, 30],
  "solid_component_ids": [10],
  "shell_component_ids": [20, 30],
  "settings": {
    "search_distance": 15.0,
    "max_search_distance": 25.0,
    "min_weld_length": 20.0,
    "min_valid_ratio": 0.7,
    "feature_angle_deg": 35.0,
    "max_chain_turn_angle_deg": 60.0,
    "gap_jump_limit": 5.0,
    "allow_closed_loop": true,
    "detect_duplicates": true
  }
}
```

## 8.2 mesh_data.json

应包含：

```json
{
  "schema_version": "1.0",
  "components": [],
  "nodes": [],
  "elements": [],
  "existing_connectors": []
}
```

### Component

```json
{
  "component_id": 10,
  "component_name": "CASTING_A",
  "mesh_class": "SOLID"
}
```

### Node

```json
{
  "node_id": 1001,
  "xyz": [0.0, 10.0, 25.0]
}
```

### Element

```json
{
  "element_id": 5001,
  "component_id": 10,
  "element_type": "CHEXA",
  "node_ids": [1, 2, 3, 4, 5, 6, 7, 8]
}
```

### Existing Connector

```json
{
  "connector_id": 9001,
  "connector_type": "seam",
  "linked_component_ids": [10, 20],
  "state": "realized",
  "location_node_ids": [100, 101, 102]
}
```

## 8.3 candidates.json

```json
{
  "schema_version": "1.0",
  "run_id": "20260715_130000_001",
  "summary": {
    "candidate_count": 4,
    "high_confidence_count": 2,
    "review_count": 1,
    "low_confidence_count": 1
  },
  "candidates": []
}
```

单条候选：

```json
{
  "candidate_id": "C0001",
  "source_solid": {
    "component_id": 10,
    "component_name": "CASTING_A"
  },
  "target_component": {
    "component_id": 20,
    "component_name": "SHELL_FRAME",
    "mesh_class": "SHELL"
  },
  "connection_mode": "SOLID_SHELL",
  "edge_class": "SOLID_FEATURE_EDGE",
  "node_ids": [1001, 1002, 1003, 1004],
  "edge_ids": [
    [1001, 1002],
    [1002, 1003],
    [1003, 1004]
  ],
  "is_closed": false,
  "joint_type": "T_JOINT",
  "suggested_realization": "PENTA_MIG_T",
  "length": 82.5,
  "average_distance": 4.2,
  "maximum_distance": 5.1,
  "valid_ratio": 0.94,
  "confidence": 0.91,
  "confidence_level": "HIGH",
  "duplicate_state": "NONE",
  "warnings": []
}
```

---

# 9. Solid 外表面提取

## 9.1 支持单元类型

第一版至少支持：

- CHEXA；
- CPENTA；
- CTETRA；
- CPYRA。

所有单元面的节点顺序必须在单元模板中明确配置。

## 9.2 外表面判断

对每个 Solid 单元展开其所有面。

对每个面生成无方向 Key：

```text
face_key = sorted(node_ids)
```

统计同一 `face_key` 出现次数：

- 出现 1 次：外表面；
- 出现 2 次：内部共享面；
- 出现大于 2 次：非流形区域，记录警告。

输出结构：

```text
SurfaceFace
├─ face_id
├─ parent_element_id
├─ component_id
├─ node_ids
├─ centroid
├─ normal
├─ area
└─ face_type
```

---

# 10. Solid 候选边提取

## 10.1 外表面边分类

从外表面面片中提取所有边。

每条边分类为：

```text
SOLID_BOUNDARY_EDGE
SOLID_FEATURE_EDGE
IGNORE
```

## 10.2 边界边

若一条边仅被一个外表面面片引用，则视为：

```text
SOLID_BOUNDARY_EDGE
```

## 10.3 特征边

若一条边被两个外表面面片引用，计算两侧面夹角：

$$
\alpha =
\cos^{-1}
\left(
\operatorname{clamp}
\left(
\mathbf n_1 \cdot \mathbf n_2,
-1,
1
\right)
\right)
$$

当：

```text
alpha >= feature_angle_deg
```

则视为：

```text
SOLID_FEATURE_EDGE
```

普通共面或近共面的表面内部网格边必须忽略。

## 10.4 边优先级

```text
BOUNDARY_EDGE > FEATURE_EDGE > IGNORE
```

当同一候选路径同时包含边界边和特征边时，应允许合并，但记录组成比例。

---

# 11. 目标组件表面构建

## 11.1 Shell 目标

Shell Component 直接使用其 Shell 单元中面作为搜索目标。

不进行：

- 厚度偏移；
- Top/Bottom 重建；
- Z0 修正；
- 法向侧选择。

## 11.2 Solid 目标

Solid–Solid 模式中：

- 对目标 Solid 同样提取外表面；
- 候选 Solid 边到目标 Solid 外表面进行距离和投影判断。

## 11.3 空间索引

目标面片必须建立空间索引，优先使用：

- AABB Tree；
- BVH；
- R-tree；
- KD-tree 仅可用于粗筛，不能替代面投影。

---

# 12. 候选焊缝识别

## 12.1 粗筛

先比较 Source Solid 与 Target Component 的扩展包围盒。

若扩展后的包围盒不相交，则跳过该组件组合。

## 12.2 边采样

对每条候选边进行采样：

- 至少包含两个端点；
- 长边按采样步长增加中间点；
- 采样步长建议为局部平均边长的 0.5～1.0 倍；
- 曲折边链应在每个原始边段上采样。

## 12.3 距离判定

对每个采样点计算到目标面片的最近距离。

候选边的基本有效条件：

```text
valid_ratio >= min_valid_ratio
average_distance <= search_distance
maximum_distance <= max_search_distance
```

这里的 distance 是 Connector 搜索意义上的邻近距离，不是物理接触间隙。

## 12.4 连续性判定

要求最近目标面片沿候选边方向连续。

以下情况应降低置信度或拆分：

- 最近面片在相距很远的区域之间跳变；
- 距离突然发生大幅变化；
- 中间存在长距离无效区段；
- 同一边链局部对应多个目标 Component。

## 12.5 有效段提取

一条原始边可以只有部分区段有效。

算法应：

1. 对采样点标记有效/无效；
2. 提取连续有效区段；
3. 将有效区段映射回原始边；
4. 以节点为边界进行分段；
5. 不允许在节点中间创建虚构的新节点。

---

# 13. 边链构建

## 13.1 合并条件

两条边可以合并为同一候选边链，当且仅当：

- 共享端点；
- 属于同一个 Source Solid；
- 对应同一个 Target Component；
- 接头类型兼容；
- 距离变化连续；
- 最近目标面片区域连续；
- 转角不超过 `max_chain_turn_angle_deg`；
- 不跨越无效段；
- 未检测到明显拓扑分叉。

## 13.2 分叉处理

当一个节点连接三条及以上候选边时：

- 不自动跨越分叉；
- 每条分支分别生成候选；
- 标记 `BRANCH_POINT` 警告；
- 交由用户确认。

## 13.3 闭合链

若首尾节点相同，且整条路径有效，则：

```text
is_closed = true
```

闭合链应作为一条候选输出。

若闭合链存在局部无效段，则拆分为一个或多个开链。

## 13.4 最短长度

若候选边链长度小于：

```text
min_weld_length
```

则默认丢弃，除非用户启用“保留短焊缝候选”。

---

# 14. 接头类型分类

## 14.1 分类结果

```text
T_JOINT
LAP_JOINT
BUTT_JOINT
ANGLED_JOINT
UNKNOWN
```

## 14.2 PENTA realization 映射

```text
T_JOINT       → PENTA_MIG_T
LAP_JOINT     → PENTA_MIG_L
BUTT_JOINT    → PENTA_MIG_B
ANGLED_JOINT  → PENTA_MIG
UNKNOWN       → PENTA_MIG
```

## 14.3 T 型焊缝

典型判断：

- Source Solid 候选边靠近 Target 面内部；
- 目标最近点不是主要落在 Target 自由边；
- Source 相邻表面与 Target 表面的局部法向关系接近 T 型；
- 沿候选边方向距离和投影连续。

建议输出：

```text
joint_type = T_JOINT
suggested_realization = PENTA_MIG_T
```

## 14.4 搭接焊缝

典型判断：

- Source 候选边位于 Target 表面覆盖区域边缘；
- Source 邻近表面与 Target 表面近似平行；
- 存在一定投影重叠；
- 焊缝位于重叠区域边界。

建议输出：

```text
joint_type = LAP_JOINT
suggested_realization = PENTA_MIG_L
```

程序不自动决定单边焊或双边焊，必须由用户确认 realization profile。

## 14.5 对接焊缝

典型判断：

- Source 候选边靠近 Target 的边界或特征边；
- 两条边切向近似一致；
- 两侧相邻表面近似共面；
- 最近点主要落在 Target 边缘附近。

建议输出：

```text
joint_type = BUTT_JOINT
suggested_realization = PENTA_MIG_B
```

## 14.6 斜接与未知

当接近关系明确，但无法稳定归入 T/L/B 时：

```text
joint_type = ANGLED_JOINT 或 UNKNOWN
suggested_realization = PENTA_MIG
```

---

# 15. 置信度模型

建议计算：

$$
C =
w_d C_d +
w_v C_v +
w_c C_c +
w_t C_t +
w_u C_u +
w_r C_r
$$

其中：

- $C_d$：平均距离和最大距离合理性；
- $C_v$：有效采样比例；
- $C_c$：路径连续性；
- $C_t$：接头类型匹配度；
- $C_u$：目标组件唯一性；
- $C_r$：是否疑似重复。

默认分级：

```text
C >= 0.85       HIGH
0.60 <= C < 0.85 REVIEW
C < 0.60        LOW
```

默认行为：

- `HIGH`：批量页默认勾选；
- `REVIEW`：默认不勾选，要求人工确认；
- `LOW`：仅显示，不允许直接批量创建；
- 存在严重警告时，即使置信度高，也不得默认勾选。

---

# 16. 多组件识别规则

当用户选择多个 Components：

```python
for solid in selected_solids:
    candidate_edges = extract_candidate_edges(solid)

    for shell in selected_shells:
        detect_candidates(
            source_solid=solid,
            target_component=shell,
            candidate_edges=candidate_edges
        )
```

明确禁止：

```python
for solid_a in selected_solids:
    for solid_b in selected_solids:
        detect_solid_solid(...)
```

示例：

```text
选择：
Solid A
Solid B
Shell C
Shell D

处理：
Solid A → Shell C
Solid A → Shell D
Solid B → Shell C
Solid B → Shell D

不处理：
Solid A ↔ Solid B
Shell C ↔ Shell D
```

---

# 17. 候选结果界面

## 17.1 主结果页

按 Source Solid 分组：

```text
CASTING_A
├─ → SHELL_01：3 条
├─ → SHELL_02：1 条
└─ → SHELL_03：0 条

CASTING_B
├─ → SHELL_01：2 条
└─ → SHELL_02：1 条
```

至少显示：

- Source Component；
- Target Component；
- 接头类型；
- 建议 realization；
- nodelist 节点数；
- 长度；
- 平均距离；
- 最大距离；
- 置信度；
- 是否疑似重复；
- 当前状态。

候选状态：

```text
PENDING
ACCEPTED
REJECTED
CREATED
FAILED
SKIPPED
```

## 17.2 操作按钮

至少包括：

```text
全部显示
逐条审查
接受全部高置信度
取消全部
创建已接受焊缝
重新识别
导出结果
关闭
```

## 17.3 逐条审查

至少支持：

```text
上一条
下一条
接受
拒绝
修改 PENTA 类型
修改 realization profile
反转 nodelist 顺序
局部显示
恢复显示
创建当前项
```

本次不强制实现：

- 手工拆分候选；
- 手工合并候选；
- 在 GUI 中编辑节点序列。

但内部数据结构必须为后续功能预留。

---

# 18. HyperMesh 候选显示

候选预览不得修改原模型拓扑。

可采用：

- 临时 node mark；
- 临时 line；
- 临时 component；
- 临时 plot element；
- HyperMesh 高亮机制。

显示规则：

- Source Solid：保持可见；
- Target Component：保持可见；
- 当前候选 nodelist：高亮；
- 其他选中组件：可选半透明或隐藏；
- 自动 fit 当前候选区域；
- 退出逐条审查时恢复用户原始显示状态。

必须保存和恢复：

- Component 显示状态；
- Element 显示状态；
- 当前选择；
- 颜色或临时高亮状态；
- 当前视角，若实现成本可控。

---

# 19. seam connector 创建

## 19.1 创建输入

对每条已接受候选，Tcl 必须提供：

```text
source_solid_component_id
target_component_id
node_ids
suggested_realization
selected_realization_profile
```

## 19.2 创建步骤

```text
1. 校验所有 node_ids 仍存在；
2. 校验 Source 和 Target Components 仍存在；
3. 校验 Source 与 Target 不相同；
4. 清理旧 mark；
5. 按 node_ids 创建 nodelist 或节点 mark；
6. 创建 seam connector；
7. 设置两个 link Components；
8. 应用 realization profile；
9. 执行 realize；
10. 读取 Connector 状态；
11. 收集新生成的 PENTA、RBE3 和 Connector ID；
12. 执行创建后校核；
13. 写入日志。
```

## 19.3 realization profile

必须通过人工在目标 HyperMesh 版本中分别创建以下焊缝，并读取 Command File：

```text
PENTA_MIG
PENTA_MIG_T
PENTA_MIG_L
PENTA_MIG_B
```

将稳定命令封装为 realization profiles。

配置示例：

```json
{
  "PENTA_MIG_T_DEFAULT": {
    "realization_type": "PENTA_MIG_T",
    "display_name": "penta (mig + T)",
    "solver": "OptiStruct",
    "hypermesh_version": "2019",
    "default_width": 6.0,
    "default_tolerance": 15.0,
    "side_mode": "AUTO",
    "command_profile": "hm2019_penta_mig_t"
  }
}
```

禁止根据未经验证的猜测拼接 Connector realization 参数。

---

# 20. 创建前校验

每条候选创建前必须检查：

- Source Component 存在；
- Target Component 存在；
- node_ids 数量不少于 2；
- node_ids 顺序连续；
- 相邻节点之间确实存在候选边；
- nodelist 不包含重复节点，闭环首尾约定除外；
- 候选未被用户拒绝；
- realization profile 存在；
- 当前求解器与 profile 匹配；
- 候选未被标记为严重重复；
- 同一 Candidate 未重复创建。

校验失败时：

- 不执行 HyperMesh 创建命令；
- 状态设置为 `SKIPPED` 或 `FAILED`；
- 记录明确原因。

---

# 21. 创建后校核

## 21.1 Connector 状态

至少识别：

```text
REALIZED
UNREALIZED
FAILED
PARTIAL
UNKNOWN
```

非 `REALIZED` 状态均视为失败或需复核。

## 21.2 PENTA 数量

检查：

- 是否生成 PENTA；
- PENTA 数量是否大于 0；
- PENTA 是否位于预期焊缝区域；
- 闭合焊缝是否首尾连续；
- PENTA 数量相对 nodelist 长度是否明显异常。

## 21.3 RBE3 检查

检查：

- 是否生成连接两侧的 RBE3；
- RBE3 是否分别关联 Source 和 Target；
- 是否只连接到预期 Components；
- RBE3 独立节点距离是否异常；
- RBE3 是否出现空从属节点集。

## 21.4 组件关联检查

检查新生成实体是否关联到：

```text
source_solid_component_id
target_component_id
```

若连接到第三方 Component，则标记严重错误。

## 21.5 重复焊缝检查

创建前和创建后均应检查：

- 相同 Source–Target Component Pair；
- 相似 nodelist；
- 相同空间区域已有 seam connector；
- 已有 PENTA 焊缝；
- 当前批次内部候选重叠。

重复状态：

```text
NONE
POSSIBLE
CONFIRMED
```

`CONFIRMED` 默认禁止创建。

## 21.6 PENTA 质量检查

至少支持读取或计算：

- Jacobian；
- aspect ratio；
- minimum angle；
- maximum angle；
- volume；
- negative volume；
- warpage，若当前单元定义适用。

质量阈值必须从配置读取，不硬编码。

## 21.7 结果分级

```text
PASS
PASS_WITH_WARNING
FAIL
```

判定示例：

- Connector REALIZED，PENTA > 0，RBE3 正确，质量合格：`PASS`
- Connector REALIZED，但部分质量指标超限：`PASS_WITH_WARNING`
- Connector FAILED 或未生成 PENTA：`FAIL`

---

# 22. 日志

## 22.1 日志内容

每次运行应记录：

- run_id；
- 时间；
- HyperMesh 版本；
- 求解器模板；
- 选中 Components；
- 模式；
- 参数；
- Python 执行状态；
- 识别候选数量；
- 每条候选状态；
- 用户修改记录；
- Connector ID；
- 新生成 PENTA 数量；
- 新生成 RBE3 数量；
- realization 状态；
- 校核结果；
- 错误堆栈或 Tcl/Python 异常。

## 22.2 日志级别

```text
DEBUG
INFO
WARNING
ERROR
CRITICAL
```

## 22.3 日志文件

```text
runtime/operation.log
runtime/realization_result.json
```

日志必须便于用户复制后交给 Agent 排查。

---

# 23. 配置项

## 23.1 detection_defaults.json

建议包含：

```json
{
  "search_distance": 15.0,
  "max_search_distance": 25.0,
  "min_weld_length": 20.0,
  "min_valid_ratio": 0.7,
  "feature_angle_deg": 35.0,
  "max_chain_turn_angle_deg": 60.0,
  "gap_jump_limit": 5.0,
  "allow_closed_loop": true,
  "retain_short_candidates": false,
  "detect_duplicates": true,
  "high_confidence_threshold": 0.85,
  "review_confidence_threshold": 0.60
}
```

## 23.2 用户可调参数

第一版 GUI 至少开放：

- Connector 搜索距离；
- 最大搜索距离；
- 最小焊缝长度；
- 特征边角度；
- 是否识别闭合焊缝；
- 是否检测重复焊缝；
- 默认 realization profile；
- 是否自动勾选高置信度项。

高级参数可放入折叠区域或配置文件。

---

# 24. 异常处理

## 24.1 Python 启动失败

提示：

```text
焊缝识别程序启动失败。
请检查 Python 运行环境、脚本路径和运行日志。
```

不得继续创建。

## 24.2 Python 输出无效

包括：

- JSON 不存在；
- JSON 无法解析；
- schema_version 不支持；
- candidate node IDs 不存在；
- Component IDs 不存在。

均应终止并记录错误。

## 24.3 HyperMesh 创建失败

单条失败不得中断整个批次。

应：

1. 将当前项设置为 FAILED；
2. 记录完整命令上下文；
3. 清理当前 mark；
4. 继续下一条；
5. 批次结束后统一汇总。

## 24.4 用户中止

用户中止时：

- 停止创建后续候选；
- 不回滚已成功创建的焊缝；
- 将未处理项标记为 `SKIPPED_BY_USER`；
- 输出当前进度和结果摘要。

---

# 25. 性能要求

## 25.1 Python 识别

目标：

- 不对整个模型做无差别扫描；
- 仅导出选中 Components；
- 先做 Component BBox 粗筛；
- 目标表面建立一次空间索引；
- Source Solid 外表面和候选边只提取一次；
- 多 Shell 目标可分别建立缓存；
- 多组件识别中避免重复解析节点和单元。

## 25.2 Tcl

Tcl 不应逐个单元执行复杂几何识别。

Tcl 只负责：

- 数据导出；
- 结果显示；
- Connector 创建；
- 校核数据读取。

## 25.3 进度反馈

GUI 至少显示：

```text
正在读取组件
正在导出网格
正在识别 Solid 1/3
正在分析目标组件 2/5
正在创建焊缝 4/12
正在执行结果校核
```

---

# 26. 测试方案

## 26.1 单元测试

Python：

- CHEXA 外表面提取；
- CPENTA 外表面提取；
- CTETRA 外表面提取；
- CPYRA 外表面提取；
- 边界边识别；
- 特征边识别；
- 闭合边链；
- 分叉边链；
- 边链合并；
- T/L/B 分类；
- 置信度计算；
- 重复候选识别。

## 26.2 集成测试

至少准备以下模型：

### Case 1：Solid–Shell 单条 T 型焊缝

预期：

- 识别 1 条候选；
- 类型为 T；
- 可成功创建 PENTA + RBE3；
- 校核通过。

### Case 2：Solid–Solid 单条 T 型焊缝

仅选择两个 Solid。

预期：

- 进入 SOLID_SOLID_PAIR；
- 识别候选；
- 创建成功。

### Case 3：多组件模式

选择：

```text
2 个 Solid
3 个 Shell
```

预期：

- 仅分析 6 个 Solid–Shell Pair；
- 不分析 Solid–Solid；
- 结果按 Source Solid 分组。

### Case 4：Shell–Shell

预期：

- 阻止执行；
- 提示使用 Shell 焊缝模块。

### Case 5：搭接焊缝

预期：

- 分类为 LAP；
- 推荐 PENTA_MIG_L；
- 允许用户修改 profile。

### Case 6：对接焊缝

预期：

- 分类为 BUTT；
- 推荐 PENTA_MIG_B。

### Case 7：未知复杂连接

预期：

- 分类为 ANGLED 或 UNKNOWN；
- 推荐 PENTA_MIG；
- 置信度为 REVIEW 或 LOW。

### Case 8：重复焊缝

模型中已有 seam connector。

预期：

- 标记 POSSIBLE 或 CONFIRMED；
- 默认不创建。

### Case 9：Connector realization 失败

故意使用不兼容 profile。

预期：

- 当前候选失败；
- 批次继续；
- 日志中包含失败原因。

### Case 10：PENTA 质量不合格

预期：

- Connector 状态可为 REALIZED；
- 最终结果为 PASS_WITH_WARNING 或 FAIL；
- 质量问题明细可查看。

---

# 27. 验收标准

## 27.1 V1 验收

- 可调用 HyperMesh 原生 Components 选择器；
- 支持两个 Components；
- 正确区分 Solid–Shell、Solid–Solid、Shell–Shell；
- 可提取 Solid 外表面边界边；
- 可识别至少一种 T 型候选；
- 可返回连续 node IDs；
- 可在 HyperMesh 中预览；
- 可由用户确认；
- 可调用 seam connector 创建 PENTA + RBE3；
- 可读取 realization 状态；
- 单条失败不会导致程序崩溃。

## 27.2 V2 验收

- 支持选择三个及以上 Components；
- 正确分类 Solid 和 Shell；
- 对每个 Solid 与每个 Shell 逐对分析；
- 不分析多组件选择中的 Solid–Solid；
- 结果按 Source Solid 和 Target Shell 分组；
- 可批量接受高置信度候选；
- 可批量创建；
- 可显示整体进度。

## 27.3 V4 验收

- 支持 T、LAP、BUTT、ANGLED、UNKNOWN；
- 分别推荐 PENTA_MIG_T、PENTA_MIG_L、PENTA_MIG_B、PENTA_MIG；
- 用户可修改建议类型；
- 不同 realization 使用独立 profile；
- profile 与 HyperMesh 版本和求解器模板绑定；
- profile 创建命令经过实际 Command File 验证。

## 27.4 V5 验收

- 创建后可读取 Connector 状态；
- 可检查 PENTA 是否生成；
- 可统计 PENTA 和 RBE3 数量；
- 可检查连接组件；
- 可检测重复焊缝；
- 可执行 PENTA 质量检查；
- 可生成 PASS / PASS_WITH_WARNING / FAIL；
- 可输出结构化结果文件和文本日志；
- 日志足以支持离线排查。

---

# 28. 推荐实施顺序

## 阶段 1：基础框架

- 新增模块入口；
- 接入 Components 选择器；
- 完成组件分类；
- 建立 Tcl–Python 数据交换；
- 建立运行目录和日志。

## 阶段 2：V1 最小闭环

- Solid 外表面提取；
- 边界边识别；
- 单个 Solid–Shell T 型识别；
- 单个 Solid–Solid T 型识别；
- 候选预览；
- 固定 PENTA_MIG_T profile；
- 创建与基础状态检查。

## 阶段 3：V2 多组件

- 多 Solid、多 Shell 分类；
- Pair 生成；
- 缓存外表面和空间索引；
- 批量结果页；
- 批量接受和批量创建；
- 进度与中止。

## 阶段 4：V4 多类型

- 特征边识别；
- T/LAP/BUTT/ANGLED 分类；
- realization profile 管理；
- 用户修改类型；
- PENTA_MIG、T、L、B 全部接入。

## 阶段 5：V5 校核

- Connector 状态；
- PENTA/RBE3 数量；
- 组件关联；
- 重复焊缝；
- PENTA 质量；
- 结果分级；
- 完整日志和报告。

---

# 29. 开发约束

- 不修改现有 Shell 焊缝模块行为；
- 新模块应复用现有项目中的 Python 启动、Tcl GUI、日志、配置和路径管理机制；
- 不引入必须联网安装的依赖；
- Python 依赖必须可离线打包；
- 不允许 Python 直接修改 HyperMesh 模型；
- 所有 HyperMesh 写操作必须集中在 Tcl 层；
- 所有 seam connector 命令必须从目标版本 Command File 验证；
- 每条候选必须具备唯一 Candidate ID；
- 所有批量操作必须允许中途停止；
- 单条失败不得使批次整体崩溃；
- 创建前后均应保留足够上下文，便于回溯。

---

# 30. 最终定义

本模块的核心行为定义为：

> 用户选择两个或多个 Components 后，系统从选中 Solid Components 的外表面边界边或特征边中，自动识别可作为实体焊缝 seam connector nodelist 的候选边链，并判断其应连接的已选目标 Component。Python 负责识别、分类和标注；Tcl 负责预览、用户确认、调用 HyperMesh 原生 seam connector，并对创建出的 PENTA 和 RBE3 进行校核。

多组件模式下：

> 仅执行每个 Solid 与每个 Shell 之间的识别，不执行 Solid–Solid。

双组件模式下：

> 当且仅当两个 Components 均为 Solid 时，允许执行 Solid–Solid 实体焊缝识别。

最终 PENTA 和 RBE3 的生成逻辑完全交由 HyperMesh 原生 connector realization 处理。

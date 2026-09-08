# local_mesh_optimizer — Large Quality-Defect Validation Model

## 用途
`LocalMeshOpt_80k.fem` 用于 `local_mesh_optimizer`（局部网格质量优化）的大规模验证：
向 5 张规则板注入 3000 个质量失败单元，供模块按 criteria 识别与修复，并验证
washer+RBE2 保护区应被跳过、干净对照板无退化。

## 场景表
| 组件 | 内容 | 预期 |
|---|---|---|
| V01..V05_MAIN_T1.5 | 5×38400 单元规则板，每板 600 缺陷（翘曲/瘦长 quad/大 skew/瘦长 tria） | 模块识别并修复；缺陷量大需分批 |
| V06_CONTROL_T1.5 | 干净对照板（无缺陷） | 质量达标基线 |
| V07..V18_WASHER_T1.5 | 12 个 washer+RBE2 保护区 | 模块应跳过（保护区） |
| AUTO_RBE2_V.. | 保护区 RBE2 输出组件 | 供跳过检测 |
| V19..V22_STRIP_T1.5 | 4 个窄条带区（宽 2 单元） | 模块边界处理 |

## 操作
1. HyperMesh 导入 `LocalMeshOpt_80k.fem`。
2. 选择 V01..V05 运行优化（criteria 与 manifest 一致）。
3. 核对 aspect_over_5 / quad_dev_over_45 数量下降、degenerate==0、0 保护区元素被修改。

## 设计说明
- 缺陷注入使用隔离式布局（缺陷单元相隔 8），保证邻近单元不退化为零面积。
- 缺陷类型：a) 法向偏移 2~6mm 翘曲、b) 0.35~0.6mm 窄 quad（aspect>5）、
  c) 面内移位 >45° 角偏（skew）、d) 长薄 CTRIA3（skinny, aspect>2.5）。
- 确定性生成（无随机）；生成时用 mesh_quality_stats 自检缺陷数量级与 degenerate==0。

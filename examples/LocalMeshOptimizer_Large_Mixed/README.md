# Local Mesh Optimizer large mixed FEM

运行：

```powershell
runtime\python\windows-x64\python.exe examples\LocalMeshOptimizer_Large_Mixed\generate_fem.py
```

默认生成：

- `LocalMeshOptimizer_Large_Mixed.fem`：大型 OptiStruct 壳网格；
- `LocalMeshOptimizer_Large_Mixed_manifest.json`：所有缺陷、washer、RBE2 和建议固定节点的准确 ID。

默认模型约有 6.2 万个壳单元，包含大面积规则四边形主体、1,200 个畸变 quad 切分候选、1,200 个瘦长 tria 短边合并候选、1,200 个细长内部 quad、12 个双层 washer（每个带中心 RBE2），以及 120 组人工失败簇。人工簇合计包含 840 个中等瘦长、零面积、自交、重复或 RBE2 保护单元。

可通过 `--nx`、`--ny`、`--washers`、`--split-defects`、`--narrow-defects`、`--skinny-defects` 和 `--manual-clusters` 调整规模与错误密度。

注意：最终失败集合由所选 `.criteria` 和 HyperMesh 原生检查决定。生成器只保证几何/拓扑测试意图，不伪造 criteria 判定。`MANUAL_*` 区域故意包含非法拓扑，只可用于测试，不能用于生产求解。

建议测试步骤：

1. 在 HyperMesh 2019 中导入 FEM，选择 OptiStruct profile。
2. 根据 manifest 核对 `SET3` 集合和 ID。
3. 将 `RECOMMENDED_USER_ANCHORS` 节点选为“固定节点”。
4. 保持 `EXCLUDE_WASHER_ELEMENTS=1`，先运行批量模式。
5. 使用同一模型、criteria 和参数切换旧版模式，比较两份性能报告。
6. 不要覆盖原 FEM；优化结果另存。

集合编号：

| SET3 | 内容 |
|---:|---|
| 1001 | 可处理的畸变 quad 切分候选 |
| 1002 | 可处理的瘦长 tria 合并候选 |
| 1003 | 可处理的细长内部 quad 候选 |
| 1101 | washer 壳单元 |
| 1102 | washer RBE2 |
| 1201-1206 | 不同类型的人工/无法安全处理缺陷 |
| 1207 | 建议手工固定的 RBE2 关联节点 |

`SET3` 是 OptiStruct 支持且在 HyperMesh 中表示为集合的 Bulk Data 卡；JSON manifest 仍是自动测试的权威 ID 清单。

# RBE2 washer 压力测试模型生成器

`generate_fem.py` 生成仅含壳单元的 OptiStruct FEM，模型中不预建 RBE2。每个孔都有两层 washer，四类测试位轮换排列，并严格对应 `config/washer_rules.txt`：

| 孔径 (mm) | 孔边节点 | washer 第 1 层 | washer 第 2 层 |
|---:|---:|---:|---:|
| 7.5 | 8 | 4 mm | 6 mm |
| 11 | 10 | 4 mm | 6 mm |
| 16 | 12 | 6 mm | 8 mm |
| 25 | 16 | 8 mm | 8 mm |

## 生成模型

默认 `large` 档包含 4 个连续壳平面，每个平面 32 x 24 个孔，共 3072 个预期 RBE2：

```powershell
python examples/RBE2_Washer_Stress/generate_fem.py
```

快速验证脚本和导入流程：

```powershell
python examples/RBE2_Washer_Stress/generate_fem.py --preset smoke
```

极限压力档包含 8000 个孔；`--fast-validation` 可跳过生成阶段耗时、占内存的全模型连通性和网格质量扫描：

```powershell
python examples/RBE2_Washer_Stress/generate_fem.py --preset extreme --fast-validation
```

也可完全自定义规模：

```powershell
python examples/RBE2_Washer_Stress/generate_fem.py --columns 60 --rows 50 --planes 6 --fast-validation
```

输出：

- `RBE2_Washer_Stress.fem`：HyperMesh/OptiStruct 输入模型。
- `RBE2_Washer_Stress_manifest.json`：规模、各类 washer 数量及预期 RBE2 数量。

## RBE2 测试建议

1. 在 HyperMesh 中导入生成的 FEM。
2. 打开 `Shell Washer-Hole RIGIDS`，选择全部 `RBE2_STRESS_PLANE_*` 组件。
3. 孔径范围使用 6–30 mm，`INNER_WASHER_NODE_LOOPS=2`，类型选择 RBE2。
4. 执行后，将实际创建数量与 manifest 的 `expected.created_rbe2` 比较。
5. 同时检查任务目录中的 `rigid_import.fem`、结果 JSON 和 `operation.log`，评估 Python 增量 FEM 生成及导入耗时。

默认输出文件属于可再生成的大文件，已通过 `.gitignore` 排除，不会误提交到仓库。

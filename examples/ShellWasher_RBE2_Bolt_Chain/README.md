# 大规模 Shell washer孔 -> RBE2 -> Bolt 压力测试模型

该示例用于测试完整链路的稳定性和速度：先从多层大型 Shell 平面上的 washer 孔创建 RBE2，再根据上下同轴的 RBE2 创建相邻层 bolt（CBEAM）。输入 FEM 只包含 Shell，不预置 RBE2 或 bolt。

## 模型规模

- 4 个平行、连续且共节点的矩形 Shell 平面，Z 坐标为 `0 / 20 / 40 / 60 mm`。
- 每个平面尺寸为 `1920 x 1440 mm`。
- 每层为 `16列 x 12行`，共有 192 个 washer 孔；四层共 768 个孔。
- 孔径按 `D8 / D12 / D18 / D26 mm` 循环排布，覆盖 `config/washer_rules.txt` 的全部 washer 区间。
- 四层的192个孔上下同轴，预期生成768个RBE2、192个同轴组和576段相邻层bolt。
- 当前FEM包含118788个节点和140160个Shell单元。

## 网格设计

washer区域继续使用已确认的规则：

- 孔边节点数为 `8 / 10 / 12 / 16`。
- 两层washer径向宽度为 `4+6 / 4+6 / 6+8 / 8+8 mm`。

非washer区域不再从圆环直接粗暴连接到方形边界，而是采用：

1. washer外环到16节点圆环的密度过渡；
2. 16节点圆环到32节点圆环的密度过渡；
3. 多层32节点圆角方形四边形环；
4. 相邻单元格边界合并节点，形成一整片连续Shell。

生成器内置的平面网格检查结果：

- 最大边长比：`3.109026`
- 最小单元角：`36.678411°`
- 最大四边形角度偏差：`45°`
- 边长比大于5：`0`
- 单元角小于20°：`0`
- 四边形角度偏差大于45°：`0`

## 生成FEM

```powershell
.\runtime\python\windows-x64\python.exe .\examples\ShellWasher_RBE2_Bolt_Chain\generate_fem.py
```

## 算法稳定性和速度检查

单次运行：

```powershell
.\runtime\python\windows-x64\python.exe .\examples\ShellWasher_RBE2_Bolt_Chain\validate_chain.py
```

连续运行5次并检查结果是否完全一致：

```powershell
.\runtime\python\windows-x64\python.exe .\examples\ShellWasher_RBE2_Bolt_Chain\validate_chain.py --repeat 5
```

输出分别记录模型构造、washer识别、bolt规划以及总耗时。该计时是纯数据Python核心基准；HyperMesh内实体创建、组件整理和界面刷新耗时仍需在HyperMesh 2019中实测。
默认同时写出 `ShellWasher_RBE2_Bolt_Chain_benchmark.json`，便于保存不同版本或不同机器的基准结果。

## HyperMesh 2019验证步骤

1. 在OptiStruct profile中导入 `ShellWasher_RBE2_Bolt_Chain.fem`。
2. 运行“Shell Washer孔 RBE2”，选择全部4个 `LARGE_SHELL_PLANE_*` 组件。
3. 确认识别并创建768个RBE2，记录识别与创建耗时。
4. 运行“RBE2 Bolt Connector”，选择上一步生成的RBE2组件。
5. 使用 `axisMode=AUTO`、`gapTol=100`、`offsetTol=5`、`elemType=CBEAM`。
6. 预期得到192个同轴组、576段相邻层bolt，每段长度20 mm。
7. 建议完整运行3到5次，比较每次实体数、拒绝数、总耗时和日志错误。

精确节点、单元、孔位和预期结果记录在 `ShellWasher_RBE2_Bolt_Chain_manifest.json`。该模型仅用于识别与创建流程验证，不是生产求解模型。

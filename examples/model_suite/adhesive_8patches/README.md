# Area Adhesive — Large Validation Model

## 用途
`Adhesive_8patches.fem` 用于 `adhesive_connector`（面/胶粘 1D 连接）的大规模验证：
4 块大板（2000x1200、10mm 网格，共约 9.6 万壳单元），板 A 顶面 10 条胶带。

## 场景（板 A 为 location，链路 = 板 B、C）
| 条目 | 内容 | 预期 |
|---|---|---|
| V01_PLATE_A_T1.5 | location 所在基板（z=0） | — |
| V02_PLATE_B_T1.5 / V03_PLATE_C_T1.5 | link 目标板（z=1/2，与 A 间隙 1~2mm，落于 A 投影内） | B、C 为 2 个 link |
| 8 条 `PATCH01..08` | 板 A 中共 B∩C 投影内的胶带 | 全部保留并 realize 成 RBE3+HEXA8 |
| 2 条 `OB01..02` | 板 A 右缘、部分伸出 B/C 投影的胶带 | 越界单元被投影清洗剔除 |

## 操作
1. 导入 `Adhesive_8patches.fem`。
2. "选择 location 单元"：框选板 A 上某条胶带所在壳单元；"选择目标组件"：选 B、C。
3. 执行创建：默认 tolerance=50；核对 8 条带内单元保留、realize 出 RBE3+HEXA8；
   对越界条带核对清洗日志（剔除伸出投影的单元）。

## 设计说明
- location 单元的面采样（4 角 + 形心）须逐点投影到**每个** link 组件的壳内
  （面内严格包含 + 沿法向距离 <= tolerance），否则整单元剔除。
- 板 B、C 相对于板 A 向内侧收拢，使板 A 右缘存在落在两者投影之外的条带。

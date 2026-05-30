# HyperMesh RBE2 Toolkit

面向 HyperMesh 2019 的 Tcl/Tk 脚本库，用于批量创建、整理和连接 RBE2 相关实体。

## 使用方式

在 HyperMesh 中通过 `File > Run > Tcl/Tk Script` 运行 `hw_toolkit.tcl`。入口脚本会加载 `modules/` 目录下的模块，并显示工具主界面。

## 目录结构

```text
.
├── hw_toolkit.tcl
└── modules/
    ├── auto_hole_rbe2.tcl
    ├── rbe2_bolt_connector.tcl
    └── shell_washer_hole_rbe2.tcl
```

## 模块说明

| 文件 | 命名空间/入口 | 作用 |
| --- | --- | --- |
| `hw_toolkit.tcl` | `::HWToolkit::run` | 创建主界面，按模块清单加载 `modules/*.tcl`，点击按钮后调用模块入口。 |
| `modules/auto_hole_rbe2.tcl` | `::AutoHoleRBE2::run` | 针对 3D solid component，生成自由面、识别圆柱贯通孔、创建中心节点和 RBE2/rigidlink。 |
| `modules/rbe2_bolt_connector.tcl` | `::RB2Bolt::run` | 读取 RBE2 独立节点，按 X/Y/Z 方向和容差分组，按相邻中心节点创建 CBEAM/CBAR 螺栓段。 |
| `modules/shell_washer_hole_rbe2.tcl` | `::RB2W::main` | 针对带标准垫圈网格的 shell component，识别圆形内自由边孔和第一圈垫圈节点，创建 RBE2 并归入输出 component。 |

## 当前注意点

- `hw_toolkit.tcl` 的模块清单中登记了 `midsurf`，但当前仓库还没有 `modules/midsurf.tcl`。在补齐该模块前，主入口加载模块时会提示缺少文件。
- 源文件包含中文界面文案，按 UTF-8 保存和编辑。
- 脚本依赖 HyperMesh Tcl 命令，普通 Tcl 解释器无法完整运行实际建模流程。
